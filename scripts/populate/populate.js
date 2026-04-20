// ============================================================================
// populate.js — v2 schema population orchestrator
// ============================================================================
//
// v2 CHANGES from v1:
//   - All source FK columns (jobber_client_id, airtable_record_id, etc.)
//     removed from business tables → entity_source_links
//   - clients trimmed to 5 business cols → contacts in client_contacts,
//     address/GPS in properties (is_primary=true), GDO in service_configs
//   - employees/vehicles/inspections trimmed — source IDs in entity_source_links
//   - inspection photos → inspection_photos table
//   - Uses INSERT RETURNING id + linkEntities() pattern
//
// Reads:
//   * Jobber JSONB cache from raw.jobber_pull_* (same Supabase project)
//   * Live Airtable, Samsara, Fillout via direct APIs
//
// Writes:
//   * Idempotent population into v2 schema (24 tables + entity_source_links)
//
// Modes:
//   --dry-run   : default. Prints what would be inserted, no writes.
//   --execute   : actually performs writes. Requires --confirm flag too.
//   --truncate  : TRUNCATE all tables before populate (clean slate)
//   --step <N>  : run only step N (1-18). Useful for partial re-runs.
//
// Dependency order (FK constraints):
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
// ============================================================================

const path = require('path');
const fs = require('fs');
const { newQuery, oldQuery, bulkUpsert, bulkInsertReturning, fetchJsonbCache, sqlEscape } = require('./lib/db');
const { linkEntities, buildLookupMap } = require('./lib/sourceLinks');
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
console.log('populate.js — UNCLOGME v2 schema');
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
  maps: {
    jobberClientById: new Map(),
    airtableClientByJobberId: new Map(),
    samsaraAddressByName: new Map(),
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

  console.log('  -> Jobber JSONB cache...');
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
    const atName = N.atField(ac, 'Client Name') || N.atField(ac, 'CLIENT XX') || '';
    const key = N.normName(atName);
    let jc = jobberByNormName.get(key);
    if (!jc) {
      const candidates = [...jobberByNormName.values()];
      const m = N.bestFuzzyMatch(atName, candidates, x => stripJobberPrefix(x.companyName || x.name), 0.85);
      if (m) jc = m.match;
    }
    if (jc) { cache.maps.airtableClientByJobberId.set(jc.id, ac); nameLinked++; }
  });
  console.log(`  AT->Jobber name-linked: ${nameLinked}`);
  cache.samsara.addresses.forEach(sa => {
    cache.maps.samsaraAddressByName.set(N.normName(sa.name), sa);
  });

  console.log(`  Maps built: jobberClientById=${cache.maps.jobberClientById.size} airtableByJobberId=${cache.maps.airtableClientByJobberId.size} samsaraByName=${cache.maps.samsaraAddressByName.size}`);
}

// ----------------------------------------------------------------------------
// ID MAP HELPERS — v2: source system IDs via entity_source_links
// ----------------------------------------------------------------------------
const idMaps = {
  clientByJobberId: new Map(),
  clientByATId: new Map(),
  propertyByJobberId: new Map(),
  jobByJobberId: new Map(),
  invoiceByJobberId: new Map(),
  quoteByJobberId: new Map(),
  vehicleByName: new Map(),
  employeeByName: new Map(),
  employeeByFilloutName: new Map(),
  employeeByJobberId: new Map(),
  visitByJobberId: new Map(),
  visitByATId: new Map(),
  manifestByATId: new Map(),
};

// Load source→entity map from entity_source_links
async function loadSourceMap(entityType, sourceSystem, mapKey, normalizer = (x) => x) {
  if (DRY_RUN) return;
  const map = await buildLookupMap(entityType, sourceSystem);
  const target = idMaps[mapKey];
  target.clear();
  for (const [sourceId, entityId] of map) {
    target.set(normalizer(String(sourceId)), entityId);
  }
}

// Load name→id map directly from business table column
async function loadNameMap(table, keyCol, mapKey, normalizer = (x) => x) {
  if (DRY_RUN) return;
  const r = await newQuery(`SELECT id, ${keyCol} FROM ${table} WHERE ${keyCol} IS NOT NULL;`);
  const m = idMaps[mapKey];
  m.clear();
  for (const row of r) m.set(normalizer(row[keyCol]), row.id);
}

// ----------------------------------------------------------------------------
// STEP 1 — CLIENTS
// v2: clients has only (client_code, name, status, balance, notes)
// Contacts → client_contacts, Address/GPS → properties, GDO → service_configs
// Source FKs → entity_source_links
// ----------------------------------------------------------------------------
async function step1_clients() {
  console.log('\n[STEP 1] Clients merge...');
  const rows = [];

  // 1a. Every Jobber client -> canonical row (Jobber wins)
  for (const jc of cache.jobber.clients) {
    const ac = cache.maps.airtableClientByJobberId.get(jc.id);
    const sa = cache.maps.samsaraAddressByName.get(N.normName(jc.companyName || jc.name));

    rows.push({
      // -- v2 business columns --
      client_code: ac ? N.atField(ac, 'Client Code #3') : null,
      name: jc.companyName || jc.name || `${jc.firstName || ''} ${jc.lastName || ''}`.trim() || 'UNKNOWN',
      status: jc.isArchived ? 'INACTIVE' : (ac && N.atField(ac, 'ACTIVE/INACTIVE')) || 'ACTIVE',
      balance: N.numOrNull(jc.balance),
      notes: null,
      // -- metadata for entity_source_links (not written to clients table) --
      _jobber_id: jc.id,
      _airtable_id: ac?.id || null,
      _samsara_id: sa?.id || null,
      _match_method: ac ? 'jobber_id_link' : (sa ? 'name_fuzzy' : 'jobber_only'),
      _match_confidence: ac ? 1.0 : (sa ? 0.85 : 1.0),
      // -- metadata for client_contacts --
      _contacts: buildContactsFromSources(jc, ac),
      // -- metadata for primary property (address/GPS enrichment) --
      _primary_property: buildPrimaryProperty(jc, ac, sa),
    });
  }

  // 1b. Airtable clients with NO Jobber match -> historical rows
  const matchedATIds = new Set(rows.map(r => r._airtable_id).filter(Boolean));
  for (const ac of cache.airtable.clients) {
    if (matchedATIds.has(ac.id)) continue;
    rows.push({
      client_code: N.atField(ac, 'Client Code #3'),
      name: N.atField(ac, 'Client Name') || 'UNKNOWN_AT',
      status: N.atField(ac, 'ACTIVE/INACTIVE') || 'INACTIVE',
      balance: null,
      notes: 'Historical Airtable client, no Jobber link',
      _jobber_id: null,
      _airtable_id: ac.id,
      _samsara_id: null,
      _match_method: 'airtable_only',
      _match_confidence: 1.0,
      _contacts: buildContactsFromSources(null, ac),
      _primary_property: buildPrimaryProperty(null, ac, null),
    });
  }

  console.log(`  Built ${rows.length} canonical client rows`);

  // INSERT into clients (v2 columns only)
  const cols = ['client_code', 'name', 'status', 'balance', 'notes'];
  const ids = await bulkInsertReturning('clients', rows, cols, { dryRun: DRY_RUN, batchSize: 100 });
  stats.steps.clients = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} clients ${DRY_RUN ? 'planned' : 'inserted'}`);

  // Write entity_source_links
  const links = [];
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i], eid = ids[i];
    if (r._jobber_id) links.push({ entity_type: 'client', entity_id: eid, source_system: 'jobber', source_id: r._jobber_id, source_name: r.name, match_method: r._match_method, match_confidence: r._match_confidence });
    if (r._airtable_id) links.push({ entity_type: 'client', entity_id: eid, source_system: 'airtable', source_id: r._airtable_id, source_name: r.name, match_method: r._match_method, match_confidence: r._match_confidence });
    if (r._samsara_id) links.push({ entity_type: 'client', entity_id: eid, source_system: 'samsara', source_id: r._samsara_id, source_name: r.name, match_method: 'name_fuzzy', match_confidence: 0.85 });
  }
  await linkEntities(links, { dryRun: DRY_RUN });
  console.log(`  ${links.length} entity_source_links written`);

  // Write client_contacts
  const contactRows = [];
  for (let i = 0; i < rows.length; i++) {
    const eid = ids[i];
    for (const ct of rows[i]._contacts) {
      if (ct.email || ct.phone || ct.name) {
        contactRows.push({ client_id: eid, contact_role: ct.role, name: ct.name || null, email: ct.email || null, phone: ct.phone || null });
      }
    }
  }
  if (contactRows.length) {
    const ctCols = ['client_id', 'contact_role', 'name', 'email', 'phone'];
    await bulkInsertReturning('client_contacts', contactRows, ctCols, { dryRun: DRY_RUN, batchSize: 500 });
    console.log(`  ${contactRows.length} client_contacts written`);
  }

  // Store row→id mapping for primary property creation in step 4
  // and for downstream steps that need client lookups
  cache._clientRows = rows;
  cache._clientIds = ids;
}

// Build contacts array from Jobber + Airtable data
function buildContactsFromSources(jc, ac) {
  const contacts = [];
  // Primary contact (from Jobber or Airtable operation fields)
  const primaryEmail = jc?.emails?.[0]?.address || (ac && N.atField(ac, 'Operation Email'));
  const primaryPhone = jc?.phones?.[0]?.number || (ac && N.atField(ac, 'Operation Phone'));
  const primaryName = ac ? N.atField(ac, 'OP Name') : null;
  if (primaryEmail || primaryPhone) {
    contacts.push({ role: 'primary', name: primaryName, email: primaryEmail, phone: primaryPhone });
  }
  // Accounting contact
  if (ac) {
    const acctEmail = N.atField(ac, 'Acounting Email');
    const acctPhone = N.atField(ac, 'Acounting Phone');
    const acctName = N.atField(ac, 'Acct Name');
    if (acctEmail || acctPhone) {
      contacts.push({ role: 'accounting', name: acctName, email: acctEmail, phone: acctPhone });
    }
  }
  // City/DERM contact
  if (ac) {
    const cityEmail = N.atField(ac, 'City Email');
    if (cityEmail) {
      contacts.push({ role: 'city', name: null, email: cityEmail, phone: null });
    }
  }
  return contacts;
}

// Build primary property data from client address fields (for step 4 enrichment)
function buildPrimaryProperty(jc, ac, sa) {
  const address = jc?.billingAddress?.street || (ac && N.atField(ac, 'Address'));
  if (!address) return null;
  return {
    address,
    city: jc?.billingAddress?.city || (ac && N.atField(ac, 'City')),
    state: jc?.billingAddress?.province || (ac && N.atField(ac, 'State')) || 'FL',
    zip: jc?.billingAddress?.postalCode || (ac && N.atField(ac, 'Zip Code')),
    county: ac ? N.atField(ac, 'County') : null,
    zone: ac ? N.atField(ac, 'Zone') : null,
    latitude: sa?.latitude || null,
    longitude: sa?.longitude || null,
    geofence_radius_meters: sa?.geofence?.circle?.radiusMeters || null,
    geofence_type: sa?.geofence?.circle ? 'circle' : (sa?.geofence?.polygon ? 'polygon' : null),
    access_hours_start: ac ? N.atField(ac, 'Hours in') : null,
    access_hours_end: ac ? N.atField(ac, 'Hours out') : null,
    access_days: ac ? N.atField(ac, 'Days of the week') : null,
    // location_photo_url dropped 2026-04-20 — the Airtable source was a
    // Yes/No checkbox, not a URL. Location photos now live in photos +
    // photo_links (entity_type='property', role='overview') per ADR 009.
    is_billing: true,
  };
}

// ----------------------------------------------------------------------------
// STEP 2 — EMPLOYEES
// v2: (full_name, role, status, shift, email, phone, hire_date, notes)
// Source FKs → entity_source_links
// ----------------------------------------------------------------------------
async function step2_employees() {
  console.log('\n[STEP 2] Employees merge...');
  const rows = [];
  const seen = new Set();
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
      shift: N.atField(ad, 'Shift'),
      phone: N.atField(ad, 'Phone'),
      email: N.atField(ad, 'Email'),
      hire_date: N.dateOnly(N.atField(ad, 'Hire Date')),
      access_level: OFFICE_NAMES.has(key) ? 'office' : 'field',
      notes: null,
      _airtable_id: ad.id,
      _samsara_id: null,
      _jobber_id: null,
      _fillout_name: fullName,
    });
  }

  // 2b. Samsara drivers — fuzzy match to existing
  for (const sd of cache.samsara.drivers) {
    const key = N.normName(sd.name);
    const existing = rows.find(r => N.normName(r.full_name) === key || N.similarity(r.full_name, sd.name) >= 0.9);
    if (existing) {
      existing._samsara_id = sd.id;
      continue;
    }
    seen.add(key);
    rows.push({
      full_name: sd.name,
      role: 'Technician',
      status: sd.driverActivationStatus === 'active' ? 'ACTIVE' : 'INACTIVE',
      shift: null,
      phone: sd.phone || null,
      email: sd.username || null,
      hire_date: null,
      access_level: OFFICE_NAMES.has(key) ? 'office' : 'field',
      notes: null,
      _airtable_id: null,
      _samsara_id: sd.id,
      _jobber_id: null,
      _fillout_name: sd.name,
    });
  }

  // 2c. Jobber users — match into existing or add as office/admin
  for (const ju of cache.jobber.users) {
    const fname = ju.name?.full || `${ju.name?.first || ''} ${ju.name?.last || ''}`.trim();
    if (!fname) continue;
    const key = N.normName(fname);
    const existing = rows.find(r => N.normName(r.full_name) === key || N.similarity(r.full_name, fname) >= 0.9);
    if (existing) {
      existing._jobber_id = ju.id;
      continue;
    }
    rows.push({
      full_name: fname,
      role: ju.isAccountOwner ? 'Owner' : (ju.isAccountAdmin ? 'Admin' : 'Office'),
      status: 'ACTIVE',
      shift: null,
      phone: null,
      email: ju.email?.address || null,
      hire_date: null,
      access_level: ju.isAccountOwner || ju.isAccountAdmin ? 'dev' : 'office',
      notes: null,
      _airtable_id: null,
      _samsara_id: null,
      _jobber_id: ju.id,
      _fillout_name: fname,
    });
  }

  const cols = ['full_name', 'role', 'status', 'shift', 'phone', 'email', 'hire_date', 'access_level', 'notes'];
  const ids = await bulkInsertReturning('employees', rows, cols, { dryRun: DRY_RUN, batchSize: 100 });
  stats.steps.employees = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} employees ${DRY_RUN ? 'planned' : 'inserted'}`);

  // entity_source_links
  const links = [];
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i], eid = ids[i];
    if (r._airtable_id) links.push({ entity_type: 'employee', entity_id: eid, source_system: 'airtable', source_id: r._airtable_id, source_name: r.full_name });
    if (r._samsara_id) links.push({ entity_type: 'employee', entity_id: eid, source_system: 'samsara', source_id: r._samsara_id, source_name: r.full_name });
    if (r._jobber_id) links.push({ entity_type: 'employee', entity_id: eid, source_system: 'jobber', source_id: r._jobber_id, source_name: r.full_name });
    // Store fillout display name as a source link for inspection matching
    if (r._fillout_name) links.push({ entity_type: 'employee', entity_id: eid, source_system: 'fillout', source_id: r._fillout_name, source_name: r.full_name, match_method: 'display_name' });
  }
  await linkEntities(links, { dryRun: DRY_RUN });
  console.log(`  ${links.length} entity_source_links written`);

  // Load maps for downstream steps
  await loadNameMap('employees', 'full_name', 'employeeByName', N.normName);
  await loadSourceMap('employee', 'fillout', 'employeeByFilloutName', N.normName);
  await loadSourceMap('employee', 'jobber', 'employeeByJobberId');
}

// ----------------------------------------------------------------------------
// STEP 3 — VEHICLES
// v2: (name, make, model, year, vin, license_plate, grease_tank_capacity_gallons, fuel_tank_capacity_gallons, status, notes)
// Grease tank = waste/vacuum tank for collected grease (drives route capacity).
// Fuel tank   = diesel/gas tank (Samsara fuelPercent reports on this). Separate quantities.
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
      grease_tank_capacity_gallons: 0,
      fuel_tank_capacity_gallons: null,
      status: 'ACTIVE',
      notes: null,
      _samsara_id: sv.id,
    });
  }

  // Manual capacity overrides + Goliath (no Samsara). Goliath is inactive.
  const MANUAL = {
    'Cloggy':  { grease_tank_capacity_gallons: 126,  fuel_tank_capacity_gallons: 26 },
    'David':   { grease_tank_capacity_gallons: 1800, fuel_tank_capacity_gallons: 66 },
    'Moises':  { grease_tank_capacity_gallons: 9000, fuel_tank_capacity_gallons: 90 },
    'Goliath': { grease_tank_capacity_gallons: 4800, fuel_tank_capacity_gallons: null, _samsara_id: null, status: 'INACTIVE' },
  };
  for (const r of rows) {
    const m = MANUAL[r.name];
    if (m) Object.assign(r, m);
  }
  if (!rows.find(r => r.name === 'Goliath')) {
    rows.push({ name: 'Goliath', make: null, model: null, year: null, vin: null, license_plate: null, ...MANUAL.Goliath, notes: null });
  }

  const cols = ['name', 'make', 'model', 'year', 'vin', 'license_plate', 'grease_tank_capacity_gallons', 'fuel_tank_capacity_gallons', 'status', 'notes'];
  const ids = await bulkInsertReturning('vehicles', rows, cols, { dryRun: DRY_RUN });
  stats.steps.vehicles = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} vehicles ${DRY_RUN ? 'planned' : 'inserted'}`);

  // entity_source_links
  const links = [];
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i], eid = ids[i];
    if (r._samsara_id) links.push({ entity_type: 'vehicle', entity_id: eid, source_system: 'samsara', source_id: r._samsara_id, source_name: r.name });
    else links.push({ entity_type: 'vehicle', entity_id: eid, source_system: 'manual', source_id: r.name, source_name: r.name });
  }
  await linkEntities(links, { dryRun: DRY_RUN });

  await loadNameMap('vehicles', 'name', 'vehicleByName', N.normName);
}

// ----------------------------------------------------------------------------
// STEP 4 — PROPERTIES
// v2: (client_id, name, address, city, state, zip, country, is_billing,
//      zone, latitude, longitude, geofence_*, access_*, is_primary, notes, county)
// Source: Jobber properties + primary properties from client address data
// ----------------------------------------------------------------------------
async function step4_properties() {
  console.log('\n[STEP 4] Properties...');
  await loadSourceMap('client', 'jobber', 'clientByJobberId');
  await loadSourceMap('client', 'airtable', 'clientByATId');

  const rows = [];

  // 4a. Jobber properties
  for (const jp of cache.jobber.properties) {
    const clientGid = jp.client?.id || jp.clientId;
    const client_id = idMaps.clientByJobberId.get(clientGid);
    if (!client_id && !DRY_RUN) continue;
    rows.push({
      client_id: client_id || null,
      name: jp.name || null,
      address: jp.address?.street || null,
      city: jp.address?.city || null,
      state: jp.address?.province || 'FL',
      zip: jp.address?.postalCode || null,
      country: jp.address?.country || 'US',
      is_billing: !!jp.isBillingAddress,
      zone: null,
      latitude: null,
      longitude: null,
      geofence_radius_meters: null,
      geofence_type: null,
      access_hours_start: null,
      access_hours_end: null,
      access_days: null,
      is_primary: false,
      notes: null,
      county: null,
      _jobber_id: jp.id,
    });
  }

  // 4b. Primary properties from client address data (cached from step 1)
  if (cache._clientRows && cache._clientIds) {
    for (let i = 0; i < cache._clientRows.length; i++) {
      const pp = cache._clientRows[i]._primary_property;
      if (!pp) continue;
      const clientId = cache._clientIds[i];
      // Check if a Jobber property already covers this address (avoid duplication)
      const isDuplicate = rows.some(r =>
        r.client_id === clientId &&
        r.address && pp.address &&
        N.normName(r.address) === N.normName(pp.address)
      );
      if (isDuplicate) {
        // Enrich the existing Jobber property with Airtable/Samsara data
        const existing = rows.find(r =>
          r.client_id === clientId &&
          r.address && pp.address &&
          N.normName(r.address) === N.normName(pp.address)
        );
        if (existing) {
          existing.zone = existing.zone || pp.zone;
          existing.latitude = existing.latitude || pp.latitude;
          existing.longitude = existing.longitude || pp.longitude;
          existing.geofence_radius_meters = existing.geofence_radius_meters || pp.geofence_radius_meters;
          existing.geofence_type = existing.geofence_type || pp.geofence_type;
          existing.access_hours_start = existing.access_hours_start || pp.access_hours_start;
          existing.access_hours_end = existing.access_hours_end || pp.access_hours_end;
          existing.access_days = existing.access_days || pp.access_days;
          existing.is_primary = true;
          existing.county = existing.county || pp.county;
        }
      } else {
        rows.push({
          client_id: clientId,
          name: null,
          address: pp.address,
          city: pp.city,
          state: pp.state || 'FL',
          zip: pp.zip,
          country: 'US',
          is_billing: pp.is_billing || false,
          zone: pp.zone,
          latitude: pp.latitude,
          longitude: pp.longitude,
          geofence_radius_meters: pp.geofence_radius_meters,
          geofence_type: pp.geofence_type,
          access_hours_start: pp.access_hours_start,
          access_hours_end: pp.access_hours_end,
          access_days: pp.access_days,
          is_primary: true,
          notes: null,
          county: pp.county,
          _jobber_id: null,
        });
      }
    }
  }

  const cols = ['client_id', 'name', 'address', 'city', 'state', 'zip', 'country', 'is_billing',
    'zone', 'latitude', 'longitude', 'geofence_radius_meters', 'geofence_type',
    'access_hours_start', 'access_hours_end', 'access_days',
    'is_primary', 'notes', 'county'];
  const ids = await bulkInsertReturning('properties', rows, cols, { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.properties = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} properties ${DRY_RUN ? 'planned' : 'inserted'}`);

  // entity_source_links for Jobber properties
  const links = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]._jobber_id) {
      links.push({ entity_type: 'property', entity_id: ids[i], source_system: 'jobber', source_id: rows[i]._jobber_id, source_name: rows[i].name || rows[i].address });
    }
  }
  await linkEntities(links, { dryRun: DRY_RUN });

  await loadSourceMap('property', 'jobber', 'propertyByJobberId');
}

// ----------------------------------------------------------------------------
// STEP 5 — SERVICE_CONFIGS (UNPIVOT from Airtable Clients)
// v2: added equipment_size_gallons, permit_number, permit_expiration
//     removed total_per_year, projected_year, visits_available, data_quality
// ----------------------------------------------------------------------------
async function step5_service_configs() {
  console.log('\n[STEP 5] Service configs (UNPIVOT)...');
  // clientByATId should already be loaded from step 4; reload if needed
  if (!idMaps.clientByATId.size && !DRY_RUN) {
    await loadSourceMap('client', 'airtable', 'clientByATId');
  }

  const rows = [];
  const TYPES = [
    { type: 'GT', freq: 'GT Frequency', freqMul: 30, price: 'GT Price', last: 'GT Last Visit', next: 'GT Next Visit', sizeField: 'Size GT in Gallon', gdoNum: 'GDO Number', gdoExp: 'GDO expiration date' },
    { type: 'CL', freq: 'CL Frequency', freqMul: 30, price: 'CL Price', last: 'CL Last Visit', next: 'CL Next Visit' },
    { type: 'WD', freq: 'WD Frequency', freqMul: 1,  price: 'WD Price', last: 'WD Last Visit', next: 'WD Next Visit' },
    { type: 'SUMP',       freq: null, price: 'Sump Price' },
    { type: 'GREY_WATER', freq: null, price: 'Grey Water Price' },
    { type: 'WARRANTY',   freq: null, price: 'Warranty Price' },
  ];

  for (const ac of cache.airtable.clients) {
    const client_id = idMaps.clientByATId.get(ac.id);
    if (!client_id && !DRY_RUN) continue;
    for (const T of TYPES) {
      const price = N.numOrNull(N.atField(ac, T.price));
      const freqRaw = T.freq ? N.numOrNull(N.atField(ac, T.freq)) : null;
      if (price === null && freqRaw === null) continue;
      rows.push({
        client_id: client_id || null,
        service_type: T.type,
        frequency_days: freqRaw !== null ? Math.round(freqRaw * (T.freqMul || 1)) : null,
        first_visit: null,
        last_visit: T.last ? N.dateOnly(N.atField(ac, T.last)) : null,
        // next_visit dropped — derived on read via clients_due_service view (3NF)
        stop_date: null,
        price_per_visit: price,
        // status dropped — derived on read via clients_due_service view (3NF)
        schedule_notes: null,
        equipment_size_gallons: T.sizeField ? N.numOrNull(N.atField(ac, T.sizeField)) : null,
        permit_number: T.gdoNum ? N.atField(ac, T.gdoNum) : null,
        permit_expiration: T.gdoExp ? N.dateOnly(N.atField(ac, T.gdoExp)) : null,
      });
    }
  }

  const cols = ['client_id', 'service_type', 'frequency_days', 'first_visit', 'last_visit',
    'stop_date', 'price_per_visit', 'schedule_notes',
    'equipment_size_gallons', 'permit_number', 'permit_expiration'];
  // service_configs has UNIQUE (client_id, service_type) — use bulkUpsert for idempotency
  const result = await bulkUpsert('service_configs', rows, cols, ['client_id', 'service_type'], { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.service_configs = { built: rows.length, ...result };
  console.log(`  ${rows.length} service_configs ${DRY_RUN ? 'planned' : 'upserted'}`);
}

// ----------------------------------------------------------------------------
// STEP 6 — QUOTES
// v2: removed message, jobber_quote_id -> entity_source_links
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
      subtotal: N.numOrNull(q.amounts?.subtotal),
      tax_amount: N.numOrNull(q.amounts?.taxAmount),
      total: N.numOrNull(q.amounts?.total),
      deposit_amount: N.numOrNull(q.amounts?.depositAmount),
      quote_status: q.quoteStatus || null,
      sent_at: q.sentAt || null,
      approved_at: q.approvedAt || null,
      converted_to_job_at: q.jobs?.nodes?.[0]?.createdAt || null,
      _jobber_id: q.id,
    });
  }
  const cols = ['client_id', 'property_id', 'quote_number', 'title', 'subtotal', 'tax_amount',
    'total', 'deposit_amount', 'quote_status', 'sent_at', 'approved_at', 'converted_to_job_at'];
  const ids = await bulkInsertReturning('quotes', rows, cols, { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.quotes = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} quotes ${DRY_RUN ? 'planned' : 'inserted'}`);

  const links = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]._jobber_id) links.push({ entity_type: 'quote', entity_id: ids[i], source_system: 'jobber', source_id: rows[i]._jobber_id, source_name: rows[i].title });
  }
  await linkEntities(links, { dryRun: DRY_RUN });

  await loadSourceMap('quote', 'jobber', 'quoteByJobberId');
}

// ----------------------------------------------------------------------------
// STEP 7 — JOBS
// v2: trimmed to (client_id, property_id, job_number, title, job_status,
//     start_at, end_at, total, quote_id, notes)
// quote_id resolved inline (quotes already loaded in step 6)
// ----------------------------------------------------------------------------
async function step7_jobs() {
  console.log('\n[STEP 7] Jobs...');
  const rows = [];
  for (const j of cache.jobber.jobs) {
    const client_id = idMaps.clientByJobberId.get(j.client?.id);
    const property_id = j.property?.id ? idMaps.propertyByJobberId.get(j.property.id) : null;
    // Resolve quote_id inline (quotes loaded in step 6)
    const quote_id = j.quote?.id ? idMaps.quoteByJobberId.get(j.quote.id) : null;
    rows.push({
      client_id: client_id || null,
      property_id: property_id || null,
      job_number: j.jobNumber || null,
      title: j.title || null,
      job_status: j.jobStatus || null,
      start_at: j.startAt || null,
      end_at: j.endAt || null,
      total: N.numOrNull(j.total),
      quote_id: quote_id || null,
      notes: j.instructions || null,
      _jobber_id: j.id,
    });
  }
  const cols = ['client_id', 'property_id', 'job_number', 'title', 'job_status', 'start_at', 'end_at',
    'total', 'quote_id', 'notes'];
  const ids = await bulkInsertReturning('jobs', rows, cols, { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.jobs = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} jobs ${DRY_RUN ? 'planned' : 'inserted'}`);

  const links = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]._jobber_id) links.push({ entity_type: 'job', entity_id: ids[i], source_system: 'jobber', source_id: rows[i]._jobber_id, source_name: rows[i].title });
  }
  await linkEntities(links, { dryRun: DRY_RUN });

  await loadSourceMap('job', 'jobber', 'jobByJobberId');
}

// ----------------------------------------------------------------------------
// STEP 8 — INVOICES
// v2: removed message, jobber_invoice_id -> entity_source_links
// ----------------------------------------------------------------------------
async function step8_invoices() {
  console.log('\n[STEP 8] Invoices...');
  const rows = [];
  for (const inv of cache.jobber.invoices) {
    const client_id = idMaps.clientByJobberId.get(inv.client?.id);
    const jobGid = inv.jobs?.nodes?.[0]?.id || inv.job?.id;
    const job_id = jobGid ? idMaps.jobByJobberId.get(jobGid) : null;
    rows.push({
      client_id: client_id || null,
      job_id: job_id || null,
      invoice_number: inv.invoiceNumber || null,
      subject: inv.subject || null,
      subtotal: N.numOrNull(inv.amounts?.subtotal),
      tax_amount: N.numOrNull(inv.amounts?.taxAmount),
      total: N.numOrNull(inv.amounts?.total),
      outstanding_amount: N.numOrNull(inv.amounts?.invoiceBalance),
      deposit_amount: N.numOrNull(inv.amounts?.depositAmount),
      invoice_status: inv.invoiceStatus || null,
      due_date: N.dateOnly(inv.dueDate),
      sent_at: inv.sentAt || inv.issuedDate || null,
      paid_at: inv.paidAt || null,
      _jobber_id: inv.id,
    });
  }
  const cols = ['client_id', 'job_id', 'invoice_number', 'subject', 'subtotal', 'tax_amount', 'total',
    'outstanding_amount', 'deposit_amount', 'invoice_status', 'due_date', 'sent_at', 'paid_at'];
  const ids = await bulkInsertReturning('invoices', rows, cols, { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.invoices = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} invoices ${DRY_RUN ? 'planned' : 'inserted'}`);

  const links = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]._jobber_id) links.push({ entity_type: 'invoice', entity_id: ids[i], source_system: 'jobber', source_id: rows[i]._jobber_id, source_name: rows[i].invoice_number });
  }
  await linkEntities(links, { dryRun: DRY_RUN });

  await loadSourceMap('invoice', 'jobber', 'invoiceByJobberId');
}

// ----------------------------------------------------------------------------
// STEP 9 — LINE ITEMS
// v2: removed jobber_line_item_id -> entity_source_links
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
      _jobber_id: li.id,
    });
  }
  const cols = ['job_id', 'quote_id', 'name', 'description', 'quantity', 'unit_price', 'total_price', 'taxable'];
  const ids = await bulkInsertReturning('line_items', rows, cols, { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.line_items = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} line_items ${DRY_RUN ? 'planned' : 'inserted'}`);

  const links = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]._jobber_id) links.push({ entity_type: 'line_item', entity_id: ids[i], source_system: 'jobber', source_id: rows[i]._jobber_id });
  }
  await linkEntities(links, { dryRun: DRY_RUN });
}

// ----------------------------------------------------------------------------
// STEP 10 — VISITS
// v2: source FKs → entity_source_links, invoice_id resolved inline
// KEPT: truck TEXT + completed_by TEXT (AT-legacy attribution for ~1400 historical visits)
// ----------------------------------------------------------------------------
async function step10_visits() {
  console.log('\n[STEP 10] Visits...');
  const rows = [];

  // 10a. Jobber visits (canonical)
  for (const v of cache.jobber.visits) {
    const client_id = idMaps.clientByJobberId.get(v.client?.id);
    const job_id = v.job?.id ? idMaps.jobByJobberId.get(v.job.id) : null;
    const property_id = v.property?.id ? idMaps.propertyByJobberId.get(v.property.id) : null;
    // Resolve invoice_id inline (invoices loaded in step 8)
    const invoice_id = v.invoice?.id ? idMaps.invoiceByJobberId.get(v.invoice.id) : null;
    rows.push({
      client_id: client_id || null,
      property_id: property_id || null,
      job_id: job_id || null,
      vehicle_id: null, // resolved via GPS enrichment or fixup pass 3
      visit_date: N.dateOnly(v.startAt || v.endAt || v.createdAt) || '1970-01-01',
      start_at: v.startAt || null,
      end_at: v.endAt || null,
      completed_at: v.completedAt || null,
      duration_minutes: v.durationMinutes ? Math.round(v.durationMinutes) : null,
      title: v.title || null,
      service_type: null, // enriched from Airtable in sync scripts
      visit_status: v.visitStatus || null,
      // is_complete dropped — derived on read (visit_status = 'COMPLETED') via visits_with_status view (3NF)
      truck: null, // Jobber visits don't have truck text
      completed_by: null, // Jobber visits use visit_assignments instead
      actual_arrival_at: null,
      actual_departure_at: null,
      is_gps_confirmed: false,
      invoice_id: invoice_id || null,
      _jobber_id: v.id,
      _airtable_id: null,
    });
  }

  // 10b. Airtable historical visits (pre-Jobber, ~1400 rows)
  // These have truck + completed_by text that is the ONLY attribution data.
  // Match to Jobber visits by jobber_visit_id field; unmatched = AT-only historical.
  const matchedJobberIds = new Set(rows.map(r => r._jobber_id));
  for (const av of cache.airtable.visits) {
    const jvid = N.atField(av, 'Jobber Visit ID') || N.atField(av, 'jobber_visit_id');
    // Skip if this AT visit matches a Jobber visit we already have
    if (jvid && matchedJobberIds.has(jvid)) continue;

    const clientATIds = N.atField(av, 'Client') || [];
    const firstATId = Array.isArray(clientATIds) ? clientATIds[0] : null;
    const client_id = firstATId ? idMaps.clientByATId.get(firstATId) : null;

    const truckText = N.atField(av, 'Truck') || N.atField(av, 'Vehicle') || null;
    const completedBy = N.atField(av, 'Completed By') || N.atField(av, 'Driver') || null;

    rows.push({
      client_id: client_id || null,
      property_id: null,
      job_id: null, // AT historical visits have no Jobber job
      vehicle_id: null, // resolved in fixup pass 3 via truck text
      visit_date: N.dateOnly(N.atField(av, 'Visit Date') || N.atField(av, 'Date')) || '1970-01-01',
      start_at: null,
      end_at: null,
      completed_at: null,
      duration_minutes: null,
      title: null,
      service_type: N.atField(av, 'Service Type') || N.atField(av, 'Type') || null,
      visit_status: 'COMPLETED',
      // is_complete dropped — derived on read (visit_status = 'COMPLETED') via visits_with_status view (3NF)
      truck: truckText, // AT-legacy: preserved for fixup pass 3
      completed_by: completedBy, // AT-legacy: preserved for fixup pass 5
      actual_arrival_at: null,
      actual_departure_at: null,
      is_gps_confirmed: false,
      invoice_id: null,
      _jobber_id: null,
      _airtable_id: av.id,
    });
  }

  console.log(`  Built ${rows.length} visits (jobber + AT historical)`);

  const cols = ['client_id', 'property_id', 'job_id', 'vehicle_id', 'visit_date', 'start_at', 'end_at',
    'completed_at', 'duration_minutes', 'title', 'service_type', 'visit_status',
    'truck', 'completed_by',
    'actual_arrival_at', 'actual_departure_at', 'is_gps_confirmed', 'invoice_id'];
  const ids = await bulkInsertReturning('visits', rows, cols, { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.visits = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} visits ${DRY_RUN ? 'planned' : 'inserted'}`);

  // entity_source_links for both Jobber and Airtable visits
  const links = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]._jobber_id) links.push({ entity_type: 'visit', entity_id: ids[i], source_system: 'jobber', source_id: rows[i]._jobber_id });
    if (rows[i]._airtable_id) links.push({ entity_type: 'visit', entity_id: ids[i], source_system: 'airtable', source_id: rows[i]._airtable_id });
  }
  await linkEntities(links, { dryRun: DRY_RUN });

  await loadSourceMap('visit', 'jobber', 'visitByJobberId');
  await loadSourceMap('visit', 'airtable', 'visitByATId');
}

// ----------------------------------------------------------------------------
// STEP 11 — VISIT_ASSIGNMENTS
// (unchanged from v1 — composite PK table)
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
  const cols = ['visit_id', 'employee_id'];
  const result = await bulkUpsert('visit_assignments', rows, cols, ['visit_id', 'employee_id'], { dryRun: DRY_RUN, batchSize: 500 });
  stats.steps.visit_assignments = { built: rows.length, ...result };
  console.log(`  ${rows.length} visit_assignments ${DRY_RUN ? 'planned' : 'upserted'}`);
}

// ----------------------------------------------------------------------------
// STEP 12 — INSPECTIONS (Fillout pre + post)
// v2: photos → inspection_photos, removed has_expense/expense_note/expense_amount,
//     fillout_submission_id/airtable_record_id/data_sources → entity_source_links
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

    // Collect photo URLs for inspection_photos
    const photos = [];
    const photoFields = [
      ['dashboard', 'dashboard'], ['cabin', 'cabin'], ['cabin_side_left', 'cabin side left'],
      ['cabin_side_right', 'cabin side right'], ['front', 'front'], ['back', 'back'],
      ['left_side', 'left side'], ['right_side', 'right side'], ['boots', 'boots'],
      ['remote', 'remote'], ['closed_valve', 'closed valve'], ['issue', 'issue'],
      ['sludge_level', 'sludge level'], ['water_level', 'water level'],
      ['derm_manifest', 'derm manifest'], ['derm_address', 'derm address'],
    ];
    for (const [photoType, label] of photoFields) {
      const url = getFilloutAnswer(sub, label);
      if (url && typeof url === 'string' && url.startsWith('http')) {
        photos.push({ photo_type: photoType, url });
      }
    }

    return {
      vehicle_id,
      employee_id,
      shift_date: N.dateOnly(sub.submissionTime || sub.lastUpdatedAt),
      inspection_type: type,
      submitted_at: sub.submissionTime || sub.lastUpdatedAt || null,
      sludge_gallons: N.intOrNull(getFilloutAnswer(sub, 'sludge')),
      water_gallons: type === 'POST' ? N.intOrNull(getFilloutAnswer(sub, 'water')) : null,
      gas_level: getFilloutAnswer(sub, 'gas'),
      is_valve_closed: getFilloutAnswer(sub, 'valve') === 'Yes',
      has_issue: !!getFilloutAnswer(sub, 'issue'),
      issue_note: getFilloutAnswer(sub, 'issue note'),
      _fillout_id: sub.submissionId,
      _photos: photos,
    };
  };

  for (const s of cache.fillout.pre) rows.push(buildRow(s, 'PRE'));
  for (const s of cache.fillout.post) rows.push(buildRow(s, 'POST'));

  // Dedupe by composite shift key
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

  const cols = ['vehicle_id', 'employee_id', 'shift_date', 'inspection_type', 'submitted_at',
    'sludge_gallons', 'water_gallons', 'gas_level', 'is_valve_closed', 'has_issue', 'issue_note'];
  const ids = await bulkInsertReturning('inspections', rows, cols, { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.inspections = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} inspections ${DRY_RUN ? 'planned' : 'inserted'}`);

  // entity_source_links
  const links = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]._fillout_id) links.push({ entity_type: 'inspection', entity_id: ids[i], source_system: 'fillout', source_id: rows[i]._fillout_id });
  }
  await linkEntities(links, { dryRun: DRY_RUN });

  // Photos → unified photos + photo_links tables (replaces inspection_photos, see ADR 009)
  // Each inspection photo becomes one row in `photos` (the file) + one row in
  // `photo_links` (entity_type='inspection', role=<photo_type>).
  const photoFileRows = [];
  const photoLinkPending = []; // defer: needs the photo_id after insert
  for (let i = 0; i < rows.length; i++) {
    for (const p of rows[i]._photos) {
      photoFileRows.push({
        storage_path: p.url,          // Fillout-hosted URL, treated as storage_path
        file_name: null,
        content_type: null,
        source: 'fillout_migration',
      });
      photoLinkPending.push({ inspection_index: i, role: p.photo_type });
    }
  }
  if (photoFileRows.length) {
    const photoCols = ['storage_path', 'file_name', 'content_type', 'source'];
    const photoIds = await bulkInsertReturning('photos', photoFileRows, photoCols, { dryRun: DRY_RUN, batchSize: 500 });
    const linkRows = photoLinkPending.map((pl, idx) => ({
      photo_id: photoIds[idx],
      entity_type: 'inspection',
      entity_id: ids[pl.inspection_index],
      role: pl.role,
    }));
    const linkCols = ['photo_id', 'entity_type', 'entity_id', 'role'];
    await bulkInsertReturning('photo_links', linkRows, linkCols, { dryRun: DRY_RUN, batchSize: 500 });
    console.log(`  ${photoFileRows.length} photos + ${linkRows.length} photo_links written`);
  }
}

// ----------------------------------------------------------------------------
// STEP 13 — EXPENSES
// v2: removed ramp_*, fillout_submission_id, data_sources → entity_source_links
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
      amount: null,
      description: getFilloutAnswer(s, 'expense note'),
      category: 'Other',
      vendor_name: null,
      vehicle_id: idMaps.vehicleByName.get(N.normName(truckText)) || null,
      employee_id: idMaps.employeeByFilloutName.get(N.normName(driverText)) || null,
      receipt_url: null,
      _fillout_id: s.submissionId + '_exp',
    });
  }
  const cols = ['expense_date', 'amount', 'description', 'category', 'vendor_name', 'vehicle_id', 'employee_id', 'receipt_url'];
  const ids = await bulkInsertReturning('expenses', rows, cols, { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.expenses = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} expenses ${DRY_RUN ? 'planned' : 'inserted'}`);

  const links = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]._fillout_id) links.push({ entity_type: 'expense', entity_id: ids[i], source_system: 'fillout', source_id: rows[i]._fillout_id });
  }
  await linkEntities(links, { dryRun: DRY_RUN });
}

// ----------------------------------------------------------------------------
// STEP 14 — DERM MANIFESTS
// v2: removed service_address/city/zip/county, airtable_record_id → entity_source_links
// ----------------------------------------------------------------------------
async function step14_derm_manifests() {
  console.log('\n[STEP 14] DERM manifests...');
  if (!idMaps.clientByATId.size && !DRY_RUN) {
    await loadSourceMap('client', 'airtable', 'clientByATId');
  }

  const rows = [];
  for (const m of cache.airtable.derm) {
    const clientATIds = N.atField(m, 'Client') || N.atField(m, 'Clients') || [];
    const firstClientATId = Array.isArray(clientATIds) ? clientATIds[0] : null;
    const client_id = firstClientATId ? idMaps.clientByATId.get(firstClientATId) : null;
    rows.push({
      client_id: client_id || null,
      service_date: N.dateOnly(N.atField(m, 'GT Last Visit') || N.atField(m, 'Date Dump Ticket')),
      dump_ticket_date: N.dateOnly(N.atField(m, 'Date Dump Ticket')),
      white_manifest_number: N.atField(m, 'White Manifest #'),
      yellow_ticket_number: N.atField(m, 'Yellow Ticket #'),
      manifest_images: null, // TODO: populate from AT attachment fields
      address_images: null,
      sent_to_client: !!N.atField(m, 'Sent to Client'),
      sent_to_city: !!N.atField(m, 'Sent to City'),
      _airtable_id: m.id,
    });
  }
  const cols = ['client_id', 'service_date', 'dump_ticket_date', 'white_manifest_number', 'yellow_ticket_number',
    'manifest_images', 'address_images', 'sent_to_client', 'sent_to_city'];
  const ids = await bulkInsertReturning('derm_manifests', rows, cols, { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.derm_manifests = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} manifests ${DRY_RUN ? 'planned' : 'inserted'}`);

  const links = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]._airtable_id) links.push({ entity_type: 'derm_manifest', entity_id: ids[i], source_system: 'airtable', source_id: rows[i]._airtable_id });
  }
  await linkEntities(links, { dryRun: DRY_RUN });

  await loadSourceMap('derm_manifest', 'airtable', 'manifestByATId');
}

// ----------------------------------------------------------------------------
// STEP 15 — MANIFEST_VISITS (link manifests to visits via client+date match)
// ----------------------------------------------------------------------------
async function step15_manifest_visits() {
  console.log('\n[STEP 15] Manifest-visit links...');
  if (DRY_RUN) { console.log('  skipped (dry-run)'); return; }

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
  const shiftDate = (d, days) => { const dt = new Date(d); dt.setUTCDate(dt.getUTCDate() + days); return dt.toISOString().slice(0, 10); };
  for (const m of manRows) {
    const sd = typeof m.service_date === 'string' ? m.service_date.slice(0, 10) : new Date(m.service_date).toISOString().slice(0, 10);
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
  const cols = ['manifest_id', 'visit_id'];
  const result = await bulkUpsert('manifest_visits', rows, cols, ['manifest_id', 'visit_id'], { dryRun: DRY_RUN, batchSize: 500 });
  stats.steps.manifest_visits = { built: rows.length, matched_manifests: matched, ...result };
  console.log(`  ${rows.length} manifest_visits from ${matched}/${manRows.length} manifests`);
}

// ----------------------------------------------------------------------------
// STEP 16 — ROUTES
// v2: removed gt_wanted_date, cl_wanted_date → route_stops table
//     removed airtable_record_id → entity_source_links
//     added route_date, vehicle_id, employee_id, notes
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
      status: N.atField(r, 'Status'),
      assignee: N.atField(r, 'Assignee'),
      zone: N.atField(r, 'Zone'),
      route_date: N.dateOnly(N.atField(r, 'GT Wanted Date') || N.atField(r, 'CL Wanted Date')),
      vehicle_id: null,
      employee_id: null,
      notes: null,
      _airtable_id: r.id,
      _gt_wanted_date: N.dateOnly(N.atField(r, 'GT Wanted Date')),
      _cl_wanted_date: N.dateOnly(N.atField(r, 'CL Wanted Date')),
    });
  }
  const cols = ['client_id', 'status', 'assignee', 'zone', 'route_date', 'vehicle_id', 'employee_id', 'notes'];
  const ids = await bulkInsertReturning('routes', rows, cols, { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.routes = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} routes ${DRY_RUN ? 'planned' : 'inserted'}`);

  const links = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]._airtable_id) links.push({ entity_type: 'route', entity_id: ids[i], source_system: 'airtable', source_id: rows[i]._airtable_id });
  }
  await linkEntities(links, { dryRun: DRY_RUN });

  // Write route_stops for GT/CL wanted dates
  const stopRows = [];
  for (let i = 0; i < rows.length; i++) {
    const r = rows[i];
    if (r._gt_wanted_date) {
      stopRows.push({ route_id: ids[i], client_id: r.client_id, property_id: null, service_type: 'GT', stop_order: null, wanted_date: r._gt_wanted_date, status: r.status });
    }
    if (r._cl_wanted_date) {
      stopRows.push({ route_id: ids[i], client_id: r.client_id, property_id: null, service_type: 'CL', stop_order: null, wanted_date: r._cl_wanted_date, status: r.status });
    }
  }
  if (stopRows.length) {
    const stopCols = ['route_id', 'client_id', 'property_id', 'service_type', 'stop_order', 'wanted_date', 'status'];
    await bulkInsertReturning('route_stops', stopRows, stopCols, { dryRun: DRY_RUN, batchSize: 500 });
    console.log(`  ${stopRows.length} route_stops written`);
  }
}

// ----------------------------------------------------------------------------
// STEP 17 — RECEIVABLES
// v2: removed last_modified, airtable_record_id → entity_source_links
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
      notes: N.atField(r, 'Note') || N.atField(r, 'Notes'),
      _airtable_id: r.id,
    });
  }
  const cols = ['client_id', 'amount_due', 'status', 'assignee', 'notes'];
  const ids = await bulkInsertReturning('receivables', rows, cols, { dryRun: DRY_RUN, batchSize: 200 });
  stats.steps.receivables = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} receivables ${DRY_RUN ? 'planned' : 'inserted'}`);

  const links = [];
  for (let i = 0; i < rows.length; i++) {
    if (rows[i]._airtable_id) links.push({ entity_type: 'receivable', entity_id: ids[i], source_system: 'airtable', source_id: rows[i]._airtable_id });
  }
  await linkEntities(links, { dryRun: DRY_RUN });
}

// ----------------------------------------------------------------------------
// STEP 18 — LEADS
// v2: removed assigned_to, service_interest, estimated_value, last_contact_at,
//     lost_reason, jobber_request_id
// ----------------------------------------------------------------------------
async function step18_leads() {
  console.log('\n[STEP 18] Leads...');
  const rows = [];
  for (const l of cache.airtable.leads) {
    const biz = N.atField(l, 'business_name') || N.atField(l, 'Business Name');
    if (!biz) continue;
    rows.push({
      converted_client_id: null,
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
      notes: N.atField(l, 'Notes'),
      first_contact_at: null,
      converted_at: null,
    });
  }
  // dedupe by contact_name
  const seen = new Map();
  for (const r of rows) seen.set(r.contact_name, r);
  rows.length = 0; rows.push(...seen.values());

  const cols = ['converted_client_id', 'contact_name', 'company_name', 'phone', 'email', 'address',
    'city', 'state', 'zip', 'lead_source', 'lead_status', 'notes', 'first_contact_at', 'converted_at'];
  const ids = await bulkInsertReturning('leads', rows, cols, { dryRun: DRY_RUN, batchSize: 100 });
  stats.steps.leads = { built: rows.length, inserted: ids.length };
  console.log(`  ${ids.length} leads ${DRY_RUN ? 'planned' : 'inserted'}`);
}

// ----------------------------------------------------------------------------
// FIXUP PASSES
// v2: Passes 1+2 resolved inline at insert time. Passes 3+5 still needed
// for AT-legacy truck/completed_by text resolution.
//   - Pass 1 (visits.invoice_id): resolved inline in step 10 ✓
//   - Pass 2 (jobs.quote_id): resolved inline in step 7 ✓
//   - Pass 3 (visits.vehicle_id via truck name): KEPT — AT historical visits
//   - Pass 4 (inspections FK): already resolved at insert time ✓
//   - Pass 5 (visit_assignments from completed_by): KEPT — AT historical visits
// ----------------------------------------------------------------------------
async function fixupPasses() {
  if (DRY_RUN) { console.log('\n[FIXUP] skipped (dry-run)'); return; }
  console.log('\n[FIXUP] Running post-population FK resolution...');

  // Pass 3: visits.vehicle_id from truck text (AT-legacy historical visits)
  console.log('  Pass 3: visits.vehicle_id <- vehicles (truck name)');
  const pass3 = await newQuery(`UPDATE visits SET vehicle_id = v.id FROM vehicles v
    WHERE lower(trim(visits.truck)) = lower(trim(v.name)) AND visits.vehicle_id IS NULL AND visits.truck IS NOT NULL;`);
  // Also handle common aliases: "Big One" / "the big one" -> David
  await newQuery(`UPDATE visits SET vehicle_id = v.id FROM vehicles v
    WHERE v.name = 'David' AND visits.vehicle_id IS NULL
    AND lower(trim(visits.truck)) IN ('big one', 'the big one', 'david 2000', 'david 2,000');`);
  console.log('  Pass 3 complete');

  // Pass 5: visit_assignments from completed_by (AT-legacy historical visits)
  console.log('  Pass 5: visit_assignments from completed_by');
  await newQuery(`INSERT INTO visit_assignments (visit_id, employee_id)
    SELECT v.id, e.id FROM visits v JOIN employees e
      ON lower(trim(v.completed_by)) = lower(trim(e.full_name))
    WHERE v.completed_by IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM visit_assignments va WHERE va.visit_id = v.id)
    ON CONFLICT DO NOTHING;`);
  console.log('  Pass 5 complete');

  // Verification queries
  console.log('\n  --- Verification ---');

  const invoiceCoverage = await newQuery(`
    SELECT
      COUNT(*) AS total,
      COUNT(invoice_id) AS with_invoice,
      COUNT(*) FILTER (WHERE visit_status = 'COMPLETED' AND invoice_id IS NULL) AS complete_no_invoice
    FROM visits;`);
  if (invoiceCoverage.length) {
    const c = invoiceCoverage[0];
    console.log(`  Visits: ${c.total} total, ${c.with_invoice} with invoice_id, ${c.complete_no_invoice} complete without invoice`);
  }

  const truckCoverage = await newQuery(`
    SELECT
      COUNT(*) FILTER (WHERE truck IS NOT NULL) AS with_truck_text,
      COUNT(*) FILTER (WHERE truck IS NOT NULL AND vehicle_id IS NOT NULL) AS truck_resolved,
      COUNT(*) FILTER (WHERE truck IS NOT NULL AND vehicle_id IS NULL) AS truck_unresolved
    FROM visits;`);
  if (truckCoverage.length) {
    const t = truckCoverage[0];
    console.log(`  Truck resolution: ${t.with_truck_text} with text, ${t.truck_resolved} resolved, ${t.truck_unresolved} unresolved`);
  }

  const completedByCoverage = await newQuery(`
    SELECT
      COUNT(*) FILTER (WHERE completed_by IS NOT NULL) AS with_completed_by,
      COUNT(DISTINCT v.id) FILTER (WHERE completed_by IS NOT NULL AND va.visit_id IS NOT NULL) AS resolved_to_assignment
    FROM visits v
    LEFT JOIN visit_assignments va ON va.visit_id = v.id;`);
  if (completedByCoverage.length) {
    const cb = completedByCoverage[0];
    console.log(`  Completed_by resolution: ${cb.with_completed_by} with text, ${cb.resolved_to_assignment} resolved to assignments`);
  }

  const linkCoverage = await newQuery(`
    SELECT entity_type, source_system, COUNT(*) AS cnt
    FROM entity_source_links
    GROUP BY entity_type, source_system
    ORDER BY entity_type, source_system;`);
  console.log('  Entity source links coverage:');
  for (const r of linkCoverage) {
    console.log(`    ${r.entity_type}/${r.source_system}: ${r.cnt}`);
  }
}

// ----------------------------------------------------------------------------
// MAIN
// ----------------------------------------------------------------------------
(async () => {
  try {
    await phase1_pull();

    if (TRUNCATE && !DRY_RUN) {
      console.log('\n[TRUNCATE] Wiping all tables...');
      // Truncate in reverse dependency order
      const order = [
        'route_stops', 'manifest_visits', 'visit_assignments',
        'photo_links', 'photos',                                  // unified photos (replaces inspection_photos + visit_photos)
        'line_items', 'expenses', 'inspections',
        'visits', 'invoices', 'quotes', 'jobs', 'service_configs', 'derm_manifests',
        'routes', 'receivables', 'leads', 'client_contacts', 'properties',
        'employees', 'vehicles', 'clients', 'entity_source_links',
      ];
      for (const t of order) {
        try {
          await newQuery(`TRUNCATE TABLE ${t} RESTART IDENTITY CASCADE;`);
          console.log(`  truncated ${t}`);
        } catch (e) {
          // TRUNCATE can fail (RLS/permissions) — fall back to DELETE
          try {
            await newQuery(`DELETE FROM ${t};`);
            console.log(`  deleted all from ${t} (TRUNCATE blocked)`);
          } catch (e2) {
            console.log(`  skip ${t} (${e2.message.slice(0, 60)})`);
          }
        }
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
    if (!ONLY_STEP || ONLY_STEP === 11) {
      // Pre-load maps needed by step 11 if running in isolation
      if (ONLY_STEP === 11) {
        await loadSourceMap('visit', 'jobber', 'visitByJobberId');
        await loadSourceMap('employee', 'jobber', 'employeeByJobberId');
      }
      await step11_visit_assignments();
    }
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
