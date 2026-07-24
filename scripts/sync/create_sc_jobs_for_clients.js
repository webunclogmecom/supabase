// ============================================================================
// create_sc_jobs_for_clients.js — create the canonical "Service Call" container
// job in Jobber for a given list of client codes that are missing an OPEN one.
//
// Generalizes create_missing_sc_jobs.js (which hardcoded 5 clients + property GIDs)
// by RESOLVING each client's Jobber client GID + a real service-property GID from
// our DB (entity_source_links), so it works for any client with a synced job whose
// property has a Jobber GID. Prefers a non-archived job's property, newest first.
//
// SC structure = the verified canonical one (001-VIN #99900563 / 010-CS #99900574):
// title "Service Call", invoicing VISIT_BASED / PER_VISIT, anchored to the property,
// no line items. Idempotent: skips a client that already has an OPEN (non-archived)
// "Service Call". Uses the jobber_write OAuth token. Dry-run by default.
//
//   node scripts/sync/create_sc_jobs_for_clients.js 076-TCE 056-STM 089-COW            # dry-run
//   node scripts/sync/create_sc_jobs_for_clients.js 076-TCE 056-STM 089-COW --execute  # create
// ============================================================================
const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true, quiet: true }); } catch (_) {}
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
const EXECUTE = process.argv.includes('--execute');
const CODES = process.argv.slice(2).filter(a => a !== '--execute');
if (!CODES.length) { console.error('Usage: node create_sc_jobs_for_clients.js <code> [<code>...] [--execute]'); process.exit(2); }
const qv = v => v == null ? 'NULL' : "'" + String(v).replace(/'/g, "''") + "'";

function sql(query) { return new Promise((res, rej) => { const b = JSON.stringify({ query }); const r = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { if (x.statusCode >= 300) return rej(new Error(x.statusCode + ': ' + d.slice(0, 300))); res(JSON.parse(d)); }); }); r.on('error', rej); r.write(b); r.end(); }); }
function gql(token, query, variables) { return new Promise((res, rej) => { const b = JSON.stringify({ query, variables }); const r = https.request({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Length': Buffer.byteLength(b) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { try { res({ status: x.statusCode, json: JSON.parse(d) }); } catch (e) { res({ status: x.statusCode, json: { parseError: d.slice(0, 200) } }); } }); }); r.on('error', rej); r.write(b); r.end(); }); }

async function getToken(force) {
  const rows = await sql(`SELECT access_token, refresh_token, client_id, client_secret, expires_at FROM public.webhook_tokens WHERE source_system='jobber_write'`);
  const t = rows[0];
  if (!force && new Date(t.expires_at).getTime() > Date.now() + 60000) return t.access_token;
  const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(t.refresh_token)}&client_id=${encodeURIComponent(t.client_id)}&client_secret=${encodeURIComponent(t.client_secret)}`;
  const r = await new Promise((res, rej) => { const rq = https.request({ hostname: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => res({ status: x.statusCode, body: d })); }); rq.on('error', rej); rq.write(body); rq.end(); });
  if (r.status >= 300) throw new Error('token refresh failed ' + r.status + ': ' + r.body.slice(0, 120));
  const j = JSON.parse(r.body); const exp = JSON.parse(Buffer.from(j.access_token.split('.')[1], 'base64').toString()).exp * 1000;
  await sql(`UPDATE public.webhook_tokens SET access_token=${qv(j.access_token)}, refresh_token=${qv(j.refresh_token || t.refresh_token)}, expires_at=${qv(new Date(exp).toISOString())}, updated_at=now() WHERE source_system='jobber_write'`);
  return j.access_token;
}

async function existingOpenSC(token, clientGid) {
  const r = await gql(token, `{ client(id:"${clientGid}"){ jobs(first:60){ nodes{ jobNumber title jobStatus } } } }`);
  const jobs = r.json?.data?.client?.jobs?.nodes || [];
  return jobs.filter(j => /^\s*service call\s*$/i.test(j.title) && String(j.jobStatus).toLowerCase() !== 'archived');
}

async function resolveTargets(codes) {
  const inList = codes.map(qv).join(',');
  const rows = await sql(`
    SELECT c.client_code, c.name, c.status,
      (SELECT source_id FROM public.entity_source_links WHERE entity_type='client' AND source_system='jobber' AND entity_id=c.id) AS client_gid,
      (SELECT e.source_id FROM public.jobs j
         JOIN public.entity_source_links e ON e.entity_type='property' AND e.source_system='jobber' AND e.entity_id=j.property_id
         WHERE j.client_id=c.id AND e.source_id IS NOT NULL
         ORDER BY (COALESCE(j.job_status,'') NOT ILIKE '%archived%') DESC, j.id DESC LIMIT 1) AS prop_gid
    FROM public.clients c WHERE c.client_code IN (${inList})`);
  return rows;
}

(async () => {
  let token = await getToken(false);
  const targets = await resolveTargets(CODES);
  const M = `mutation($input: JobCreateAttributes!){ jobCreate(input:$input){ job{ id jobNumber title jobType } userErrors{ message path } } }`;
  const results = [];
  console.log(`MODE=${EXECUTE ? 'EXECUTE' : 'DRY-RUN'} — ${targets.length} client(s)\n`);
  for (const code of CODES) {
    const t = targets.find(x => x.client_code === code);
    if (!t) { console.log(`  ${code}: SKIP — no DB row`); results.push({ code, status: 'skip_no_row' }); continue; }
    if (!t.client_gid) { console.log(`  ${code}: SKIP — no Jobber client GID`); results.push({ code, status: 'skip_no_client_gid' }); continue; }
    if (!t.prop_gid) { console.log(`  ${code}: SKIP — no resolvable Jobber property GID (needs a real property)`); results.push({ code, status: 'skip_no_property' }); continue; }
    const dup = await existingOpenSC(token, t.client_gid);
    if (dup.length) { console.log(`  ${code}: SKIP — already has open Service Call #${dup.map(d => d.jobNumber).join(',')}`); results.push({ code, status: 'skip_exists' }); continue; }
    const input = { propertyId: t.prop_gid, invoicing: { invoicingType: 'VISIT_BASED', invoicingSchedule: 'PER_VISIT' }, title: 'Service Call' };
    if (!EXECUTE) { console.log(`  ${code} (${t.name}): would create Service Call on property …${t.prop_gid.slice(-10)}`); results.push({ code, status: 'would_create' }); continue; }
    let r; try { r = await gql(token, M, { input }); } catch (e) { r = { status: 0, json: { netError: String(e.message) } }; }
    if (r.status === 401) { token = await getToken(true); r = await gql(token, M, { input }); }
    const jc = r.json?.data?.jobCreate; const ue = (jc?.userErrors || []).map(e => e.message).join('; ');
    if (jc?.job && !ue) { console.log(`  ${code}: CREATED #${jc.job.jobNumber} "${jc.job.title}" (${jc.job.jobType})`); results.push({ code, status: 'ok', jobNumber: jc.job.jobNumber, gid: jc.job.id }); }
    else { console.log(`  ${code}: ERROR ${ue || r.json.netError || ('http ' + r.status)}`); results.push({ code, status: 'error', err: ue || r.json.netError }); }
    await new Promise(s => setTimeout(s, 800));
  }
  const ok = results.filter(r => r.status === 'ok').length, fail = results.filter(r => r.status === 'error').length, skip = results.filter(r => String(r.status).startsWith('skip')).length;
  if (EXECUTE) {
    await sql(`INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_updated, rows_errored, status, details)
      VALUES ('create_sc_jobs_for_clients', now(), now(), ${ok}, ${fail}, ${qv(fail ? 'partial' : 'success')}, ${qv(JSON.stringify(results))}::jsonb)`).catch(() => {});
  }
  console.log(`\nDONE: created ${ok}, failed ${fail}, skipped ${skip}${EXECUTE ? '' : ' (dry-run — re-run with --execute)'}`);
  if (fail) console.log('errors: ' + JSON.stringify(results.filter(r => r.status === 'error')));
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
