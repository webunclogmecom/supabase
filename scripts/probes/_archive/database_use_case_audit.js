// Run real-world operational queries against the DB, easy → complex.
// Each query simulates a question someone (Yannick's app, a report, Viktor)
// would actually ask. We print the question, the SQL, and the result so we
// can verify the schema supports the use case without contortions.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.setTimeout(30000, () => req.destroy(new Error('timeout')));
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

const TESTS = [];
function test(level, name, sql, expectAtLeast = 0) { TESTS.push({ level, name, sql, expectAtLeast }); }

// ============================================================================
// EASY — basic SELECTs, confirms the schema works for trivial questions
// ============================================================================

test('EASY', 'Active clients right now',
  `SELECT COUNT(*) AS n FROM clients WHERE status IN ('ACTIVE', 'Recuring')`);

test('EASY', 'Completed visits in last 7 days (ET-localized)',
  `SELECT COUNT(*) AS n FROM visits
   WHERE visit_status='completed'
     AND visit_date >= (now() AT TIME ZONE 'America/New_York')::date - interval '7 days'`);

test('EASY', 'Photos linked to a specific visit (sample)',
  `SELECT COUNT(DISTINCT pl.photo_id) AS photos_for_v1463
   FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=1463`);

test('EASY', 'Total invoiced this month (sent_at = invoice issuance)',
  `SELECT COALESCE(SUM(total), 0)::text AS total_dollars FROM invoices
   WHERE sent_at >= date_trunc('month', now() AT TIME ZONE 'America/New_York')`);

test('EASY', 'Trucks in fleet',
  `SELECT name, fuel_tank_capacity_gallons, grease_tank_capacity_gallons FROM vehicles ORDER BY name`);

// ============================================================================
// MEDIUM — JOINs, aggregates, common operational reports
// ============================================================================

test('MEDIUM', 'Visits per client, top 10 (2026)',
  `SELECT c.client_code, c.name, COUNT(*) AS visits
   FROM visits v JOIN clients c ON c.id=v.client_id
   WHERE v.visit_date >= '2026-01-01' AND v.visit_status='completed'
   GROUP BY c.client_code, c.name ORDER BY visits DESC LIMIT 10`);

test('MEDIUM', 'Visits per truck per week (last 4 weeks)',
  `SELECT veh.name AS truck,
     date_trunc('week', v.visit_date)::date AS week,
     COUNT(*) AS visits
   FROM visits v JOIN vehicles veh ON veh.id=v.vehicle_id
   WHERE v.visit_date >= now() - interval '4 weeks' AND v.visit_status='completed'
   GROUP BY veh.name, week ORDER BY week DESC, truck`);

test('MEDIUM', 'Photo coverage rate per driver (April 2026)',
  `SELECT e.full_name AS driver,
     COUNT(*) AS visits,
     COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)) AS with_photos,
     ROUND(100.0 * COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)) / COUNT(*), 1) AS pct
   FROM visits v JOIN visit_assignments va ON va.visit_id=v.id
                 JOIN employees e ON e.id=va.employee_id
   WHERE v.visit_date BETWEEN '2026-04-01' AND '2026-04-30' AND v.visit_status='completed'
   GROUP BY e.full_name ORDER BY visits DESC`);

test('MEDIUM', 'Clients overdue for service (frequency_days exceeded)',
  `SELECT c.client_code, c.name,
     sc.frequency_days,
     MAX(v.visit_date)::text AS last_visit,
     (CURRENT_DATE - MAX(v.visit_date))::int AS days_since
   FROM clients c
   JOIN service_configs sc ON sc.client_id=c.id
   LEFT JOIN visits v ON v.client_id=c.id AND v.visit_status='completed'
   WHERE c.status IN ('ACTIVE','Recuring') AND sc.frequency_days BETWEEN 1 AND 180
   GROUP BY c.client_code, c.name, sc.frequency_days
   HAVING (CURRENT_DATE - MAX(v.visit_date)) > sc.frequency_days
   ORDER BY days_since DESC LIMIT 10`);

test('MEDIUM', 'Outstanding invoices (outstanding_amount > 0)',
  `SELECT COUNT(*) AS n, COALESCE(SUM(outstanding_amount), 0)::text AS total_owed
   FROM invoices WHERE outstanding_amount > 0`);

// ============================================================================
// COMPLEX — multi-table cross-references, the real value of the schema
// ============================================================================

test('COMPLEX', 'Inspections with truck attribution (via employee+date → visits.vehicle_id)',
  `SELECT i.id, i.inspection_type, i.shift_date::text,
     e.full_name AS inspector,
     veh.name AS truck_inferred
   FROM inspections i
   LEFT JOIN employees e ON e.id=i.employee_id
   LEFT JOIN LATERAL (
     SELECT v.vehicle_id FROM visits v
     JOIN visit_assignments va ON va.visit_id=v.id
     WHERE va.employee_id=i.employee_id AND v.visit_date=i.shift_date AND v.vehicle_id IS NOT NULL
     GROUP BY v.vehicle_id ORDER BY COUNT(*) DESC LIMIT 1
   ) inferred ON true
   LEFT JOIN vehicles veh ON veh.id=inferred.vehicle_id
   WHERE i.shift_date >= '2026-04-01' ORDER BY i.shift_date DESC LIMIT 8`);

test('COMPLEX', 'Suspect: completed visits with no invoice in 14-day window',
  `SELECT v.id, c.client_code, v.visit_date::text, v.visit_status
   FROM visits v
   JOIN clients c ON c.id=v.client_id
   WHERE v.visit_status='completed' AND v.visit_date >= '2026-04-01'
     AND NOT EXISTS (
       SELECT 1 FROM invoices inv
       WHERE inv.client_id=v.client_id
         AND COALESCE(inv.sent_at, inv.created_at)::date BETWEEN v.visit_date AND v.visit_date + interval '14 days'
     )
   ORDER BY v.visit_date DESC LIMIT 10`);

test('COMPLEX', 'GPS-confirmed visits: telemetry within 100m during start_at..completed_at',
  `WITH tel_window AS (
     SELECT v.id AS visit_id, vt.vehicle_id, COUNT(*) AS pings
     FROM visits v
     JOIN properties p ON p.id=v.property_id OR (v.property_id IS NULL AND p.client_id=v.client_id AND p.is_primary)
     JOIN vehicle_telemetry_readings vt
       ON vt.recorded_at BETWEEN v.start_at AND COALESCE(v.completed_at, v.start_at + interval '4 hours')
     WHERE v.visit_date >= '2026-04-25' AND v.visit_status='completed'
       AND p.latitude IS NOT NULL
       AND ((vt.latitude - p.latitude)^2 + (vt.longitude - p.longitude)^2) < (0.001)^2
     GROUP BY v.id, vt.vehicle_id
   )
   SELECT v.id, c.client_code, v.visit_date::text,
     COALESCE(veh.name, '(unmatched)') AS truck,
     COALESCE(tw.pings, 0) AS gps_pings_at_client
   FROM visits v JOIN clients c ON c.id=v.client_id
   LEFT JOIN tel_window tw ON tw.visit_id=v.id
   LEFT JOIN vehicles veh ON veh.id=tw.vehicle_id
   WHERE v.visit_date >= '2026-04-25' AND v.visit_status='completed'
   ORDER BY v.visit_date DESC, c.client_code LIMIT 12`);

test('COMPLEX', 'DERM compliance: recent manifests + their linked visits',
  `SELECT m.white_manifest_number, m.service_date::text, m.dump_ticket_date::text,
     COUNT(DISTINCT mv.visit_id) AS linked_visits
   FROM derm_manifests m
   LEFT JOIN manifest_visits mv ON mv.manifest_id=m.id
   WHERE m.service_date >= '2026-03-01'
   GROUP BY m.white_manifest_number, m.service_date, m.dump_ticket_date
   ORDER BY m.service_date DESC LIMIT 8`);

test('COMPLEX', 'Cross-source health: same client, who knows about it (Jobber/Airtable/Samsara)',
  `SELECT c.client_code, c.name,
     COUNT(*) FILTER (WHERE esl.source_system='jobber') AS in_jobber,
     COUNT(*) FILTER (WHERE esl.source_system='airtable') AS in_airtable,
     COUNT(*) FILTER (WHERE esl.source_system='samsara') AS in_samsara
   FROM clients c
   LEFT JOIN entity_source_links esl ON esl.entity_type='client' AND esl.entity_id=c.id
   WHERE c.status IN ('ACTIVE','Recuring')
   GROUP BY c.client_code, c.name
   HAVING COUNT(*) FILTER (WHERE esl.source_system='airtable')=0
   ORDER BY c.client_code LIMIT 10`);

// ============================================================================
// runner
// ============================================================================

(async () => {
  let pass = 0, fail = 0, warn = 0;
  for (const t of TESTS) {
    console.log(`\n${'─'.repeat(72)}\n[${t.level}] ${t.name}\n${'─'.repeat(72)}`);
    try {
      const start = Date.now();
      const rows = await pg(t.sql);
      const ms = Date.now() - start;
      const status = rows.length >= t.expectAtLeast ? '✅' : '⚠️ ';
      if (status === '✅') pass++; else warn++;
      console.log(`${status} ${rows.length} row(s) in ${ms}ms`);
      if (rows.length === 0) console.log('  (no rows — query ran but returned empty)');
      for (const r of rows.slice(0, 5)) console.log(' ', JSON.stringify(r));
      if (rows.length > 5) console.log(`  … +${rows.length - 5} more rows omitted`);
    } catch (e) {
      fail++;
      console.log(`❌ FAILED: ${e.message.slice(0, 200)}`);
    }
  }
  console.log(`\n${'='.repeat(72)}`);
  console.log(`SUMMARY: ${pass} ✅   ${warn} ⚠️    ${fail} ❌`);
  console.log('='.repeat(72));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
