// Cross-check each active client's DB county against AT's canonical "County"
// field. Surface discrepancies for fix.
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, ...(opts.headers || {}) } });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  return r.json();
}

async function pullAtClients() {
  const all = [];
  let offset = null;
  do {
    const qs = new URLSearchParams({ pageSize: '100' });
    if (offset) qs.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/Clients?${qs}`, {
      headers: { Authorization: `Bearer ${AT_KEY}` },
    }).then(r => r.json());
    all.push(...(r.records || []));
    offset = r.offset;
  } while (offset);
  return all;
}

function normCounty(c) {
  if (!c) return null;
  const s = String(c).toLowerCase().replace(/\s+/g, '');
  if (s === 'dade' || s === 'miamidade' || s === 'miami-dade') return 'Dade';
  if (s === 'broward') return 'Broward';
  if (s === 'palmbeach' || s === 'palm-beach') return 'Palm Beach';
  if (s === 'monroe') return 'Monroe';
  if (s === 'none' || s === '') return null;
  return String(c).trim();
}

(async () => {
  console.log('Pulling AT Clients + DB clients/properties...');
  const atRecords = await pullAtClients();
  console.log(`  ${atRecords.length} AT clients`);

  // Index AT by ID + by client_code
  const atById = {}, atByCode = {};
  for (const r of atRecords) {
    atById[r.id] = r;
    const code = r.fields?.['Client Code #3'];
    if (code) atByCode[String(code).toUpperCase()] = r;
  }

  // Pull DB active clients + their primary properties
  const clients = await rest('clients?status=in.(ACTIVE,RECURRING)&select=id,client_code,name&limit=10000');
  const ids = clients.map(c => c.id);

  // Build property lookup
  const propsByClient = {};
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    const rows = await rest(`properties?client_id=in.(${chunk.join(',')})&is_primary=eq.true&select=id,client_id,address,city,county`);
    for (const p of rows) propsByClient[p.client_id] = p;
  }

  // ESL — link DB client to AT record
  const eslRows = [];
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    const r = await rest(`entity_source_links?entity_type=eq.client&source_system=eq.airtable&entity_id=in.(${chunk.join(',')})&select=entity_id,source_id`);
    eslRows.push(...r);
  }
  const atIdForClient = {};
  for (const e of eslRows) atIdForClient[e.entity_id] = e.source_id;

  // Compare
  const issues = [];
  let matched = 0, atSilent = 0, agree = 0, disagree = 0, dbMissing = 0;
  for (const c of clients) {
    const dbProp = propsByClient[c.id];
    const dbCounty = normCounty(dbProp?.county);
    let atRec = atIdForClient[c.id] ? atById[atIdForClient[c.id]] : null;
    if (!atRec && c.client_code) atRec = atByCode[c.client_code.toUpperCase()] || null;
    const atCounty = normCounty(atRec?.fields?.County);

    if (!atRec) { atSilent++; continue; }
    matched++;
    if (!dbCounty) { dbMissing++; issues.push({ kind: 'db_missing', client: c.client_code || c.name, db_county: dbCounty, at_county: atCounty, city: dbProp?.city }); continue; }
    if (!atCounty) { /* AT silent on this one */ continue; }
    if (dbCounty === atCounty) { agree++; continue; }
    disagree++;
    issues.push({ kind: 'disagree', client: c.client_code || c.name, db_county: dbCounty, at_county: atCounty, city: dbProp?.city, addr: dbProp?.address?.slice(0, 40) });
  }

  console.log('\n=== Summary ===');
  console.table([
    { metric: 'active clients in DB',                  count: clients.length },
    { metric: 'matched to AT (via ESL or code)',       count: matched },
    { metric: 'no AT match',                           count: atSilent },
    { metric: 'AT + DB agree on county',               count: agree },
    { metric: 'DB has county, AT silent',              count: matched - agree - disagree - dbMissing },
    { metric: 'DB missing county (AT has it)',         count: dbMissing },
    { metric: 'AT + DB DISAGREE',                      count: disagree },
  ]);

  if (issues.length) {
    console.log(`\n=== Discrepancies (${issues.length}) ===`);
    console.table(issues.slice(0, 40));
  }
})().catch(err => { console.error(err); process.exit(1); });
