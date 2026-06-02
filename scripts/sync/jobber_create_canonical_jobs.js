// ============================================================================
// jobber_create_canonical_jobs.js
// Pre-create canonical container jobs ("Service Agreement" + "Service Call") in
// Jobber for every ACTIVE/RECURRING client that is missing them (case-insensitive,
// trimmed match against our synced jobs mirror). These container jobs hold the
// Calendar's scheduled visits; the visit's Service type + Detail live on the visit.
//
//   jobCreate(input:{ propertyId, invoicing:{invoicingType:VISIT_BASED,
//                     invoicingSchedule:PER_VISIT}, title })
//
// Dry-run by default (prints the plan, writes nothing). Pass --execute to create.
// Idempotent: re-reads who's missing from the DB each run (webhooks backfill new
// jobs), and skips clients already having the canonical job. Respects Jobber's
// GraphQL cost throttle. Logs per-job results + a sync_log summary.
//
//   node scripts/sync/jobber_create_canonical_jobs.js            # dry-run
//   node scripts/sync/jobber_create_canonical_jobs.js --execute  # create
// ============================================================================
const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true, quiet: true }); } catch (_) {}
const PAT = process.env.SUPABASE_PAT;
const ref = process.env.SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
const EXECUTE = process.argv.includes('--execute');
const CANON = ['Service Agreement', 'Service Call'];
const sleep = ms => new Promise(r => setTimeout(r, ms));

function sql(q) { return new Promise((res, rej) => { const b = JSON.stringify({ query: q }); const r = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query', method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { if (x.statusCode >= 300) return rej(new Error(x.statusCode + ': ' + d.slice(0, 300))); res(JSON.parse(d)); }); }); r.on('error', rej); r.write(b); r.end(); }); }
function gql(token, query, variables) { return new Promise((res, rej) => { const b = JSON.stringify({ query, variables }); const r = https.request({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Length': Buffer.byteLength(b) } }, x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { try { res({ status: x.statusCode, json: JSON.parse(d) }); } catch (e) { res({ status: x.statusCode, json: { parseError: d.slice(0, 200) } }); } }); }); r.on('error', rej); r.write(b); r.end(); }); }
const q = v => v == null ? 'NULL' : "'" + String(v).replace(/'/g, "''") + "'";

// decode a Jobber base64 gid and check it is a real Property gid
function isRealPropertyGid(gid) {
  try { return Buffer.from(gid, 'base64').toString().startsWith('gid://Jobber/Property/'); } catch (_) { return false; }
}

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

async function buildPlan() {
  const rows = await sql(`
    WITH ac AS (SELECT id, client_code FROM public.clients WHERE status IN ('ACTIVE','RECURRING')),
    jci AS (SELECT client_id,
        bool_or(lower(btrim(title))='service agreement') has_sa,
        bool_or(lower(btrim(title))='service call') has_sc
        FROM public.jobs GROUP BY client_id),
    cg AS (SELECT entity_id, source_id FROM public.entity_source_links WHERE entity_type='client' AND source_system='jobber'),
    props AS (SELECT p.client_id,
        json_agg(json_build_object('gid', e.source_id, 'primary', p.is_primary, 'billing', p.is_billing) ORDER BY p.is_primary DESC NULLS LAST) gids
        FROM public.properties p
        JOIN public.entity_source_links e ON e.entity_type='property' AND e.entity_id=p.id AND e.source_system='jobber'
        GROUP BY p.client_id)
    SELECT ac.client_code, ac.id AS client_id, cg.source_id AS client_gid,
      COALESCE(jci.has_sa,false) AS has_sa, COALESCE(jci.has_sc,false) AS has_sc, props.gids
    FROM ac
    LEFT JOIN jci ON jci.client_id=ac.id
    LEFT JOIN cg ON cg.entity_id=ac.id
    LEFT JOIN props ON props.client_id=ac.id
    ORDER BY ac.client_code`);
  const plan = [], noProp = [];
  for (const r of rows) {
    const gids = (r.gids || []).map(g => g.gid).filter(isRealPropertyGid);
    const propGid = gids[0] || null;
    const missing = [];
    if (!r.has_sa) missing.push('Service Agreement');
    if (!r.has_sc) missing.push('Service Call');
    if (!missing.length) continue;
    if (!propGid) { noProp.push({ client_code: r.client_code, missing }); continue; }
    for (const title of missing) plan.push({ client_code: r.client_code, propGid, title });
  }
  return { plan, noProp, totalClients: rows.length };
}

(async () => {
  const started = new Date().toISOString();
  let { plan, noProp, totalClients } = await buildPlan();
  let prevOk = [];
  try { const prev = JSON.parse(require('fs').readFileSync(require('path').resolve(__dirname, '../../jobber_canonical_jobs_results.json'), 'utf8')); prevOk = prev.filter(r => r.status === 'ok'); const done = new Set(prevOk.map(r => r.propGid + '|' + r.title)); const before = plan.length; plan = plan.filter(p => !done.has(p.propGid + '|' + p.title)); if (before !== plan.length) console.log('excluded ' + (before - plan.length) + ' already-created (prior results file)'); } catch (_) {}
  const bySa = plan.filter(p => p.title === 'Service Agreement').length;
  const bySc = plan.filter(p => p.title === 'Service Call').length;
  console.log(`MODE: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}`);
  console.log(`active/recurring clients: ${totalClients}`);
  console.log(`jobs to create: ${plan.length}  (Service Agreement: ${bySa}, Service Call: ${bySc})`);
  console.log(`clients skipped (no real Jobber property gid): ${noProp.length}${noProp.length ? ' -> ' + noProp.map(n => n.client_code).join(', ') : ''}`);
  console.log('sample (first 8):'); console.log(JSON.stringify(plan.slice(0, 8), null, 1));
  if (!EXECUTE) { console.log('\nDry-run only. Re-run with --execute to create.'); return; }

  let token = await getToken();
  const M = `mutation($input: JobCreateAttributes!){ jobCreate(input:$input){ job{ id jobNumber title } userErrors{ message path } } }`;
  const results = []; let ok = 0, fail = 0;
  for (let i = 0; i < plan.length; i++) {
    const p = plan[i];
    const input = { propertyId: p.propGid, invoicing: { invoicingType: 'VISIT_BASED', invoicingSchedule: 'PER_VISIT' }, title: p.title };
    let r;
    try { r = await gql(token, M, { input }); } catch (e) { r = { status: 0, json: { netError: String(e.message) } }; }
    if (r.status === 401) { token = await getToken(true); try { r = await gql(token, M, { input }); } catch (e) { r = { status: 0, json: { netError: String(e.message) } }; } }
    const jc = r.json && r.json.data && r.json.data.jobCreate;
    const ue = jc && jc.userErrors && jc.userErrors.length ? JSON.stringify(jc.userErrors) : null;
    const gqlErr = r.json && r.json.errors ? JSON.stringify(r.json.errors).slice(0, 160) : null;
    if (jc && jc.job && !ue) { ok++; results.push({ ...p, gid: jc.job.id, jobNumber: jc.job.jobNumber, status: 'ok' }); }
    else { fail++; results.push({ ...p, status: 'error', err: ue || gqlErr || r.json.netError || ('http ' + r.status) }); }
    if ((i + 1) % 25 === 0 || i === plan.length - 1) console.log(`  ${i + 1}/${plan.length}  ok=${ok} fail=${fail}`);
    // throttle: back off if cost budget is getting low
    const avail = r.json && r.json.extensions && r.json.extensions.cost && r.json.extensions.cost.throttleStatus && r.json.extensions.cost.throttleStatus.currentlyAvailable;
    if (typeof avail === 'number' && avail < 1500) await sleep(1200); else await sleep(70);
  }
  require('fs').writeFileSync(require('path').resolve(__dirname, '../../jobber_canonical_jobs_results.json'), JSON.stringify([...prevOk, ...results], null, 1));
  console.log(`\nDONE: created ${ok}, failed ${fail}. Results -> jobber_canonical_jobs_results.json`);
  if (fail) console.log('first errors:', JSON.stringify(results.filter(r => r.status === 'error').slice(0, 5), null, 1));
  await sql(`INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_updated, rows_errored, status, details)
    VALUES ('jobber_create_canonical_jobs', ${q(started)}, now(), ${ok}, ${fail}, ${fail ? "'partial'" : "'success'"}, ${q(JSON.stringify({ created: ok, failed: fail, noProp: noProp.map(n => n.client_code) }))})`);
})().catch(e => { console.error('FATAL', e.message); process.exit(1); });
