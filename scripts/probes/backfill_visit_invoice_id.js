// ============================================================================
// Backfill visits.invoice_id from Jobber's visit.invoice for visits where ours is NULL.
//
// Root cause: cron_jobber polls visits by completedAt cursor. Once a visit is
// completed, its completedAt doesn't change again. If Jobber adds an invoice
// link AFTER the visit was last polled, our visit.invoice_id never updates.
//
// This script:
//   1. Finds all visits in our DB with invoice_id IS NULL
//   2. For each, looks up the visit's Jobber GID
//   3. Queries Jobber for visit { invoice { id } }
//   4. If Jobber returns an invoice GID, looks up our invoices.id via entity_source_links
//   5. UPDATEs visits.invoice_id = matched_invoice_id
//   6. Reports fixed / no-jobber-invoice / errors
//
// Idempotent: only touches NULL rows. Safe to re-run.
//
// CLI:
//   node scripts/probes/backfill_visit_invoice_id.js              # full run
//   node scripts/probes/backfill_visit_invoice_id.js --dry-run    # report only, no writes
//   node scripts/probes/backfill_visit_invoice_id.js --limit=50   # cap iterations
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

  // 1. Find candidates
  console.log('\n[1/3] Finding visits with NULL invoice_id + linked Jobber GID...');
  const candidates = await pg(`
    SELECT v.id AS visit_id, v.visit_date::text, v.job_id, esl.source_id AS visit_gid, c.client_code, v.title
    FROM visits v
    LEFT JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    LEFT JOIN clients c ON c.id = v.client_id
    WHERE v.invoice_id IS NULL
      AND esl.source_id IS NOT NULL
      AND v.visit_status = 'completed'
    ORDER BY v.visit_date DESC
    ${LIMIT ? `LIMIT ${LIMIT}` : ''};`);
  console.log(`  ${candidates.length} candidate visits`);

  // 2. Pre-cache invoice GID → internal id map
  console.log('\n[2/3] Caching invoice GID → invoice.id map...');
  const invMap = {};
  const invs = await pg(`SELECT esl.source_id AS gid, esl.entity_id AS internal_id FROM entity_source_links esl WHERE esl.entity_type='invoice' AND esl.source_system='jobber';`);
  for (const i of invs) invMap[i.gid] = i.internal_id;
  console.log(`  ${Object.keys(invMap).length} invoices in our DB with Jobber GID`);

  // 3. Refresh Jobber token
  await refreshAccessToken();
  console.log('\n[3/3] Querying Jobber per visit + updating...');

  let updated = 0, jobberNullInvoice = 0, invoiceNotInDb = 0, errors = 0;
  let processed = 0;
  for (const v of candidates) {
    processed++;
    if (processed % 25 === 0) console.log(`  ${processed}/${candidates.length}  updated=${updated} jobber_null=${jobberNullInvoice} not_in_db=${invoiceNotInDb} errors=${errors}`);
    try {
      const data = await gql(`query Q($id: EncodedId!) { visit(id: $id) { invoice { id } } }`, { id: v.visit_gid });
      const invGid = data.visit?.invoice?.id;
      if (!invGid) { jobberNullInvoice++; continue; }
      const ourInvId = invMap[invGid];
      if (!ourInvId) { invoiceNotInDb++; continue; }
      if (DRY_RUN) { updated++; continue; }
      await rest(`/visits?id=eq.${v.visit_id}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ invoice_id: ourInvId }) });
      updated++;
    } catch (e) { errors++; console.log(`  ✗ v${v.visit_id}: ${e.message.slice(0,150)}`); }
  }

  console.log('\n=== SUMMARY ===');
  console.log(`  Candidates processed: ${processed}`);
  console.log(`  ✓ ${DRY_RUN ? 'Would update' : 'Updated'}: ${updated}`);
  console.log(`  ⚠ Jobber visit has no invoice (legitimately uninvoiced): ${jobberNullInvoice}`);
  console.log(`  ⚠ Invoice not yet synced to our DB: ${invoiceNotInDb}`);
  console.log(`  ✗ Errors: ${errors}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
