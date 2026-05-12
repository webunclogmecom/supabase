// Who did each visit? Audit driver/truck attribution coverage on visits.
// Two potential sources:
//   1. Jobber → visit.assignedTo[] (drivers/employees on the visit)
//   2. Samsara → which truck was at the geofence at visit time (telemetry)
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PAT = process.env.SUPABASE_PAT;
const TARGETS = [
  { label: 'PRODUCTION', projectId: process.env.SUPABASE_PROJECT_ID },
  { label: 'SANDBOX',    projectId: process.env.SANDBOX_SUPABASE_PROJECT_ID },
];

function q(projectId, sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${projectId}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  for (const t of TARGETS) {
    console.log(`\n${'='.repeat(70)}\n${t.label} (${t.projectId})\n${'='.repeat(70)}`);

    console.log('\n=== visits table — does it have driver/vehicle/employee FK columns? ===');
    console.table(await q(t.projectId, `
      SELECT column_name, data_type FROM information_schema.columns
      WHERE table_schema='public' AND table_name='visits' ORDER BY ordinal_position;
    `));

    console.log('\n=== visit_assignments table — schema ===');
    console.table(await q(t.projectId, `
      SELECT column_name, data_type FROM information_schema.columns
      WHERE table_schema='public' AND table_name='visit_assignments' ORDER BY ordinal_position;
    `));

    console.log('\n=== Coverage: how many visits have ANY assignment row? ===');
    console.table(await q(t.projectId, `
      SELECT
        (SELECT COUNT(*) FROM visits) AS total_visits,
        (SELECT COUNT(DISTINCT visit_id) FROM visit_assignments) AS visits_with_assignment,
        ROUND(100.0 * (SELECT COUNT(DISTINCT visit_id) FROM visit_assignments) /
              NULLIF((SELECT COUNT(*) FROM visits), 0), 1) AS pct_covered;
    `));

    console.log('\n=== visit_assignments breakdown by employee ===');
    console.table(await q(t.projectId, `
      SELECT
        e.full_name AS employee,
        e.role,
        e.status,
        COUNT(*) AS n_visits
      FROM visit_assignments va
      LEFT JOIN employees e ON e.id = va.employee_id
      GROUP BY e.full_name, e.role, e.status
      ORDER BY n_visits DESC LIMIT 15;
    `));

    console.log('\n=== visits.vehicle_id / truck / completed_by coverage ===');
    console.table(await q(t.projectId, `
      SELECT
        (SELECT COUNT(*) FROM visits) AS total,
        (SELECT COUNT(*) FROM visits WHERE vehicle_id IS NOT NULL) AS has_vehicle_fk,
        (SELECT COUNT(*) FROM visits WHERE truck IS NOT NULL AND truck != '') AS has_truck_text,
        (SELECT COUNT(*) FROM visits WHERE completed_by IS NOT NULL AND completed_by != '') AS has_completed_by_text;
    `));

    console.log('\n=== Visits WITHOUT any assignment (gaps) — by year/status ===');
    console.table(await q(t.projectId, `
      SELECT
        EXTRACT(YEAR FROM v.visit_date)::int AS year,
        v.visit_status,
        COUNT(*) AS n
      FROM visits v
      WHERE NOT EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id = v.id)
      GROUP BY year, v.visit_status
      ORDER BY year DESC, v.visit_status;
    `));

    console.log('\n=== Sample 5 recent visits + attributions ===');
    console.table(await q(t.projectId, `
      SELECT
        v.id, v.visit_date, v.visit_status,
        c.client_code,
        v.truck AS truck_text,
        v.completed_by AS completed_by_text,
        veh.name AS vehicle_fk,
        STRING_AGG(e.full_name, ', ') AS assigned_employees
      FROM visits v
      LEFT JOIN clients c ON c.id = v.client_id
      LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
      LEFT JOIN visit_assignments va ON va.visit_id = v.id
      LEFT JOIN employees e ON e.id = va.employee_id
      WHERE v.visit_date >= current_date - INTERVAL '30 days'
      GROUP BY v.id, v.visit_date, v.visit_status, c.client_code, v.truck, v.completed_by, veh.name
      ORDER BY v.visit_date DESC LIMIT 5;
    `));
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
