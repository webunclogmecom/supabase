// Look at the Airtable PRE-POST inspection table to find which fields hold
// photos/attachments.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const TABLE = 'PRE-POST insptection'; // sic — confirmed typo in CLAUDE.md

function http(opts) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej); req.end();
  });
}

(async () => {
  console.log(`Pulling first page of "${TABLE}" from Airtable...\n`);
  const r = await http({
    hostname: 'api.airtable.com',
    path: `/v0/${AT_BASE}/${encodeURIComponent(TABLE)}?pageSize=10`,
    headers: { Authorization: `Bearer ${AT_KEY}` },
  });
  if (r.status >= 300) {
    console.error(`HTTP ${r.status}: ${r.body.slice(0, 400)}`);
    process.exit(1);
  }
  const j = JSON.parse(r.body);
  console.log(`  ${j.records.length} records on first page (total > 100? ${j.offset ? 'yes' : 'no'})`);

  // Aggregate fields seen across records
  const fieldSummary = new Map(); // name → { types: Set, sampleValues: Array }
  for (const rec of j.records) {
    for (const [k, v] of Object.entries(rec.fields || {})) {
      if (!fieldSummary.has(k)) fieldSummary.set(k, { types: new Set(), examples: [] });
      const e = fieldSummary.get(k);
      if (Array.isArray(v) && v.length > 0 && typeof v[0] === 'object' && v[0].url) {
        e.types.add('attachment[]');
        e.examples.push(`${v.length} att(s): ${v[0].filename || v[0].id}`);
      } else if (Array.isArray(v)) {
        e.types.add('array');
        e.examples.push(JSON.stringify(v).slice(0, 60));
      } else if (typeof v === 'object') {
        e.types.add('object');
        e.examples.push(JSON.stringify(v).slice(0, 60));
      } else {
        e.types.add(typeof v);
        e.examples.push(String(v).slice(0, 60));
      }
    }
  }

  console.log('\nFields observed:');
  const tab = [];
  for (const [name, info] of fieldSummary.entries()) {
    tab.push({
      field: name,
      types: [...info.types].join(','),
      sample: info.examples[0] || '',
    });
  }
  console.table(tab);

  console.log('\nAttachment fields specifically:');
  const attFields = [...fieldSummary.entries()].filter(([_, v]) => v.types.has('attachment[]'));
  for (const [name, info] of attFields) {
    console.log(`  "${name}" — ${info.examples.length} examples seen on this page`);
  }

  console.log('\nFirst record full payload (preview):');
  if (j.records[0]) {
    const r0 = j.records[0];
    console.log(`  id: ${r0.id}`);
    console.log(`  createdTime: ${r0.createdTime}`);
    for (const [k, v] of Object.entries(r0.fields || {})) {
      const display = Array.isArray(v) && v[0]?.url
        ? `[attachment[${v.length}]: ${v.map(a => a.filename || a.id).join(', ').slice(0, 80)}]`
        : JSON.stringify(v).slice(0, 80);
      console.log(`  ${k}: ${display}`);
    }
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
