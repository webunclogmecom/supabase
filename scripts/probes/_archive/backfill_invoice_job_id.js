// ============================================================================
// Backfill invoices.job_id from Jobber.
//
// Currently 96% of our invoices have job_id NULL even though Jobber knows the
// link. Root cause: the invoice handler in webhook-jobber receives invoice
// payload from Jobber but the job_id lookup might be failing OR the cron
// replay isn't passing the job context.
//
// This script:
//   1. Finds invoices in our DB with job_id IS NULL + Jobber source_id
//   2. Queries Jobber for each invoice's job.id
//   3. Looks up our internal job_id via entity_source_links
//   4. UPDATE invoices.job_id = matched
//
// Idempotent. Safe to re-run. Doesn't touch invoices that already have job_id.
//
// CLI:
//   node scripts/probes/backfill_invoice_job_id.js              # full
//   node scripts/probes/backfill_invoice_job_id.js --dry-run
//   node scripts/probes/backfill_invoice_job_id.js --limit=N
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const { gql, refreshAccessToken } = require('../sync/lib/jobber');
const https = require('https');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROD = process.env.SUPABASE_PROJECT_ID;
const DRY_RUN = process.argv.includes('--dry-run');
const limitArg = process.argv.find(a => a.startsWith('--limit='));
const LIMIT = limitArg ? parseInt(limitArg.split('=')[1], 10) : null;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }
async function rest(path, opts={}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  const r = await http({hostname: u.hostname, path: u.pathname + u.search, method: opts.method||'GET', headers: {apikey: SVC, Authorization: `Bearer ${SVC}`, 'Content-Type':'application/json', ...(opts.headers||{})}}, opts.body);
  if (r.status >= 300) throw new Error(`REST ${path}: ${r.status} ${r.body.slice(0,300)}`);
  return r.body ? JSON.parse(r.body) : null;
}

(async () => {
  console.log(`Mode: ${DRY_RUN ? 'DRY-RUN' : 'EXECUTE'}${LIMIT ? `  Limit: ${LIMIT}` : ''}`);

  console.log('\n[1/3] Finding invoices with job_id IS NULL + Jobber GID...');
  const candidates = await pg(`
    SELECT i.id AS invoice_id, i.invoice_number, esl.source_id AS invoice_gid
    FROM invoices i
    JOIN entity_source_links esl ON esl.entity_type='invoice' AND esl.entity_id=i.id AND esl.source_system='jobber'
    WHERE i.job_id IS NULL
    ORDER BY i.created_at DESC
    ${LIMIT ? `LIMIT ${LIMIT}` : ''};`);
  console.log(`  ${candidates.length} candidates`);

  console.log('\n[2/3] Caching job GID → job.id map...');
  const jobMap = {};
  const jobs = await pg(`SELECT esl.source_id AS gid, esl.entity_id AS internal_id FROM entity_source_links esl WHERE esl.entity_type='job' AND esl.source_system='jobber';`);
  for (const j of jobs) jobMap[j.gid] = j.internal_id;
  console.log(`  ${Object.keys(jobMap).length} jobs in our DB with Jobber GID`);

  await refreshAccessToken();
  console.log('\n[3/3] Querying Jobber per invoice + updating...');

  let updated = 0, jobberNullJob = 0, jobNotInDb = 0, errors = 0;
  let processed = 0;
  for (const inv of candidates) {
    processed++;
    if (processed % 100 === 0) console.log(`  ${processed}/${candidates.length}  updated=${updated} jobber_null=${jobberNullJob} not_in_db=${jobNotInDb} errors=${errors}`);
    try {
      const data = await gql(`
        query Q($id: EncodedId!) {
          invoice(id: $id) {
            jobs(first: 5) { nodes { id } }
            archivedJobs(first: 5) { nodes { id } }
            visits(first: 3) { nodes { job { id } } }
          }
        }`, { id: inv.invoice_gid });
      const inv2 = data.invoice;
      let jobGid = null;
      if (inv2?.jobs?.nodes?.length) jobGid = inv2.jobs.nodes[0].id;
      else if (inv2?.archivedJobs?.nodes?.length) jobGid = inv2.archivedJobs.nodes[0].id;
      else if (inv2?.visits?.nodes?.length) jobGid = inv2.visits.nodes.map(v => v?.job?.id).filter(Boolean)[0] || null;
      if (!jobGid) { jobberNullJob++; continue; }
      const ourJobId = jobMap[jobGid];
      if (!ourJobId) { jobNotInDb++; continue; }
      if (DRY_RUN) { updated++; continue; }
      await rest(`/invoices?id=eq.${inv.invoice_id}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ job_id: ourJobId }) });
      updated++;
    } catch (e) {
      errors++;
      if (errors <= 5) console.log(`  ✗ inv${inv.invoice_id}: ${e.message.slice(0,150)}`);
    }
  }

  console.log('\n=== SUMMARY ===');
  console.log(`  Candidates processed: ${processed}`);
  console.log(`  ✓ ${DRY_RUN ? 'Would update' : 'Updated'}: ${updated}`);
  console.log(`  ⚠ Jobber invoice has no job (legitimately job-less): ${jobberNullJob}`);
  console.log(`  ⚠ Job not yet synced to our DB: ${jobNotInDb}`);
  console.log(`  ✗ Errors: ${errors}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
