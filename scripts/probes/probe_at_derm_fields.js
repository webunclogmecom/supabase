// Probe Airtable DERM table fields for visit 1619's manifest to find:
//   - "White Manifest" / "DERM Manifest" → maps to WWTP Disposal Receipt
//   - "DERM Address" → maps to DERM FOG eManifest
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const DERM_TABLE = 'tblz0CnWim7ViFjcw'; // from rehandle_at_derm_inspections.js

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({status: r.statusCode, body: Buffer.concat(c).toString()}));
    });
    req.on('error', rej);
    if (body) req.write(body);
    req.end();
  });
}

async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROD}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}

(async () => {
  // 1) Get the AT record ID for visit 1619's manifest
  const link = await pg(`
    SELECT esl.source_id, esl.entity_id
    FROM entity_source_links esl
    WHERE esl.entity_type = 'derm_manifest'
      AND esl.source_system = 'airtable'
      AND esl.entity_id IN (SELECT manifest_id FROM manifest_visits WHERE visit_id = 1619);
  `);
  console.log('AT record ID for visit 1619 manifest:', link);
  if (!link.length) { console.log('No AT record. Aborting.'); return; }
  const atRecordId = link[0].source_id;

  // 2) Fetch that record from Airtable directly to see ALL its fields
  const r = await http({
    hostname: 'api.airtable.com',
    path: `/v0/${AT_BASE}/${DERM_TABLE}/${atRecordId}`,
    method: 'GET',
    headers: { Authorization: `Bearer ${AT_KEY}` }
  });
  if (r.status >= 300) { console.log('AT error:', r.status, r.body.slice(0, 400)); return; }
  const rec = JSON.parse(r.body);
  console.log('\n=== ALL Airtable DERM fields for this record ===');
  console.log('Record ID:', rec.id);
  console.log('Created:', rec.createdTime);
  console.log('Fields:');
  for (const [k, v] of Object.entries(rec.fields || {})) {
    let display = v;
    if (typeof v === 'object') display = JSON.stringify(v).slice(0, 200);
    if (typeof v === 'string' && v.length > 200) display = v.slice(0, 200) + '…';
    console.log(`  "${k}":`, display);
  }

  // 3) Also list the DERM table schema (field names + types) to find anything we missed
  console.log('\n=== DERM table schema in Airtable ===');
  const schema = await http({
    hostname: 'api.airtable.com',
    path: `/v0/meta/bases/${AT_BASE}/tables`,
    method: 'GET',
    headers: { Authorization: `Bearer ${AT_KEY}` }
  });
  if (schema.status < 300) {
    const tables = JSON.parse(schema.body).tables;
    const dermTable = tables.find(t => t.id === DERM_TABLE);
    if (dermTable) {
      console.log('Table name:', dermTable.name);
      console.log('All fields:');
      dermTable.fields.forEach(f => console.log(`  "${f.name}" (${f.type})`));
    }
  } else {
    console.log('  (cannot fetch schema:', schema.status, ')');
  }
})();
