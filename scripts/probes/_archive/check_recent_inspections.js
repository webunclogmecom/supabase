require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c) }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}

async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.toString().slice(0, 200)}`);
  return JSON.parse(r.body.toString());
}

(async () => {
  // 1. Last 7 days of inspections, grouped by date (ET-local)
  console.log('=== Inspections last 7 days (ET date) ===');
  const ins = await pg(`
    SELECT
      (i.submitted_at AT TIME ZONE 'America/New_York')::date AS et_date,
      i.inspection_type,
      COUNT(*) AS n,
      MIN(i.submitted_at AT TIME ZONE 'America/New_York')::text AS first_et,
      MAX(i.submitted_at AT TIME ZONE 'America/New_York')::text AS last_et
    FROM inspections i
    WHERE i.submitted_at >= now() - interval '7 days'
    GROUP BY 1, 2
    ORDER BY 1 DESC, 2;
  `);
  for (const r of ins) console.log(' ', r.et_date, r.inspection_type, '×', r.n, '|', r.first_et, '→', r.last_et);

  // 2. Recent Airtable webhook events for inspections (PRE/POST)
  console.log('\n=== Airtable webhook events on inspections, last 36h ===');
  const evs = await pg(`
    SELECT received_at, source_system, action, payload->>'tableName' AS table_name, status, error_message
    FROM webhook_events_log
    WHERE received_at >= now() - interval '36 hours'
      AND source_system = 'airtable'
      AND (payload->>'tableName' ILIKE '%PRE%' OR payload->>'tableName' ILIKE '%POST%' OR payload->>'tableName' ILIKE '%inspect%')
    ORDER BY received_at DESC
    LIMIT 20;
  `);
  if (!evs.length) console.log('  (none)');
  for (const r of evs) console.log(' ', r.received_at, r.action, '|', r.table_name, '|', r.status || '?', r.error_message ? '— '+r.error_message.slice(0,80) : '');

  // 3. ANY airtable webhook events last 6h
  console.log('\n=== Any Airtable webhook events, last 6h ===');
  const recent = await pg(`
    SELECT received_at, source_system, action, payload->>'tableName' AS table_name, status
    FROM webhook_events_log
    WHERE received_at >= now() - interval '6 hours'
      AND source_system = 'airtable'
    ORDER BY received_at DESC
    LIMIT 30;
  `);
  if (!recent.length) console.log('  (none — Airtable webhook may be silent or sync_cursors stuck)');
  for (const r of recent) console.log(' ', r.received_at, r.action, '|', r.table_name, '|', r.status || '?');
})();
