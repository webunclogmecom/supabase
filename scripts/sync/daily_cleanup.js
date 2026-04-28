// ============================================================================
// daily_cleanup.js — periodic DB hygiene
// ============================================================================
// Runs daily via GitHub Actions. Two jobs in one script:
//
//   1. webhook_events_log retention — delete rows older than RETENTION_DAYS
//      (default 30). Without this, the table grows ~2k rows/day (mostly cron
//      replay traffic) and crosses 700 MB within a year. The data has minimal
//      audit value past a month; recent failures are what we actually act on.
//
//   2. Stale-cache cleanup — find raw.jobber_pull_* rows whose Jobber entity
//      has been deleted (last 7 days of "not found" failures) and clear their
//      needs_populate flag. Without this, the cron retries them every cycle
//      forever, polluting the log with the same failures.
//
// Required env (set as GH Actions secrets — same as cron_jobber.js):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_PAT
//
// CLI:
//   node scripts/sync/daily_cleanup.js                 # all jobs
//   node scripts/sync/daily_cleanup.js --retention=60  # 60-day retention
//   node scripts/sync/daily_cleanup.js --skip-stale    # only retention
// ============================================================================

const https = require('https');

const SUPABASE_URL = process.env.SUPABASE_URL;
const PAT = process.env.SUPABASE_PAT;
if (!SUPABASE_URL || !PAT) throw new Error('SUPABASE_URL and SUPABASE_PAT required');

const RETENTION_DAYS = parseInt((process.argv.find(a => a.startsWith('--retention=')) || '').split('=')[1] || '30', 10);
const SKIP_STALE = process.argv.includes('--skip-stale');

const projectRef = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

function execSql(sql) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${projectRef}/database/query`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${PAT}`, 'Content-Length': Buffer.byteLength(body) },
    }, res => {
      let d = ''; res.on('data', c => (d += c));
      res.on('end', () => res.statusCode < 300 ? resolve(JSON.parse(d || '[]')) : reject(new Error(`SQL ${res.statusCode}: ${d.slice(0, 200)}`)));
    });
    req.on('error', reject);
    req.setTimeout(60_000, () => req.destroy(new Error('timeout')));
    req.write(body); req.end();
  });
}

(async () => {
  console.log(`[cleanup] start ${new Date().toISOString()}`);

  // 1. webhook_events_log retention
  console.log(`[cleanup] purging webhook_events_log rows older than ${RETENTION_DAYS} days`);
  const r1 = await execSql(`
    WITH del AS (
      DELETE FROM webhook_events_log
      WHERE created_at < now() - interval '${RETENTION_DAYS} days'
      RETURNING 1
    )
    SELECT count(*)::int AS deleted FROM del;
  `);
  console.log(`[cleanup] deleted ${r1[0]?.deleted ?? 0} log rows`);

  // 2. Stale-cache cleanup — clear needs_populate on raw rows that consistently
  // fail "not found" on Jobber (last 7 days). Self-healing without a schema change.
  if (!SKIP_STALE) {
    const queries = [
      ['visits', 'jobber_pull_visits', `error_message LIKE 'Jobber GraphQL error%Visit not found%' OR error_message LIKE 'Visit insert failed: null value in column "visit_date"%' OR error_message LIKE 'Visit update failed: null value in column "visit_date"%'`],
      ['clients', 'jobber_pull_clients', `error_message LIKE 'Client%not found in Jobber'`],
      ['properties', 'jobber_pull_properties', `error_message LIKE 'Property%not found in Jobber'`],
      ['jobs', 'jobber_pull_jobs', `error_message LIKE 'Job%not found in Jobber'`],
      ['invoices', 'jobber_pull_invoices', `error_message LIKE 'Invoice%not found in Jobber'`],
      ['quotes', 'jobber_pull_quotes', `error_message LIKE 'Quote%not found in Jobber'`],
    ];
    for (const [name, table, pattern] of queries) {
      const r = await execSql(`
        WITH cleared AS (
          UPDATE raw.${table} SET needs_populate=FALSE
          WHERE needs_populate=TRUE
            AND data->>'id' IN (
              SELECT DISTINCT payload->'webHookEvent'->>'itemId'
              FROM webhook_events_log
              WHERE source_system='jobber' AND status='failed'
                AND (${pattern})
                AND created_at > now() - interval '7 days'
            )
          RETURNING 1
        )
        SELECT count(*)::int AS n FROM cleared;
      `);
      const n = r[0]?.n ?? 0;
      if (n > 0) console.log(`[cleanup] ${name}: cleared ${n} stale flag(s)`);
    }
  }

  console.log(`[cleanup] done ${new Date().toISOString()}`);
})().catch(err => {
  console.error('[cleanup] FATAL:', err.message);
  process.exit(1);
});
