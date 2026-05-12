// Can we figure out which driver was in which truck at visit time?
// Step 1: see what Samsara-derived driver/vehicle pairing data we already have.
// Step 2: check what columns/tables hint at driver-vehicle attribution.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROJECT}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('=== 1. employees table — does it have any vehicle/driver pairing fields? ===');
  console.table(await q(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='employees' ORDER BY ordinal_position;`));

  console.log('\n=== 2. vehicles table — schema ===');
  console.table(await q(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='vehicles' ORDER BY ordinal_position;`));

  console.log('\n=== 3. employees with samsara link (drivers per Samsara) ===');
  console.table(await q(`
    SELECT e.id, e.full_name, e.role, e.status, esl.source_id AS samsara_id
    FROM employees e
    JOIN entity_source_links esl ON esl.entity_type='employee' AND esl.entity_id=e.id AND esl.source_system='samsara'
    ORDER BY e.full_name;
  `));

  console.log('\n=== 4. Vehicles + their Samsara IDs ===');
  console.table(await q(`
    SELECT v.id, v.name, esl.source_id AS samsara_id
    FROM vehicles v
    LEFT JOIN entity_source_links esl ON esl.entity_type='vehicle' AND esl.entity_id=v.id AND esl.source_system='samsara';
  `));

  console.log('\n=== 5. vehicle_telemetry_readings — sample rows (any driver field?) ===');
  console.table(await q(`SELECT * FROM vehicle_telemetry_readings ORDER BY recorded_at DESC LIMIT 3;`));

  console.log('\n=== 6. Tables that mention "driver" in any column ===');
  console.table(await q(`
    SELECT table_name, column_name, data_type
    FROM information_schema.columns
    WHERE table_schema='public' AND column_name ILIKE '%driver%'
    ORDER BY table_name, column_name;
  `));

  console.log('\n=== 7. Visits with truck text — distinct truck names ===');
  console.table(await q(`
    SELECT truck, COUNT(*) AS n
    FROM visits WHERE truck IS NOT NULL AND truck != ''
    GROUP BY truck ORDER BY n DESC LIMIT 15;
  `));

  console.log('\n=== 8. visit.vehicle_id → vehicles.name distribution ===');
  console.table(await q(`
    SELECT v.name AS truck_name, COUNT(*) AS n
    FROM visits vis JOIN vehicles v ON v.id = vis.vehicle_id
    GROUP BY v.name ORDER BY n DESC;
  `));

  console.log('\n=== 9. For visits with vehicle_id, do we also have visit_assignments? ===');
  console.table(await q(`
    SELECT
      COUNT(*) AS total_with_vehicle,
      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id=v.id)) AS also_has_employee,
      COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id=v.id)) AS truck_only_no_employee
    FROM visits v WHERE v.vehicle_id IS NOT NULL;
  `));

  console.log('\n=== 10. raw.* tables — anything that captured Samsara driver-vehicle pairings? ===');
  console.table(await q(`
    SELECT table_name FROM information_schema.tables
    WHERE table_schema='public' AND (table_name ILIKE '%samsara%' OR table_name ILIKE '%trip%' OR table_name ILIKE '%shift%')
    ORDER BY table_name;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
