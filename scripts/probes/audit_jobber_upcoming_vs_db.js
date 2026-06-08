// ============================================================================
// audit_jobber_upcoming_vs_db.js — standing reconciliation MONITOR
// ============================================================================
// Compares Jobber's upcoming (materialized, startAt>=today) visits to our DB and
// reports any that are in Jobber's schedule but NOT in our DB. READ-ONLY — it
// never writes; it just answers "is our DB in sync with Jobber's upcoming schedule
// right now?". Exits non-zero when a gap exists, so it can run as a CI/cron alert.
//
// This is the "prove it's working" check for the no-real-time-webhook gap: the
// upcoming-sync cron (every 15 min) ingests + self-verifies, and THIS probe is the
// independent watchdog. If it ever reports a gap, the pipeline fell behind.
//
//   node scripts/probes/audit_jobber_upcoming_vs_db.js
//
// Required env (process.env or ../../.env): SUPABASE_URL, SUPABASE_PAT.
// ============================================================================
const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true }); } catch (_) {}
const SUPABASE_URL = process.env.SUPABASE_URL, PAT = process.env.SUPABASE_PAT;
if (!SUPABASE_URL || !PAT) throw new Error('SUPABASE_URL and SUPABASE_PAT required');
const projectRef = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];
const EXCLUDED_CLIENT_GIDS = new Set(['Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=']); // 112-YA test account

function request({ host, path, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({ hostname: host, path, method, headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) } },
      (res) => { let d = ''; res.on('data', c => d += c); res.on('end', () => resolve({ status: res.statusCode, body: d })); });
    req.on('error', reject); req.setTimeout(60000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload); req.end();
  });
}
async function execSql(sql) {
  const r = await request({ host: 'api.supabase.com', path: `/v1/projects/${projectRef}/database/query`, method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${PAT}` }, body: JSON.stringify({ query: sql }) });
  if (r.status >= 300) throw new Error(`SQL ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}
async function gql(token, query) {
  const r = await request({ host: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' }, body: JSON.stringify({ query }) });
  if (r.status >= 300) throw new Error(`GraphQL ${r.status}: ${r.body.slice(0, 200)}`);
  const j = JSON.parse(r.body); if (j.errors?.length) throw new Error(JSON.stringify(j.errors).slice(0, 250)); return j.data;
}

(async () => {
  const token = (await execSql(`SELECT access_token FROM public.webhook_tokens WHERE source_system='jobber' LIMIT 1`))[0].access_token;
  const today = new Date(); today.setUTCHours(0, 0, 0, 0); const todayIso = today.toISOString();

  // Pull all materialized upcoming Jobber visits (startAt >= today), paginated.
  let nodes = [], cursor = null, page = 0;
  while (page++ < 40) {
    const after = cursor ? `, after: "${cursor}"` : '';
    const d = await gql(token, `{ visits(first: 50, filter: { startAt: { after: "${todayIso}" } }${after}) { pageInfo { hasNextPage endCursor } nodes { id startAt title client { id } } } }`);
    nodes.push(...d.visits.nodes);
    if (!d.visits.pageInfo.hasNextPage) break;
    cursor = d.visits.pageInfo.endCursor;
    await new Promise(s => setTimeout(s, 1000));
  }
  const eligible = nodes.filter(v => !EXCLUDED_CLIENT_GIDS.has(v.client?.id));

  const ids = eligible.map(v => `'${v.id}'`).join(',') || "''";
  const present = await execSql(`SELECT source_id FROM public.entity_source_links WHERE entity_type='visit' AND source_system='jobber' AND source_id IN (${ids})`);
  const presentSet = new Set(present.map(r => r.source_id));
  const missing = eligible.filter(v => !presentSet.has(v.id));

  console.log(`[audit] Jobber upcoming (eligible) = ${eligible.length} | in our DB = ${presentSet.size} | MISSING = ${missing.length}`);
  missing.slice(0, 25).forEach(v => console.error(`  MISSING  ${v.startAt}  ${(v.title || '').slice(0, 55)}  (${v.id})`));
  console.log('--- audit complete --- ' + JSON.stringify({ probe: 'jobber_upcoming_vs_db', jobber_upcoming: eligible.length, in_db: presentSet.size, missing: missing.length }));
  if (missing.length > 0) process.exitCode = 1;
})().catch(err => { console.error('[audit] FATAL:', err.message); process.exit(1); });
