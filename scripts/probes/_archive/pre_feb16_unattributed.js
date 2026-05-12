require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res(JSON.parse(b)));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
(async () => {
  console.log('=== Pre-2026-02-16 completed visits with no vehicle_id ===');
  console.log('(per memory rule: Moises not operational, so these MUST be David)\n');
  const rows = await pg(`
    SELECT v.id AS visit_id, v.visit_date::text, c.client_code, c.name AS client_name,
      v.start_at AT TIME ZONE 'America/New_York' AS start_et,
      v.completed_at AT TIME ZONE 'America/New_York' AS completed_et,
      v.service_type, v.title
    FROM visits v LEFT JOIN clients c ON c.id = v.client_id
    WHERE v.visit_date >= '2026-01-01' AND v.visit_date < '2026-02-16'
      AND v.visit_status = 'completed' AND v.vehicle_id IS NULL
    ORDER BY v.visit_date, v.id;`);
  console.log(`Found: ${rows.length} unattributed pre-Feb-16 completed visits\n`);
  for (const r of rows) {
    console.log(`  ${r.visit_date}  visit=${r.visit_id}  ${(r.client_code||'-').padEnd(8)}  ${(r.client_name||'').slice(0,35).padEnd(35)}  ${r.service_type||'-'}  ${r.start_et||'-'}`);
  }

  // Check if these have ANY clue at all — assignments, completed_by, title hints
  console.log('\n=== Sanity check: do any of these have visit_assignments or completed_by? ===');
  const r2 = await pg(`
    SELECT
      v.id AS visit_id, v.completed_by,
      ARRAY_AGG(e.full_name) FILTER (WHERE e.full_name IS NOT NULL) AS assignments
    FROM visits v
    LEFT JOIN visit_assignments va ON va.visit_id = v.id
    LEFT JOIN employees e ON e.id = va.employee_id
    WHERE v.visit_date >= '2026-01-01' AND v.visit_date < '2026-02-16'
      AND v.visit_status = 'completed' AND v.vehicle_id IS NULL
    GROUP BY v.id, v.completed_by
    ORDER BY v.id LIMIT 30;`);
  for (const r of r2) {
    console.log(`  visit=${r.visit_id}  completed_by=${r.completed_by||'-'}  assignments=${r.assignments?.join(',')||'-'}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
