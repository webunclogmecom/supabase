#!/usr/bin/env node
// ============================================================================
// migrate_v2.js — Transform v1 schema to v2 (clean foundation)
// ============================================================================
// Steps:
//   1. Create new tables (entity_source_links, client_contacts, inspection_photos, visit_photos, route_stops)
//   2. Migrate source FKs → entity_source_links
//   3. Migrate contacts from clients → client_contacts
//   4. Migrate address/GPS from clients → properties
//   5. Migrate GDO/scheduling from clients → service_configs
//   6. Drop unused columns from all tables
//   7. Recreate views
//   8. Apply RLS + policies
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '..', '.env') });
const https = require('https');

const DRY_RUN = !process.argv.includes('--execute');

function q(sql, label) {
  if (DRY_RUN) {
    console.log(`  [dry-run] ${label || sql.substring(0, 80)}...`);
    return Promise.resolve([]);
  }
  return new Promise((res, rej) => {
    const b = JSON.stringify({ query: sql });
    const r = https.request({
      hostname: 'api.supabase.com',
      path: '/v1/projects/' + process.env.SUPABASE_PROJECT_ID + '/database/query',
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + process.env.SUPABASE_PAT,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(b),
      },
    }, resp => {
      let d = '';
      resp.on('data', c => d += c);
      resp.on('end', () => {
        if (resp.statusCode >= 300) {
          const err = new Error(`${label}: HTTP ${resp.statusCode}: ${d.slice(0, 300)}`);
          rej(err);
        } else {
          res(JSON.parse(d));
        }
      });
    });
    r.on('error', rej);
    r.write(b);
    r.end();
  });
}

async function run(sql, label) {
  try {
    const result = await q(sql, label);
    console.log(`  ✅ ${label}`);
    return result;
  } catch (e) {
    console.log(`  ❌ ${label}: ${e.message.slice(0, 200)}`);
    throw e;
  }
}

async function safeRun(sql, label) {
  try {
    await run(sql, label);
  } catch (e) {
    // swallow — usually "already exists" or "does not exist"
    console.log(`     (non-fatal, continuing)`);
  }
}

(async () => {
  console.log('============================================================');
  console.log('migrate_v2.js — UNCLOGME Schema V2 Migration');
  console.log(`Mode: ${DRY_RUN ? 'DRY-RUN' : 'EXECUTE'}`);
  console.log('============================================================\n');

  // ===========================================================================
  // STEP 1: Create new tables
  // ===========================================================================
  console.log('[STEP 1] Create new tables...');

  await run(`
    CREATE TABLE IF NOT EXISTS entity_source_links (
      id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      entity_type     text    NOT NULL,
      entity_id       bigint  NOT NULL,
      source_system   text    NOT NULL,
      source_id       text    NOT NULL,
      source_name     text,
      match_method    text,
      match_confidence numeric,
      synced_at       timestamptz DEFAULT now(),
      created_at      timestamptz DEFAULT now()
    )
  `, 'CREATE entity_source_links');

  await safeRun(`CREATE UNIQUE INDEX IF NOT EXISTS idx_esl_entity_source ON entity_source_links (entity_type, entity_id, source_system)`, 'UNIQUE idx entity+source');
  await safeRun(`CREATE UNIQUE INDEX IF NOT EXISTS idx_esl_source_id ON entity_source_links (entity_type, source_system, source_id)`, 'UNIQUE idx source lookup');
  await safeRun(`CREATE INDEX IF NOT EXISTS idx_esl_entity ON entity_source_links (entity_type, entity_id)`, 'idx entity');
  await safeRun(`CREATE INDEX IF NOT EXISTS idx_esl_source ON entity_source_links (source_system, source_id)`, 'idx source');

  await run(`
    CREATE TABLE IF NOT EXISTS client_contacts (
      id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      client_id       bigint  NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
      contact_role    text    NOT NULL,
      name            text,
      email           text,
      phone           text,
      created_at      timestamptz DEFAULT now(),
      updated_at      timestamptz DEFAULT now(),
      UNIQUE (client_id, contact_role)
    )
  `, 'CREATE client_contacts');

  await run(`
    CREATE TABLE IF NOT EXISTS inspection_photos (
      id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      inspection_id   bigint  NOT NULL REFERENCES inspections(id) ON DELETE CASCADE,
      photo_type      text    NOT NULL,
      url             text    NOT NULL,
      created_at      timestamptz DEFAULT now()
    )
  `, 'CREATE inspection_photos');

  await safeRun(`CREATE INDEX IF NOT EXISTS idx_inspection_photos_insp ON inspection_photos (inspection_id)`, 'idx inspection_photos');

  await run(`
    CREATE TABLE IF NOT EXISTS visit_photos (
      id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      visit_id        bigint  REFERENCES visits(id) ON DELETE CASCADE,
      client_id       bigint  REFERENCES clients(id),
      photo_type      text,
      url             text    NOT NULL,
      thumbnail_url   text,
      file_name       text,
      content_type    text,
      caption         text,
      taken_at        timestamptz,
      created_at      timestamptz DEFAULT now()
    )
  `, 'CREATE visit_photos');

  await safeRun(`CREATE INDEX IF NOT EXISTS idx_visit_photos_visit ON visit_photos (visit_id)`, 'idx visit_photos_visit');
  await safeRun(`CREATE INDEX IF NOT EXISTS idx_visit_photos_client ON visit_photos (client_id)`, 'idx visit_photos_client');

  await run(`
    CREATE TABLE IF NOT EXISTS route_stops (
      id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
      route_id        bigint  NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
      client_id       bigint  REFERENCES clients(id),
      property_id     bigint  REFERENCES properties(id),
      service_type    text,
      stop_order      integer,
      wanted_date     date,
      status          text,
      created_at      timestamptz DEFAULT now()
    )
  `, 'CREATE route_stops');

  await safeRun(`CREATE INDEX IF NOT EXISTS idx_route_stops_route ON route_stops (route_id)`, 'idx route_stops');

  // ===========================================================================
  // STEP 2: Migrate source FKs → entity_source_links
  // ===========================================================================
  console.log('\n[STEP 2] Migrate source FKs → entity_source_links...');

  // Helper: migrate a source FK column to entity_source_links
  const migrateSourceFK = async (table, entityType, col, sourceSystem) => {
    const label = `${table}.${col} → entity_source_links (${sourceSystem})`;
    await safeRun(`
      INSERT INTO entity_source_links (entity_type, entity_id, source_system, source_id)
      SELECT '${entityType}', id, '${sourceSystem}', ${col}
      FROM ${table}
      WHERE ${col} IS NOT NULL AND ${col} != ''
      ON CONFLICT (entity_type, source_system, source_id) DO NOTHING
    `, label);
  };

  // Also migrate match metadata from clients
  await safeRun(`
    INSERT INTO entity_source_links (entity_type, entity_id, source_system, source_id, match_method, match_confidence)
    SELECT 'client', id, 'jobber', jobber_client_id, match_method, match_confidence
    FROM clients
    WHERE jobber_client_id IS NOT NULL AND jobber_client_id != ''
    ON CONFLICT (entity_type, source_system, source_id) DO UPDATE SET
      match_method = EXCLUDED.match_method,
      match_confidence = EXCLUDED.match_confidence
  `, 'clients.jobber_client_id (with match metadata)');

  await migrateSourceFK('clients', 'client', 'airtable_record_id', 'airtable');
  await migrateSourceFK('clients', 'client', 'samsara_address_id', 'samsara');

  await migrateSourceFK('employees', 'employee', 'airtable_record_id', 'airtable');
  await migrateSourceFK('employees', 'employee', 'samsara_driver_id', 'samsara');
  await migrateSourceFK('employees', 'employee', 'jobber_user_id', 'jobber');

  // employees.fillout_display_name → store as source_name
  await safeRun(`
    INSERT INTO entity_source_links (entity_type, entity_id, source_system, source_id, source_name)
    SELECT 'employee', id, 'fillout', fillout_display_name, fillout_display_name
    FROM employees
    WHERE fillout_display_name IS NOT NULL AND fillout_display_name != ''
    ON CONFLICT (entity_type, source_system, source_id) DO NOTHING
  `, 'employees.fillout_display_name');

  await migrateSourceFK('vehicles', 'vehicle', 'samsara_vehicle_id', 'samsara');
  await migrateSourceFK('vehicles', 'vehicle', 'airtable_record_id', 'airtable');

  await migrateSourceFK('visits', 'visit', 'jobber_visit_id', 'jobber');
  await migrateSourceFK('visits', 'visit', 'airtable_record_id', 'airtable');

  await migrateSourceFK('invoices', 'invoice', 'jobber_invoice_id', 'jobber');

  await migrateSourceFK('jobs', 'job', 'jobber_job_id', 'jobber');

  await migrateSourceFK('quotes', 'quote', 'jobber_quote_id', 'jobber');

  await migrateSourceFK('line_items', 'line_item', 'jobber_line_item_id', 'jobber');

  await migrateSourceFK('properties', 'property', 'jobber_property_id', 'jobber');

  await migrateSourceFK('inspections', 'inspection', 'fillout_submission_id', 'fillout');
  await migrateSourceFK('inspections', 'inspection', 'airtable_record_id', 'airtable');

  await migrateSourceFK('expenses', 'expense', 'fillout_submission_id', 'fillout');
  await migrateSourceFK('expenses', 'expense', 'ramp_transaction_id', 'ramp');

  await migrateSourceFK('derm_manifests', 'derm_manifest', 'airtable_record_id', 'airtable');

  await migrateSourceFK('receivables', 'receivable', 'airtable_record_id', 'airtable');

  await migrateSourceFK('routes', 'route', 'airtable_record_id', 'airtable');

  await migrateSourceFK('leads', 'lead', 'jobber_request_id', 'jobber');

  // Count what we migrated
  if (!DRY_RUN) {
    const count = await q('SELECT count(*) as n FROM entity_source_links');
    console.log(`  📊 Total entity_source_links: ${count[0].n}`);
  }

  // ===========================================================================
  // STEP 3: Migrate contacts from clients → client_contacts
  // ===========================================================================
  console.log('\n[STEP 3] Migrate contacts → client_contacts...');

  await run(`
    INSERT INTO client_contacts (client_id, contact_role, name, email, phone)
    SELECT id, 'primary', NULL, email, phone
    FROM clients WHERE email IS NOT NULL OR phone IS NOT NULL
    ON CONFLICT (client_id, contact_role) DO NOTHING
  `, 'primary contacts');

  await run(`
    INSERT INTO client_contacts (client_id, contact_role, name, email, phone)
    SELECT id, 'accounting', acct_name, accounting_email, accounting_phone
    FROM clients WHERE accounting_email IS NOT NULL OR accounting_phone IS NOT NULL OR acct_name IS NOT NULL
    ON CONFLICT (client_id, contact_role) DO NOTHING
  `, 'accounting contacts');

  await run(`
    INSERT INTO client_contacts (client_id, contact_role, name, email, phone)
    SELECT id, 'operations', op_name, operation_email, operation_phone
    FROM clients WHERE operation_email IS NOT NULL OR operation_phone IS NOT NULL OR op_name IS NOT NULL
    ON CONFLICT (client_id, contact_role) DO NOTHING
  `, 'operations contacts');

  await run(`
    INSERT INTO client_contacts (client_id, contact_role, name, email, phone)
    SELECT id, 'city_compliance', NULL, city_email, NULL
    FROM clients WHERE city_email IS NOT NULL
    ON CONFLICT (client_id, contact_role) DO NOTHING
  `, 'city compliance contacts');

  if (!DRY_RUN) {
    const count = await q('SELECT count(*) as n FROM client_contacts');
    console.log(`  📊 Total client_contacts: ${count[0].n}`);
  }

  // ===========================================================================
  // STEP 4: Migrate address/GPS/scheduling from clients → properties
  // ===========================================================================
  console.log('\n[STEP 4] Enrich properties with GPS, zone, access schedule...');

  // Add new columns to properties if they don't exist
  const propNewCols = [
    ['zone', 'text'],
    ['latitude', 'numeric'],
    ['longitude', 'numeric'],
    ['geofence_radius_meters', 'numeric'],
    ['geofence_type', 'text'],
    ['access_hours_start', 'text'],
    ['access_hours_end', 'text'],
    ['access_days', 'text[]'],
    ['location_photo_url', 'text'],
    ['is_primary', 'boolean DEFAULT true'],
    ['notes', 'text'],
  ];

  for (const [col, type] of propNewCols) {
    await safeRun(`ALTER TABLE properties ADD COLUMN IF NOT EXISTS ${col} ${type}`, `properties.${col}`);
  }

  // Rename street → address for clarity
  await safeRun(`ALTER TABLE properties RENAME COLUMN street TO address`, 'rename street→address');
  // Rename postal_code → zip
  await safeRun(`ALTER TABLE properties RENAME COLUMN postal_code TO zip`, 'rename postal_code→zip');

  // Update properties with client data (for clients that have a matching property)
  await run(`
    UPDATE properties p SET
      zone = c.zone,
      latitude = c.latitude,
      longitude = c.longitude,
      geofence_radius_meters = c.geofence_radius_meters,
      geofence_type = c.geofence_type,
      access_hours_start = c.hours_in,
      access_hours_end = c.hours_out,
      access_days = c.days_of_week,
      location_photo_url = c.photo_location_gt,
      is_primary = true
    FROM clients c
    WHERE p.client_id = c.id
  `, 'properties ← clients (GPS, zone, access schedule)');

  // For clients WITHOUT a property row, create one from the client's address
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

  if (!DRY_RUN) {
    const count = await q('SELECT count(*) as n FROM properties');
    console.log(`  📊 Total properties: ${count[0].n}`);
  }

  // ===========================================================================
  // STEP 5: Migrate GDO/GT-specific data → service_configs
  // ===========================================================================
  console.log('\n[STEP 5] Migrate GDO + equipment data → service_configs...');

  await safeRun(`ALTER TABLE service_configs ADD COLUMN IF NOT EXISTS equipment_size_gallons numeric`, 'service_configs.equipment_size_gallons');
  await safeRun(`ALTER TABLE service_configs ADD COLUMN IF NOT EXISTS permit_number text`, 'service_configs.permit_number');
  await safeRun(`ALTER TABLE service_configs ADD COLUMN IF NOT EXISTS permit_expiration date`, 'service_configs.permit_expiration');

  await run(`
    UPDATE service_configs sc SET
      equipment_size_gallons = c.gt_size_gallons,
      permit_number = c.gdo_number,
      permit_expiration = c.gdo_expiration_date
    FROM clients c
    WHERE sc.client_id = c.id
      AND sc.service_type = 'GT'
      AND (c.gt_size_gallons IS NOT NULL OR c.gdo_number IS NOT NULL)
  `, 'GT service_configs ← clients (GDO + size)');

  // ===========================================================================
  // STEP 6: Migrate routes → route_stops (one stop per old route row)
  // ===========================================================================
  console.log('\n[STEP 6] Migrate routes → route_stops...');

  // Add new columns to routes
  await safeRun(`ALTER TABLE routes ADD COLUMN IF NOT EXISTS route_date date`, 'routes.route_date');
  await safeRun(`ALTER TABLE routes ADD COLUMN IF NOT EXISTS vehicle_id bigint REFERENCES vehicles(id)`, 'routes.vehicle_id');
  await safeRun(`ALTER TABLE routes ADD COLUMN IF NOT EXISTS employee_id bigint REFERENCES employees(id)`, 'routes.employee_id');
  await safeRun(`ALTER TABLE routes ADD COLUMN IF NOT EXISTS notes text`, 'routes.notes');

  // Old route rows become route_stops
  await run(`
    INSERT INTO route_stops (route_id, client_id, service_type, wanted_date, status)
    SELECT id, client_id, 'GT', gt_wanted_date, status
    FROM routes
    WHERE client_id IS NOT NULL
    ON CONFLICT DO NOTHING
  `, 'routes → route_stops');

  // ===========================================================================
  // STEP 7: Drop unused columns from all tables
  // ===========================================================================
  console.log('\n[STEP 7] Drop unused columns...');

  // --- CLIENTS: drop everything that moved out ---
  const clientDropCols = [
    'display_name', 'address_line1', 'city', 'state', 'zip_code', 'county', 'zone',
    'latitude', 'longitude', 'geofence_radius_meters', 'geofence_type',
    'email', 'phone', 'accounting_email', 'operation_email', 'accounting_phone',
    'operation_phone', 'city_email', 'op_name', 'acct_name',
    'days_of_week', 'hours_in', 'hours_out',
    'gdo_number', 'gdo_expiration_date', 'gdo_frequency',
    'contract_warranty', 'signature_date', 'photo_location_gt',
    'gt_size_gallons',
    'airtable_record_id', 'jobber_client_id', 'samsara_address_id',
    'data_sources', 'match_method', 'match_confidence',
  ];
  for (const col of clientDropCols) {
    await safeRun(`ALTER TABLE clients DROP COLUMN IF EXISTS ${col}`, `clients DROP ${col}`);
  }

  // --- EMPLOYEES: drop empty/source-specific ---
  const empDropCols = [
    'first_name', 'last_name', 'cdl_license', 'certifications', 'emergency_contact',
    'eld_settings', 'driver_activation', 'license_state',
    'is_account_owner', 'is_account_admin', 'access_level',
    'airtable_record_id', 'samsara_driver_id', 'jobber_user_id', 'fillout_display_name',
    'data_sources',
  ];
  for (const col of empDropCols) {
    await safeRun(`ALTER TABLE employees DROP COLUMN IF EXISTS ${col}`, `employees DROP ${col}`);
  }

  // --- VEHICLES: drop source-specific + hardware ---
  const vehDropCols = [
    'short_code', 'primary_use',
    'gateway_serial', 'gateway_model', 'camera_serial',
    'samsara_vehicle_id', 'airtable_record_id',
    'data_sources',
  ];
  for (const col of vehDropCols) {
    await safeRun(`ALTER TABLE vehicles DROP COLUMN IF EXISTS ${col}`, `vehicles DROP ${col}`);
  }

  // --- VISITS: drop redundant/calculated/source ---
  const visitDropCols = [
    'truck', 'zone', 'completed_by',
    'late_status', 'late_status_gt_freq',
    'amount', 'instructions', 'source',
    'jobber_visit_id', 'jobber_invoice_id', 'airtable_record_id',
    'data_sources',
  ];
  for (const col of visitDropCols) {
    await safeRun(`ALTER TABLE visits DROP COLUMN IF EXISTS ${col}`, `visits DROP ${col}`);
  }

  // --- JOBS: drop empty/calculated/source ---
  const jobDropCols = [
    'instructions', 'job_type', 'billing_type', 'service_category',
    'completed_at', 'invoiced_total', 'uninvoiced_total',
    'jobber_job_id', 'jobber_quote_id',
  ];
  for (const col of jobDropCols) {
    await safeRun(`ALTER TABLE jobs DROP COLUMN IF EXISTS ${col}`, `jobs DROP ${col}`);
  }

  // Add notes to jobs
  await safeRun(`ALTER TABLE jobs ADD COLUMN IF NOT EXISTS notes text`, 'jobs ADD notes');

  // --- INVOICES: drop source ---
  await safeRun(`ALTER TABLE invoices DROP COLUMN IF EXISTS jobber_invoice_id`, 'invoices DROP jobber_invoice_id');
  await safeRun(`ALTER TABLE invoices DROP COLUMN IF EXISTS message`, 'invoices DROP message');

  // --- QUOTES: drop source ---
  await safeRun(`ALTER TABLE quotes DROP COLUMN IF EXISTS jobber_quote_id`, 'quotes DROP jobber_quote_id');
  await safeRun(`ALTER TABLE quotes DROP COLUMN IF EXISTS message`, 'quotes DROP message');

  // --- LINE_ITEMS: drop source ---
  await safeRun(`ALTER TABLE line_items DROP COLUMN IF EXISTS jobber_line_item_id`, 'line_items DROP jobber_line_item_id');

  // --- PROPERTIES: drop source ---
  await safeRun(`ALTER TABLE properties DROP COLUMN IF EXISTS jobber_property_id`, 'properties DROP jobber_property_id');
  // Drop old is_billing_address, keep is_billing
  await safeRun(`ALTER TABLE properties RENAME COLUMN is_billing_address TO is_billing`, 'rename is_billing_address→is_billing');

  // --- INSPECTIONS: drop photo columns (moved to inspection_photos) + source + expense ---
  const inspDropCols = [
    'photo_dashboard', 'photo_cabin', 'photo_cabin_side_left', 'photo_cabin_side_right',
    'photo_front', 'photo_back', 'photo_left_side', 'photo_right_side',
    'photo_boots', 'photo_remote', 'photo_closed_valve', 'photo_issue',
    'photo_sludge_level', 'photo_water_level', 'photo_derm_manifest', 'photo_derm_address',
    'photo_expense_receipt',
    'has_expense', 'expense_note', 'expense_amount',
    'fillout_submission_id', 'airtable_record_id',
    'data_sources',
  ];
  for (const col of inspDropCols) {
    await safeRun(`ALTER TABLE inspections DROP COLUMN IF EXISTS ${col}`, `inspections DROP ${col}`);
  }

  // --- EXPENSES: drop source-specific ---
  const expDropCols = [
    'ramp_card_holder', 'ramp_merchant', 'ramp_transaction_id',
    'fillout_submission_id',
    'data_sources',
  ];
  for (const col of expDropCols) {
    await safeRun(`ALTER TABLE expenses DROP COLUMN IF EXISTS ${col}`, `expenses DROP ${col}`);
  }

  // --- DERM_MANIFESTS: drop redundant address + source ---
  const dermDropCols = [
    'service_address', 'service_city', 'service_zip', 'service_county',
    'airtable_record_id',
  ];
  for (const col of dermDropCols) {
    await safeRun(`ALTER TABLE derm_manifests DROP COLUMN IF EXISTS ${col}`, `derm_manifests DROP ${col}`);
  }

  // --- RECEIVABLES: drop source ---
  await safeRun(`ALTER TABLE receivables DROP COLUMN IF EXISTS airtable_record_id`, 'receivables DROP airtable_record_id');
  await safeRun(`ALTER TABLE receivables DROP COLUMN IF EXISTS last_modified`, 'receivables DROP last_modified');

  // --- ROUTES: drop old service-specific columns ---
  const routeDropCols = ['gt_wanted_date', 'cl_wanted_date', 'airtable_record_id'];
  for (const col of routeDropCols) {
    await safeRun(`ALTER TABLE routes DROP COLUMN IF EXISTS ${col}`, `routes DROP ${col}`);
  }

  // --- LEADS: drop source + unused ---
  const leadDropCols = [
    'jobber_request_id',
    'assigned_to', 'service_interest', 'estimated_value',
    'last_contact_at', 'lost_reason',
  ];
  for (const col of leadDropCols) {
    await safeRun(`ALTER TABLE leads DROP COLUMN IF EXISTS ${col}`, `leads DROP ${col}`);
  }

  // --- Drop source_map table (replaced by entity_source_links) ---
  await safeRun(`DROP TABLE IF EXISTS source_map CASCADE`, 'DROP source_map');

  // ===========================================================================
  // STEP 8: Drop service_configs calculated columns
  // ===========================================================================
  console.log('\n[STEP 8] Clean service_configs...');

  const scDropCols = [
    'next_visit_calculated', 'total_per_year', 'projected_year',
    'data_quality', 'visits_available',
  ];
  for (const col of scDropCols) {
    await safeRun(`ALTER TABLE service_configs DROP COLUMN IF EXISTS ${col}`, `service_configs DROP ${col}`);
  }

  // ===========================================================================
  // STEP 9: Recreate views
  // ===========================================================================
  console.log('\n[STEP 9] Recreate views...');

  await run(`DROP VIEW IF EXISTS client_services_flat CASCADE`, 'drop view client_services_flat');
  await run(`DROP VIEW IF EXISTS clients_due_service CASCADE`, 'drop view clients_due_service');
  await run(`DROP VIEW IF EXISTS visits_recent CASCADE`, 'drop view visits_recent');
  await run(`DROP VIEW IF EXISTS manifest_detail CASCADE`, 'drop view manifest_detail');
  await run(`DROP VIEW IF EXISTS driver_inspection_status CASCADE`, 'drop view driver_inspection_status');

  await run(`
    CREATE VIEW client_services_flat WITH (security_invoker = true) AS
    SELECT
      c.id, c.name, c.client_code,
      p.address, p.city, p.zone,
      c.status,
      MAX(CASE WHEN s.service_type = 'GT' THEN s.equipment_size_gallons END) AS gt_size_gallons,
      MAX(CASE WHEN s.service_type = 'GT' THEN s.frequency_days END) AS gt_frequency_days,
      MAX(CASE WHEN s.service_type = 'GT' THEN s.price_per_visit END) AS gt_price_per_visit,
      MAX(CASE WHEN s.service_type = 'GT' THEN s.last_visit END) AS gt_last_visit,
      MAX(CASE WHEN s.service_type = 'GT' THEN s.next_visit END) AS gt_next_visit,
      MAX(CASE WHEN s.service_type = 'GT' THEN s.status END) AS gt_status,
      MAX(CASE WHEN s.service_type = 'CL' THEN s.frequency_days END) AS cl_frequency_days,
      MAX(CASE WHEN s.service_type = 'CL' THEN s.price_per_visit END) AS cl_price_per_visit,
      MAX(CASE WHEN s.service_type = 'CL' THEN s.last_visit END) AS cl_last_visit,
      MAX(CASE WHEN s.service_type = 'CL' THEN s.next_visit END) AS cl_next_visit,
      MAX(CASE WHEN s.service_type = 'CL' THEN s.status END) AS cl_status,
      MAX(CASE WHEN s.service_type = 'WD' THEN s.frequency_days END) AS wd_frequency_days,
      MAX(CASE WHEN s.service_type = 'WD' THEN s.price_per_visit END) AS wd_price_per_visit,
      MAX(CASE WHEN s.service_type = 'WD' THEN s.last_visit END) AS wd_last_visit,
      MAX(CASE WHEN s.service_type = 'WD' THEN s.next_visit END) AS wd_next_visit,
      MAX(CASE WHEN s.service_type = 'WD' THEN s.status END) AS wd_status
    FROM clients c
    LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
    LEFT JOIN service_configs s ON s.client_id = c.id
    GROUP BY c.id, p.address, p.city, p.zone
  `, 'CREATE VIEW client_services_flat');

  await run(`
    CREATE VIEW clients_due_service WITH (security_invoker = true) AS
    SELECT
      c.id, c.name, c.client_code,
      p.address, p.city, p.zone,
      s.service_type, s.last_visit, s.next_visit, s.frequency_days,
      s.next_visit - CURRENT_DATE AS days_until_due,
      CASE
        WHEN s.next_visit < CURRENT_DATE THEN 'OVERDUE'
        WHEN s.next_visit <= CURRENT_DATE + 14 THEN 'DUE_SOON'
        ELSE 'OK'
      END AS due_status
    FROM clients c
    JOIN service_configs s ON s.client_id = c.id
    LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
    WHERE c.status = 'Active'
      AND s.status IS DISTINCT FROM 'Paused'
      AND s.next_visit IS NOT NULL
    ORDER BY s.next_visit
  `, 'CREATE VIEW clients_due_service');

  await run(`
    CREATE VIEW visits_recent WITH (security_invoker = true) AS
    SELECT
      v.id, v.visit_date, v.service_type,
      c.name AS client_name,
      p.address, p.zone,
      v.visit_status, v.gps_confirmed,
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
  `, 'CREATE VIEW visits_recent');

  await run(`
    CREATE VIEW manifest_detail WITH (security_invoker = true) AS
    SELECT
      m.id, m.white_manifest_num, m.service_date,
      c.name AS client_name,
      p.address,
      p.county AS service_county,
      m.sent_to_client, m.sent_to_city,
      COUNT(mv.visit_id) AS visit_count
    FROM derm_manifests m
    JOIN clients c ON c.id = m.client_id
    LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
    LEFT JOIN manifest_visits mv ON mv.manifest_id = m.id
    GROUP BY m.id, m.white_manifest_num, m.service_date,
             c.name, p.address, p.county, m.sent_to_client, m.sent_to_city
    ORDER BY m.service_date DESC
  `, 'CREATE VIEW manifest_detail');

  await run(`
    CREATE VIEW driver_inspection_status WITH (security_invoker = true) AS
    SELECT
      e.id, e.full_name,
      MAX(CASE WHEN i.inspection_type = 'PRE' AND i.shift_date = CURRENT_DATE THEN i.submitted_at END) AS pre_submitted_at,
      MAX(CASE WHEN i.inspection_type = 'POST' THEN i.submitted_at END) AS post_submitted_at,
      COUNT(CASE WHEN i.shift_date = CURRENT_DATE THEN 1 END) AS inspections_today,
      BOOL_OR(CASE WHEN i.has_issue THEN true END) AS has_open_issue
    FROM employees e
    LEFT JOIN inspections i ON i.employee_id = e.id
      AND (i.shift_date = CURRENT_DATE
           OR (i.shift_date = CURRENT_DATE - 1 AND i.inspection_type = 'POST'
               AND i.submitted_at >= CURRENT_DATE::timestamptz))
    WHERE e.status = 'Active'
    GROUP BY e.id, e.full_name
  `, 'CREATE VIEW driver_inspection_status');

  // New: visits_with_status (computed late status)
  await run(`
    CREATE VIEW visits_with_status WITH (security_invoker = true) AS
    SELECT
      v.*,
      c.name AS client_name,
      p.zone,
      veh.name AS vehicle_name,
      sc.frequency_days,
      CASE
        WHEN v.visit_status = 'Completed' THEN 'OK'
        WHEN v.visit_date < CURRENT_DATE AND NOT v.is_complete THEN 'LATE'
        ELSE 'ON_TIME'
      END AS computed_late_status
    FROM visits v
    JOIN clients c ON c.id = v.client_id
    LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
    LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
    LEFT JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = v.service_type
  `, 'CREATE VIEW visits_with_status');

  // ===========================================================================
  // STEP 10: Apply RLS + grants on new tables
  // ===========================================================================
  console.log('\n[STEP 10] Apply security...');

  const newTables = ['entity_source_links', 'client_contacts', 'inspection_photos', 'visit_photos', 'route_stops'];
  for (const t of newTables) {
    await safeRun(`ALTER TABLE ${t} ENABLE ROW LEVEL SECURITY`, `RLS enable ${t}`);
    await safeRun(`ALTER TABLE ${t} FORCE ROW LEVEL SECURITY`, `RLS force ${t}`);
    await safeRun(`CREATE POLICY "anon_read_${t}" ON ${t} FOR SELECT TO anon USING (true)`, `policy anon ${t}`);
    await safeRun(`CREATE POLICY "auth_read_${t}" ON ${t} FOR SELECT TO authenticated USING (true)`, `policy auth ${t}`);
    await safeRun(`CREATE POLICY "sr_all_${t}" ON ${t} FOR ALL TO service_role USING (true) WITH CHECK (true)`, `policy sr ${t}`);
    await safeRun(`REVOKE ALL ON ${t} FROM anon`, `revoke anon ${t}`);
    await safeRun(`GRANT SELECT ON ${t} TO anon`, `grant anon ${t}`);
    await safeRun(`REVOKE ALL ON ${t} FROM authenticated`, `revoke auth ${t}`);
    await safeRun(`GRANT SELECT ON ${t} TO authenticated`, `grant auth ${t}`);
    await safeRun(`GRANT ALL ON ${t} TO service_role`, `grant sr ${t}`);
  }

  // Views
  const newViews = ['visits_with_status'];
  for (const v of newViews) {
    await safeRun(`REVOKE ALL ON ${v} FROM anon`, `revoke anon ${v}`);
    await safeRun(`GRANT SELECT ON ${v} TO anon`, `grant anon ${v}`);
    await safeRun(`REVOKE ALL ON ${v} FROM authenticated`, `revoke auth ${v}`);
    await safeRun(`GRANT SELECT ON ${v} TO authenticated`, `grant auth ${v}`);
    await safeRun(`GRANT ALL ON ${v} TO service_role`, `grant sr ${v}`);
  }

  // No public access to entity_source_links (sync infrastructure only)
  await safeRun(`REVOKE ALL ON entity_source_links FROM anon`, 'lock esl from anon');
  await safeRun(`REVOKE ALL ON entity_source_links FROM authenticated`, 'lock esl from auth');
  await safeRun(`GRANT ALL ON entity_source_links TO service_role`, 'esl → service_role');

  // ===========================================================================
  // STEP 11: Verify
  // ===========================================================================
  console.log('\n[STEP 11] Verify...');

  if (!DRY_RUN) {
    // Count columns per table
    const colCounts = await q(`
      SELECT table_name, count(*) as cols
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name NOT LIKE '%_flat' AND table_name NOT LIKE '%_due_%'
        AND table_name NOT LIKE '%_recent' AND table_name NOT LIKE '%_detail'
        AND table_name NOT LIKE '%_status' AND table_name NOT LIKE '%_with_%'
      GROUP BY table_name ORDER BY table_name
    `);

    console.log('\n  📊 FINAL TABLE COLUMN COUNTS:');
    for (const r of colCounts) {
      console.log(`    ${r.table_name.padEnd(25)} ${r.cols} columns`);
    }

    const eslCount = await q('SELECT count(*) as n FROM entity_source_links');
    const ccCount = await q('SELECT count(*) as n FROM client_contacts');
    const propCount = await q('SELECT count(*) as n FROM properties');

    console.log(`\n  📊 entity_source_links: ${eslCount[0].n} rows`);
    console.log(`  📊 client_contacts: ${ccCount[0].n} rows`);
    console.log(`  📊 properties: ${propCount[0].n} rows`);
  }

  console.log('\n============================================================');
  console.log(DRY_RUN ? 'DRY RUN COMPLETE — run with --execute to apply' : 'MIGRATION COMPLETE');
  console.log('============================================================');
})();
