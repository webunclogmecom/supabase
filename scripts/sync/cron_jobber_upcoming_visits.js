// ============================================================================
// cron_jobber_upcoming_visits.js — pull Jobber's UPCOMING (scheduled/future)
// visits and replay them through webhook-jobber so handleVisit upserts them as
// `scheduled` visits and PROMOTES/dedups any matching cron projection.
// ============================================================================
// Why this exists: cron_jobber.js cursors visits on `completedAt`, so it only
// ever pulls COMPLETED visits. Jobber's materialized FUTURE (scheduled) visit
// instances never land in our DB unless a VISIT_UPDATE webhook happens to fire.
// That's why the Calendar shows only our cron projections, not Jobber's real
// near-term schedule. This sync fills that gap (Phase 1 of the Calendar<->Jobber
// reconcile): it funnels each upcoming Jobber visit through the SAME handleVisit
// chokepoint, which:
//   - infers service_type from the title, sets visit_status='scheduled'
//   - resolves client/property/job, links entity_source_links(visit,jobber,GID)
//   - PROMOTES a matching supabase_cron projection (same client+service+scheduled)
//     instead of inserting a duplicate  ->  the reconcile is automatic + idempotent
//   - already excludes 112-YA (test account) at the gate
//
// Reads everything from public.webhook_tokens (access/refresh/client_id/secret),
// refreshing the Jobber token on demand — stateless, no Jobber creds in env.
//
// Required env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_PAT.
// CLI:
//   node scripts/sync/cron_jobber_upcoming_visits.js --dry-run   # pull + count, no writes
//   node scripts/sync/cron_jobber_upcoming_visits.js             # pull + replay through handleVisit
// ============================================================================

const https = require('https');
const crypto = require('crypto');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env'), override: true }); } catch (_) {}

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PAT          = process.env.SUPABASE_PAT;
const DRY_RUN      = process.argv.includes('--dry-run');
if (!SUPABASE_URL || !SERVICE_KEY || !PAT) throw new Error('SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_PAT required');

const GRAPHQL_VERSION = '2026-04-16';
const EXCLUDED_CLIENT_GIDS = new Set(['Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=']); // 112-YA test
const projectRef = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

function request({ host, path, method = 'GET', headers = {}, body = null }) {
  return new Promise((resolve, reject) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({ hostname: host, path, method, headers: { ...headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) } },
      (res) => { let d = ''; res.on('data', c => d += c); res.on('end', () => resolve({ status: res.statusCode, body: d })); });
    req.on('error', reject); req.setTimeout(60_000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload); req.end();
  });
}
async function execSql(sql) {
  const r = await request({ host: 'api.supabase.com', path: `/v1/projects/${projectRef}/database/query`, method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${PAT}` }, body: JSON.stringify({ query: sql }) });
  if (r.status >= 300) throw new Error(`SQL ${r.status}: ${r.body.slice(0, 200)}`);
  try { return JSON.parse(r.body); } catch { return []; }
}

// ---- Jobber token (read+refresh from webhook_tokens, like webhook-jobber) ----
async function getJobberCreds() {
  const rows = await execSql(`SELECT access_token, refresh_token, client_id, client_secret, expires_at::text FROM public.webhook_tokens WHERE source_system='jobber' LIMIT 1`);
  const row = rows[0];
  if (!row) throw new Error('No jobber row in webhook_tokens');
  let token = row.access_token;
  if (new Date(row.expires_at).getTime() <= Date.now() + 60_000) {
    console.log('[upcoming] token expiring; refreshing');
    const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(row.client_id)}&client_secret=${encodeURIComponent(row.client_secret)}`;
    const tr = await request({ host: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body });
    if (tr.status >= 300) {
      // Rotation race: a sibling refresher may have just rotated the token and stored a
      // fresh access_token. Re-read once and use it if now valid, instead of FATAL-exiting.
      const rows2 = await execSql(`SELECT access_token, expires_at::text FROM public.webhook_tokens WHERE source_system='jobber' LIMIT 1`);
      const row2 = rows2[0];
      if (row2 && new Date(row2.expires_at).getTime() > Date.now() + 60_000) {
        console.log(`[upcoming] refresh got ${tr.status} but a sibling already refreshed; using current token`);
        return { token: row2.access_token, clientSecret: row.client_secret };
      }
      throw new Error(`Refresh failed ${tr.status}: ${tr.body.slice(0,150)}`);
    }
    const t = JSON.parse(tr.body);
    const newExp = JSON.parse(Buffer.from(t.access_token.split('.')[1], 'base64').toString()).exp * 1000;
    await execSql(`UPDATE public.webhook_tokens SET access_token=${q(t.access_token)}, refresh_token=${q(t.refresh_token || row.refresh_token)}, expires_at=${q(new Date(newExp).toISOString())}, updated_at=now() WHERE source_system='jobber'`);
    token = t.access_token;
    console.log('[upcoming] refreshed');
  }
  return { token, clientSecret: row.client_secret };
}
function q(v) { return v == null ? 'NULL' : "'" + String(v).replace(/'/g, "''") + "'"; }
async function gql(token, query) {
  const r = await request({ host: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': GRAPHQL_VERSION }, body: JSON.stringify({ query }) });
  if (r.status >= 300) throw new Error(`GraphQL ${r.status}: ${r.body.slice(0, 200)}`);
  const j = JSON.parse(r.body);
  if (j.errors?.length) throw new Error(`GraphQL: ${JSON.stringify(j.errors[0]).slice(0,200)}`);
  return j.data;
}

(async () => {
  const startMs = Date.now();
  const startedAt = new Date().toISOString();
  console.log(`[upcoming] start ${startedAt} ${DRY_RUN ? '(DRY RUN)' : ''}`);
  const { token, clientSecret } = await getJobberCreds();

  // Pull all materialized upcoming visits (startAt from start of today, ET ~= 04:00Z)
  const today = new Date(); today.setUTCHours(0, 0, 0, 0);
  const afterIso = today.toISOString();
  let visits = [], cursor = null, page = 0;
  while (page++ < 40) {
    const after = cursor ? `, after: "${cursor}"` : '';
    const data = await gql(token, `{ visits(first: 50, filter: { startAt: { after: "${afterIso}" } }${after}) {
      totalCount pageInfo { hasNextPage endCursor } nodes { id title client { id } } } }`);
    const conn = data.visits;
    visits.push(...conn.nodes);
    if (!conn.pageInfo.hasNextPage) break;
    cursor = conn.pageInfo.endCursor;
    await new Promise(s => setTimeout(s, 1200));
  }
  const eligible = visits.filter(v => !EXCLUDED_CLIENT_GIDS.has(v.client?.id));
  const excluded = visits.length - eligible.length;
  console.log(`[upcoming] pulled ${visits.length} upcoming Jobber visits (${excluded} excluded: 112-YA)`);

  if (DRY_RUN) {
    console.log('[upcoming] DRY RUN — sample:', JSON.stringify(eligible.slice(0, 6).map(v => v.title?.slice(0, 50))));
    console.log(`[upcoming] would replay ${eligible.length} through handleVisit`);
    return;
  }

  // Replay each through webhook-jobber (VISIT_UPDATE) — handleVisit does the upsert + promote/dedup
  let ok = 0, fail = 0;
  for (const v of eligible) {
    const payload = JSON.stringify({ topic: 'VISIT_UPDATE', webHookEvent: { itemId: v.id, occurredAt: new Date().toISOString() } });
    const sig = crypto.createHmac('sha256', clientSecret).update(payload).digest('base64');
    const wr = await request({ host: SUPABASE_URL.replace(/https?:\/\//, '').replace(/\/$/, ''), path: '/functions/v1/webhook-jobber', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-jobber-hmac-sha256': sig }, body: payload });
    if (wr.status >= 200 && wr.status < 300) ok++; else { fail++; if (fail <= 3) console.error(`  fail ${v.id}: ${wr.status} ${wr.body.slice(0,120)}`); }
  }
  const dur = Math.round((Date.now() - startMs) / 1000);
  console.log(`[upcoming] replayed: ok=${ok} fail=${fail} in ${dur}s`);

  // VERIFY (added 2026-06-08): after replaying, EVERY eligible upcoming Jobber visit must now exist
  // in our DB. A residual gap here is a real ingestion bug (handleVisit rejected/dropped it), not
  // just latency — surface it loudly: record it in sync_log AND exit non-zero so the workflow goes
  // red and we find out from the pipeline, not from someone eyeballing Jobber.
  const verifyIds = eligible.map(v => `'${v.id}'`).join(',') || "''";
  const present = await execSql(`SELECT source_id FROM public.entity_source_links WHERE entity_type='visit' AND source_system='jobber' AND source_id IN (${verifyIds})`);
  const presentSet = new Set(present.map(r => r.source_id));
  const stillMissing = eligible.filter(v => !presentSet.has(v.id));
  console.log(`[upcoming] VERIFY: ${presentSet.size}/${eligible.length} eligible upcoming visits present in DB; residual gap = ${stillMissing.length}`);
  stillMissing.slice(0, 10).forEach(v => console.error(`  STILL MISSING after replay: ${(v.title || '').slice(0, 55)} (${v.id})`));

  await execSql(`INSERT INTO public.sync_log (sync_source, started_at, finished_at, rows_inserted, rows_updated, rows_errored, duration_seconds, status, details)
    VALUES ('jobber_upcoming_visits', ${q(startedAt)}, now(), ${ok}, 0, ${fail}, ${dur}, ${stillMissing.length === 0 && fail === 0 ? "'success'" : "'partial'"},
            ${q(JSON.stringify({ pulled: visits.length, excluded_112ya: excluded, replayed_ok: ok, replayed_fail: fail, residual_gap: stillMissing.length }))})`);

  if (stillMissing.length > 0) { console.error(`[upcoming] FAIL: ${stillMissing.length} upcoming visit(s) still missing after replay`); process.exitCode = 1; }
})().catch(err => { console.error('[upcoming] FATAL:', err.message); process.exit(1); });
