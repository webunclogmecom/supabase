const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

(async () => {
  const records = [];
  let offset = null;
  do {
    const qs = new URLSearchParams({ pageSize: '100' });
    if (offset) qs.set('offset', offset);
    const r = await fetch(`https://api.airtable.com/v0/${AT_BASE}/Clients?${qs}`, {
      headers: { Authorization: `Bearer ${AT_KEY}` },
    }).then(r => r.json());
    records.push(...(r.records || []));
    offset = r.offset;
  } while (offset);

  console.log(`Total AT records: ${records.length}\n`);
  console.log('Matches for G7/Kitchen:');
  for (const r of records) {
    const n = (r.fields['Client Name'] || '').toLowerCase();
    if (/g7|kitchens?/i.test(n)) {
      console.log(' ', r.fields['Client Code #3'] || '(no code)', '|', r.fields['Client Name'], '|', r.fields['ACTIVE/INACTIVE']);
    }
  }
  console.log('\nMatches for Bayshore/SLS/Shaulson:');
  for (const r of records) {
    const n = (r.fields['Client Name'] || '').toLowerCase();
    if (/bayshore|sls|shaulson/i.test(n)) {
      console.log(' ', r.fields['Client Code #3'] || '(no code)', '|', r.fields['Client Name'], '|', r.fields['ACTIVE/INACTIVE']);
    }
  }
})();
