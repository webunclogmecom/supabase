// 100_claudie_at_visit_lookup.mjs
// AT DERM rec5eQbs7I8ww8uDp references AT Visit recpKiq8FDYVqpOOW.
// The backfill script didn't link it to our DB visit 5099 (Claudie May 14).
// Fetch the AT visit record directly and inspect every field to find
// the date field name(s) and see why the match failed.
import 'dotenv/config';
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

const targets = [
  'recpKiq8FDYVqpOOW', // Claudie May DERM #824713
];

for (const id of targets) {
  console.log(`\n=== AT Visit ${id} ===`);
  const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/Visits/${id}`, {
    headers: { Authorization: `Bearer ${AT_KEY}` },
  });
  if (!r.ok) {
    console.log(`  HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`);
    continue;
  }
  const v = await r.json();
  console.log(`  createdTime: ${v.createdTime}`);
  console.log(`  fields:`);
  for (const [k, val] of Object.entries(v.fields || {})) {
    const s = typeof val === 'string' ? val : JSON.stringify(val);
    console.log(`    ${k.padEnd(35)} ${s.slice(0, 80)}`);
  }
}
