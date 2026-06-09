// 86_check_real_missing_in_db.mjs
// For each of the 49 REAL missing DERM records, check if the DB already has
// a derm_manifests row for the same (client_code, manifest_number, service_date)
// — i.e. data is in DB but entity_source_links is broken.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${(await r.text()).slice(0, 600)}`);
  return JSON.parse(await r.text());
}

async function fetchAll(table) {
  const all = [];
  let offset = null;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/${encodeURIComponent(table)}?${q}`, {
      headers: { Authorization: `Bearer ${AT_KEY}` },
    });
    const j = await r.json();
    all.push(...(j.records || []));
    offset = j.offset;
  } while (offset);
  return all;
}

const linked = await pg(`
  SELECT source_id FROM public.entity_source_links
  WHERE entity_type='derm_manifest' AND source_system='airtable';
`);
const linkedSet = new Set(linked.map(r => r.source_id));

const atRecords = await fetchAll('DERM');
const missing = atRecords.filter(r => !linkedSet.has(r.id));

const REAL = missing.filter(r => {
  const f = r.fields || {};
  const m = f['White Manifest #'] || f['White Manifest Number'] || f['Manifest #'] || null;
  const d = f['GT Last Visit'] || f['Date'] || f['Service Date'] || null;
  const county = Array.isArray(f['County']) ? f['County'][0] : f['County'];
  return m && /^\d{3,}$/.test(String(m).trim())
    && d && /^\d{4}-\d{2}-\d{2}/.test(d)
    && !/broward/i.test(String(county || ''));
});

console.log(`REAL missing AT DERMs: ${REAL.length}`);

// Pull every white_manifest_number we already have, for fast lookup
const dbManifests = await pg(`
  SELECT id, white_manifest_number, service_date, client_id
  FROM public.derm_manifests
  WHERE white_manifest_number IS NOT NULL;
`);
const dbByManifest = new Map();
for (const r of dbManifests) {
  const k = String(r.white_manifest_number).trim();
  if (!dbByManifest.has(k)) dbByManifest.set(k, []);
  dbByManifest.get(k).push(r);
}

let alreadyInDb = 0;
let trulyMissing = 0;
const trulyMissingList = [];

for (const r of REAL) {
  const f = r.fields;
  const manifest = String(f['White Manifest #'] || f['White Manifest Number'] || f['Manifest #']).trim();
  const code = (f['Client Code #3 (from Client)'] || [''])[0];
  const client = (f['Client Name (from Client)'] || [''])[0];
  const date = f['GT Last Visit'] || f['Date'] || f['Service Date'];
  const candidates = dbByManifest.get(manifest) || [];
  // We don't have an AT→client_id mapping locally, so just check manifest# presence as a strong signal
  if (candidates.length > 0) {
    alreadyInDb++;
  } else {
    trulyMissing++;
    trulyMissingList.push({ at_id: r.id, manifest, date, code, client });
  }
}

console.log(`\nManifest# already in DB (orphan AT link): ${alreadyInDb}`);
console.log(`Truly missing (DB has no record with this manifest#): ${trulyMissing}`);

if (trulyMissingList.length > 0) {
  console.log('\n=== Truly missing — backfill candidates ===');
  trulyMissingList.forEach(r => {
    console.log(`  ${r.at_id}  ${r.date}  #${r.manifest.padEnd(8)}  ${r.code.padEnd(10)}  ${r.client}`);
  });
}

// Also: for the AT records whose manifest# IS in DB, list them so we know to just re-link
const reLinkList = [];
for (const r of REAL) {
  const f = r.fields;
  const manifest = String(f['White Manifest #'] || f['White Manifest Number'] || f['Manifest #']).trim();
  if (dbByManifest.has(manifest)) {
    reLinkList.push({
      at_id: r.id,
      manifest,
      code: (f['Client Code #3 (from Client)'] || [''])[0],
      client: (f['Client Name (from Client)'] || [''])[0],
      date: f['GT Last Visit'] || f['Date'] || f['Service Date'],
      db_candidates: dbByManifest.get(manifest).map(c => ({ id: c.id, client_id: c.client_id, date: c.service_date })),
    });
  }
}
if (reLinkList.length > 0) {
  console.log('\n=== Need re-link (DB has the manifest#, just missing AT link) ===');
  reLinkList.forEach(r => {
    console.log(`  ${r.at_id}  #${r.manifest}  ${r.code} ${r.client}  →  DB candidates: ${JSON.stringify(r.db_candidates)}`);
  });
}
