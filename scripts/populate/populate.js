// ============================================================================
// populate.js — Main population orchestrator
// ============================================================================
//
// Reads:
//   • Jobber JSONB cache from OLD Supabase project (jobber_pull_*)
//   • Live Airtable, Samsara, Fillout via direct APIs
//
// Writes:
//   • Idempotent UPSERTs into NEW Supabase project (20 tables)
//
// Modes:
//   --dry-run   : default. Prints what would be inserted, no writes.
//   --execute   : actually performs writes. Requires --confirm flag too.
//   --truncate  : TRUNCATE all 20 tables before populate (clean slate)
//   --step <N>  : run only step N (1-18). Useful for partial re-runs.
//
// Strategy:
//   PHASE 1 — Pull all source data into in-memory caches
//   PHASE 2 — Build canonical merged records (no writes)
//   PHASE 3 — Bulk UPSERT in dependency order (parents before children)
//   PHASE 4 — Fixup passes (resolve text→bigint FK references)
//   PHASE 5 — Write sync_log entry
//
// Dependency order (so FK constraints are satisfied):
//   1. clients              (parent of everything)
//   2. employees            (parent of visit_assignments, inspections)
//   3. vehicles             (parent of inspections, expenses, visits)
//   4. properties           (FK→clients)
//   5. service_configs      (FK→clients)
//   6. quotes               (FK→clients, properties)
//   7. jobs                 (FK→clients, properties, quotes)
//   8. invoices             (FK→clients, jobs)
//   9. line_items           (FK→jobs)
//  10. visits               (FK→clients, properties, jobs, vehicles, invoices)
//  11. visit_assignments    (FK→visits, employees)
//  12. inspections          (FK→vehicles, employees)
//  13. expenses             (FK→vehicles, employees)
//  14. derm_manifests       (FK→clients)
//  15. manifest_visits      (FK→derm_manifests, visits)
//  16. routes               (FK→clients)
//  17. receivables          (FK→clients)
//  18. leads                (FK→clients via converted_client_id)
//
// FK fixup passes (after main inserts):
//   A. visits.invoice_id     ← invoices.id WHERE jobber_invoice_id matches
//   B. visits.vehicle_id     ← vehicles.id WHERE truck text matches
//   C. inspections.vehicle_id← vehicles.id WHERE truck text matches
//   D. inspections.employee_id ← employees.id WHERE driver text matches
//   E. jobs.quote_id         ← quotes.id WHERE jobber_quote_id matches
// ============================================================================

const path = require('path');
const fs = require('fs');
const { newQuery, oldQuery, bulkUpsert, fetchJsonbCache } = require('./lib/db');
const { pullAirtable, pullSamsara, pullFillout } = require('./lib/sources');
const N = require('./lib/normalize');

// ----------------------------------------------------------------------------
// CLI args
// ----------------------------------------------------------------------------
const args = process.argv.slice(2);
const DRY_RUN = !args.includes('--execute');
const CONFIRM = args.includes('--confirm');
const TRUNCATE = args.includes('--truncate');
const stepArg = args.find(a => a.startsWith('--step='));
const ONLY_STEP = stepArg ? parseInt(stepArg.split('=')[1]) : null;

if (!DRY_RUN && !CONFIRM) {
  console.error('REFUSING TO EXECUTE: --execute requires --confirm');
  process.exit(1);
}

console.log('='.repeat(70));
console.log('populate.js — UNCLOGME');
console.log(`Mode:     ${DRY_RUN ? 'DRY-RUN (no writes)' : 'EXECUTE (writes enabled)'}`);
console.log(`Truncate: ${TRUNCATE ? 'YES' : 'no'}`);
console.log(`Step:     ${ONLY_STEP || 'all'}`);
console.log('='.repeat(70));

// ----------------------------------------------------------------------------
// In-memory data caches
// ----------------------------------------------------------------------------
const cache = {
  jobber: { clients: [], properties: [], jobs: [], visits: [], invoices: [], quotes: [], users: [], lineItems: [] },
  airtable: { clients: [], visits: [], derm: [], inspections: [], routeCreation: [], drivers: [], pastDue: [], leads: [] },
  samsara: { vehicles: [], addresses: [], drivers: [] },
  fillout: { pre: [], post: [] },
  // Lookup maps built after pulls
  maps: {
    jobberClientById: new Map(),       // jobber gid → jobber client object
    airtableClientByJobberId: new Map(),// jobber gid → airtable record (manual link via field)
    samsaraAddressByName: new Map(),    // normName → samsara address
    canonicalClientByJobberId: new Map(),// jobber gid → final canonical row
    canonicalClientByATId: new Map(),   // airtable rec id → final canonical row
  },
};

const stats = {
  started_at: new Date(),
  steps: {},
  errors: [],
};

// ----------------------------------------------------------------------------
// PHASE 1 — PULL ALL SOURCE DATA
// ----------------------------------------------------------------------------
async function phase1_pull() {
  console.log('\n[PHASE 1] Pulling source data...');

  console.log('  → Jobber JSONB cache (old Supabase)...');
  const [c, p, j, v, i, q, u, li] = await Promise.all([
    fetchJsonbCache('jobber_pull_clients'),
    fetchJsonbCache('jobber_pull_properties'),
    fetchJsonbCache('jobber_pull_jobs'),
    fetchJsonbCache('jobber_pull_visits'),
    fetchJsonbCache('jobber_pull_invoices'),
    fetchJsonbCache('jobber_pull_quotes'),
    fetchJsonbCache('jobber_pull_users'),
    fetchJsonbCache('jobber_pull_line_items'),
  ]);
  cache.jobber = { clients: c, properties: p, jobs: j, visits: v, invoices: i, quotes: q, users: u, lineItems: li };
  console.log(`    clients=${c.length} properties=${p.length} jobs=${j.length} visits=${v.length} invoices=${i.length} quotes=${q.length} users=${u.length} lineItems=${li.length}`);

  cache.airtable = await pullAirtable();
  cache.samsara = await pullSamsara();
  cache.fillout = await pullFillout();

  // Build lookup maps
  cache.jobber.clients.forEach(jc => cache.maps.jobberClientById.set(jc.id, jc));
  // Build name → jobber client lookup for fuzzy AT match.
  // Jobber companyName has "NNN-XX " code prefix; AT Client Name doesn't. Strip it.
  const stripJobberPrefix = (s) => String(s || '').replace(/^\d{2,4}[-\s]?[A-Z0-9]{1,5}\s+/i, '').trim();
  const jobberByNormName = new Map();
  for (const jc of cache.jobber.clients) {
    const stripped = stripJobberPrefix(jc.companyName || jc.name || `${jc.firstName || ''} ${jc.lastName || ''}`.trim());
    if (stripped) jobberByNormName.set(N.normName(stripped), jc);
  }
  let nameLinked = 0;
  cache.airtable.clients.forEach(ac => {
    const jid = N.atField(ac, 'Jobber Client ID');
    if (jid) { cache.maps.airtableClientByJobberId.set(jid, ac); return; }
    // name-based fallback
    const atName = N.atField(ac, 'Client Name') || N.atField(ac, 'CLIENT XX') || '';
    const key = N.normName(atName);
    let jc = jobberByNormName.get(key);
    if (!jc) {
      // fuzzy
      const candidates = [...jobberByNormName.values()];
      const m = N.bestFuzzyMatch(atName, candidates, x => stripJobberPrefix(x.companyName || x.name), 0.85);
      if (m) jc = m.match;
    }
    if (jc) { cache.maps.airtableClientByJobberId.set(jc.id, ac); nameLinked++; }
  });
  console.log(`  AT→Jobber name-linked: ${nameLinked}`);
  cache.samsara.addresses.forEach(sa => {
    cache.maps.samsaraAddressByName.set(N.normName(sa.name), sa);
  });

  console.log(`  Maps built: jobberClientById=${cache.maps.jobberClientById.size} airtableByJobberId=${cache.maps.airtableClientByJobberId.size} samsaraByName=${cache.maps.samsaraAddressByName.size}`);
}

// ----------------------------------------------------------------------------
// STEP 1 — CLIENTS
// ----------------------------------------------------------------------------
async function step1_clients() {
  console.log('\n[STEP 1] Clients merge...');
  const rows = [];

  // 1a. Every Jobber client → canonical row (Jobber wins on conflicts)
  for (const jc of cache.jobber.clients) {
    const ac = cache.maps.airtableClientByJobberId.get(jc.id);
    const sa = cache.maps.samsaraAddressByName.get(N.normName(jc.companyName || jc.name));
    const sources = ['jobber'];
    if (ac) sources.push('airtable');
    if (sa) sources.push('samsara');

    rows.push({
      name: jc.companyName || jc.name || `${jc.firstName || ''} ${jc.lastName || ''}`.trim() || 'UNKNOWN',
      display_name: ac ? N.atField(ac, 'CLIENT XX') : null,
      client_code: ac ? N.atField(ac, 'Client Code #3') : null,
      status: jc.isArchived ? 'INACTIVE' : (ac && N.atField(ac, 'ACTIVE/INACTIVE')) || 'ACTIVE',
      address_line1: jc.billingAddress?.street || (ac && N.atField(ac, 'Address')),
      city: jc.billingAddress?.city || (ac && N.atField(ac, 'City')),
      state: jc.billingAddress?.province || (ac && N.atField(ac, 'State')),
      zip_code: jc.billingAddress?.postalCode || (ac && N.atField(ac, 'Zip Code')),
      county: ac ? N.atField(ac, 'County') : null,
      zone: ac ? N.atField(ac, 'Zone') : null,
      latitude: sa?.latitude || null,
      longitude: sa?.longitude || null,
      email: jc.emails?.[0]?.address || (ac && N.atField(ac, 'Operation Email')),
      phone: jc.phones?.[0]?.number || (ac && N.atField(ac, 'Operation Phone')),
      // Airtable-only fields (Jobber has no equivalent)
      accounting_email: ac ? N.atField(ac, 'Acounting Email') : null,
      operation_email: ac ? N.atField(ac, 'Operation Email') : null,
      accounting_phone: ac ? N.atField(ac, 'Acounting Phone') : null,
      operation_phone: ac ? N.atField(ac, 'Operation Phone') : null,
      city_email: ac ? N.atField(ac, 'City Email') : null,
      op_name: ac ? N.atField(ac, 'OP Name') : null,
      acct_name: ac ? N.atField(ac, 'Acct Name') : null,
      days_of_week: ac ? N.atField(ac, 'Days of the week') : null,
      hours_in: ac ? N.atField(ac, 'Hours in') : null,
      hours_out: ac ? N.atField(ac, 'Hours out') : null,
      gdo_number: ac ? N.atField(ac, 'GDO Number') : null,
      gdo_expiration_date: N.dateOnly(ac && N.atField(ac, 'GDO expiration date')),
      gdo_frequency: N.intOrNull(ac && N.atField(ac, 'GDO Frequency')),
      contract_warranty: ac ? N.atField(ac, 'Contract/Warranty') : null,
      signature_date: N.dateOnly(ac && N.atField(ac, 'Signature Date')),
      photo_location_gt: ac ? N.atField(ac, 'Photo and Location of GT') : null,
      balance: N.numOrNull(jc.balance),
      gt_size_gallons: N.numOrNull(ac && N.atField(ac, 'Size GT in Gallon')),
      geofence_radius_meters: sa?.geofence?.circle?.radiusMeters || null,
      geofence_type: sa?.geofence?.circle ? 'circle' : (sa?.geofence?.polygon ? 'polygon' : null),
      airtable_record_id: ac?.id || null,
      jobber_client_id: jc.id,
      samsara_address_id: sa?.id || null,
      data_sources: sources,
      match_method: ac ? 'jobber_id_link' : (sa ? 'name_fuzzy' : 'jobber_only'),
      match_confidence: ac ? 1.0 : (sa ? 0.85 : 1.0),
      notes: null,
    });
  }

  // 1b. Airtable clients with NO Jobber match → historical rows
  const matchedATIds = new Set(rows.map(r => r.airtable_record_id).filter(Boolean));
  for (const ac of cache.airtable.clients) {
    if (matchedATIds.has(ac.id)) continue;
    rows.push({
      name: N.atField(ac, 'Client Name') || 'UNKNOWN_AT',
      display_name: N.atField(ac, 'CLIENT XX'),
      client_code: N.atField(ac, 'Client Code #3'),
      status: N.atField(ac, 'ACTIVE/INACTIVE') || 'INACTIVE',
      address_line1: N.atField(ac, 'Address'),
      city: N.atField(ac, 'City'),
      state: N.atField(ac, 'State'),
      zip_code: N.atField(ac, 'Zip Code'),
      county: N.atField(ac, 'County'),
      zone: N.atField(ac, 'Zone'),
      email: N.atField(ac, 'Operation Email'),
      phone: N.atField(ac, 'Operation Phone'),
      accounting_email: N.atField(ac, 'Acounting Email'),
      operation_email: N.atField(ac, 'Operation Email'),
      accounting_phone: N.atField(ac, 'Acounting Phone'),
      operation_phone: N.atField(ac, 'Operation Phone'),
      city_email: N.atField(ac, 'City Email'),
      op_name: N.atField(ac, 'OP Name'),
      acct_name: N.atField(ac, 'Acct Name'),
      days_of_week: N.atField(ac, 'Days of the week'),
      hours_in: N.atField(ac, 'Hours in'),
      hours_out: N.atField(ac, 'Hours out'),
      gdo_number: N.atField(ac, 'GDO Number'),
      gdo_expiration_date: N.dateOnly(N.atField(ac, 'GDO expiration date')),
      gdo_frequency: N.intOrNull(N.atField(ac, 'GDO Frequency')),
      contract_warranty: N.atField(ac, 'Contract/Warranty'),
      signature_date: N.dateOnly(N.atField(ac, 'Signature Date')),
      photo_location_gt: N.atField(ac, 'Photo and Location of GT'),
      gt_size_gallons: N.numOrNull(N.atField(ac, 'Size GT in Gallon')),
      airtable_record_id: ac.id,
      jobber_client_id: null,
      samsara_address_id: null,
      data_sources: ['airtable'],
      match_method: 'airtable_only',
      match_confidence: 1.0,
      notes: 'Historical Airtable client, no Jobber link',
    });
  }

  console.log(`  Built ${rows.length} canonical client rows (jobber-merged + AT-historical)`);

  const cols = [
    'name','display_name','client_code','status','address_line1','city','state','zip_code','county','zone',
    'latitude','longitude','email','phone','accounting_email','operation_email','accounting_phone','operation_phone',
    'city_email','op_name','acct_name','days_of_week','hours_in','hours_out','gdo_number','gdo_expiration_date',
    'gdo_frequency','contract_warranty','signature_date','photo_location_gt','balance','gt_size_gallons',
    'geofence_radius_meters','geofence_type','airtable_record_id','jobber_client_id','samsara_address_id',
    'data_sources','match_method','match_confidence','notes'
  ];

  const result = await bulkUpsert('clients', rows, cols, 'jobber_client_id', { dryRun: DRY_RUN, batchSize: 100 });
  // Note: clients with NULL jobber_client_id won't conflict on jobber_client_id constraint.
  // We'll need a separate UPSERT path for those, OR a unique index on airtable_record_id.
  // For now: try jobber_client_id first, then airtable_record_id for the historical ones.

  stats.steps.clients = { built: rows.length, ...result };
  console.log(`  ${result.batches} batches, ${result.inserted || rows.length} rows ${DRY_RUN ? 'planned' : 'inserted'}`);
}

// ----------------------------------------------------------------------------
// ID MAP HELPERS — After each upsert, query back to build source→pk maps
// ----------------------------------------------------------------------------
const idMaps = {
  clientByJobberId: new Map(),
  clientByATId: new Map(),
  propertyByJobberId: new Map(),
  jobByJobberId: new Map(),
  invoiceByJobberId: new Map(),
  quoteByJobberId: new Map(),
  vehicleByName: new Map(),
  vehicleBySamsaraId: new Map(),
  employeeByName: new Map(),
  employeeByFilloutName: new Map(),
  employeeBySamsaraId: new Map(),
  employeeByJobberId: new Map(),
  visitByJobberId: new Map(),
  visitByATId: new Map(),
  manifestByATId: new Map(),
};

async function loadIdMap(table, keyCol, mapKey, normalizer = (x) => x) {
  if (DRY_RUN) return;
  const r = await newQuery(`SELECT id, ${keyCol} FROM ${table} WHERE ${keyCol} IS NOT NULL;`);
  const m = idMaps[mapKey];
  m.clear();
  for (const row of r) m.set(normalizer(row[keyCol]), row.id);
}

// ----------------------------------------------------------------------------
// STEP 2 — EMPLOYEES
// ----------------------------------------------------------------------------
async function step2_employees() {
  console.log('\n[STEP 2] Employees merge...');
  const rows = [];
  const seen = new Set();

  // Office staff that show up in Samsara driver list but should be 'office'
  const OFFICE_NAMES = new Set(['yannick', 'aaron', 'diego', 'yannick ayache', 'fred', 'fred zerpa']);

  // 2a. Airtable drivers (field staff master)
  for (const ad of cache.airtable.drivers) {
    const fullName = N.atField(ad, 'Name') || N.atField(ad, 'Full Name') || N.atField(ad, 'Driver');
    if (!fullName) continue;
    const key = N.normName(fullName);
    if (seen.has(key)) continue;
    seen.add(key);
    rows.push({
      full_name: fullName,
      role: N.atField(ad, 'Role') || 'Technician',
      status: N.atField(ad, 'Status') || 'ACTIVE',
      access_level: OFFICE_NAMES.has(key) ? 'office' : 'field',
      shift: N.atField(ad, 'Shift'),
      phone: N.atField(ad, 'Phone'),
      email: N.atField(ad, 'Email'),
      hire_date: N.dateOnly(N.atField(ad, 'Hire Date')),
      airtable_record_id: ad.id,
      samsara_driver_id: null,
      jobber_user_id: null,
      fillout_display_name: fullName,
      data_sources: ['airtable'],
      notes: null,
    });
  }

  // 2b. Samsara drivers — fuzzy match to existing
  for (const sd of cache.samsara.drivers) {
    const key = N.normName(sd.name);
    const existing = rows.find(r => N.normName(r.full_name) === key || N.similarity(r.full_name, sd.name) >= 0.9);
    if (existing) {
      existing.samsara_driver_id = sd.id;
      if (!existing.data_sources.includes('samsara')) existing.data_sources.push('samsara');
      continue;
    }
    seen.add(key);
    rows.push({
      full_name: sd.name,
      role: 'Technician',
      status: sd.driverActivationStatus === 'active' ? 'ACTIVE' : 'INACTIVE',
      access_level: OFFICE_NAMES.has(key) ? 'office' : 'field',
      phone: sd.phone || null,
      email: sd.username || null,
      license_state: sd.licenseState || null,
      driver_activation: sd.driverActivationStatus || null,
      airtable_record_id: null,
      samsara_driver_id: sd.id,
      jobber_user_id: null,
      fillout_display_name: sd.name,
      data_sources: ['samsara'],
      notes: null,
    });
  }

  // 2c. Jobber users — match into existing or add as office/admin
  for (const ju of cache.jobber.users) {
    const fname = ju.name?.full || `${ju.name?.first || ''} ${ju.name?.last || ''}`.trim();
    if (!fname) continue;
    const key = N.normName(fname);
    const existing = rows.find(r => N.normName(r.full_name) === key || N.similarity(r.full_name, fname) >= 0.9);
    if (existing) {
      existing.jobber_user_id = ju.id;
      existing.is_account_owner = !!ju.isAccountOwner;
      existing.is_account_admin = !!ju.isAccountAdmin;
      if (!existing.data_sources.includes('jobber')) existing.data_sources.push('jobber');
      continue;
    }
    rows.push({
      full_name: fname,
      role: ju.isAccountOwner ? 'Owner' : (ju.isAccountAdmin ? 'Admin' : 'Office'),
      status: 'ACTIVE',
      access_level: ju.isAccountOwner || ju.isAccountAdmin ? 'dev' : 'office',
      email: ju.email?.address || null,
      is_account_owner: !!ju.isAccountOwner,
      is_account_admin: !!ju.isAccountAdmin,
      airtable_record_id: null,
      samsara_driver_id: null,
      jobber_user_id: ju.id,
      fillout_display_name: fname,
      data_sources: ['jobber'],
      notes: null,
    });
  }

  const cols = ['full_name','role','status','access_level','shift','phone','email','hire_date',
    'license_state','driver_activation','is_account_owner','is_account_admin',
    'airtable_record_id','samsara_driver_id','jobber_user_id','fillout_display_name','data_sources','notes'];
  const result = await bulkUpsert('employees', rows, cols, 'full_name', { dryRun: DRY_RUN, batchSize: 100 });
  stats.steps.employees = { built: rows.length, ...result };
  console.log(`  ${rows.length} employees ${DRY_RUN ? 'planned' : 'upserted'}`);

  await loadIdMap('employees', 'full_name', 'employeeByName', N.normName);
  await loadIdMap('employees', 'fillout_display_name', 'employeeByFilloutName', N.normName);
  await loadIdMap('employees', 'samsara_driver_id', 'employeeBySamsaraId');
  await loadIdMap('employees', 'jobber_user_id', 'employeeByJobberId');
}

// ----------------------------------------------------------------------------
// STEP 3 — VEHICLES
// ----------------------------------------------------------------------------
async function step3_vehicles() {
  console.log('\n[STEP 3] Vehicles...');
  const rows = [];

  // Samsara vehicles (Cloggy, David, Moises)
  for (const sv of cache.samsara.vehicles) {
    rows.push({
      name: sv.name,
      make: sv.make || null,
      model: sv.model || null,
      year: N.intOrNull(sv.year),
      vin: sv.vin || null,
      license_plate: sv.licensePlate || null,
      tank_capacity_gallons: 0, // unknown from samsara — overridden by manual map below
      status: 'ACTIVE',
      gateway_serial: sv.gateway?.serial || null,
      gateway_model: sv.gateway?.model || null,
      samsara_vehicle_id: sv.id,
      data_sources: ['samsara'],
      notes: null,
    });
  }

  // Manual capacity overrides + Goliath (no Samsara)
  const MANUAL = {
    'Cloggy':  { tank_capacity_gallons: 126,  primary_use: 'Day jobs',          short_code: 'TOY' },
    'David':   { tank_capacity_gallons: 1800, primary_use: 'Night commercial',  short_code: 'INT' },
    'Moises':  { tank_capacity_gallons: 9000, primary_use: 'Large commercial',  short_code: 'KEN' },
    'Goliath': { tank_capacity_gallons: 4800, primary_use: 'Large commercial',  short_code: 'PET', samsara_vehicle_id: null, status: 'ACTIVE' },
  };
  for (const r of rows) {
    const m = MANUAL[r.name];
    if (m) Object.assign(r, m);
  }
  if (!rows.find(r => r.name === 'Goliath')) {
    rows.push({ name: 'Goliath', ...MANUAL.Goliath, data_sources: ['manual'] });
  }

  const cols = ['name','short_code','make','model','year','vin','license_plate','tank_capacity_gallons',
    'primary_use','status','gateway_serial','gateway_model','samsara_vehicle_id','data_sources','notes'];
  const result = await bulkUpsert('vehicles', rows, cols, 'name', { dryRun: DRY_RUN });
  stats.steps.vehicles = { built: rows.length, ...result };
  console.log(`  ${rows.length} vehicles ${DRY_RUN ? 'planned' : 'upserted'}`);

  await loadIdMap('vehicles', 'name', 'vehicleByName', N.normName);
  await loadIdMap('vehicles', 'samsara_vehicle_id', 'vehicleBySamsaraId');
}

// ----------------------------------------------------------------------------
// STEP 4 — PROPERTIES
// ----------------------------------------------------------------------------
async function step4_properties() {
  console.log('\n[STEP 4] Properties...');
  await loadIdMap('clients', 'jobber_client_id', 'clientByJobberId');

  const rows = [];
  for (const jp of cache.jobber.properties) {
    const clientGid = jp.client?.id || jp.clientId;
    const client_id = idMaps.clientByJobberId.get(clientGid);
    if (!client_id && !DRY_RUN) continue; // skip orphans
    rows.push({
      client_id: client_id || null,
      name: jp.name || null,
      street: jp.address?.street || null,
      city: jp.address?.city || null,
      state: jp.address?.province || 'FL',
      postal_code: jp.address?.postalCode || null,
      country: jp.address?.country || 'US',
      is_billing_address: !!jp.isBillingAddress,
      jobber_property_id: jp.id,
    });
  }

  const cols = ['client_id','name','street','city','state','postal_code','country','is_billing_address','jobber_property_id'];
  const result = await bulkUpsert('properties', rows, cols, 'jobber_property_id', { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.properties = { built: rows.length, ...result };
  console.log(`  ${rows.length} properties ${DRY_RUN ? 'planned' : 'upserted'}`);

  await loadIdMap('properties', 'jobber_property_id', 'propertyByJobberId');
}

// ----------------------------------------------------------------------------
// STEP 5 — SERVICE_CONFIGS (UNPIVOT from Airtable Clients)
// ----------------------------------------------------------------------------
async function step5_service_configs() {
  console.log('\n[STEP 5] Service configs (UNPIVOT)...');
  await loadIdMap('clients', 'airtable_record_id', 'clientByATId');

  const rows = [];
  // service_type -> { freq field, freqMultiplier(days), price field, last, next, total, projected }
  const TYPES = [
    { type: 'GT', freq: 'GT Frequency', freqMul: 30,  price: 'GT Price', last: 'GT Last Visit', next: 'GT Next Visit', total: 'GT Total per year', projected: 'GT Projected Year', dq: 'computed' },
    { type: 'CL', freq: 'CL Frequency', freqMul: 30,  price: 'CL Price', last: 'CL Last Visit', next: 'CL Next Visit', total: 'CL Total per year', projected: 'CL Projected Year', dq: 'manual' },
    { type: 'WD', freq: 'WD Frequency', freqMul: 1,   price: 'WD Price', last: 'WD Last Visit', next: 'WD Next Visit', total: 'WD Total per year', projected: 'WD Projected Year', dq: 'missing' },
    { type: 'SUMP',        freq: null, price: 'Sump Price',         dq: 'manual' },
    { type: 'GREY_WATER',  freq: null, price: 'Grey Water Price',   dq: 'manual' },
    { type: 'WARRANTY',    freq: null, price: 'Warranty Price',     dq: 'manual' },
  ];

  for (const ac of cache.airtable.clients) {
    const client_id = idMaps.clientByATId.get(ac.id);
    if (!client_id && !DRY_RUN) continue;
    for (const T of TYPES) {
      const price = N.numOrNull(N.atField(ac, T.price));
      const freqRaw = T.freq ? N.numOrNull(N.atField(ac, T.freq)) : null;
      if (price === null && freqRaw === null) continue; // skip empty
      rows.push({
        client_id: client_id || null,
        service_type: T.type,
        frequency_days: freqRaw !== null ? Math.round(freqRaw * T.freqMul) : null,
        price_per_visit: price,
        last_visit: T.last ? N.dateOnly(N.atField(ac, T.last)) : null,
        next_visit: T.next ? N.dateOnly(N.atField(ac, T.next)) : null,
        total_per_year: T.total ? N.numOrNull(N.atField(ac, T.total)) : null,
        projected_year: T.projected ? N.numOrNull(N.atField(ac, T.projected)) : null,
        status: N.atField(ac, 'Status'),
        visits_available: true,
        data_quality: T.dq,
      });
    }
  }

  const cols = ['client_id','service_type','frequency_days','price_per_visit','last_visit','next_visit',
    'total_per_year','projected_year','status','visits_available','data_quality'];
  const result = await bulkUpsert('service_configs', rows, cols, ['client_id','service_type'], { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.service_configs = { built: rows.length, ...result };
  console.log(`  ${rows.length} service_configs ${DRY_RUN ? 'planned' : 'upserted'}`);
}

// ----------------------------------------------------------------------------
// STEP 6 — QUOTES
// ----------------------------------------------------------------------------
async function step6_quotes() {
  console.log('\n[STEP 6] Quotes...');
  const rows = [];
  for (const q of cache.jobber.quotes) {
    const client_id = idMaps.clientByJobberId.get(q.client?.id);
    const property_id = q.property?.id ? idMaps.propertyByJobberId.get(q.property.id) : null;
    rows.push({
      client_id: client_id || null,
      property_id: property_id || null,
      quote_number: q.quoteNumber || null,
      title: q.title || null,
      message: q.message || null,
      subtotal: N.numOrNull(q.amounts?.subtotal),
      tax_amount: N.numOrNull(q.amounts?.taxAmount),
      total: N.numOrNull(q.amounts?.total),
      deposit_amount: N.numOrNull(q.amounts?.depositAmount),
      quote_status: q.quoteStatus || null,
      sent_at: q.sentAt || null,
      converted_to_job_at: q.jobs?.nodes?.[0]?.createdAt || null,
      jobber_quote_id: q.id,
    });
  }
  const cols = ['client_id','property_id','quote_number','title','message','subtotal','tax_amount',
    'total','deposit_amount','quote_status','sent_at','converted_to_job_at','jobber_quote_id'];
  const result = await bulkUpsert('quotes', rows, cols, 'jobber_quote_id', { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.quotes = { built: rows.length, ...result };
  console.log(`  ${rows.length} quotes ${DRY_RUN ? 'planned' : 'upserted'}`);
  await loadIdMap('quotes', 'jobber_quote_id', 'quoteByJobberId');
}

// ----------------------------------------------------------------------------
// STEP 7 — JOBS
// ----------------------------------------------------------------------------
async function step7_jobs() {
  console.log('\n[STEP 7] Jobs...');
  const rows = [];
  for (const j of cache.jobber.jobs) {
    const client_id = idMaps.clientByJobberId.get(j.client?.id);
    const property_id = j.property?.id ? idMaps.propertyByJobberId.get(j.property.id) : null;
    rows.push({
      client_id: client_id || null,
      property_id: property_id || null,
      job_number: j.jobNumber || null,
      title: j.title || null,
      instructions: j.instructions || null,
      job_type: j.jobType || null,
      billing_type: j.billingType || null,
      job_status: j.jobStatus || null,
      start_at: j.startAt || null,
      end_at: j.endAt || null,
      completed_at: j.completedAt || null,
      total: N.numOrNull(j.total),
      invoiced_total: N.numOrNull(j.invoicedTotal),
      uninvoiced_total: N.numOrNull(j.uninvoicedTotal),
      quote_id: null, // resolved in fixup pass
      jobber_quote_id: j.quote?.id || null,
      jobber_job_id: j.id,
    });
  }
  const cols = ['client_id','property_id','job_number','title','instructions','job_type','billing_type',
    'job_status','start_at','end_at','completed_at','total','invoiced_total','uninvoiced_total',
    'quote_id','jobber_quote_id','jobber_job_id'];
  const result = await bulkUpsert('jobs', rows, cols, 'jobber_job_id', { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.jobs = { built: rows.length, ...result };
  console.log(`  ${rows.length} jobs ${DRY_RUN ? 'planned' : 'upserted'}`);
  await loadIdMap('jobs', 'jobber_job_id', 'jobByJobberId');
}

// ----------------------------------------------------------------------------
// STEP 8 — INVOICES
// ----------------------------------------------------------------------------
async function step8_invoices() {
  console.log('\n[STEP 8] Invoices...');
  const rows = [];
  for (const inv of cache.jobber.invoices) {
    const client_id = idMaps.clientByJobberId.get(inv.client?.id);
    // Jobber invoices may link to multiple jobs; take first
    const jobGid = inv.jobs?.nodes?.[0]?.id || inv.job?.id;
    const job_id = jobGid ? idMaps.jobByJobberId.get(jobGid) : null;
    rows.push({
      client_id: client_id || null,
      job_id: job_id || null,
      invoice_number: inv.invoiceNumber || null,
      subject: inv.subject || null,
      message: inv.message || null,
      subtotal: N.numOrNull(inv.amounts?.subtotal),
      tax_amount: N.numOrNull(inv.amounts?.taxAmount),
      total: N.numOrNull(inv.amounts?.total),
      outstanding: N.numOrNull(inv.amounts?.invoiceBalance),
      deposit_amount: N.numOrNull(inv.amounts?.depositAmount),
      invoice_status: inv.invoiceStatus || null,
      due_date: N.dateOnly(inv.dueDate),
      sent_at: inv.sentAt || inv.issuedDate || null, // issuedDate is the Jobber "invoice date" — only sent_at-ish field in cache
      paid_at: inv.paidAt || null,
      jobber_invoice_id: inv.id,
    });
  }
  const cols = ['client_id','job_id','invoice_number','subject','message','subtotal','tax_amount','total',
    'outstanding','deposit_amount','invoice_status','due_date','sent_at','paid_at','jobber_invoice_id'];
  const result = await bulkUpsert('invoices', rows, cols, 'jobber_invoice_id', { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.invoices = { built: rows.length, ...result };
  console.log(`  ${rows.length} invoices ${DRY_RUN ? 'planned' : 'upserted'}`);
  await loadIdMap('invoices', 'jobber_invoice_id', 'invoiceByJobberId');
}

// ----------------------------------------------------------------------------
// STEP 9 — LINE ITEMS
// ----------------------------------------------------------------------------
async function step9_line_items() {
  console.log('\n[STEP 9] Line items...');
  const rows = [];
  for (const li of cache.jobber.lineItems) {
    const jGid = li._job_id || li.job?.id;
    const qGid = li._quote_id || li.quote?.id;
    const job_id = jGid ? idMaps.jobByJobberId.get(jGid) : null;
    const quote_id = qGid ? idMaps.quoteByJobberId.get(qGid) : null;
    if (!job_id && !quote_id) continue;
    rows.push({
      job_id: job_id || null,
      quote_id: quote_id || null,
      name: li.name || null,
      description: li.description || null,
      quantity: N.numOrNull(li.quantity),
      unit_price: N.numOrNull(li.unitPrice),
      total_price: N.numOrNull(li.totalPrice),
      taxable: !!li.taxable,
      jobber_line_item_id: li.id,
    });
  }
  const cols = ['job_id','quote_id','name','description','quantity','unit_price','total_price','taxable','jobber_line_item_id'];
  const result = await bulkUpsert('line_items', rows, cols, 'jobber_line_item_id', { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.line_items = { built: rows.length, ...result };
  console.log(`  ${rows.length} line_items ${DRY_RUN ? 'planned' : 'upserted'}`);
}

// ----------------------------------------------------------------------------
// STEP 10 — VISITS (Jobber + Airtable historical)
// ----------------------------------------------------------------------------
async function step10_visits() {
  console.log('\n[STEP 10] Visits...');
  const rows = [];
  const matchedATIds = new Set();

  // 10a. Jobber visits (canonical)
  for (const v of cache.jobber.visits) {
    const client_id = idMaps.clientByJobberId.get(v.client?.id);
    const job_id = v.job?.id ? idMaps.jobByJobberId.get(v.job.id) : null;
    rows.push({
      client_id: client_id || null,
      property_id: v.property?.id ? idMaps.propertyByJobberId.get(v.property.id) : null,
      job_id: job_id || null,
      vehicle_id: null,
      visit_date: N.dateOnly(v.startAt || v.endAt || v.createdAt) || '1970-01-01',
      start_at: v.startAt || null,
      end_at: v.endAt || null,
      completed_at: v.completedAt || null,
      duration_minutes: v.durationMinutes ? Math.round(v.durationMinutes) : null,
      title: v.title || null,
      instructions: v.instructions || null,
      visit_status: v.visitStatus || null,
      is_complete: !!v.completedAt,
      amount: null,
      truck: null,
      zone: null,
      completed_by: null,
      invoice_id: null,
      jobber_invoice_id: v.invoice?.id || null,
      airtable_record_id: null,
      jobber_visit_id: v.id,
      data_sources: ['jobber'],
      source: 'jobber',
    });
  }

  // 10b. SKIPPED — Viktor verified AT visits are parallel duplicates of Jobber, not historical.
  // AT visits date range starts 2025-04-11, Jobber goes back to 2023-11-07. Loading them creates phantoms.
  // Operational data (manifest #s, dump tickets) already lives in derm_manifests step 14.

  const cols = ['client_id','property_id','job_id','vehicle_id','visit_date','start_at','end_at',
    'completed_at','duration_minutes','title','instructions','service_type','visit_status','is_complete',
    'amount','truck','zone','completed_by','invoice_id','jobber_invoice_id','airtable_record_id',
    'jobber_visit_id','data_sources','source'];

  const r1 = await bulkUpsert('visits', rows, cols, 'jobber_visit_id', { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.visits = { jobber: rows.length, batches: r1.batches };
  console.log(`  ${rows.length} jobber visits ${DRY_RUN ? 'planned' : 'upserted'}`);

  await loadIdMap('visits', 'jobber_visit_id', 'visitByJobberId');
  await loadIdMap('visits', 'airtable_record_id', 'visitByATId');
}

// ----------------------------------------------------------------------------
// STEP 11 — VISIT_ASSIGNMENTS
// ----------------------------------------------------------------------------
async function step11_visit_assignments() {
  console.log('\n[STEP 11] Visit assignments...');
  const rows = [];
  for (const v of cache.jobber.visits) {
    const visit_id = idMaps.visitByJobberId.get(v.id);
    if (!visit_id && !DRY_RUN) continue;
    const assigned = v.assignedUsers?.nodes || [];
    for (const u of assigned) {
      const employee_id = idMaps.employeeByJobberId.get(u.id);
      if (!employee_id && !DRY_RUN) continue;
      rows.push({ visit_id: visit_id || 0, employee_id: employee_id || 0 });
    }
  }
  const cols = ['visit_id','employee_id'];
  const result = await bulkUpsert('visit_assignments', rows, cols, ['visit_id','employee_id'], { dryRun: DRY_RUN, batchSize: 500 });
  stats.steps.visit_assignments = { built: rows.length, ...result };
  console.log(`  ${rows.length} visit_assignments ${DRY_RUN ? 'planned' : 'upserted'}`);
}

// ----------------------------------------------------------------------------
// STEP 12 — INSPECTIONS (Fillout pre + post)
// ----------------------------------------------------------------------------
function getFilloutAnswer(submission, label) {
  const qs = submission.questions || [];
  const q = qs.find(x => x.name && x.name.toLowerCase().includes(label.toLowerCase()));
  return q ? q.value : null;
}

async function step12_inspections() {
  console.log('\n[STEP 12] Inspections...');
  const rows = [];

  const buildRow = (sub, type) => {
    const truckText = N.stripTruckSuffix(getFilloutAnswer(sub, 'truck') || '');
    const driverText = getFilloutAnswer(sub, 'driver') || getFilloutAnswer(sub, 'name') || '';
    const vehicle_id = idMaps.vehicleByName.get(N.normName(truckText)) || null;
    const employee_id = idMaps.employeeByFilloutName.get(N.normName(driverText)) || idMaps.employeeByName.get(N.normName(driverText)) || null;
    return {
      vehicle_id,
      employee_id,
      shift_date: N.dateOnly(sub.submissionTime || sub.lastUpdatedAt),
      inspection_type: type,
      submitted_at: sub.submissionTime || sub.lastUpdatedAt || null,
      sludge_gallons: N.intOrNull(getFilloutAnswer(sub, 'sludge')),
      water_gallons: type === 'POST' ? N.intOrNull(getFilloutAnswer(sub, 'water')) : null,
      gas_level: getFilloutAnswer(sub, 'gas'),
      valve_is_closed: getFilloutAnswer(sub, 'valve') === 'Yes',
      has_issue: !!getFilloutAnswer(sub, 'issue'),
      issue_note: getFilloutAnswer(sub, 'issue note'),
      has_expense: type === 'POST' ? !!getFilloutAnswer(sub, 'expense') : false,
      expense_note: type === 'POST' ? getFilloutAnswer(sub, 'expense note') : null,
      expense_amount: null, // not in fillout, comes from Ramp
      fillout_submission_id: sub.submissionId,
      data_sources: ['fillout'],
    };
  };

  for (const s of cache.fillout.pre) rows.push(buildRow(s, 'PRE'));
  for (const s of cache.fillout.post) rows.push(buildRow(s, 'POST'));

  // Dedupe by composite shift key (shift_date, vehicle_id, employee_id, inspection_type)
  // Keep latest submission_at
  const dedupeMap = new Map();
  for (const r of rows) {
    const key = `${r.shift_date}|${r.vehicle_id}|${r.employee_id}|${r.inspection_type}`;
    const existing = dedupeMap.get(key);
    if (!existing || (r.submitted_at && r.submitted_at > existing.submitted_at)) {
      dedupeMap.set(key, r);
    }
  }
  rows.length = 0;
  rows.push(...dedupeMap.values());

  const cols = ['vehicle_id','employee_id','shift_date','inspection_type','submitted_at','sludge_gallons',
    'water_gallons','gas_level','valve_is_closed','has_issue','issue_note','has_expense','expense_note',
    'expense_amount','fillout_submission_id','data_sources'];
  const result = await bulkUpsert('inspections', rows, cols, 'fillout_submission_id', { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.inspections = { built: rows.length, ...result };
  console.log(`  ${rows.length} inspections ${DRY_RUN ? 'planned' : 'upserted'}`);
}

// ----------------------------------------------------------------------------
// STEP 13 — EXPENSES (placeholder from Fillout post; Ramp pipeline TBD)
// ----------------------------------------------------------------------------
async function step13_expenses() {
  console.log('\n[STEP 13] Expenses (Fillout-derived stubs)...');
  const rows = [];
  for (const s of cache.fillout.post) {
    if (!getFilloutAnswer(s, 'expense')) continue;
    const truckText = N.stripTruckSuffix(getFilloutAnswer(s, 'truck') || '');
    const driverText = getFilloutAnswer(s, 'driver') || getFilloutAnswer(s, 'name') || '';
    rows.push({
      expense_date: N.dateOnly(s.submissionTime),
      amount: null, // unknown — Ramp pipeline
      description: getFilloutAnswer(s, 'expense note'),
      category: 'Other',
      vehicle_id: idMaps.vehicleByName.get(N.normName(truckText)) || null,
      employee_id: idMaps.employeeByFilloutName.get(N.normName(driverText)) || null,
      fillout_submission_id: s.submissionId + '_exp',
      data_sources: ['fillout'],
    });
  }
  const cols = ['expense_date','amount','description','category','vehicle_id','employee_id','fillout_submission_id','data_sources'];
  const result = await bulkUpsert('expenses', rows, cols, 'fillout_submission_id', { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.expenses = { built: rows.length, ...result };
  console.log(`  ${rows.length} expenses ${DRY_RUN ? 'planned' : 'upserted'}`);
}

// ----------------------------------------------------------------------------
// STEP 14 — DERM MANIFESTS
// ----------------------------------------------------------------------------
async function step14_derm_manifests() {
  console.log('\n[STEP 14] DERM manifests...');
  const rows = [];
  for (const m of cache.airtable.derm) {
    const clientATIds = N.atField(m, 'Client') || N.atField(m, 'Clients') || [];
    const firstClientATId = Array.isArray(clientATIds) ? clientATIds[0] : null;
    const client_id = firstClientATId ? idMaps.clientByATId.get(firstClientATId) : null;
    rows.push({
      client_id: client_id || null,
      service_date: N.dateOnly(N.atField(m, 'GT Last Visit') || N.atField(m, 'Date Dump Ticket')),
      dump_ticket_date: N.dateOnly(N.atField(m, 'Date Dump Ticket')),
      white_manifest_num: N.atField(m, 'White Manifest #'),
      yellow_ticket_num: N.atField(m, 'Yellow Ticket #'),
      sent_to_client: !!N.atField(m, 'Sent to Client'),
      sent_to_city: !!N.atField(m, 'Sent to City'),
      service_address: N.atField(m, 'Service Address'),
      service_city: N.atField(m, 'Service City'),
      service_zip: N.atField(m, 'Service Zip'),
      service_county: N.atField(m, 'County'),
      airtable_record_id: m.id,
    });
  }
  const cols = ['client_id','service_date','dump_ticket_date','white_manifest_num','yellow_ticket_num',
    'sent_to_client','sent_to_city','service_address','service_city','service_zip','service_county','airtable_record_id'];
  const result = await bulkUpsert('derm_manifests', rows, cols, 'airtable_record_id', { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.derm_manifests = { built: rows.length, ...result };
  console.log(`  ${rows.length} manifests ${DRY_RUN ? 'planned' : 'upserted'}`);
  await loadIdMap('derm_manifests', 'airtable_record_id', 'manifestByATId');
}

// ----------------------------------------------------------------------------
// STEP 15 — MANIFEST_VISITS (UNNEST)
// ----------------------------------------------------------------------------
async function step15_manifest_visits() {
  console.log('\n[STEP 15] Manifest-visit links (via client+date match to Jobber visits)...');
  if (DRY_RUN) { console.log('  skipped (dry-run)'); return; }
  // Build (client_id, visit_date) -> visit_id index from loaded Jobber visits
  const r = await newQuery(`SELECT id, client_id, visit_date FROM visits WHERE client_id IS NOT NULL AND visit_date IS NOT NULL;`);
  const visitIdx = new Map();
  for (const row of r) {
    const k = `${row.client_id}|${row.visit_date}`;
    if (!visitIdx.has(k)) visitIdx.set(k, []);
    visitIdx.get(k).push(row.id);
  }

  const manRows = await newQuery(`SELECT id, client_id, service_date FROM derm_manifests WHERE client_id IS NOT NULL AND service_date IS NOT NULL;`);
  const rows = [];
  let matched = 0;
  const shiftDate = (d, days) => { const dt = new Date(d); dt.setUTCDate(dt.getUTCDate() + days); return dt.toISOString().slice(0,10); };
  for (const m of manRows) {
    const sd = typeof m.service_date === 'string' ? m.service_date.slice(0,10) : new Date(m.service_date).toISOString().slice(0,10);
    let cands = null;
    for (const off of [0, -1, 1]) {
      const k = `${m.client_id}|${shiftDate(sd, off)}`;
      cands = visitIdx.get(k);
      if (cands) break;
    }
    if (!cands) continue;
    for (const vid of cands) rows.push({ manifest_id: m.id, visit_id: vid });
    matched++;
  }
  const cols = ['manifest_id','visit_id'];
  const result = await bulkUpsert('manifest_visits', rows, cols, ['manifest_id','visit_id'], { dryRun: DRY_RUN, batchSize: 500 });
  stats.steps.manifest_visits = { built: rows.length, matched_manifests: matched, ...result };
  console.log(`  ${rows.length} manifest_visits from ${matched}/${manRows.length} manifests`);
}

// ----------------------------------------------------------------------------
// STEP 16 — ROUTES
// ----------------------------------------------------------------------------
async function step16_routes() {
  console.log('\n[STEP 16] Routes...');
  const rows = [];
  for (const r of cache.airtable.routeCreation) {
    const clientATIds = N.atField(r, 'Client') || [];
    const firstATId = Array.isArray(clientATIds) ? clientATIds[0] : null;
    const client_id = firstATId ? idMaps.clientByATId.get(firstATId) : null;
    rows.push({
      client_id: client_id || null,
      gt_wanted_date: N.dateOnly(N.atField(r, 'GT Wanted Date')),
      cl_wanted_date: N.dateOnly(N.atField(r, 'CL Wanted Date')),
      status: N.atField(r, 'Status'),
      assignee: N.atField(r, 'Assignee'),
      zone: N.atField(r, 'Zone'),
      airtable_record_id: r.id,
    });
  }
  const cols = ['client_id','gt_wanted_date','cl_wanted_date','status','assignee','zone','airtable_record_id'];
  const result = await bulkUpsert('routes', rows, cols, 'airtable_record_id', { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.routes = { built: rows.length, ...result };
  console.log(`  ${rows.length} routes ${DRY_RUN ? 'planned' : 'upserted'}`);
}

// ----------------------------------------------------------------------------
// STEP 17 — RECEIVABLES
// ----------------------------------------------------------------------------
async function step17_receivables() {
  console.log('\n[STEP 17] Receivables...');
  const rows = [];
  for (const r of cache.airtable.pastDue) {
    const clientATIds = N.atField(r, 'Client') || [];
    const firstATId = Array.isArray(clientATIds) ? clientATIds[0] : null;
    const client_id = firstATId ? idMaps.clientByATId.get(firstATId) : null;
    rows.push({
      client_id: client_id || null,
      amount_due: N.numOrNull(N.atField(r, 'Amount Due') || N.atField(r, 'Balance')),
      status: N.atField(r, 'Status') || 'Open',
      assignee: N.atField(r, 'Assignee'),
      note: N.atField(r, 'Note') || N.atField(r, 'Notes'),
      airtable_record_id: r.id,
    });
  }
  const cols = ['client_id','amount_due','status','assignee','note','airtable_record_id'];
  const result = await bulkUpsert('receivables', rows, cols, 'airtable_record_id', { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.receivables = { built: rows.length, ...result };
  console.log(`  ${rows.length} receivables ${DRY_RUN ? 'planned' : 'upserted'}`);
}

// ----------------------------------------------------------------------------
// STEP 18 — LEADS
// ----------------------------------------------------------------------------
async function step18_leads() {
  console.log('\n[STEP 18] Leads...');
  const rows = [];
  for (const l of cache.airtable.leads) {
    const biz = N.atField(l, 'business_name') || N.atField(l, 'Business Name');
    if (!biz) continue; // skip stub rows
    rows.push({
      contact_name: N.atField(l, 'op_name') || N.atField(l, 'nick_name') || biz,
      company_name: biz,
      phone: N.atField(l, 'Phone'),
      email: N.atField(l, 'Email'),
      address: N.atField(l, 'Address'),
      city: N.atField(l, 'City'),
      state: N.atField(l, 'State') || 'FL',
      zip: N.atField(l, 'Zip'),
      lead_source: N.atField(l, 'Source') || 'other',
      lead_status: N.atField(l, 'Status') || 'new',
      assigned_to: N.atField(l, 'Assignee'),
      notes: N.atField(l, 'Notes'),
    });
  }
  // dedupe by contact_name
  const seen = new Map();
  for (const r of rows) seen.set(r.contact_name, r);
  rows.length = 0; rows.push(...seen.values());

  const cols = ['contact_name','company_name','phone','email','address','city','state','zip',
    'lead_source','lead_status','assigned_to','notes'];
  const result = await bulkUpsert('leads', rows, cols, 'contact_name', { dryRun: DRY_RUN, batchSize: 100 });
  stats.steps.leads = { built: rows.length, ...result };
  console.log(`  ${rows.length} leads ${DRY_RUN ? 'planned' : 'upserted'}`);
}

// ----------------------------------------------------------------------------
// FIXUP PASSES
// ----------------------------------------------------------------------------
async function fixupPasses() {
  if (DRY_RUN) { console.log('\n[FIXUP] skipped (dry-run)'); return; }
  console.log('\n[FIXUP] Running post-population FK resolution...');

  console.log('  Pass 1: visits.invoice_id ← invoices');
  await newQuery(`UPDATE visits SET invoice_id = i.id FROM invoices i
    WHERE i.jobber_invoice_id = visits.jobber_invoice_id AND visits.invoice_id IS NULL;`);

  console.log('  Pass 2: jobs.quote_id ← quotes');
  await newQuery(`UPDATE jobs SET quote_id = q.id FROM quotes q
    WHERE q.jobber_quote_id = jobs.jobber_quote_id AND jobs.quote_id IS NULL;`);

  console.log('  Pass 3: visits.vehicle_id ← vehicles (truck name)');
  await newQuery(`UPDATE visits SET vehicle_id = v.id FROM vehicles v
    WHERE lower(trim(visits.truck)) = lower(trim(v.name)) AND visits.vehicle_id IS NULL;`);

  console.log('  Pass 4: inspections already FK-resolved at insert (skip)');

  console.log('  Pass 5: visit_assignments from completed_by');
  await newQuery(`INSERT INTO visit_assignments (visit_id, employee_id)
    SELECT v.id, e.id FROM visits v JOIN employees e
      ON lower(trim(v.completed_by)) = lower(trim(e.full_name))
    WHERE v.airtable_record_id IS NOT NULL AND v.jobber_visit_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id = v.id)
    ON CONFLICT DO NOTHING;`);
}

// ----------------------------------------------------------------------------
// MAIN
// ----------------------------------------------------------------------------
(async () => {
  try {
    await phase1_pull();

    if (TRUNCATE && !DRY_RUN) {
      console.log('\n[TRUNCATE] Wiping all 20 tables...');
      const order = [
        'manifest_visits','visit_assignments','line_items','expenses','inspections',
        'visits','invoices','quotes','jobs','service_configs','derm_manifests',
        'routes','receivables','leads','source_map','properties','employees',
        'vehicles','clients'
      ];
      for (const t of order) {
        await newQuery(`TRUNCATE TABLE ${t} RESTART IDENTITY CASCADE;`);
        console.log(`  truncated ${t}`);
      }
    }

    if (!ONLY_STEP || ONLY_STEP === 1) await step1_clients();
    if (!ONLY_STEP || ONLY_STEP === 2) await step2_employees();
    if (!ONLY_STEP || ONLY_STEP === 3) await step3_vehicles();
    if (!ONLY_STEP || ONLY_STEP === 4) await step4_properties();
    if (!ONLY_STEP || ONLY_STEP === 5) await step5_service_configs();
    if (!ONLY_STEP || ONLY_STEP === 6) await step6_quotes();
    if (!ONLY_STEP || ONLY_STEP === 7) await step7_jobs();
    if (!ONLY_STEP || ONLY_STEP === 8) await step8_invoices();
    if (!ONLY_STEP || ONLY_STEP === 9) await step9_line_items();
    if (!ONLY_STEP || ONLY_STEP === 10) await step10_visits();
    if (!ONLY_STEP || ONLY_STEP === 11) await step11_visit_assignments();
    if (!ONLY_STEP || ONLY_STEP === 12) await step12_inspections();
    if (!ONLY_STEP || ONLY_STEP === 13) await step13_expenses();
    if (!ONLY_STEP || ONLY_STEP === 14) await step14_derm_manifests();
    if (!ONLY_STEP || ONLY_STEP === 15) await step15_manifest_visits();
    if (!ONLY_STEP || ONLY_STEP === 16) await step16_routes();
    if (!ONLY_STEP || ONLY_STEP === 17) await step17_receivables();
    if (!ONLY_STEP || ONLY_STEP === 18) await step18_leads();
    if (!ONLY_STEP) await fixupPasses();

    console.log('\n' + '='.repeat(70));
    console.log('SUMMARY');
    console.log('='.repeat(70));
    console.log(JSON.stringify(stats, null, 2));

    const reportPath = path.resolve(__dirname, 'populate_report.json');
    fs.writeFileSync(reportPath, JSON.stringify({ ...stats, finished_at: new Date(), mode: DRY_RUN ? 'dry-run' : 'execute' }, null, 2));
    console.log(`\nReport written: ${reportPath}`);
  } catch (err) {
    console.error('\nFATAL:', err);
    stats.errors.push(err.message);
    process.exit(1);
  }
})();
