// ============================================================================
// full_session_audit.js — comprehensive cloud + local sanity check
// ============================================================================
// Run after every batch of fixes (per Fred 2026-05-04). Checks:
//   CLOUD: cron health, edge function reachability, webhook freshness,
//          API token validity, Prod ↔ Sandbox parity, orphan FKs, storage
//   LOCAL: repo cleanliness, doc drift, memory index integrity,
//          handoff char count, migration commit state
//
// Output: ✅ / ⚠️ / ❌ per check, grouped by Cloud vs Local, with a final
// "ready to ship" or "blockers found" verdict.
//
// Usage:
//   node scripts/probes/full_session_audit.js
// ============================================================================

const https = require('https');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });

const PROJECT_ROOT = path.resolve(__dirname, '../..');

// ---- HTTP + PG helpers -------------------------------------------------------

function http(opts, body) {
  return new Promise((res, rej) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({
      ...opts,
      headers: { ...opts.headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) },
    }, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej);
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function pg(projectId, sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${projectId}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;

// ---- Result tracking ---------------------------------------------------------

const results = { cloud: [], local: [] };
function ok(g, msg) { results[g].push({ status: '✅', msg }); }
function warn(g, msg) { results[g].push({ status: '⚠️ ', msg }); }
function fail(g, msg) { results[g].push({ status: '❌', msg }); }

// ---- CLOUD checks ------------------------------------------------------------

async function checkCronWorkflows() {
  try {
    const out = execSync('gh run list --limit=30 --json name,status,conclusion,createdAt,event', { cwd: PROJECT_ROOT, encoding: 'utf8' });
    const runs = JSON.parse(out);
    const since = Date.now() - 24 * 3600 * 1000;
    // Only COMPLETED runs count — an in-progress/queued run has conclusion=null and
    // was being miscounted as a failure (false BLOCKER when the audit ran mid-run).
    const recent = runs.filter(r => new Date(r.createdAt).getTime() > since && r.event === 'schedule' && r.status === 'completed');
    const byName = {};
    for (const r of recent) {
      if (!byName[r.name]) byName[r.name] = { ok: 0, fail: 0 };
      if (r.conclusion === 'success') byName[r.name].ok++;
      else byName[r.name].fail++;
    }
    if (Object.keys(byName).length === 0) {
      warn('cloud', 'No scheduled workflow runs in last 24h (unexpected)');
      return;
    }
    // What matters operationally: is the cron HEALTHY NOW? Look at the
    // MOST RECENT run per workflow rather than "any failure in 24h" — a
    // transient 429/rate-limit hours ago that self-resolved isn't a blocker
    // if the latest run is green.
    const latestByName = {};
    for (const r of recent) {
      if (!latestByName[r.name] || new Date(r.createdAt) > new Date(latestByName[r.name].createdAt)) {
        latestByName[r.name] = r;
      }
    }
    for (const [name, c] of Object.entries(byName)) {
      const latest = latestByName[name];
      if (c.fail === 0) ok('cloud', `Cron ${name}: ${c.ok} runs, all green`);
      else if (latest?.conclusion === 'success') warn('cloud', `Cron ${name}: ${c.fail} historical failure(s) but latest green — likely transient`);
      else fail('cloud', `Cron ${name}: ${c.fail} failures, ${c.ok} ok, latest=${latest?.conclusion}`);
    }
  } catch (e) {
    fail('cloud', `gh run list failed: ${e.message.slice(0, 100)}`);
  }
}

async function checkEdgeFunctions() {
  const fns = ['webhook-jobber', 'webhook-airtable', 'webhook-samsara'];
  for (const fn of fns) {
    try {
      const r = await http({
        hostname: `${PROD}.supabase.co`,
        path: `/functions/v1/${fn}`,
        method: 'OPTIONS',
        headers: { 'Content-Type': 'application/json' },
      });
      // These are POST-only webhook receivers: a non-POST probe gets 400 {"error":"POST only"}
      // (jobber/airtable/samsara) or 405 — both PROVE the function is deployed + routing. The goal
      // here is reachability, so any clean non-5xx HTTP response counts; only a 5xx or a connection
      // error (the catch below) is a real failure.
      if (r.status < 500) ok('cloud', `Edge function ${fn} reachable (HTTP ${r.status}${r.status === 400 ? ' POST-only guard' : ''})`);
      else warn('cloud', `Edge function ${fn} returned HTTP ${r.status}`);
    } catch (e) {
      fail('cloud', `Edge function ${fn} unreachable: ${e.message.slice(0, 80)}`);
    }
  }
}

async function checkWebhookFreshness() {
  try {
    const rows = await pg(PROD, `
      SELECT source_system, MAX(created_at)::text AS last_event,
        EXTRACT(EPOCH FROM (now() - MAX(created_at)))::int AS seconds_since
      FROM webhook_events_log
      WHERE created_at >= now() - interval '7 days'
      GROUP BY source_system
      ORDER BY 1;
    `);
    // Samsara webhooks are naturally low-volume (a handful per 2 weeks). The real
    // Samsara health signal is telemetry landing in vehicle_telemetry_readings via
    // the direct pull (checkSamsaraTelemetry below), NOT this webhook — so keep the
    // samsara threshold loose to avoid false "silent" alarms.
    const expected = { airtable: 24 * 3600, jobber: 30 * 60, samsara: 4 * 24 * 3600, internal: 7 * 24 * 3600 };
    for (const r of rows) {
      const max = expected[r.source_system] ?? 24 * 3600;
      if (r.seconds_since <= max) ok('cloud', `Webhook ${r.source_system}: last event ${Math.round(r.seconds_since/60)}min ago`);
      else warn('cloud', `Webhook ${r.source_system}: SILENT ${Math.round(r.seconds_since/3600)}h (expected ≤${Math.round(max/3600)}h)`);
    }
  } catch (e) {
    fail('cloud', `webhook freshness: ${e.message.slice(0, 100)}`);
  }
}

async function checkSamsaraTelemetry() {
  // The true Samsara health signal: GPS/fuel/engine telemetry landing in
  // vehicle_telemetry_readings (pulled directly, not via webhook). A quiet webhook
  // is normal; a stale telemetry table means the pull actually broke.
  try {
    const r = (await pg(PROD, `SELECT
      EXTRACT(EPOCH FROM (now() - MAX(recorded_at)))::int AS secs_since,
      COUNT(*) FILTER (WHERE recorded_at > now() - interval '7 days') AS n7
      FROM vehicle_telemetry_readings`))[0];
    const hrs = Math.round(Number(r.secs_since) / 3600);
    if (Number(r.secs_since) <= 48 * 3600 && Number(r.n7) >= 200) ok('cloud', `Samsara telemetry: fresh (${hrs}h ago, ${r.n7} readings/7d)`);
    else if (Number(r.secs_since) > 48 * 3600) fail('cloud', `Samsara telemetry STALE: latest ${hrs}h ago — the pull likely broke`);
    else warn('cloud', `Samsara telemetry: only ${r.n7} readings/7d (low — verify trucks are reporting)`);
  } catch (e) { warn('cloud', `Samsara telemetry: ${e.message.slice(0, 80)}`); }
}

async function checkApiTokens() {
  // Jobber — auto-refresh first since the token has a ~1h life and the audit
  // is run after long batches of work. A "fresh refresh confirms valid"
  // signal is more useful than a "stale-token" failure.
  try {
    execSync('node scripts/sync/jobber_token.js', { cwd: PROJECT_ROOT, encoding: 'utf8', stdio: 'pipe' });
    // Re-read the rotated token
    require('dotenv').config({ path: path.resolve(PROJECT_ROOT, '.env'), override: true });
    const r = await http({
      hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
      headers: { Authorization: `Bearer ${process.env.JOBBER_ACCESS_TOKEN}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-13', 'Content-Type': 'application/json' }
    }, JSON.stringify({ query: '{ account { id } }' }));
    const j = JSON.parse(r.body);
    if (r.status === 200 && j.data) ok('cloud', 'Jobber API token valid (auto-refreshed)');
    else fail('cloud', `Jobber API token issue: ${(j.message || j.errors?.[0]?.message || r.status).toString().slice(0, 80)}`);
  } catch (e) { fail('cloud', `Jobber API: ${e.message.slice(0, 80)}`); }
  // Samsara
  try {
    const r = await http({
      hostname: 'api.samsara.com', path: '/fleet/vehicles?limit=1', method: 'GET',
      headers: { Authorization: `Bearer ${process.env.SAMSARA_API_TOKEN}` },
    });
    if (r.status === 200) ok('cloud', 'Samsara API token valid');
    else fail('cloud', `Samsara API: HTTP ${r.status}`);
  } catch (e) { fail('cloud', `Samsara API: ${e.message.slice(0, 80)}`); }
  // Airtable
  try {
    const r = await http({
      hostname: 'api.airtable.com', path: `/v0/${process.env.AIRTABLE_BASE_ID}/Clients?maxRecords=1`, method: 'GET',
      headers: { Authorization: `Bearer ${process.env.AIRTABLE_API_KEY}` },
    });
    if (r.status === 200) ok('cloud', 'Airtable API token valid');
    else fail('cloud', `Airtable API: HTTP ${r.status} ${r.body.slice(0, 80)}`);
  } catch (e) { fail('cloud', `Airtable API: ${e.message.slice(0, 80)}`); }
  // Supabase PAT (use it for the very next pg query)
  ok('cloud', 'Supabase PAT working (queries above succeeded)');
}

function jwtClaims(jwt) { try { return JSON.parse(Buffer.from(jwt.split('.')[1], 'base64').toString()); } catch { return {}; } }

async function checkTokenIntegrity() {
  // Root-cause guard for the 2026-06-02 contamination incident: each token row's
  // access_token MUST belong to that row's OWN app (jwt app_id == client_id).
  // When a shared refresher (jobber_token.js getValidToken) picked the freshest
  // token across apps and PATCHed the write-app's token into the read ('jobber')
  // row, the read app's refresh broke AND webhook enrichment silently stopped —
  // a ~30% visit gap that freshness/failure metrics never surfaced. This check
  // is cheap, deterministic, and would have caught it on the next audit.
  try {
    const rows = await pg(PROD, `SELECT source_system, client_id, access_token FROM webhook_tokens WHERE source_system IN ('jobber','jobber_write') ORDER BY source_system`);
    for (const r of rows) {
      const appId = jwtClaims(r.access_token).app_id;
      if (!appId) { warn('cloud', `Token ${r.source_system}: access_token has no app_id claim`); continue; }
      if (appId === r.client_id) ok('cloud', `Token ${r.source_system}: app_id matches client_id (not contaminated)`);
      else fail('cloud', `Token ${r.source_system}: CONTAMINATED — access_token app_id ${appId.slice(0,8)}… != client_id ${(r.client_id||'').slice(0,8)}… (cross-app token written into this row — re-auth this app)`);
    }
  } catch (e) { warn('cloud', `Token integrity: ${e.message.slice(0, 80)}`); }
}

async function checkUpstreamCompleteness() {
  // Completeness != no-failures. webhook_events_log can be all-green and freshness
  // fine while a chunk of upstream records never landed (the read token broke, so
  // enrichment no-op'd). This counts UPSTREAM (Jobber) vs our DB jobber-linked rows
  // and flags REAL gaps after excluding known test/junk records. Two highest-signal
  // entities: clients (identity) + visits (the thing that broke). Quotes are
  // intentionally excluded (no canonical table — that's an open ops decision).
  const JUNK = [/^x\s+\d+\b/i, /\btest\b/i, /not use/i, /^example/i, /\[archived\]/i];
  const isJunk = n => !n || JUNK.some(re => re.test(n));
  const EXCLUDED_VISIT_CLIENTS = new Set(['Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=']); // 112-YA test (webhook-jobber excludes at the gate)
  let token;
  try {
    const row = (await pg(PROD, `SELECT access_token, refresh_token, client_id, client_secret, expires_at::text FROM webhook_tokens WHERE source_system='jobber'`))[0];
    token = row.access_token;
    if (new Date(row.expires_at).getTime() <= Date.now() + 60_000) {
      const body = `grant_type=refresh_token&refresh_token=${encodeURIComponent(row.refresh_token)}&client_id=${encodeURIComponent(row.client_id)}&client_secret=${encodeURIComponent(row.client_secret)}`;
      const tr = await http({ hostname: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }, body);
      if (tr.status < 300) token = JSON.parse(tr.body).access_token;
    }
  } catch (e) { warn('cloud', `Completeness: no Jobber token: ${e.message.slice(0, 80)}`); return; }
  const gql = async (q) => {
    const r = await http({ hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' } }, JSON.stringify({ query: q }));
    return JSON.parse(r.body);
  };
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  // CLIENTS — name-diff (authoritative), junk-filtered
  try {
    let after = null, jc = [];
    for (let p = 0; p < 10; p++) { const d = await gql(`{ clients(first:100${after ? `, after:"${after}"` : ''}){ nodes{ id name } pageInfo{ hasNextPage endCursor } } }`); const c = d.data.clients; jc.push(...c.nodes); if (!c.pageInfo.hasNextPage) break; after = c.pageInfo.endCursor; await sleep(150); }
    const linked = new Set((await pg(PROD, `SELECT source_id FROM entity_source_links WHERE entity_type='client' AND source_system='jobber'`)).map(r => r.source_id));
    const missing = jc.filter(c => !linked.has(c.id));
    const realMissing = missing.filter(c => !isJunk(c.name));
    if (realMissing.length === 0) ok('cloud', `Completeness clients: all real clients linked (${jc.length} upstream; ${missing.length - realMissing.length} junk/test correctly unlinked)`);
    else fail('cloud', `Completeness clients: ${realMissing.length} REAL client(s) missing from DB → ${realMissing.slice(0, 6).map(c => c.name).join(', ')}`);
  } catch (e) { warn('cloud', `Completeness clients: ${e.message.slice(0, 80)}`); }
  // VISITS (last 30d) — gid-diff, 112-YA excluded (avoids the UTC-startAt vs ET-visit_date window artifact by matching on GID, not date)
  // Post-decoupling (2026-06-02) the Calendar app owns the visit lifecycle and the office still
  // hand-enters some visits directly in Jobber; the sync-jobber-upcoming-visits poll only catches
  // FUTURE-dated visits, so a past-dated / LATE / duplicate visit created in Jobber after-the-fact
  // legitimately won't be in our DB. So split the diff: a missing visit whose JOB already has a
  // linked DB visit is an expected straggler/dup (⚠ informational) — only a job with visits in
  // Jobber but ZERO linked in our DB is the systemic silent-sync failure this check guards against (❌).
  try {
    const since = new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString();
    let after = null, jv = [];
    for (let p = 0; p < 10; p++) { const d = await gql(`{ visits(first:100${after ? `, after:"${after}"` : ''}, filter:{startAt:{after:"${since}"}}){ nodes{ id title client{ id } job{ id } } pageInfo{ hasNextPage endCursor } } }`); const c = d.data.visits; jv.push(...c.nodes); if (!c.pageInfo.hasNextPage) break; after = c.pageInfo.endCursor; await sleep(150); }
    const eligible = jv.filter(v => !EXCLUDED_VISIT_CLIENTS.has(v.client?.id));
    const linked = new Set((await pg(PROD, `SELECT source_id FROM entity_source_links WHERE entity_type='visit' AND source_system='jobber'`)).map(r => r.source_id));
    // Jobber JOB GIDs that already have ≥1 linked visit in our DB → that job synced fine
    const syncedJobGids = new Set((await pg(PROD, `SELECT DISTINCT j_esl.source_id AS job_gid FROM visits v JOIN entity_source_links j_esl ON j_esl.entity_type='job' AND j_esl.entity_id=v.job_id AND j_esl.source_system='jobber' JOIN entity_source_links v_esl ON v_esl.entity_type='visit' AND v_esl.entity_id=v.id AND v_esl.source_system='jobber' WHERE v.job_id IS NOT NULL AND v.deleted_at IS NULL`)).map(r => r.job_gid));
    const missing = eligible.filter(v => !linked.has(v.id));
    const realGaps = missing.filter(v => !syncedJobGids.has(v.job?.id)); // job entirely unlinked = real sync gap
    const stragglers = missing.filter(v => syncedJobGids.has(v.job?.id)); // dup/manual past entry on an already-synced job
    if (missing.length === 0) ok('cloud', `Completeness visits(30d): all ${eligible.length} upstream visits linked (112-YA excluded)`);
    else if (realGaps.length > 0) fail('cloud', `Completeness visits(30d): ${realGaps.length} upstream visit(s) on UNSYNCED jobs missing from DB → ${realGaps.slice(0, 6).map(v => (v.title || '').slice(0, 24)).join(', ')}`);
    else warn('cloud', `Completeness visits(30d): ${stragglers.length} unlinked Jobber visit(s) on already-synced jobs (expected — manual/past/dup Jobber entry outside the upcoming-visits poll; not a DB gap) → ${stragglers.slice(0, 6).map(v => (v.title || '').slice(0, 24)).join(', ')}`);
  } catch (e) { warn('cloud', `Completeness visits: ${e.message.slice(0, 80)}`); }
}

async function checkProdSandboxParity() {
  // Sandbox #1 (ubtlwpcyntelgbykdatn) DELETED 2026-06-11 — zero app consumers
  // (0 API requests/7d; all Lovable apps verified on Prod or Lovable Cloud).
  // Parity checks retired with it; final backup of its unique tables lives at
  // ..\..\backups\sandbox1_final_backup_2026-06-11.json (outside repo).
  ok('cloud', 'Sandbox parity: retired (Sandbox #1 deleted 2026-06-11, no consumers)');
}

async function checkOrphanFKs() {
  const checks = [
    { name: 'visits.client_id → clients', sql: `SELECT COUNT(*) AS n FROM visits v WHERE v.client_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clients c WHERE c.id = v.client_id)` },
    { name: 'visits.vehicle_id → vehicles', sql: `SELECT COUNT(*) AS n FROM visits v WHERE v.vehicle_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM vehicles veh WHERE veh.id = v.vehicle_id)` },
    { name: 'visit_assignments.visit_id → visits', sql: `SELECT COUNT(*) AS n FROM visit_assignments va WHERE NOT EXISTS (SELECT 1 FROM visits v WHERE v.id = va.visit_id)` },
    { name: 'visit_assignments.employee_id → employees', sql: `SELECT COUNT(*) AS n FROM visit_assignments va WHERE NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = va.employee_id)` },
    { name: 'photo_links.photo_id → photos', sql: `SELECT COUNT(*) AS n FROM photo_links pl WHERE NOT EXISTS (SELECT 1 FROM photos p WHERE p.id = pl.photo_id)` },
    { name: 'inspections.employee_id → employees', sql: `SELECT COUNT(*) AS n FROM inspections i WHERE i.employee_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM employees e WHERE e.id = i.employee_id)` },
  ];
  for (const c of checks) {
    try {
      const n = (await pg(PROD, c.sql))[0].n;
      if (n === 0) ok('cloud', `Orphan FK ${c.name}: 0`);
      else fail('cloud', `Orphan FK ${c.name}: ${n} bad refs`);
    } catch (e) { warn('cloud', `Orphan FK ${c.name}: ${e.message.slice(0, 80)}`); }
  }
}

async function checkDbSize() {
  // Flags table or DB growth before it becomes a Pro-tier problem.
  // Supabase Pro = 8 GB. We warn at 1 GB per table / 6 GB total (75%),
  // fail at 4 GB per table / 7 GB total (87.5%).
  try {
    const db = await pg(PROD, `SELECT pg_database_size(current_database()) AS bytes, pg_size_pretty(pg_database_size(current_database())) AS pretty`);
    const dbBytes = Number(db[0].bytes);
    const dbGb = dbBytes / 1024 / 1024 / 1024;
    if (dbGb >= 7)      fail('cloud', `DB size: ${db[0].pretty} (>87% of 8GB Pro cap)`);
    else if (dbGb >= 6) warn('cloud', `DB size: ${db[0].pretty} (>75% of 8GB Pro cap)`);
    else                ok('cloud',   `DB size: ${db[0].pretty} (${(dbGb*100/8).toFixed(1)}% of 8GB cap)`);

    const top = await pg(PROD, `
      SELECT relname, pg_size_pretty(pg_total_relation_size(c.oid)) AS pretty,
             pg_total_relation_size(c.oid) AS bytes
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='r'
      ORDER BY pg_total_relation_size(c.oid) DESC LIMIT 3;
    `);
    for (const t of top) {
      const gb = Number(t.bytes) / 1024 / 1024 / 1024;
      if (gb >= 4)      fail('cloud', `Table ${t.relname}: ${t.pretty} (>4GB — needs retention/compression)`);
      else if (gb >= 1) warn('cloud', `Table ${t.relname}: ${t.pretty} (>1GB — consider retention soon)`);
      else              ok('cloud',   `Table ${t.relname}: ${t.pretty}`);
    }
  } catch (e) { warn('cloud', `DB size check: ${e.message.slice(0, 80)}`); }
}

async function checkStaleESLs() {
  // Stale ESL = a row in entity_source_links pointing to an upstream record
  // that no longer exists. Happens when Jobber/Airtable deletes a record but
  // the *_DESTROY webhook didn't fire (Jobber webhook reliability) AND the
  // polling cron didn't catch the absence. Per Fred 2026-05-05: tolerate up
  // to 50 total before flagging — small drift is normal, growth = leak.
  //
  // Allow-list (added 2026-05-24): the 81 visit→jobber rows from the
  // 2026-04-29 19:50:17.095+00 redo-wipe batch are KNOWN STALE and are
  // documented in MEMORY.md / CLAUDE.md ADR-context. Filtering by exact
  // synced_at is the tightest match — any NEW orphan with the same
  // entity_type/source_system but a different synced_at will still surface.
  try {
    const r = await pg(PROD, `
      SELECT entity_type, COUNT(*) AS n
      FROM entity_source_links esl
      WHERE (
              (entity_type='client'   AND NOT EXISTS (SELECT 1 FROM clients   WHERE id=esl.entity_id))
           OR (entity_type='visit'    AND NOT EXISTS (SELECT 1 FROM visits    WHERE id=esl.entity_id))
           OR (entity_type='job'      AND NOT EXISTS (SELECT 1 FROM jobs      WHERE id=esl.entity_id))
           OR (entity_type='invoice'  AND NOT EXISTS (SELECT 1 FROM invoices  WHERE id=esl.entity_id))
           OR (entity_type='property' AND NOT EXISTS (SELECT 1 FROM properties WHERE id=esl.entity_id))
            )
        AND NOT (
              entity_type   = 'visit'
          AND source_system = 'jobber'
          AND synced_at     = '2026-04-29 19:50:17.095+00'::timestamptz
        )
      GROUP BY entity_type
      ORDER BY 1;
    `);
    const total = r.reduce((s, x) => s + Number(x.n), 0);
    if (total === 0) ok('cloud', 'Stale ESLs: 0 (excluding 81 allow-listed 2026-04-29 wipe-leftovers)');
    else if (total <= 50) ok('cloud', `Stale ESLs: ${total} (under tolerance threshold of 50; 81 allow-listed)`);
    else fail('cloud', `Stale ESLs: ${total} (over 50 — investigate sync gaps; excludes 81 allow-listed)`);
  } catch (e) { warn('cloud', `Stale ESL check: ${e.message.slice(0, 80)}`); }
}

async function checkViewSecurity() {
  // Catches the regression where a view gets recreated without
  // WITH (security_invoker = true), which Supabase's advisor flags as
  // CRITICAL (RLS bypass).
  try {
    const rows = await pg(PROD, `
      SELECT c.relname,
        ('security_invoker=true' = ANY(c.reloptions) OR 'security_invoker=on' = ANY(c.reloptions)) AS invoker
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='public' AND c.relkind='v'
      ORDER BY c.relname;
    `);
    const definers = rows.filter(r => !r.invoker);
    if (definers.length === 0) ok('cloud', `View security: all ${rows.length} public views are SECURITY INVOKER`);
    else for (const v of definers) fail('cloud', `View ${v.relname}: SECURITY DEFINER (RLS bypass — fix with ALTER VIEW SET (security_invoker = true))`);
  } catch (e) { warn('cloud', `View security check: ${e.message.slice(0, 80)}`); }
}

async function checkStorageURLs() {
  try {
    const samples = await pg(PROD, `SELECT storage_path FROM photos WHERE storage_path IS NOT NULL ORDER BY id DESC LIMIT 3`);
    let okCount = 0;
    for (const s of samples) {
      const url = `/storage/v1/object/public/GT%20-%20Visits%20Images/${encodeURIComponent(s.storage_path).replace(/%2F/g, '/')}`;
      const r = await http({ hostname: `${PROD}.supabase.co`, path: url, method: 'HEAD' });
      if (r.status === 200) okCount++;
    }
    if (okCount === samples.length) ok('cloud', `Photo storage URLs resolve (${okCount}/${samples.length} sampled)`);
    else warn('cloud', `Photo storage: only ${okCount}/${samples.length} sampled URLs returned 200`);
  } catch (e) { warn('cloud', `Storage check: ${e.message.slice(0, 80)}`); }
}

// ---- LOCAL checks ------------------------------------------------------------

function checkRepoCleanliness() {
  try {
    const status = execSync('git status --porcelain', { cwd: PROJECT_ROOT, encoding: 'utf8' }).trim();
    if (!status) ok('local', 'Working tree clean (no uncommitted changes)');
    else warn('local', `Working tree has ${status.split('\n').length} uncommitted file(s)`);
    const branch = execSync('git rev-parse --abbrev-ref HEAD', { cwd: PROJECT_ROOT, encoding: 'utf8' }).trim();
    if (branch === 'main') ok('local', 'On branch main');
    else warn('local', `On branch ${branch} (expected main)`);
    const ahead = execSync('git rev-list --count @{u}..HEAD', { cwd: PROJECT_ROOT, encoding: 'utf8' }).trim();
    const behind = execSync('git rev-list --count HEAD..@{u}', { cwd: PROJECT_ROOT, encoding: 'utf8' }).trim();
    if (ahead === '0' && behind === '0') ok('local', 'Synced with origin/main');
    else warn('local', `Origin diff: ahead=${ahead} behind=${behind}`);
  } catch (e) { fail('local', `Git state: ${e.message.slice(0, 100)}`); }
}

function checkClaudeMdLinks() {
  const claudeMd = path.join(PROJECT_ROOT, 'CLAUDE.md');
  if (!fs.existsSync(claudeMd)) { fail('local', 'CLAUDE.md missing'); return; }
  const txt = fs.readFileSync(claudeMd, 'utf8');
  const docLinks = [...txt.matchAll(/\[([^\]]+)\]\((docs\/[^)]+)\)/g)].map(m => m[2]);
  let missing = 0;
  for (const link of [...new Set(docLinks)]) {
    const p = path.join(PROJECT_ROOT, link.split('#')[0]);
    if (!fs.existsSync(p)) { missing++; warn('local', `CLAUDE.md links to missing ${link}`); }
  }
  if (missing === 0) ok('local', `CLAUDE.md: all ${[...new Set(docLinks)].length} doc links resolve`);
}

function checkLovablePromptSize() {
  const f = path.join(PROJECT_ROOT, 'docs/handoffs/unclogme-lovable-handoff/LOVABLE-SYSTEM-PROMPT.md');
  if (!fs.existsSync(f)) { warn('local', 'Lovable handoff doc not found'); return; }
  const txt = fs.readFileSync(f, 'utf8');
  const m = txt.match(/```text\n([\s\S]*?)\n```/);
  if (!m) { warn('local', 'Lovable handoff: no ```text``` block found'); return; }
  const len = m[1].length;
  if (len <= 10000) ok('local', `Lovable prompt: ${len} chars (under 10K cap)`);
  else fail('local', `Lovable prompt: ${len} chars OVER 10K cap`);
}

function checkMemoryIndex() {
  const memDir = path.join(process.env.USERPROFILE || process.env.HOME, '.claude/projects/C--Users-FRED-Desktop-Virtrify-Yannick-Claude/memory');
  if (!fs.existsSync(memDir)) { warn('local', 'memory/ folder not found'); return; }
  const files = fs.readdirSync(memDir).filter(f => f.endsWith('.md') && f !== 'MEMORY.md');
  const idx = path.join(memDir, 'MEMORY.md');
  if (!fs.existsSync(idx)) { fail('local', 'MEMORY.md index missing'); return; }
  const idxTxt = fs.readFileSync(idx, 'utf8');
  const referenced = new Set([...idxTxt.matchAll(/\(([^)]+\.md)\)/g)].map(m => m[1]));
  const orphan = files.filter(f => !referenced.has(f));
  const missing = [...referenced].filter(r => !files.includes(r));
  if (orphan.length === 0 && missing.length === 0) ok('local', `MEMORY.md: ${files.length} files, all indexed`);
  else {
    if (orphan.length) warn('local', `MEMORY.md: orphan files not in index: ${orphan.slice(0,5).join(', ')}`);
    if (missing.length) warn('local', `MEMORY.md: index references missing files: ${missing.slice(0,5).join(', ')}`);
  }
}

function checkMigrationCommits() {
  // ACTIVE migrations live in docs/migrations/ (canonical dated SQL since 2026-05-14).
  // scripts/migrations/ is FROZEN (pre-2026-05-13, still referenced by ADRs/guides as the
  // historical record). Check BOTH — the old code only checked the frozen dir, so new
  // docs/migrations/ files were silently unaudited (a blind spot, fixed 2026-06-09).
  const dirs = ['docs/migrations', 'scripts/migrations'].filter(d => fs.existsSync(path.join(PROJECT_ROOT, d)));
  let uncommitted = 0, total = 0;
  for (const d of dirs) {
    total += fs.readdirSync(path.join(PROJECT_ROOT, d)).filter(f => f.endsWith('.sql')).length;
    try {
      const status = execSync(`git status --porcelain ${d}/`, { cwd: PROJECT_ROOT, encoding: 'utf8' }).trim();
      if (status) uncommitted += status.split('\n').length;
    } catch { /* per-dir ignore */ }
  }
  if (!uncommitted) ok('local', `Migrations: ${total} files (docs/migrations active + scripts/migrations frozen), all committed`);
  else warn('local', `Migrations: ${uncommitted} uncommitted across docs/migrations + scripts/migrations`);
}

function checkEnvVars() {
  const required = ['SUPABASE_URL', 'SUPABASE_PROJECT_ID', 'SUPABASE_PAT', 'SUPABASE_SERVICE_ROLE_KEY',
    'JOBBER_ACCESS_TOKEN', 'AIRTABLE_API_KEY', 'AIRTABLE_BASE_ID', 'SAMSARA_API_TOKEN'];
  // SANDBOX_SUPABASE_PROJECT_ID removed 2026-06-11 — Sandbox #1 deleted.
  const missing = required.filter(k => !process.env[k]);
  if (missing.length === 0) ok('local', `Env vars: all ${required.length} required present`);
  else fail('local', `Env vars missing: ${missing.join(', ')}`);
}

// ---- main --------------------------------------------------------------------

(async () => {
  console.log('='.repeat(72));
  console.log(`Full session audit — ${new Date().toISOString()}`);
  console.log('='.repeat(72));

  console.log('\n[CLOUD] Cron workflow health…');     await checkCronWorkflows();
  console.log('\n[CLOUD] Edge functions reachable…'); await checkEdgeFunctions();
  console.log('\n[CLOUD] Webhook event freshness…');  await checkWebhookFreshness();
  console.log('\n[CLOUD] Samsara telemetry freshness…'); await checkSamsaraTelemetry();
  console.log('\n[CLOUD] API tokens valid…');         await checkApiTokens();
  console.log('\n[CLOUD] Token integrity (app match)…'); await checkTokenIntegrity();
  console.log('\n[CLOUD] Upstream completeness…');     await checkUpstreamCompleteness();
  console.log('\n[CLOUD] Prod ↔ Sandbox parity…');    await checkProdSandboxParity();
  console.log('\n[CLOUD] Orphan FKs…');               await checkOrphanFKs();
  console.log('\n[CLOUD] DB size + top tables…');     await checkDbSize();
  console.log('\n[CLOUD] Stale ESLs (sync drift)…');   await checkStaleESLs();
  console.log('\n[CLOUD] View security (RLS bypass)…'); await checkViewSecurity();
  console.log('\n[CLOUD] Photo storage URLs…');       await checkStorageURLs();

  console.log('\n[LOCAL] Repo cleanliness…');         checkRepoCleanliness();
  console.log('\n[LOCAL] CLAUDE.md links…');          checkClaudeMdLinks();
  console.log('\n[LOCAL] Lovable prompt size…');      checkLovablePromptSize();
  console.log('\n[LOCAL] Memory index…');             checkMemoryIndex();
  console.log('\n[LOCAL] Migration commits…');        checkMigrationCommits();
  console.log('\n[LOCAL] Env vars…');                 checkEnvVars();

  // Render
  const print = (group, title) => {
    console.log(`\n${'='.repeat(72)}\n${title}\n${'='.repeat(72)}`);
    for (const r of results[group]) console.log(`  ${r.status} ${r.msg}`);
  };
  print('cloud', 'CLOUD');
  print('local', 'LOCAL');

  const all = [...results.cloud, ...results.local];
  const failures = all.filter(r => r.status === '❌').length;
  const warnings = all.filter(r => r.status.includes('⚠')).length;
  const successes = all.filter(r => r.status === '✅').length;

  console.log('\n' + '='.repeat(72));
  console.log(`VERDICT: ${successes} ✅   ${warnings} ⚠️    ${failures} ❌`);
  if (failures > 0) console.log('  → BLOCKERS FOUND. Address ❌ items before shipping.');
  else if (warnings > 0) console.log('  → READY TO SHIP with warnings. Review ⚠️  items.');
  else console.log('  → ALL GREEN. Ready to ship.');
  console.log('='.repeat(72));
})().catch(e => { console.error('FATAL audit error:', e.message); process.exit(2); });
