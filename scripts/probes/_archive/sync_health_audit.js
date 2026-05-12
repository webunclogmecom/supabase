// Comprehensive sync-health audit across all services (Jobber, Airtable,
// Samsara) and all crons. Inspired by the createdAt/updatedAt bug found
// 2026-05-04 — surface similar issues before they bite.
//
// Sections:
//   1. Webhook delivery health per source (last event, count, errors)
//   2. Cron health per workflow (last run, failure rate)
//   3. Cursor-field correctness scan (createdAt vs updatedAt for mutable entities)
//   4. Sync coverage per entity (Jobber/Airtable/Samsara totals vs our DB)
//   5. Data freshness (most-recent timestamp per entity)

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const https = require('https');

const PROJECT_ROOT = path.resolve(__dirname, '../..');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.setTimeout(60000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}
async function gqlJobber(query, variables) {
  const body = JSON.stringify({ query, variables });
  const r = await http({
    hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: {
      Authorization: `Bearer ${process.env.JOBBER_ACCESS_TOKEN}`,
      'X-JOBBER-GRAPHQL-VERSION': '2026-04-13',
      'Content-Type': 'application/json',
    },
  }, body);
  return JSON.parse(r.body);
}

const SECTION = (t) => console.log(`\n${'='.repeat(72)}\n${t}\n${'='.repeat(72)}`);

(async () => {
  console.log(`Sync-health audit — ${new Date().toISOString()}`);

  // ============================================================================
  // 1. WEBHOOK DELIVERY HEALTH
  // ============================================================================
  SECTION('1. Webhook delivery health (last 24h)');

  const wh = await pg(`
    SELECT
      source_system,
      COUNT(*) AS total_24h,
      COUNT(*) FILTER (WHERE status='success') AS ok,
      COUNT(*) FILTER (WHERE status='error' OR error_message IS NOT NULL) AS err,
      MAX(created_at)::text AS last_event,
      EXTRACT(EPOCH FROM (now() - MAX(created_at)))::int AS seconds_since
    FROM webhook_events_log
    WHERE created_at >= now() - interval '24 hours'
    GROUP BY source_system
    ORDER BY 1;
  `);
  console.log('  source     | 24h total | ok    | err   | last event           | minutes since');
  console.log('  -----------|-----------|-------|-------|----------------------|---------------');
  for (const r of wh) {
    console.log(`  ${r.source_system.padEnd(11)}| ${String(r.total_24h).padStart(9)} | ${String(r.ok).padStart(5)} | ${String(r.err).padStart(5)} | ${r.last_event.slice(0,19)} | ${Math.round(r.seconds_since/60)}`);
  }

  // Per-source event-type breakdown
  console.log('\n  Event-type breakdown last 24h:');
  const byType = await pg(`
    SELECT source_system, event_type, COUNT(*) AS n,
      COUNT(*) FILTER (WHERE error_message IS NOT NULL) AS err
    FROM webhook_events_log
    WHERE created_at >= now() - interval '24 hours'
    GROUP BY source_system, event_type
    ORDER BY source_system, n DESC
    LIMIT 30;
  `);
  let lastSrc = '';
  for (const r of byType) {
    if (r.source_system !== lastSrc) { console.log(`    ${r.source_system}:`); lastSrc = r.source_system; }
    console.log(`      ${(r.event_type || '(null)').padEnd(35)} ${String(r.n).padStart(5)}${r.err > 0 ? ` (${r.err} err)` : ''}`);
  }

  // ============================================================================
  // 2. CRON HEALTH
  // ============================================================================
  SECTION('2. Cron workflow health (last 24h)');

  try {
    const out = execSync('gh run list --limit=50 --json name,status,conclusion,createdAt,event,databaseId', { cwd: PROJECT_ROOT, encoding: 'utf8' });
    const runs = JSON.parse(out);
    const since = Date.now() - 24 * 3600 * 1000;
    const recent = runs.filter(r => new Date(r.createdAt).getTime() > since && r.event === 'schedule');
    const byName = {};
    for (const r of recent) {
      if (!byName[r.name]) byName[r.name] = { ok: 0, fail: 0, latest: null, latestStatus: null };
      if (r.conclusion === 'success') byName[r.name].ok++; else byName[r.name].fail++;
      if (!byName[r.name].latest || new Date(r.createdAt) > new Date(byName[r.name].latest)) {
        byName[r.name].latest = r.createdAt;
        byName[r.name].latestStatus = r.conclusion;
      }
    }
    console.log('  workflow                                          | runs | ok | fail | latest                | latest status');
    console.log('  --------------------------------------------------|------|----|----- |-----------------------|---------------');
    for (const [name, c] of Object.entries(byName)) {
      const total = c.ok + c.fail;
      console.log(`  ${name.slice(0, 50).padEnd(50)}| ${String(total).padStart(4)} | ${String(c.ok).padStart(2)} | ${String(c.fail).padStart(4)} | ${c.latest.slice(0,19)} | ${c.latestStatus}`);
    }
  } catch (e) { console.log(`  ERR: ${e.message.slice(0, 100)}`); }

  // ============================================================================
  // 3. CURSOR-FIELD CORRECTNESS SCAN (the createdAt/updatedAt bug class)
  // ============================================================================
  SECTION('3. Cursor-field correctness scan');
  console.log('  Looking for createdAt cursors on entities that change after creation.');
  console.log('  Mutable entities: visits (status transitions), invoices (payment),');
  console.log('  jobs (status), notes (edits). Should use updatedAt for incremental sync.\n');

  const cronJobber = fs.readFileSync(path.resolve(__dirname, '../sync/cron_jobber.js'), 'utf8');
  // Find CURSOR_FIELD assignments per entity
  const cursorMatches = [...cronJobber.matchAll(/(\w+):\s*\{[^}]*CURSOR_FIELD:\s*['"](\w+)['"]/g)];
  const nodeTimeMatches = [...cronJobber.matchAll(/(\w+):\s*\{[^}]*NODE_TIME_FIELD:\s*['"](\w+)['"]/g)];
  console.log('  cron_jobber.js cursors:');
  for (const m of cursorMatches) {
    const tbl = m[1], field = m[2];
    const mutable = ['visits', 'invoices', 'jobs', 'notes', 'quotes'].includes(tbl);
    const ok = !mutable || field === 'updatedAt';
    const note = (mutable && field === 'createdAt') ? "  ← BUG: status changes won't trigger re-pull" : '';
    console.log(`    ${ok ? '✅' : '❌'} ${tbl.padEnd(15)} CURSOR_FIELD=${field}${note}`);
  }

  // Same scan on samsara/airtable replay scripts
  for (const f of ['cron_samsara_telemetry.js', 'airtable_replay.js']) {
    const fp = path.resolve(__dirname, '../sync', f);
    if (!fs.existsSync(fp)) continue;
    const content = fs.readFileSync(fp, 'utf8');
    const cursorRegex = /['"](modifiedTime|updatedAt|createdAt|created_at|recorded_at)['"]/g;
    const found = [...new Set([...content.matchAll(cursorRegex)].map(m => m[1]))];
    console.log(`\n  ${f} cursor-related strings: ${found.join(', ') || '(none found)'}`);
  }

  // ============================================================================
  // 4. SYNC COVERAGE — Jobber side
  // ============================================================================
  SECTION('4. Sync coverage (Jobber vs DB, lightweight count check)');

  for (const [name, query, table, eslType] of [
    ['clients', '{ clients(first: 1) { totalCount } }', 'clients', 'client'],
    ['visits ≥2026',  '{ visits(first: 1, filter: { startAt: { after: "2026-01-01T00:00:00Z" } }) { totalCount } }', 'visits', 'visit'],
    ['invoices', '{ invoices(first: 1) { totalCount } }', 'invoices', 'invoice'],
    ['jobs', '{ jobs(first: 1) { totalCount } }', 'jobs', 'job'],
  ]) {
    try {
      const j = await gqlJobber(query, {});
      const jobberCount = j.data?.[Object.keys(j.data)[0]]?.totalCount;
      const dbCount = (await pg(`SELECT COUNT(*) AS n FROM entity_source_links WHERE entity_type='${eslType}' AND source_system='jobber'`))[0].n;
      const gap = jobberCount - dbCount;
      const status = gap === 0 ? '✅' : gap > 0 ? '❌' : '⚠️';
      console.log(`  ${status} ${name.padEnd(15)} jobber=${String(jobberCount).padStart(5)} db=${String(dbCount).padStart(5)} gap=${gap >= 0 ? '+' : ''}${gap}`);
    } catch (e) { console.log(`  ⚠️  ${name}: ${e.message.slice(0, 80)}`); }
  }

  // ============================================================================
  // 5. DATA FRESHNESS — most-recent timestamp per entity
  // ============================================================================
  SECTION('5. Data freshness in our DB');

  const fresh = await pg(`
    SELECT 'clients'    AS entity, MAX(updated_at)::text AS latest, EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int AS sec_since FROM clients UNION ALL
    SELECT 'visits',                 MAX(updated_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int FROM visits UNION ALL
    SELECT 'invoices',               MAX(updated_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int FROM invoices UNION ALL
    SELECT 'jobs',                   MAX(updated_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int FROM jobs UNION ALL
    SELECT 'inspections',            MAX(submitted_at)::text,         EXTRACT(EPOCH FROM (now() - MAX(submitted_at)))::int FROM inspections UNION ALL
    SELECT 'derm_manifests',         MAX(updated_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int FROM derm_manifests UNION ALL
    SELECT 'vehicle_telemetry_readings', MAX(recorded_at)::text,      EXTRACT(EPOCH FROM (now() - MAX(recorded_at)))::int FROM vehicle_telemetry_readings UNION ALL
    SELECT 'notes',                  MAX(updated_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(updated_at)))::int FROM notes UNION ALL
    SELECT 'photos',                 MAX(created_at)::text,           EXTRACT(EPOCH FROM (now() - MAX(created_at)))::int FROM photos
    ORDER BY 1;
  `);
  console.log('  entity                          | latest                | hrs since');
  console.log('  --------------------------------|-----------------------|----------');
  for (const r of fresh) {
    const hrs = (r.sec_since / 3600).toFixed(1);
    const flag = r.sec_since > 24 * 3600 ? '⚠️ ' : '   ';
    console.log(`  ${flag} ${r.entity.padEnd(30)}| ${(r.latest || '(no rows)').slice(0,19)} | ${hrs}h`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
