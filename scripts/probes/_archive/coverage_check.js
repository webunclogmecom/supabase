// Sync coverage check: for every canonical entity, identify its keep-fresh
// path and verify it's actually working (last write recency, expected cadence).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const { execSync } = require('child_process');
const path = require('path');

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const PROJECT_ROOT = path.resolve(__dirname, '../..');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROD}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

// Each entity → (data freshness column, expected sync path, max hours stale before WARN)
// Each entity → (data freshness column, sync path, max hours stale before WARN)
// max_hours reflects realistic operational cadence, not strict polling — visits
// only update when there's activity (overnight shift), inspections only when
// drivers submit PRE-POST forms, etc. Set thresholds to flag genuine breakage,
// not lulls.
const ENTITY_MAP = [
  ['clients',                       'updated_at',  'webhook-jobber + jobber-poll (2 min)',         48],
  ['client_contacts',               'updated_at',  'webhook-jobber CLIENT_UPDATE',                 168],
  ['properties',                    'updated_at',  'webhook-jobber + jobber-poll (full only)',     720],
  ['service_configs',               'updated_at',  'airtable webhook + populate (rare)',          720],
  ['jobs',                          'updated_at',  'webhook-jobber JOB_* + jobber-poll',           48],
  ['visits',                        'updated_at',  'webhook-jobber VISIT_* + jobber-poll',         24],
  ['invoices',                      'updated_at',  'webhook-jobber INVOICE_* + jobber-poll',       48],
  // line_items don't have an incremental webhook path — they're attached to
  // jobs and were loaded once via populate.js (2026-04-29). With Jobber
  // sunsetting May 2026, building a per-invoice line-item refresh isn't worth
  // it. Set threshold to "should-not-go-stale-before-sunset" (60 days).
  ['line_items',                    'updated_at',  'populate.js one-shot (no webhook refresh)',  1440],
  ['quotes',                        'updated_at',  'webhook-jobber QUOTE_* + jobber-poll',        168],
  ['employees',                     'updated_at',  'jobber-poll users (full only)',              720],
  ['vehicles',                      'updated_at',  'samsara webhook + manual seed',              720],
  ['inspections',                   'submitted_at', 'webhook-airtable PRE-POST',                   24],
  ['derm_manifests',                'updated_at',  'webhook-airtable Manifests',                  168],
  ['notes',                         'updated_at',  'daily-notes-photos-sync (12:00 UTC)',          48],
  ['photos',                        'created_at',  'daily-notes-photos-sync + airtable inspection sync', 48],
  ['photo_links',                   'created_at',  'same as photos',                                48],
  ['vehicle_telemetry_readings',    'recorded_at', 'samsara-poll (10 min)',                          1],
  ['entity_source_links',           'synced_at',   'all webhooks/syncs',                            48],
];

const SECTION = (t) => console.log(`\n${'='.repeat(72)}\n${t}\n${'='.repeat(72)}`);

(async () => {
  // ============================================================================
  // 1. PER-ENTITY DATA FRESHNESS
  // ============================================================================
  SECTION('1. Per-entity coverage (each canonical table → sync path → freshness)');
  console.log('  entity                       | last write           | hrs ago | max | sync path');
  console.log('  -----------------------------|----------------------|---------|-----|--------------------------------');
  let stale = 0, total = 0;
  for (const [entity, col, sync, maxH] of ENTITY_MAP) {
    total++;
    const r = await pg(`SELECT MAX(${col})::text AS latest, EXTRACT(EPOCH FROM (now() - MAX(${col})))::int / 3600.0 AS hrs FROM ${entity}`);
    const hrs = r[0].hrs ? Number(r[0].hrs).toFixed(1) : '∞';
    const latest = r[0].latest ? r[0].latest.slice(0, 19) : '(no rows)';
    const isStale = r[0].hrs === null || Number(r[0].hrs) > maxH;
    if (isStale) stale++;
    const flag = isStale ? '⚠️ ' : '   ';
    console.log(`  ${flag}${entity.padEnd(28)}| ${latest.padEnd(20)} | ${String(hrs).padStart(7)} | ${String(maxH).padStart(3)} | ${sync}`);
  }
  console.log(`\n  ${total - stale} of ${total} entities within freshness budget.`);

  // ============================================================================
  // 2. WEBHOOK DELIVERY (last 24h, per source)
  // ============================================================================
  SECTION('2. Webhook delivery — inbound feeds (24h)');
  const wh = await pg(`
    SELECT source_system,
      COUNT(*) AS n,
      COUNT(*) FILTER (WHERE error_message IS NOT NULL AND error_message <> '') AS err,
      MAX(created_at)::text AS last,
      EXTRACT(EPOCH FROM (now() - MAX(created_at)))::int / 60 AS min_since
    FROM webhook_events_log
    WHERE created_at >= now() - interval '24 hours'
    GROUP BY source_system ORDER BY 1;
  `);
  console.log('  source     | events | err | last event           | min since');
  console.log('  -----------|--------|-----|----------------------|----------');
  // Per-source expectations:
  //   airtable: should fire daily (PRE-POST inspection submissions)
  //   jobber: should fire daily (visits/jobs/clients churn)
  //   samsara: bursty — only fires when admin adds/edits geofence addresses.
  //            Real-time vehicle data flows via the 10-min polling cron, NOT
  //            webhooks. Days of silence are normal.
  const expectedSources = [
    { name: 'airtable', maxQuietMin: 240 },
    { name: 'jobber',   maxQuietMin: 360 },
    { name: 'samsara',  maxQuietMin: 14 * 24 * 60, note: 'config-only; telemetry via polling' },
  ];
  for (const src of expectedSources) {
    const r = wh.find(x => x.source_system === src.name);
    if (!r) {
      console.log(`     ${src.name.padEnd(9)}| 0 events in 24h${src.note ? ' — ' + src.note : ''}`);
    } else {
      const flag = r.err > 0 || r.min_since > src.maxQuietMin ? '⚠️ ' : '   ';
      console.log(`  ${flag}${src.name.padEnd(9)}| ${String(r.n).padStart(6)} | ${String(r.err).padStart(3)} | ${r.last.slice(0,19)} | ${r.min_since}`);
    }
  }

  // ============================================================================
  // 3. CRON HEALTH (latest run per workflow — only the latest matters)
  // ============================================================================
  SECTION('3. Cron health — latest run state per workflow');
  let runs;
  try {
    const out = execSync('gh run list --limit=80 --json name,status,conclusion,createdAt,event,workflowName', { cwd: PROJECT_ROOT, encoding: 'utf8' });
    runs = JSON.parse(out);
  } catch { runs = []; }
  const latest = {};
  for (const r of runs) {
    const k = r.workflowName || r.name;
    if (!latest[k] || new Date(r.createdAt) > new Date(latest[k].createdAt)) latest[k] = r;
  }
  console.log('  workflow                                          | latest run         | conclusion');
  console.log('  --------------------------------------------------|--------------------|------------');
  for (const [k, r] of Object.entries(latest)) {
    const flag = r.conclusion === 'success' ? '   ' : '⚠️ ';
    console.log(`  ${flag}${k.slice(0, 50).padEnd(50)}| ${r.createdAt.slice(0,19)} | ${r.conclusion}`);
  }

  // ============================================================================
  // 4. SYNC CURSORS (any stuck?)
  // ============================================================================
  SECTION('4. Sync cursors (stuck = no progress in 24h+)');
  const cur = await pg(`
    SELECT entity, last_synced_at::text, rows_pulled, last_run_status,
      EXTRACT(EPOCH FROM (now() - last_synced_at))::int / 3600.0 AS hrs_since
    FROM sync_cursors
    ORDER BY last_synced_at DESC NULLS LAST;
  `);
  // Entities with null CURSOR_FIELD in cron_jobber.js — full-pull only, so
  // last_synced_at staying at the epoch sentinel is correct, not stuck.
  const NULL_CURSOR_ENTITIES = new Set(['users', 'properties', 'line_items']);
  console.log('  entity                       | last run             | rows | status      | hrs ago | note');
  console.log('  -----------------------------|----------------------|------|-------------|---------|------');
  for (const c of cur) {
    const noCursor = NULL_CURSOR_ENTITIES.has(c.entity);
    // 72h threshold (same as audit_yesterday_today.js) — quotes and similar
    // low-activity entities can legitimately go a day without updates.
    const flag = noCursor ? '   ' : ((c.last_run_status === 'error' || (c.hrs_since && Number(c.hrs_since) > 72)) ? '⚠️ ' : '   ');
    const note = noCursor ? '(full-pull only)' : '';
    console.log(`  ${flag}${(c.entity || '?').padEnd(28)} | ${(c.last_synced_at || 'never').slice(0,19)} | ${String(c.rows_pulled || 0).padStart(4)} | ${(c.last_run_status || '?').padEnd(11)} | ${(c.hrs_since ? Number(c.hrs_since).toFixed(1) : 'n/a').padStart(7)} | ${note}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
