// ============================================================================
// create_missing_sc_jobs.js — create the canonical "Service Call" container job
// in Jobber for a specific set of clients that are missing one, reusing the real
// Jobber Property GID from one of the client's existing jobs.
//
// Why a focused script (not jobber_create_canonical_jobs.js): these clients have
// only a synthetic `<client>_billing` pseudo-property in our DB, so the canonical
// script's isRealPropertyGid() filter skips them. The real service-property GID
// only lives in Jobber (read off each client's existing job) — hardcoded below,
// resolved 2026-07-02 via job->property lookups (see scripts/probes/_prop_by_client.json).
//
// SC structure matches existing Service Call jobs verified live (001-VIN #99900563,
// 010-CS #99900574): title "Service Call", RECURRING, no line items, total 0,
// invoicing VISIT_BASED / PER_VISIT, anchored to the property.
//
// Idempotent: before creating, re-checks Jobber for an existing open (non-archived,
// non-[OLD]) "Service Call" on that client and SKIPS if present. Dry-run by default.
//
//   node scripts/sync/create_missing_sc_jobs.js            # dry-run
//   node scripts/sync/create_missing_sc_jobs.js --execute  # create
// ============================================================================
const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true, quiet: true }); } catch (_) {}
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
const EXECUTE = process.argv.includes('--execute');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const q = v => v == null ? 'NULL' : "'" + String(v).replace(/'/g, "''") + "'";

// 4 clients missing a current Service Call, with the real Jobber property GID read
// off an existing job (220-WYN "Pari Pari" is intentionally EXCLUDED — it has no
// property/job in Jobber, so a Service Call job cannot be anchored until a property
// is created; flagged to Fred separately).
const TARGETS = [
  { client_code: '233-AH',  client_gid: 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xNDI0ODI2MTQ=', propGid: 'Z2lkOi8vSm9iYmVyL1Byb3BlcnR5LzE0ODk2OTczNA==' },
  { client_code: '234-PV',  client_gid: 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xNDI1NTM0OTQ=', propGid: 'Z2lkOi8vSm9iYmVyL1Byb3BlcnR5LzE0OTA0NjgxMA==' },
  { client_code: '243-FE',  client_gid: 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xNDQ4MjkxMDk=', propGid: 'Z2lkOi8vSm9iYmVyL1Byb3BlcnR5LzE1MTI4OTM3NQ==' },
  { client_code: '244-URI', client_gid: 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xNDUwMTMwMDg=', propGid: 'Z2lkOi8vSm9iYmVyL1Byb3BlcnR5LzE1MTQ4MTg0MQ==' },
];

function sql(query) { return new Promise((res, rej) => { const b = JSON.stringify({ query }); const r = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { if (x.statusCode >= 300) return rej(new Error(x.statusCode + ': ' + d.slice(0, 300))); res(JSON.parse(d)); }); }); r.on('error', rej); r.write(b); r.end(); }); }
function gql(token, query, variables) { return new Promise((res, rej) => { const b = JSON.stringify({ query, variables }); const r = https.request({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Length': Buffer.byteLength(b) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { try { res({ status: x.statusCode, json: JSON.parse(d) }); } catch (e) { res({ status: x.statusCode, json: { parseError: d.slice(0, 200) } }); } }); }); r.on('error', rej); r.write(b); r.end(); }); }

async function getToken(force) {
  const rows = await sql(`SELECT access_token, refresh_token, client_id, client_secret, expires_at FROM public.webhook_tokens WHERE source_system='jobber_write'`);
  const t = rows[0];
  if (!force && new Date(t.expires_at).getTime() > Date.now() + 120000) return t.access_token;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(t.refresh_token)}&client_id=${encodeURIComponent(t.client_id)}&client_secret=${encodeURIComponent(t.client_secret)}`;
  const r = await new Promise((res, rej) => { const rq = https.request({ hostname: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => res({ status: x.statusCode, body: d })); }); rq.on('error', rej); rq.write(body); rq.end(); });
  if (r.status >= 300) throw new Error('token refresh failed ' + r.status + ': ' + r.body.slice(0, 120));
  const j = JSON.parse(r.body);
  const exp = JSON.parse(Buffer.from(j.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await sql(`UPDATE public.webhook_tokens SET access_token=${q(j.access_token)}, refresh_token=${q(j.refresh_token || t.refresh_token)}, expires_at=${q(new Date(exp).toISOString())}, updated_at=now() WHERE source_system='jobber_write'`);
  return j.access_token;
}

async function existingOpenSC(token, clientGid) {
  const r = await gql(token, `{ client(id:"${clientGid}"){ jobs(first:60){ nodes{ jobNumber title jobStatus } } } }`);
  const jobs = (r.json?.data?.client?.jobs?.nodes) || [];
  return jobs.filter(j => /^\s*service call\s*$/i.test(j.title) && String(j.jobStatus).toLowerCase() !== 'archived');
}

(async () => {
  const started = new Date().toISOString();
  console.log(`MODE: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}   targets: ${TARGETS.map(t => t.client_code).join(', ')}`);
  let token = await getToken();
  const M = `mutation($input: JobCreateAttributes!){ jobCreate(input:$input){ job{ id jobNumber title jobType } userErrors{ message path } } }`;
  const results = [];
  for (const t of TARGETS) {
    const dup = await existingOpenSC(token, t.client_gid);
    if (dup.length) { console.log(`  ${t.client_code}: SKIP — already has open Service Call #${dup.map(d => d.jobNumber).join(',')}`); results.push({ ...t, status: 'skip_exists' }); continue; }
    const input = { propertyId: t.propGid, invoicing: { invoicingType: 'VISIT_BASED', invoicingSchedule: 'PER_VISIT' }, title: 'Service Call' };
    if (!EXECUTE) { console.log(`  ${t.client_code}: would create Service Call on property ${t.propGid.slice(-12)}…`); results.push({ ...t, status: 'would_create' }); continue; }
    let r; try { r = await gql(token, M, { input }); } catch (e) { r = { status: 0, json: { netError: String(e.message) } }; }
    if (r.status === 401) { token = await getToken(true); r = await gql(token, M, { input }); }
    const jc = r.json?.data?.jobCreate;
    const ue = jc?.userErrors?.length ? JSON.stringify(jc.userErrors) : null;
    const gqlErr = r.json?.errors ? JSON.stringify(r.json.errors).slice(0, 200) : null;
    if (jc?.job && !ue) { console.log(`  ${t.client_code}: CREATED #${jc.job.jobNumber} "${jc.job.title}" (${jc.job.jobType})`); results.push({ ...t, status: 'ok', jobNumber: jc.job.jobNumber, gid: jc.job.id }); }
    else { console.log(`  ${t.client_code}: ERROR ${ue || gqlErr || r.json.netError || ('http ' + r.status)}`); results.push({ ...t, status: 'error', err: ue || gqlErr || r.json.netError }); }
    await sleep(400);
  }
  if (EXECUTE) {
    const ok = results.filter(r => r.status === 'ok').length, fail = results.filter(r => r.status === 'error').length;
    await sql(`INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_updated, rows_errored, status, details)
      VALUES ('create_missing_sc_jobs', ${q(started)}, now(), ${ok}, ${fail}, ${fail ? "'partial'" : "'success'"}, ${q(JSON.stringify(results))})`);
    console.log(`\nDONE: created ${ok}, failed ${fail}, skipped ${results.filter(r => r.status === 'skip_exists').length}`);
  } else console.log('\nDry-run only. Re-run with --execute to create.');
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
