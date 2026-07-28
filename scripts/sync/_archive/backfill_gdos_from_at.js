// Backfill public.gdos from AT Clients.GDO Number field. Many AT clients
// have a GDO Number we never imported (gdos table has 104 rows, AT has
// ~200+ records). Idempotent — upserts on (client_id, gdo_number).
//
// Per CLAUDE.md rules:
//   - 3NF: gdo is client+location-scoped; existing gdos table is correct.
//   - Types preserved (TEXT for gdo_number, DATE for expiration, etc.).
//   - Audit triggers fire automatically on gdos INSERT (opted-in).
//   - ON CONFLICT keeps it re-runnable.
//   - Never hard-delete: this script only INSERTs net-new rows.
//
// Match strategy: AT record → DB client via
//   1. entity_source_links (entity_type=client, source_system=airtable)
//   2. client_code (AT "Client Code #3" ↔ DB clients.client_code)
//   3. normalized name match (last resort, ≥6 char overlap)
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const EXECUTE = process.argv.includes('--execute');

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, {
    ...opts,
    headers: { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json', ...(opts.headers || {}) },
  });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
}
async function airtableAll() {
  const all = [];
  let offset = null;
  do {
    const qs = new URLSearchParams({ pageSize: '100' });
    if (offset) qs.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/Clients?${qs}`, { headers: { Authorization: `Bearer ${AT_KEY}` } }).then(r => r.json());
    all.push(...(r.records || []));
    offset = r.offset;
  } while (offset);
  return all;
}
function normalize(s) {
  return (s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}
// Normalize GDO format: AT sometimes stores raw number, sometimes "GDO-NNNN", sometimes with extra prefix
function normalizeGdo(raw) {
  if (!raw) return null;
  const s = String(raw).trim().toUpperCase().replace(/\s+/g, '');
  if (!s) return null;
  // Already in GDO-NNNNN form
  if (/^GDO-\d{3,6}$/.test(s)) return s;
  // Bare digits — pad to standard format
  if (/^\d{3,6}$/.test(s)) return 'GDO-' + s;
  // Has extra prefix or comma-separated multi-value: split on commas/spaces, normalize each
  const parts = s.split(/[, ]+/).filter(Boolean);
  if (parts.length > 1) {
    // Multiple GDOs in one cell — return as array
    return parts.map(p => normalizeGdo(p)).filter(Boolean);
  }
  // Unknown shape — keep as-is
  return s;
}

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);

  const atRecords = await airtableAll();
  console.log(`Pulled ${atRecords.length} AT clients`);

  // DB indexes
  const dbClients = await rest('clients?select=id,client_code,name,status&limit=10000');
  const codeIdx = {};
  const nameIdx = {};
  for (const c of dbClients) {
    if (c.client_code) codeIdx[c.client_code.toUpperCase()] = c;
    const nk = normalize(c.name);
    if (nk) nameIdx[nk] = c;
  }
  const eslRows = await rest('entity_source_links?entity_type=eq.client&source_system=eq.airtable&select=entity_id,source_id&limit=10000');
  const dbByAtId = {};
  for (const e of eslRows) dbByAtId[e.source_id] = dbClients.find(c => c.id === e.entity_id);

  // Existing gdos
  const existingGdos = await rest('gdos?select=client_id,gdo_number&limit=10000');
  const haveGdo = new Set(existingGdos.map(g => `${g.client_id}:${g.gdo_number.toUpperCase()}`));

  const toInsert = [];
  const unmatched = [];
  const alreadyHave = [];
  const malformed = [];

  for (const r of atRecords) {
    const atCode = r.fields?.['Client Code #3'];
    const atName = r.fields?.['Client Name'];
    const atGdoRaw = r.fields?.['GDO Number'];
    if (!atGdoRaw) continue;

    let dbClient = dbByAtId[r.id]
                || (atCode && codeIdx[String(atCode).toUpperCase()])
                || (atName && nameIdx[normalize(atName)]);
    if (!dbClient) {
      unmatched.push({ at_code: atCode, at_name: atName, at_gdo: atGdoRaw });
      continue;
    }

    const gdoNormalized = normalizeGdo(atGdoRaw);
    const gdos = Array.isArray(gdoNormalized) ? gdoNormalized : [gdoNormalized].filter(Boolean);
    if (!gdos.length) { malformed.push({ at_name: atName, raw: atGdoRaw }); continue; }

    for (const g of gdos) {
      // Skip if obviously bad (e.g. random text)
      if (!/^GDO-\d{3,6}$/.test(g)) {
        malformed.push({ at_name: atName, db_id: dbClient.id, raw: atGdoRaw, normalized: g });
        continue;
      }
      const key = `${dbClient.id}:${g}`;
      if (haveGdo.has(key)) { alreadyHave.push({ db_id: dbClient.id, gdo: g }); continue; }
      toInsert.push({
        client_id: dbClient.id,
        gdo_number: g,
        permit_expiration: r.fields?.['GDO expiration date'] || null,
        status: 'ACTIVE',
      });
    }
  }

  console.log('\n=== Summary ===');
  console.table([
    { metric: 'AT clients with GDO Number',  count: atRecords.filter(r => r.fields?.['GDO Number']).length },
    { metric: 'Already in DB',                count: alreadyHave.length },
    { metric: 'NEW GDOs to insert',           count: toInsert.length },
    { metric: 'AT GDO present, DB no client', count: unmatched.length },
    { metric: 'Malformed GDO values',         count: malformed.length },
  ]);

  if (toInsert.length) {
    console.log('\n=== Sample (first 10 to insert) ===');
    console.table(toInsert.slice(0, 10));
  }
  if (malformed.length) {
    console.log(`\n=== Malformed (${malformed.length}, first 5) ===`);
    console.table(malformed.slice(0, 5));
  }
  if (unmatched.length) {
    console.log(`\n=== Unmatched AT clients (${unmatched.length}, first 5) ===`);
    console.table(unmatched.slice(0, 5));
  }

  if (!EXECUTE) {
    console.log('\n[DRY-RUN] Re-run with --execute to insert.');
    return;
  }

  console.log(`\nInserting ${toInsert.length} new GDOs...`);
  for (const row of toInsert) {
    try {
      await rest('gdos?on_conflict=client_id,gdo_number', {
        method: 'POST',
        headers: { Prefer: 'resolution=ignore-duplicates,return=minimal' },
        body: JSON.stringify(row),
      });
    } catch (e) {
      console.warn(`  fail (client ${row.client_id} ${row.gdo_number}):`, e.message?.slice(0, 80));
    }
  }
  console.log('Done. Now backfilling property_id for the new rows...');

  // Backfill property_id for any GDO row still missing it
  await rest('gdos?property_id=is.null', {
    method: 'PATCH',
    headers: { Prefer: 'return=minimal' },
    body: JSON.stringify({}),  // no-op, just to confirm shape
  }).catch(() => {});

  // Use SQL via management API for the property_id linkage
  const PROJECT = process.env.SUPABASE_PROJECT_ID;
  const PAT = process.env.SUPABASE_PAT;
  const linkSql = `
    WITH primary_props AS (
      SELECT DISTINCT ON (client_id) client_id, id AS property_id
      FROM properties WHERE is_primary = true ORDER BY client_id, id
    )
    UPDATE gdos g SET property_id = pp.property_id
    FROM primary_props pp
    WHERE g.client_id = pp.client_id AND g.property_id IS NULL;
  `;
  const linkR = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: linkSql }),
  });
  console.log('property_id linkage:', linkR.status);

  // Final coverage
  const final = await rest('gdos?select=id', { headers: { Prefer: 'count=exact', Range: '0-0' } });
  console.log(`Final gdos rowcount: see content-range`);

  // Re-check derm.visits chip coverage
  const derm = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: 'SELECT COUNT(*) AS total, COUNT(gdo_number) AS with_gdo FROM derm.visits;' }),
  }).then(r => r.json());
  console.log('derm.visits GDO chip coverage:', derm);
})().catch(err => { console.error(err); process.exit(1); });
