// For each active client + service_type, compute:
//   expected_next_visit = last_completed_visit + frequency_days
//   actual_next_visit   = next scheduled visit of same type after today
// Flag where actual is way past expected (or no next visit scheduled at all).
// Mirrors Yannick's 069-TCE concern.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

async function pg(sql) {
  for (let i = 0; i < 3; i++) {
    const out = await new Promise((res, rej) => {
      const req = https.request({
        hostname: 'api.supabase.com',
        path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
        method: 'POST',
        headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
      }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({ status: x.statusCode, body: b })); });
      req.on('error', rej); req.write(JSON.stringify({ query: sql })); req.end();
    });
    if (out.status < 300) return JSON.parse(out.body);
    await new Promise(rs => setTimeout(rs, 4000));
  }
  throw new Error('5xx');
}

(async () => {
  const rows = await pg(`
    WITH active AS (
      SELECT sc.client_id, c.client_code, c.name, sc.service_type, sc.frequency_days
      FROM service_configs sc
      JOIN clients c ON c.id = sc.client_id
      WHERE c.status IN ('ACTIVE','Recuring','recuring')
        AND sc.frequency_days > 0
        AND sc.service_type IN ('GT','CL')
    ),
    last_visit AS (
      SELECT v.client_id, v.service_type, MAX(v.visit_date) AS last_done
      FROM visits v
      WHERE v.visit_status = 'completed'
      GROUP BY v.client_id, v.service_type
    ),
    next_visit AS (
      SELECT v.client_id, v.service_type, MIN(v.visit_date) AS next_scheduled
      FROM visits v
      WHERE v.visit_status IN ('scheduled','today','late')
        AND v.visit_date >= CURRENT_DATE - INTERVAL '60 days'
      GROUP BY v.client_id, v.service_type
    )
    SELECT
      a.client_code,
      a.name,
      a.service_type,
      a.frequency_days AS freq,
      lv.last_done::text,
      (lv.last_done + a.frequency_days * INTERVAL '1 day')::date::text AS expected_next,
      nv.next_scheduled::text AS actual_next,
      (CURRENT_DATE - lv.last_done)::int AS days_since_last,
      CASE
        WHEN nv.next_scheduled IS NULL THEN
          (CURRENT_DATE - (lv.last_done + a.frequency_days * INTERVAL '1 day')::date)::int
        ELSE
          (nv.next_scheduled - (lv.last_done + a.frequency_days * INTERVAL '1 day')::date)::int
      END AS slip_days
    FROM active a
    LEFT JOIN last_visit lv ON lv.client_id = a.client_id AND lv.service_type = a.service_type
    LEFT JOIN next_visit nv ON nv.client_id = a.client_id AND nv.service_type = a.service_type
    WHERE lv.last_done IS NOT NULL  -- skip clients that never had a typed visit
    ORDER BY slip_days DESC NULLS FIRST;
  `);

  // Group by status
  const noNext     = rows.filter(r => r.actual_next === null && r.slip_days > 0);
  const wayLate    = rows.filter(r => r.actual_next !== null && r.slip_days > 14);
  const slightlyLate = rows.filter(r => r.actual_next !== null && r.slip_days > 0 && r.slip_days <= 14);

  console.log(`=== UPCOMING-VISIT-vs-FREQUENCY DRIFT ===`);
  console.log(`Inputs: ${rows.length} active GT/CL configs with at least one completed visit\n`);

  console.log(`A. NO upcoming visit scheduled — already overdue: ${noNext.length}`);
  console.log(`   client    | svc | freq | last done   | should-have-been-by | days overdue | name`);
  console.log(`   ----------|-----|------|-------------|---------------------|--------------|-----`);
  for (const r of noNext) {
    console.log(`   ${r.client_code.padEnd(10)}| ${r.service_type.padEnd(3)} | ${String(r.freq).padStart(4)} | ${r.last_done}  | ${r.expected_next}          | ${String(r.slip_days).padStart(12)} | ${r.name.slice(0, 40)}`);
  }

  console.log(`\nB. Has upcoming visit but scheduled WAY late (>14 days past expected): ${wayLate.length}`);
  console.log(`   client    | svc | freq | last done   | expected next  | actual next    | slip | name`);
  console.log(`   ----------|-----|------|-------------|----------------|----------------|------|-----`);
  for (const r of wayLate) {
    console.log(`   ${r.client_code.padEnd(10)}| ${r.service_type.padEnd(3)} | ${String(r.freq).padStart(4)} | ${r.last_done}  | ${r.expected_next}     | ${r.actual_next}     | ${String(r.slip_days).padStart(4)} | ${r.name.slice(0, 35)}`);
  }

  console.log(`\nC. Slightly late (1-14 days past expected): ${slightlyLate.length} — informational`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
