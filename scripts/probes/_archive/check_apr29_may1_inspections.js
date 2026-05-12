// Check May 1 + Apr 29 inspections specifically and their photo coverage in Prod and Sandbox.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const r = (project, sql) => new Promise((res, rej) => {
  const req = https.request({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${project}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(JSON.parse(b))); });
  req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
});

const PROD = process.env.SUPABASE_PROJECT_ID;
const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;

(async () => {
  for (const [label, proj] of [['PROD', PROD], ['SANDBOX', SB]]) {
    console.log(`\n=== ${label}: shift_dates 2026-04-29 + 2026-05-01 ===`);
    const rows = await r(proj, `
      SELECT i.id, i.inspection_type,
             i.shift_date::text AS shift_date,
             i.submitted_at::text AS submitted,
             (i.submitted_at AT TIME ZONE 'America/New_York')::text AS submitted_et,
             i.created_at::text AS db_created,
             i.employee_id,
             (SELECT COUNT(*) FROM photo_links pl WHERE pl.entity_type='inspection' AND pl.entity_id = i.id) AS photo_count
      FROM inspections i
      WHERE i.shift_date IN ('2026-04-29', '2026-05-01')
      ORDER BY i.shift_date, i.inspection_type, i.submitted_at;
    `);
    console.log(`  ${rows.length} inspections`);
    for (const row of rows) {
      console.log(`    #${row.id}  ${row.inspection_type}  shift=${row.shift_date}  submitted_ET=${row.submitted_et}  emp=${row.employee_id}  photos=${row.photo_count}  db_created=${row.db_created}`);
    }
  }

  // Sync cursor for inspection sync
  console.log(`\n=== Sandbox sync cursors (any inspection-related) ===`);
  const cur = await r(SB, `SELECT entity, last_run_at::text, rows_pulled, last_run_status FROM sync_cursors ORDER BY last_run_at DESC NULLS LAST LIMIT 20`).catch(e => { console.log('err:', e.message); return []; });
  for (const c of (Array.isArray(cur) ? cur : [])) {
    if (/inspect|airtable|prepost|pre_post/i.test(c.entity)) console.log(`  ${c.entity.padEnd(40)} last_run=${c.last_run_at}  rows=${c.rows_pulled}  status=${c.last_run_status}`);
  }

  // Recent airtable webhook events
  console.log(`\n=== Recent Airtable webhook events (last 48h, Prod) ===`);
  const wh = await r(PROD, `
    SELECT received_at::text, action, payload->>'tableName' AS table_name, status
    FROM webhook_events_log
    WHERE received_at >= now() - interval '48 hours' AND source_system = 'airtable'
      AND (payload->>'tableName' ILIKE '%PRE%' OR payload->>'tableName' ILIKE '%POST%' OR payload->>'tableName' ILIKE '%inspect%')
    ORDER BY received_at DESC LIMIT 15
  `).catch(() => []);
  if (!wh.length) console.log('  (no Airtable PRE/POST webhook events in 48h)');
  for (const w of wh) console.log(`  ${w.received_at}  ${w.action}  ${w.table_name}  status=${w.status}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
