#!/usr/bin/env node
// Resume v2 migration from where it stopped (county column missing)
require('dotenv').config({ path: require('path').resolve(__dirname, '..', '.env') });
const https = require('https');

function q(sql, label) {
  return new Promise((res, rej) => {
    const b = JSON.stringify({ query: sql });
    const r = https.request({
      hostname: 'api.supabase.com',
      path: '/v1/projects/' + process.env.SUPABASE_PROJECT_ID + '/database/query',
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + process.env.SUPABASE_PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) },
    }, resp => {
      let d = ''; resp.on('data', c => d += c);
      resp.on('end', () => { if (resp.statusCode >= 300) rej(new Error(`${label}: HTTP ${resp.statusCode}: ${d.slice(0, 400)}`)); else res(JSON.parse(d)); });
    });
    r.on('error', rej); r.write(b); r.end();
  });
}

async function run(sql, label) {
  try { await q(sql, label); console.log(`  ✅ ${label}`); } catch (e) { console.log(`  ❌ ${label}: ${e.message.slice(0, 200)}`); throw e; }
}
async function safeRun(sql, label) {
  try { await run(sql, label); } catch (e) { console.log(`     (non-fatal)`); }
}

(async () => {
  console.log('=== RESUME: Fix county + continue ===\n');

  // Add missing county column to properties
  await safeRun(`ALTER TABLE properties ADD COLUMN IF NOT EXISTS county text`, 'properties.county');

  // Create properties for clients that don't have one
  await run(`
    INSERT INTO properties (client_id, address, city, state, zip, county, zone,
      latitude, longitude, geofence_radius_meters, geofence_type,
      access_hours_start, access_hours_end, access_days, location_photo_url, is_primary)
    SELECT c.id, c.address_line1, c.city, c.state, c.zip_code, c.county, c.zone,
      c.latitude, c.longitude, c.geofence_radius_meters, c.geofence_type,
      c.hours_in, c.hours_out, c.days_of_week, c.photo_location_gt, true
    FROM clients c
    WHERE NOT EXISTS (SELECT 1 FROM properties p WHERE p.client_id = c.id)
      AND (c.address_line1 IS NOT NULL OR c.city IS NOT NULL)
  `, 'create properties for clients without one');

  const propCount = await q('SELECT count(*) as n FROM properties');
  console.log(`  📊 Total properties: ${propCount[0].n}`);

  // STEP 5: GDO → service_configs
  console.log('\n[STEP 5] GDO + equipment → service_configs...');
  await safeRun(`ALTER TABLE service_configs ADD COLUMN IF NOT EXISTS equipment_size_gallons numeric`, 'sc.equipment_size_gallons');
  await safeRun(`ALTER TABLE service_configs ADD COLUMN IF NOT EXISTS permit_number text`, 'sc.permit_number');
  await safeRun(`ALTER TABLE service_configs ADD COLUMN IF NOT EXISTS permit_expiration date`, 'sc.permit_expiration');

  await run(`
    UPDATE service_configs sc SET
      equipment_size_gallons = c.gt_size_gallons,
      permit_number = c.gdo_number,
      permit_expiration = c.gdo_expiration_date
    FROM clients c
    WHERE sc.client_id = c.id AND sc.service_type = 'GT'
      AND (c.gt_size_gallons IS NOT NULL OR c.gdo_number IS NOT NULL)
  `, 'GT configs ← clients (GDO + size)');

  // STEP 6: Routes
  console.log('\n[STEP 6] Routes → route_stops...');
  await safeRun(`ALTER TABLE routes ADD COLUMN IF NOT EXISTS route_date date`, 'routes.route_date');
  await safeRun(`ALTER TABLE routes ADD COLUMN IF NOT EXISTS vehicle_id bigint REFERENCES vehicles(id)`, 'routes.vehicle_id');
  await safeRun(`ALTER TABLE routes ADD COLUMN IF NOT EXISTS employee_id bigint REFERENCES employees(id)`, 'routes.employee_id');
  await safeRun(`ALTER TABLE routes ADD COLUMN IF NOT EXISTS notes text`, 'routes.notes');

  await safeRun(`
    INSERT INTO route_stops (route_id, client_id, service_type, wanted_date, status)
    SELECT id, client_id, 'GT', gt_wanted_date, status
    FROM routes WHERE client_id IS NOT NULL
  `, 'routes → route_stops');

  // STEP 7: Drop unused columns
  console.log('\n[STEP 7] Drop columns...');

  // CLIENTS
  const clientDropCols = [
    'display_name','address_line1','city','state','zip_code','county','zone',
    'latitude','longitude','geofence_radius_meters','geofence_type',
    'email','phone','accounting_email','operation_email','accounting_phone',
    'operation_phone','city_email','op_name','acct_name',
    'days_of_week','hours_in','hours_out',
    'gdo_number','gdo_expiration_date','gdo_frequency',
    'contract_warranty','signature_date','photo_location_gt','gt_size_gallons',
    'airtable_record_id','jobber_client_id','samsara_address_id',
    'data_sources','match_method','match_confidence',
  ];
  for (const col of clientDropCols) await safeRun(`ALTER TABLE clients DROP COLUMN IF EXISTS ${col}`, `clients.${col}`);

  // EMPLOYEES
  for (const col of ['first_name','last_name','cdl_license','certifications','emergency_contact',
    'eld_settings','driver_activation','license_state','is_account_owner','is_account_admin','access_level',
    'airtable_record_id','samsara_driver_id','jobber_user_id','fillout_display_name','data_sources'])
    await safeRun(`ALTER TABLE employees DROP COLUMN IF EXISTS ${col}`, `employees.${col}`);

  // VEHICLES
  for (const col of ['short_code','primary_use','gateway_serial','gateway_model','camera_serial',
    'samsara_vehicle_id','airtable_record_id','data_sources'])
    await safeRun(`ALTER TABLE vehicles DROP COLUMN IF EXISTS ${col}`, `vehicles.${col}`);

  // VISITS
  for (const col of ['truck','zone','completed_by','late_status','late_status_gt_freq',
    'amount','instructions','source','jobber_visit_id','jobber_invoice_id','airtable_record_id','data_sources'])
    await safeRun(`ALTER TABLE visits DROP COLUMN IF EXISTS ${col}`, `visits.${col}`);

  // JOBS
  for (const col of ['instructions','job_type','billing_type','service_category','completed_at',
    'invoiced_total','uninvoiced_total','jobber_job_id','jobber_quote_id'])
    await safeRun(`ALTER TABLE jobs DROP COLUMN IF EXISTS ${col}`, `jobs.${col}`);
  await safeRun(`ALTER TABLE jobs ADD COLUMN IF NOT EXISTS notes text`, 'jobs.notes');

  // INVOICES
  await safeRun(`ALTER TABLE invoices DROP COLUMN IF EXISTS jobber_invoice_id`, 'invoices.jobber_invoice_id');
  await safeRun(`ALTER TABLE invoices DROP COLUMN IF EXISTS message`, 'invoices.message');

  // QUOTES
  await safeRun(`ALTER TABLE quotes DROP COLUMN IF EXISTS jobber_quote_id`, 'quotes.jobber_quote_id');
  await safeRun(`ALTER TABLE quotes DROP COLUMN IF EXISTS message`, 'quotes.message');

  // LINE_ITEMS
  await safeRun(`ALTER TABLE line_items DROP COLUMN IF EXISTS jobber_line_item_id`, 'line_items.jobber_line_item_id');

  // PROPERTIES
  await safeRun(`ALTER TABLE properties DROP COLUMN IF EXISTS jobber_property_id`, 'properties.jobber_property_id');
  await safeRun(`ALTER TABLE properties RENAME COLUMN is_billing_address TO is_billing`, 'properties rename is_billing');

  // INSPECTIONS (17 photo cols + expense + source)
  for (const col of ['photo_dashboard','photo_cabin','photo_cabin_side_left','photo_cabin_side_right',
    'photo_front','photo_back','photo_left_side','photo_right_side','photo_boots','photo_remote',
    'photo_closed_valve','photo_issue','photo_sludge_level','photo_water_level','photo_derm_manifest',
    'photo_derm_address','photo_expense_receipt','has_expense','expense_note','expense_amount',
    'fillout_submission_id','airtable_record_id','data_sources'])
    await safeRun(`ALTER TABLE inspections DROP COLUMN IF EXISTS ${col}`, `inspections.${col}`);

  // EXPENSES
  for (const col of ['ramp_card_holder','ramp_merchant','ramp_transaction_id','fillout_submission_id','data_sources'])
    await safeRun(`ALTER TABLE expenses DROP COLUMN IF EXISTS ${col}`, `expenses.${col}`);

  // DERM_MANIFESTS
  for (const col of ['service_address','service_city','service_zip','service_county','airtable_record_id'])
    await safeRun(`ALTER TABLE derm_manifests DROP COLUMN IF EXISTS ${col}`, `derm_manifests.${col}`);

  // RECEIVABLES
  await safeRun(`ALTER TABLE receivables DROP COLUMN IF EXISTS airtable_record_id`, 'receivables.airtable_record_id');
  await safeRun(`ALTER TABLE receivables DROP COLUMN IF EXISTS last_modified`, 'receivables.last_modified');

  // ROUTES
  for (const col of ['gt_wanted_date','cl_wanted_date','airtable_record_id'])
    await safeRun(`ALTER TABLE routes DROP COLUMN IF EXISTS ${col}`, `routes.${col}`);

  // LEADS
  for (const col of ['jobber_request_id','assigned_to','service_interest','estimated_value','last_contact_at','lost_reason'])
    await safeRun(`ALTER TABLE leads DROP COLUMN IF EXISTS ${col}`, `leads.${col}`);

  // SOURCE_MAP
  await safeRun(`DROP TABLE IF EXISTS source_map CASCADE`, 'DROP source_map');

  // SERVICE_CONFIGS
  for (const col of ['next_visit_calculated','total_per_year','projected_year','data_quality','visits_available'])
    await safeRun(`ALTER TABLE service_configs DROP COLUMN IF EXISTS ${col}`, `service_configs.${col}`);

  // STEP 9: Recreate views
  console.log('\n[STEP 9] Recreate views...');
  await run(`DROP VIEW IF EXISTS client_services_flat CASCADE`, 'drop csf');
  await run(`DROP VIEW IF EXISTS clients_due_service CASCADE`, 'drop cds');
  await run(`DROP VIEW IF EXISTS visits_recent CASCADE`, 'drop vr');
  await run(`DROP VIEW IF EXISTS manifest_detail CASCADE`, 'drop md');
  await run(`DROP VIEW IF EXISTS driver_inspection_status CASCADE`, 'drop dis');

  await run(`
    CREATE VIEW client_services_flat WITH (security_invoker = true) AS
    SELECT c.id, c.name, c.client_code, p.address, p.city, p.zone, c.status,
      MAX(CASE WHEN s.service_type='GT' THEN s.equipment_size_gallons END) AS gt_size_gallons,
      MAX(CASE WHEN s.service_type='GT' THEN s.frequency_days END) AS gt_frequency_days,
      MAX(CASE WHEN s.service_type='GT' THEN s.price_per_visit END) AS gt_price_per_visit,
      MAX(CASE WHEN s.service_type='GT' THEN s.last_visit END) AS gt_last_visit,
      MAX(CASE WHEN s.service_type='GT' THEN s.next_visit END) AS gt_next_visit,
      MAX(CASE WHEN s.service_type='GT' THEN s.status END) AS gt_status,
      MAX(CASE WHEN s.service_type='CL' THEN s.frequency_days END) AS cl_frequency_days,
      MAX(CASE WHEN s.service_type='CL' THEN s.price_per_visit END) AS cl_price_per_visit,
      MAX(CASE WHEN s.service_type='CL' THEN s.last_visit END) AS cl_last_visit,
      MAX(CASE WHEN s.service_type='CL' THEN s.next_visit END) AS cl_next_visit,
      MAX(CASE WHEN s.service_type='CL' THEN s.status END) AS cl_status,
      MAX(CASE WHEN s.service_type='WD' THEN s.frequency_days END) AS wd_frequency_days,
      MAX(CASE WHEN s.service_type='WD' THEN s.price_per_visit END) AS wd_price_per_visit,
      MAX(CASE WHEN s.service_type='WD' THEN s.last_visit END) AS wd_last_visit,
      MAX(CASE WHEN s.service_type='WD' THEN s.next_visit END) AS wd_next_visit,
      MAX(CASE WHEN s.service_type='WD' THEN s.status END) AS wd_status
    FROM clients c
    LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
    LEFT JOIN service_configs s ON s.client_id = c.id
    GROUP BY c.id, p.address, p.city, p.zone
  `, 'CREATE client_services_flat');

  await run(`
    CREATE VIEW clients_due_service WITH (security_invoker = true) AS
    SELECT c.id, c.name, c.client_code, p.address, p.city, p.zone,
      s.service_type, s.last_visit, s.next_visit, s.frequency_days,
      s.next_visit - CURRENT_DATE AS days_until_due,
      CASE WHEN s.next_visit < CURRENT_DATE THEN 'OVERDUE'
           WHEN s.next_visit <= CURRENT_DATE + 14 THEN 'DUE_SOON'
           ELSE 'OK' END AS due_status
    FROM clients c
    JOIN service_configs s ON s.client_id = c.id
    LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
    WHERE c.status = 'Active' AND s.status IS DISTINCT FROM 'Paused' AND s.next_visit IS NOT NULL
    ORDER BY s.next_visit
  `, 'CREATE clients_due_service');

  await run(`
    CREATE VIEW visits_recent WITH (security_invoker = true) AS
    SELECT v.id, v.visit_date, v.service_type, c.name AS client_name,
      p.address, p.zone, v.visit_status, v.gps_confirmed,
      v.actual_arrival_at, v.actual_departure_at,
      veh.name AS vehicle_name,
      string_agg(e.full_name, ', ') AS assigned_to
    FROM visits v
    JOIN clients c ON c.id = v.client_id
    LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
    LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
    LEFT JOIN visit_assignments va ON va.visit_id = v.id
    LEFT JOIN employees e ON e.id = va.employee_id
    WHERE v.visit_date >= CURRENT_DATE - 30
    GROUP BY v.id, v.visit_date, v.service_type, c.name, p.address, p.zone,
      v.visit_status, v.gps_confirmed, v.actual_arrival_at, v.actual_departure_at, veh.name
    ORDER BY v.visit_date DESC
  `, 'CREATE visits_recent');

  await run(`
    CREATE VIEW manifest_detail WITH (security_invoker = true) AS
    SELECT m.id, m.white_manifest_num, m.service_date, c.name AS client_name,
      p.address, p.county AS service_county, m.sent_to_client, m.sent_to_city,
      COUNT(mv.visit_id) AS visit_count
    FROM derm_manifests m
    JOIN clients c ON c.id = m.client_id
    LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
    LEFT JOIN manifest_visits mv ON mv.manifest_id = m.id
    GROUP BY m.id, m.white_manifest_num, m.service_date, c.name, p.address, p.county, m.sent_to_client, m.sent_to_city
    ORDER BY m.service_date DESC
  `, 'CREATE manifest_detail');

  await run(`
    CREATE VIEW driver_inspection_status WITH (security_invoker = true) AS
    SELECT e.id, e.full_name,
      MAX(CASE WHEN i.inspection_type='PRE' AND i.shift_date=CURRENT_DATE THEN i.submitted_at END) AS pre_submitted_at,
      MAX(CASE WHEN i.inspection_type='POST' THEN i.submitted_at END) AS post_submitted_at,
      COUNT(CASE WHEN i.shift_date=CURRENT_DATE THEN 1 END) AS inspections_today,
      BOOL_OR(CASE WHEN i.has_issue THEN true END) AS has_open_issue
    FROM employees e
    LEFT JOIN inspections i ON i.employee_id = e.id
      AND (i.shift_date = CURRENT_DATE OR (i.shift_date = CURRENT_DATE - 1 AND i.inspection_type = 'POST' AND i.submitted_at >= CURRENT_DATE::timestamptz))
    WHERE e.status = 'Active'
    GROUP BY e.id, e.full_name
  `, 'CREATE driver_inspection_status');

  await safeRun(`
    CREATE VIEW visits_with_status WITH (security_invoker = true) AS
    SELECT v.*, c.name AS client_name, p.zone, veh.name AS vehicle_name, sc.frequency_days,
      CASE WHEN v.visit_status='Completed' THEN 'OK'
           WHEN v.visit_date < CURRENT_DATE AND NOT v.is_complete THEN 'LATE'
           ELSE 'ON_TIME' END AS computed_late_status
    FROM visits v JOIN clients c ON c.id = v.client_id
    LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
    LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
    LEFT JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = v.service_type
  `, 'CREATE visits_with_status');

  // STEP 10: Security
  console.log('\n[STEP 10] Security...');
  const newTables = ['entity_source_links','client_contacts','inspection_photos','visit_photos','route_stops'];
  for (const t of newTables) {
    await safeRun(`ALTER TABLE ${t} ENABLE ROW LEVEL SECURITY`, `RLS ${t}`);
    await safeRun(`ALTER TABLE ${t} FORCE ROW LEVEL SECURITY`, `force ${t}`);
    await safeRun(`CREATE POLICY "anon_read_${t}" ON ${t} FOR SELECT TO anon USING (true)`, `pol anon ${t}`);
    await safeRun(`CREATE POLICY "auth_read_${t}" ON ${t} FOR SELECT TO authenticated USING (true)`, `pol auth ${t}`);
    await safeRun(`CREATE POLICY "sr_all_${t}" ON ${t} FOR ALL TO service_role USING (true) WITH CHECK (true)`, `pol sr ${t}`);
    await safeRun(`REVOKE ALL ON ${t} FROM anon`, `rev anon ${t}`);
    await safeRun(`GRANT SELECT ON ${t} TO anon`, `grant anon ${t}`);
    await safeRun(`REVOKE ALL ON ${t} FROM authenticated`, `rev auth ${t}`);
    await safeRun(`GRANT SELECT ON ${t} TO authenticated`, `grant auth ${t}`);
    await safeRun(`GRANT ALL ON ${t} TO service_role`, `grant sr ${t}`);
  }
  // Lock entity_source_links from public
  await safeRun(`REVOKE ALL ON entity_source_links FROM anon`, 'lock esl anon');
  await safeRun(`REVOKE ALL ON entity_source_links FROM authenticated`, 'lock esl auth');
  await safeRun(`GRANT ALL ON entity_source_links TO service_role`, 'esl sr');

  // Views grants
  for (const v of ['visits_with_status']) {
    await safeRun(`GRANT SELECT ON ${v} TO anon`, `grant ${v} anon`);
    await safeRun(`GRANT SELECT ON ${v} TO authenticated`, `grant ${v} auth`);
  }

  // VERIFY
  console.log('\n[VERIFY]');
  const colCounts = await q(`
    SELECT table_name, count(*) as cols
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name NOT IN ('client_services_flat','clients_due_service','visits_recent',
                             'manifest_detail','driver_inspection_status','visits_with_status')
    GROUP BY table_name ORDER BY table_name
  `);
  console.log('\n  TABLE COLUMN COUNTS:');
  for (const r of colCounts) console.log(`    ${r.table_name.padEnd(25)} ${r.cols} columns`);

  const eslCount = await q('SELECT count(*) as n FROM entity_source_links');
  const ccCount = await q('SELECT count(*) as n FROM client_contacts');
  const propCount2 = await q('SELECT count(*) as n FROM properties');
  console.log(`\n  entity_source_links: ${eslCount[0].n} rows`);
  console.log(`  client_contacts: ${ccCount[0].n} rows`);
  console.log(`  properties: ${propCount2[0].n} rows`);

  // Row counts for all tables
  const tables = ['clients','employees','vehicles','properties','service_configs','jobs','visits',
    'invoices','quotes','line_items','inspections','expenses','derm_manifests','manifest_visits',
    'routes','route_stops','receivables','leads','visit_assignments','entity_source_links',
    'client_contacts','inspection_photos','visit_photos'];
  console.log('\n  ROW COUNTS:');
  for (const t of tables) {
    const c = await q(`SELECT count(*) as n FROM ${t}`);
    console.log(`    ${t.padEnd(25)} ${c[0].n} rows`);
  }

  console.log('\n=== MIGRATION COMPLETE ===');
})();
