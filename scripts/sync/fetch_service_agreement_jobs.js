// fetch_service_agreement_jobs.js
// FETCH step (Jobber -> DB) of the Service Agreement visit-generation pipeline.
// Spec: Supabase/docs/service-agreement-visit-generation.md (§9).
//
// For active jobs titled "Service Agreement ..." (scoped to one client; default 112-YA),
// pull the "Frequency" numeric custom field + line items from Jobber and save to our DB:
//   - public.jobs.frequency_days   (the recurring interval, in days)
//   - public.line_items            (job-level rows; idempotent delete+insert)
// The Calendar app is the source of truth for visits; the generator reads this DB config,
// NOT Jobber live. Jobber stays decoupled (no native recurrence / no Jobber-generated visits).
//
// Usage: node scripts/sync/fetch_service_agreement_jobs.js [--client=112-YA] [--execute]
//   default: DRY-RUN, client 112-YA.

const https = require('https');
const fs = require('fs');
const path = require('path');
const { getValidToken } = require('./jobber_token');

function readEnv(k) {
  const p = path.resolve(__dirname, '../../.env');
  const l = fs.readFileSync(p, 'utf8').split(/\r?\n/).find(x => x.startsWith(k + '='));
  return l ? l.slice(k.length + 1).trim() : null;
}
const SUPABASE_URL = readEnv('SUPABASE_URL');
const SERVICE_KEY = readEnv('SUPABASE_SERVICE_ROLE_KEY');

const args = process.argv.slice(2);
const EXECUTE = args.includes('--execute');
const clientArg = (args.find(a => a.startsWith('--client=')) || '--client=112-YA').split('=')[1];

function rest(qs, opts = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(`${SUPABASE_URL}/rest/v1/${qs}`);
    const body = opts.body || null;
    const req = https.request({ hostname: u.hostname, path: u.pathname + u.search, method: opts.method || 'GET',
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json', 'X-App-Source': 'sql',
        ...(opts.headers || {}), ...(body ? { 'Content-Length': Buffer.byteLength(body) } : {}) } },
      r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { if (r.statusCode >= 300) return reject(new Error(`REST ${r.statusCode} ${d.slice(0, 300)}`)); resolve(d ? JSON.parse(d) : null); }); });
    req.on('error', reject); if (body) req.write(body); req.end();
  });
}
function gql(token, query) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query });
    const req = https.request({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
      headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Length': Buffer.byteLength(body) } },
      r => { let d = ''; r.on('data', c => d += c); r.on('end', () => { try { resolve(JSON.parse(d)); } catch (e) { reject(new Error('parse ' + r.statusCode)); } }); });
    req.on('error', reject); req.setTimeout(30000, () => req.destroy(new Error('timeout'))); req.write(body); req.end();
  });
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
async function gqlRetry(token, q, label) {
  for (let a = 1; a <= 6; a++) {
    const r = await gql(token, q);
    if (r.errors && r.errors[0] && r.errors[0].extensions && r.errors[0].extensions.code === 'THROTTLED') { const w = 3 * a; console.log(`  throttled ${label} ${a}, sleep ${w}s`); await sleep(w * 1000); continue; }
    return r;
  }
  return { errors: [{ message: 'throttled-out' }] };
}
const isServiceAgreement = title => /^\s*service agreement\b/i.test(title || '');

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'} | client: ${clientArg}\n`);
  const token = await getValidToken();

  // 1. Resolve client + Jobber GID + job GID->dbId map
  const clients = await rest(`clients?client_code=eq.${encodeURIComponent(clientArg)}&select=id,client_code,name`);
  if (!clients || !clients.length) { console.error(`client ${clientArg} not found`); process.exit(1); }
  const client = clients[0];
  const cLink = await rest(`entity_source_links?entity_type=eq.client&source_system=eq.jobber&entity_id=eq.${client.id}&select=source_id`);
  const clientGid = cLink && cLink[0] && cLink[0].source_id;
  if (!clientGid) { console.error(`no Jobber GID for client ${clientArg}`); process.exit(1); }
  const jobLinks = await rest(`entity_source_links?entity_type=eq.job&source_system=eq.jobber&select=entity_id,source_id`);
  const jobIdByGid = Object.fromEntries((jobLinks || []).map(r => [r.source_id, r.entity_id]));

  // 2. Two-phase pull to stay under Jobber's cost-based rate limit:
  //    (a) cheap job list to find the Service Agreement jobs, then
  //    (b) one small per-job detail query for custom fields + line items.
  //    (A single client->jobs(50)+lineItems(40) query exceeds the per-query cost ceiling.)
  const listQ = `{ client(id:"${clientGid}") { name jobs(first:30) { nodes { id jobNumber jobStatus title } } } }`;
  const lr = await gqlRetry(token, listQ, 'jobs-list');
  if (lr.errors) { console.error('Jobber error (list):', JSON.stringify(lr.errors).slice(0, 300)); process.exit(1); }
  const jobsList = (lr.data && lr.data.client && lr.data.client.jobs && lr.data.client.jobs.nodes) || [];
  const saList = jobsList.filter(j => j.jobStatus !== 'archived' && isServiceAgreement(j.title));
  console.log(`${client.client_code} ${client.name}: ${jobsList.length} jobs total, ${saList.length} active "Service Agreement"\n`);

  const saJobs = [];
  for (const jb of saList) {
    await sleep(1500);
    const dq = `{ job(id:"${jb.id}") {
        id jobNumber jobStatus title
        customFields { __typename ... on CustomFieldNumeric { label valueNumeric unit } }
        lineItems(first:30) { nodes { name description quantity unitCost totalPrice } }
    } }`;
    const dr = await gqlRetry(token, dq, 'detail #' + jb.jobNumber);
    if (dr.errors || !dr.data || !dr.data.job) { console.error(`  detail error #${jb.jobNumber}: ${JSON.stringify(dr.errors || 'no data').slice(0, 200)}`); continue; }
    saJobs.push(dr.data.job);
  }

  let updated = 0, itemsWritten = 0, skipped = 0;
  for (const j of saJobs) {
    const freqCf = (j.customFields || []).find(c => /frequency/i.test(c.label || ''));
    const freq = freqCf && freqCf.valueNumeric != null ? Math.round(freqCf.valueNumeric) : null;
    const items = (j.lineItems && j.lineItems.nodes) || [];
    const ourJobId = jobIdByGid[j.id];
    console.log(`#${j.jobNumber} "${j.title}" [${j.jobStatus}] freq=${freq} days | items=${items.length} | dbJob=${ourJobId || 'NOT-SYNCED'}`);
    items.forEach(it => console.log(`     - ${it.name}`));
    if (!ourJobId) { console.log('     !! job not in our DB (entity_source_links) — skipping writes'); skipped++; continue; }
    if (!EXECUTE) continue;

    // 3a. jobs.frequency_days
    await rest(`jobs?id=eq.${ourJobId}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify({ frequency_days: freq }) });
    updated++;
    // 3b. line_items — job-level rows only (invoice_id IS NULL), idempotent delete+insert
    await rest(`line_items?job_id=eq.${ourJobId}&invoice_id=is.null`, { method: 'DELETE', headers: { Prefer: 'return=minimal' } });
    if (items.length) {
      const rows = items.map(it => ({ job_id: ourJobId, name: it.name || null, description: it.description || null, quantity: it.quantity != null ? it.quantity : null, unit_price: it.unitCost != null ? it.unitCost : null, total_price: it.totalPrice != null ? it.totalPrice : null }));
      await rest('line_items', { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify(rows) });
      itemsWritten += rows.length;
    }
  }
  console.log(`\n=== ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'} === jobs updated: ${updated} | line items written: ${itemsWritten} | skipped(no DB job): ${skipped}`);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
