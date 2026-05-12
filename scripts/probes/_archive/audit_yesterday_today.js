// Stuck/missing cron + webhook audit covering yesterday + today (48h window).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const { execSync } = require('child_process');
const path = require('path');

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;
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
async function pg(project, sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${project}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

const SECTION = (t) => console.log(`\n${'='.repeat(70)}\n${t}\n${'='.repeat(70)}`);

(async () => {
  console.log(`Audit window: last 48h  |  ran at ${new Date().toISOString()}`);

  // ============================================================================
  // 1. GITHUB ACTIONS — every workflow run, last 48h
  // ============================================================================
  SECTION('1. GitHub Actions cron health (48h)');
  let runs;
  try {
    const out = execSync('gh run list --limit=100 --json name,status,conclusion,createdAt,event,workflowName,databaseId', { cwd: PROJECT_ROOT, encoding: 'utf8' });
    runs = JSON.parse(out);
  } catch (e) { console.log(`  ERR: ${e.message.slice(0, 100)}`); runs = []; }

  const since = Date.now() - 48 * 3600 * 1000;
  const recent = runs.filter(r => new Date(r.createdAt).getTime() > since);
  const byName = {};
  for (const r of recent) {
    const k = r.workflowName || r.name;
    if (!byName[k]) byName[k] = { ok: 0, fail: 0, latest: null, latestStatus: null, latestEvent: null };
    if (r.conclusion === 'success') byName[k].ok++;
    else if (r.conclusion === 'failure' || r.conclusion === 'cancelled') byName[k].fail++;
    if (!byName[k].latest || new Date(r.createdAt) > new Date(byName[k].latest)) {
      byName[k].latest = r.createdAt;
      byName[k].latestStatus = r.conclusion || r.status;
      byName[k].latestEvent = r.event;
    }
  }
  console.log('  workflow                                      |  ok | fail | latest                | status      | event');
  console.log('  ----------------------------------------------|-----|------|-----------------------|-------------|----------');
  // Flag only when LATEST run is failed/cancelled. Historical fails in the
  // 48h window are surfaced via the `fail` count column but don't trigger
  // the ⚠️ — those happen during normal iteration / reliability-noise and
  // muddy the signal of what's actually broken right now.
  for (const [k, c] of Object.entries(byName)) {
    const flag = (c.latestStatus === 'failure' || c.latestStatus === 'cancelled') ? '⚠️ ' : '   ';
    console.log(`  ${flag}${k.slice(0, 44).padEnd(44)} | ${String(c.ok).padStart(3)} | ${String(c.fail).padStart(4)} | ${c.latest.slice(0,19)} | ${(c.latestStatus || '?').padEnd(11)} | ${c.latestEvent}`);
  }

  // List workflows that should run on schedule and check expected cadence
  SECTION('2. Schedule-vs-actual gaps');
  const expected = [
    // GH Actions free runners DELAY scheduled events under load — a "every 2 min"
    // cron in YAML actually fires every 1-2 hours in practice. We compensate
    // here so the audit doesn't false-flag normal scheduling delays as failure.
    ['Jobber poll',            'jobber-poll',                  7200,  'every 2 min (GH delays → 1-2h)'],
    ['Samsara telemetry poll', 'samsara-poll',                 7200,  'every 10 min (GH delays → 1-2h)'],
    ['Daily cleanup',          'daily-cleanup',                86400, 'daily'],
    ['Daily notes+photos',     'daily-notes-photos-sync',     86400, 'daily'],
    ['Daily no-photo alert',   'daily-no-photo-alert',        86400, 'daily'],
    ['Sandbox refresh',        'sandbox-refresh',              86400, 'daily'],
    ['Derive vehicle id',      'derive-visit-vehicle-id',      3600, 'hourly'],
    ['Weekly dedup audit',     'weekly-dedup-audit',         604800, 'weekly Sun'],
    // (geocode-missing-properties is a one-shot script — no scheduled workflow)
  ];
  // Workflow-name → expected-yml-stem mapping. Match by inspecting the .github
  // file path via gh's --json `path` — but since gh doesn't return path here,
  // fall back to a curated lookup table of human names we know fire on schedule.
  const WORKFLOW_DISPLAY_NAMES = {
    'jobber-poll':              'Jobber polling sync',
    'samsara-poll':             'Samsara telemetry polling',
    'daily-cleanup':            'Daily DB cleanup',
    'daily-notes-photos-sync':  'Daily notes + photos sync from Jobber',
    'daily-no-photo-alert':     'Daily no-photo visits alert',
    'sandbox-refresh':          'Sandbox refresh (Production → Sandbox data sync)',
    'derive-visit-vehicle-id':  'Derive visit.vehicle_id from Samsara telemetry',
    'weekly-dedup-audit':       'Weekly dedup audit',
  };
  // For weekly+ workflows, also pull older runs so "0 in 48h" doesn't false-flag
  // when the cron simply hasn't fired this window. We re-query gh for runs
  // covering up to 14 days back when needed.
  let extendedRuns = null;
  for (const [label, ymlStem, expectedSec, cadence] of expected) {
    const displayName = WORKFLOW_DISPLAY_NAMES[ymlStem];
    let fired = recent.filter(r => (r.workflowName || r.name) === displayName);
    if (!fired.length && expectedSec >= 86400 * 3) {
      // Weekly+ — look further back so we can still report latest run age.
      if (!extendedRuns) {
        try {
          const out = execSync('gh run list --limit=400 --json name,status,conclusion,createdAt,workflowName', { cwd: PROJECT_ROOT, encoding: 'utf8' });
          extendedRuns = JSON.parse(out);
        } catch { extendedRuns = []; }
      }
      fired = extendedRuns.filter(r => (r.workflowName || r.name) === displayName);
    }
    if (!fired.length) {
      console.log(`  ⚠️  ${label.padEnd(28)} (${cadence})  → 0 runs found`);
      continue;
    }
    fired.sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
    const latest = fired[0];
    const ageSec = (Date.now() - new Date(latest.createdAt).getTime()) / 1000;
    const hrs = (ageSec / 3600).toFixed(1);
    const overdue = ageSec > expectedSec * 2;
    const recent48 = recent.filter(r => (r.workflowName || r.name) === displayName).length;
    console.log(`  ${overdue ? '⚠️ ' : '   '} ${label.padEnd(28)} (${cadence}) → latest ${hrs}h ago, ${recent48} runs in 48h`);
  }

  // ============================================================================
  // 3. WEBHOOK DELIVERY — Prod
  // ============================================================================
  SECTION('3. Webhook delivery (Prod, last 48h)');
  const wh = await pg(PROD, `
    SELECT
      source_system,
      COUNT(*) AS total_48h,
      COUNT(*) FILTER (WHERE error_message IS NULL OR error_message = '') AS ok,
      COUNT(*) FILTER (WHERE error_message IS NOT NULL AND error_message <> '') AS err,
      MIN(created_at)::text AS first_event,
      MAX(created_at)::text AS last_event,
      EXTRACT(EPOCH FROM (now() - MAX(created_at)))::int / 60 AS minutes_since
    FROM webhook_events_log
    WHERE created_at >= now() - interval '48 hours'
    GROUP BY source_system
    ORDER BY 1;
  `);
  if (!wh.length) {
    console.log('  (no events in 48h — webhook receivers may be down)');
  } else {
    console.log('  source     | 48h total | ok    | err  | last event           | min since');
    console.log('  -----------|-----------|-------|------|----------------------|----------');
    for (const r of wh) {
      const flag = r.err > 0 || r.minutes_since > 240 ? '⚠️ ' : '   ';
      console.log(`  ${flag}${r.source_system.padEnd(9)}| ${String(r.total_48h).padStart(9)} | ${String(r.ok).padStart(5)} | ${String(r.err).padStart(4)} | ${r.last_event.slice(0,19)} | ${r.minutes_since}`);
    }
  }

  // Per-source event-type breakdown — schema column is `event_type`, not `action`.
  console.log('\n  Event types (Prod, 48h):');
  const byType = await pg(PROD, `
    SELECT source_system, event_type, COUNT(*) AS n,
      COUNT(*) FILTER (WHERE error_message IS NOT NULL AND error_message <> '') AS err
    FROM webhook_events_log
    WHERE created_at >= now() - interval '48 hours'
    GROUP BY source_system, event_type
    ORDER BY source_system, n DESC;
  `);
  let lastSrc = '';
  for (const r of byType) {
    if (r.source_system !== lastSrc) { console.log(`    ${r.source_system}:`); lastSrc = r.source_system; }
    const flag = r.err > 0 ? '⚠️ ' : '   ';
    console.log(`    ${flag}  ${(r.event_type || '(null)').slice(0, 45).padEnd(45)} ${String(r.n).padStart(5)}${r.err > 0 ? `  (${r.err} err)` : ''}`);
  }

  // ============================================================================
  // 4. SYNC CURSORS — any stuck?
  // ============================================================================
  SECTION('4. Sync cursors (Prod)');
  const cur = await pg(PROD, `
    SELECT entity, last_synced_at::text, rows_pulled, last_run_status,
      EXTRACT(EPOCH FROM (now() - last_synced_at))::int / 60 AS min_since
    FROM sync_cursors
    ORDER BY last_synced_at DESC NULLS LAST;
  `);
  // Entities that have a null CURSOR_FIELD in cron_jobber.js (no incremental
  // delta — they're pulled in --full mode only). Their last_synced_at staying
  // at the epoch sentinel is correct, not a problem.
  const NULL_CURSOR_ENTITIES = new Set(['users', 'properties', 'line_items']);
  console.log('  entity                              | last run             | rows | status      | min ago | note');
  console.log('  ------------------------------------|----------------------|------|-------------|---------|---------');
  for (const c of cur) {
    const noCursor = NULL_CURSOR_ENTITIES.has(c.entity);
    // 72h threshold — many entities (quotes, certain client edits) genuinely
    // don't see activity every day. Anything past 3 days suggests the path
    // is broken; anything inside is normal lull.
    const flag = noCursor ? '   ' : ((c.last_run_status === 'error' || c.min_since > 60 * 72) ? '⚠️ ' : '   ');
    const note = noCursor ? '(no incremental cursor — full-pull only)' : '';
    console.log(`  ${flag}${(c.entity || '?').slice(0, 35).padEnd(35)} | ${(c.last_synced_at || 'never').slice(0,19)} | ${String(c.rows_pulled || 0).padStart(4)} | ${(c.last_run_status || '?').padEnd(11)} | ${String(c.min_since || 'n/a').padStart(7)} | ${note}`);
  }

  // ============================================================================
  // 5. DATA FRESHNESS per canonical entity (Prod)
  // ============================================================================
  SECTION('5. Data freshness (Prod, hours since last write)');
  const fresh = await pg(PROD, `
    SELECT 'clients'                AS entity, MAX(updated_at)::text AS latest, EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int AS sec FROM clients UNION ALL
    SELECT 'visits',                                  MAX(updated_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int FROM visits UNION ALL
    SELECT 'invoices',                                MAX(updated_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int FROM invoices UNION ALL
    SELECT 'jobs',                                    MAX(updated_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int FROM jobs UNION ALL
    SELECT 'inspections (submitted_at)',              MAX(submitted_at)::text,         EXTRACT(EPOCH FROM (now() - MAX(submitted_at)))::int FROM inspections UNION ALL
    SELECT 'derm_manifests',                          MAX(updated_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int FROM derm_manifests UNION ALL
    SELECT 'vehicle_telemetry_readings (recorded)',   MAX(recorded_at)::text,          EXTRACT(EPOCH FROM (now() - MAX(recorded_at)))::int FROM vehicle_telemetry_readings UNION ALL
    SELECT 'notes',                                   MAX(updated_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int FROM notes UNION ALL
    SELECT 'photos',                                  MAX(created_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(created_at)))::int FROM photos
    ORDER BY 1;
  `);
  console.log('  entity                                  | latest                | hours');
  console.log('  ----------------------------------------|-----------------------|--------');
  for (const r of fresh) {
    const hrs = (r.sec / 3600);
    const flag = hrs > 26 ? '⚠️ ' : '   ';
    console.log(`  ${flag}${r.entity.slice(0, 38).padEnd(38)} | ${(r.latest || 'n/a').slice(0,19)} | ${hrs.toFixed(1)}h`);
  }

  // ============================================================================
  // 6. SANDBOX vs PROD row count diff (mirroring health)
  // ============================================================================
  // Sandbox refreshes from Prod once daily. Drift between refreshes is normal
  // (Prod has new rows that Sandbox won't see until tomorrow's refresh).
  // Threshold for ⚠️: drift > 5% of total OR sandbox has MORE rows than prod
  // (would indicate a refresh issue). Otherwise just informational.
  SECTION('6. Sandbox row counts vs Prod (drift expected between daily refreshes)');
  const tables = ['clients','visits','invoices','jobs','inspections','notes','photos','photo_links','derm_manifests','employees','vehicles','entity_source_links'];
  for (const t of tables) {
    const [p, s] = await Promise.all([
      pg(PROD, `SELECT COUNT(*) AS n FROM ${t}`),
      pg(SB,   `SELECT COUNT(*) AS n FROM ${t}`)
    ]);
    const pn = p[0].n, sn = s[0].n;
    const diff = pn - sn;
    const driftPct = pn > 0 ? Math.abs(diff) / pn : 0;
    const concerning = diff < 0 || driftPct > 0.05;
    const flag = concerning ? '⚠️ ' : '   ';
    console.log(`  ${flag}${t.padEnd(25)} prod=${String(pn).padStart(7)}  sandbox=${String(sn).padStart(7)}  diff=${diff > 0 ? '+' : ''}${diff}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
