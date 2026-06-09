// 85_categorize_missing_derm.mjs
// Bucket the 118 AT DERM records missing from DB into:
//   - REAL: has manifest# (numeric) + service date + Dade county → backfill
//   - BROWARD: county is Broward → ignore (DERM is Miami-Dade only)
//   - JUNK: no manifest# and no date → skip
//   - PARTIAL: date but no manifest#, or manifest# but no date → review

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

const linkedRows = await pg(`
  SELECT source_id FROM public.entity_source_links
  WHERE entity_type='derm_manifest' AND source_system='airtable';
`);
const linkedSet = new Set(linkedRows.map(r => r.source_id));

const atRecords = await fetchAll('DERM');
const missing = atRecords.filter(r => !linkedSet.has(r.id));

console.log(`Total missing: ${missing.length}`);

function bucket(r) {
  const f = r.fields || {};
  const manifest = f['White Manifest #'] || f['White Manifest Number'] || f['Manifest #'] || null;
  const dateStr = f['GT Last Visit'] || f['Date'] || f['Service Date'] || null;
  const county = Array.isArray(f['County']) ? f['County'][0] : f['County'];
  const hasNumericManifest = manifest && /^\d{3,}$/.test(String(manifest).trim());
  const hasValidDate = dateStr && /^\d{4}-\d{2}-\d{2}/.test(dateStr);
  const isBroward = /broward/i.test(String(county || ''));

  if (isBroward) return 'BROWARD_SKIP';
  if (hasNumericManifest && hasValidDate) return 'REAL';
  if (hasNumericManifest && !hasValidDate) return 'MANIFEST_NO_DATE';
  if (!hasNumericManifest && hasValidDate) return 'DATE_NO_MANIFEST';
  return 'JUNK';
}

const buckets = {};
const records = {};
for (const r of missing) {
  const b = bucket(r);
  buckets[b] = (buckets[b] || 0) + 1;
  if (!records[b]) records[b] = [];
  records[b].push(r);
}

console.log('\n=== Bucket counts ===');
console.log(buckets);

for (const [b, list] of Object.entries(records)) {
  console.log(`\n=== ${b} (${list.length}) ===`);
  list.slice(0, b === 'REAL' ? 30 : 10).forEach(r => {
    const f = r.fields || {};
    const manifest = f['White Manifest #'] || f['White Manifest Number'] || f['Manifest #'] || '—';
    const date = f['GT Last Visit'] || f['Date'] || f['Service Date'] || '—';
    const client = (f['Client Name (from Client)'] || ['—'])[0];
    const county = Array.isArray(f['County']) ? f['County'][0] : (f['County'] || '—');
    const code = (f['Client Code #3 (from Client)'] || ['—'])[0];
    console.log(`  ${r.id}  ${date.padEnd(10)}  #${String(manifest).padEnd(8)}  ${code.padEnd(10)}  ${client} [${county}]`);
  });
  if (list.length > (b === 'REAL' ? 30 : 10)) {
    console.log(`  ...and ${list.length - (b === 'REAL' ? 30 : 10)} more`);
  }
}
