// 84_at_derm_in_db_audit.mjs
// Fetch all DERM records from Airtable, cross-reference against
// public.entity_source_links (entity_type='derm_manifest', source_system='airtable').
// Report missing.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
if (!AT_KEY || !AT_BASE) throw new Error('AIRTABLE_API_KEY/AIRTABLE_BASE_ID missing');

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

async function fetchAllAtRecords(tableName) {
  const all = [];
  let offset = null;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/${encodeURIComponent(tableName)}?${q}`, {
      headers: { Authorization: `Bearer ${AT_KEY}` },
    });
    if (!r.ok) throw new Error(`AT ${r.status}: ${(await r.text()).slice(0, 300)}`);
    const json = await r.json();
    all.push(...(json.records || []));
    offset = json.offset;
  } while (offset);
  return all;
}

const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);

banner('1. How is DERM linked? Probe schema + sample row');
console.log(await pg(`
  SELECT column_name, data_type
  FROM information_schema.columns
  WHERE table_schema='public' AND table_name='derm_manifests'
  ORDER BY ordinal_position;
`));
console.log('\n--- sample entity_source_links for derm_manifest entity type ---');
console.log(await pg(`
  SELECT source_system, COUNT(*)::int AS n
  FROM public.entity_source_links
  WHERE entity_type='derm_manifest'
  GROUP BY source_system ORDER BY n DESC;
`));

banner('2. Fetch all AT DERM records');
const atRecords = await fetchAllAtRecords('DERM');
console.log(`  Total AT DERM records: ${atRecords.length}`);

banner('3. Pull our linked AT record IDs from entity_source_links');
const linkedRows = await pg(`
  SELECT source_id, entity_id
  FROM public.entity_source_links
  WHERE entity_type='derm_manifest' AND source_system='airtable';
`);
const linkedSet = new Set(linkedRows.map(r => r.source_id));
console.log(`  Linked entity_source_links rows: ${linkedRows.length}`);
console.log(`  Distinct AT source_ids in DB: ${linkedSet.size}`);

banner('4. Compare — AT records not present in entity_source_links');
const missing = atRecords.filter(r => !linkedSet.has(r.id));
console.log(`  AT records missing from DB: ${missing.length}`);
if (missing.length > 0) {
  console.log('\n  First 20 missing AT records:');
  missing.slice(0, 20).forEach(r => {
    const f = r.fields || {};
    console.log(`    ${r.id}  manifest# ${f['Manifest #'] || f['White Manifest #'] || f['White Manifest Number'] || '?'}  date ${f['GT Last Visit'] || f['Date'] || f['Service Date'] || '?'}  client ${(f['Client Name (from Client)'] || f['Client'] || ['?'])[0] || '?'}`);
  });
  console.log('\n  Sample full payload (first missing):');
  console.log(JSON.stringify(missing[0], null, 2).slice(0, 1500));
}

banner('5. Reverse — DB-linked AT ids NOT in current AT pull (deleted in AT?)');
const atIdSet = new Set(atRecords.map(r => r.id));
const ghostsInDb = linkedRows.filter(r => !atIdSet.has(r.source_id));
console.log(`  Entity_source_links pointing to AT records that no longer exist: ${ghostsInDb.length}`);
if (ghostsInDb.length > 0) console.log('  Sample:', ghostsInDb.slice(0, 5));

banner('6. Summary');
console.log({
  at_records_total: atRecords.length,
  db_linked_total: linkedRows.length,
  db_distinct_at_ids: linkedSet.size,
  at_missing_from_db: missing.length,
  db_ghosts: ghostsInDb.length,
});
