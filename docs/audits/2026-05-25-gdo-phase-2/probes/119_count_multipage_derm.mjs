// 119_count_multipage_derm.mjs
// Count AT DERM records with 2+ pages in either DERM Manifest or DERM Address
// attachments. Drives the backfill strategy decision.
import 'dotenv/config';
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
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

const at = await fetchAll('DERM');
console.log(`Total AT DERM records: ${at.length}`);

let mfst2 = 0, mfst3plus = 0, addr2 = 0, addr3plus = 0, eitherMulti = 0;
const sample = [];

for (const r of at) {
  const f = r.fields || {};
  const m = Array.isArray(f['DERM Manifest']) ? f['DERM Manifest'].length : 0;
  const a = Array.isArray(f['DERM Address']) ? f['DERM Address'].length : 0;
  if (m >= 2) mfst2++;
  if (m >= 3) mfst3plus++;
  if (a >= 2) addr2++;
  if (a >= 3) addr3plus++;
  if (m >= 2 || a >= 2) {
    eitherMulti++;
    if (sample.length < 10) {
      sample.push({
        at_id: r.id,
        manifest_pages: m,
        address_pages: a,
        client: (f['Client Name (from Client)'] || ['?'])[0],
        wm: f['White Manifest #'] || '?',
      });
    }
  }
}

console.log({
  manifest_2plus: mfst2,
  manifest_3plus: mfst3plus,
  address_2plus: addr2,
  address_3plus: addr3plus,
  either_multi: eitherMulti,
});

console.log('\nSample multi-page records:');
sample.forEach(s => console.log(' ', JSON.stringify(s)));
