// Pick 10 sample GDOs for Phase 2a (diverse — easy + tricky)
const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });
const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
function pg(sql) { return new Promise((res, rej) => { const body = JSON.stringify({ query: sql }); const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>{try{res(JSON.parse(d))}catch(_){res(d)}})});req.on('error',rej);req.write(body);req.end();}); }
(async () => {
  console.log('=== 10 sample GDOs for Phase 2a backfill ===');
  console.log('Mix: 5 easy (single tenant) + 3 from multi-tenant addresses + Casa Neos (3 rows) + the 3 typo pairs');

  console.log('\n--- Casa Neos (3 rows) ---');
  console.log(await pg(`
    SELECT g.id, g.gdo_number, g.client_id, c.client_code, c.name AS client_name,
           p.id AS prop_id, p.address, p.zip,
           g.location_label, g.permit_expiration::text, g.max_frequency_days
    FROM gdos g
    JOIN clients c ON c.id = g.client_id
    JOIN properties p ON p.id = g.property_id
    WHERE g.property_id = 42
    ORDER BY g.id;
  `));

  console.log('\n--- 5 simple (single-tenant) GDOs ---');
  console.log(await pg(`
    SELECT g.id, g.gdo_number, c.client_code, c.name AS client_name,
           p.address, p.zip, g.permit_expiration::text
    FROM gdos g
    JOIN clients c ON c.id = g.client_id
    JOIN properties p ON p.id = g.property_id
    WHERE g.status = 'ACTIVE'
      AND g.property_id NOT IN (SELECT property_id FROM gdos GROUP BY property_id HAVING COUNT(*) > 1)
      AND p.address IS NOT NULL
      AND c.status = 'ACTIVE'
      AND c.client_code IN ('111-YC', '042-MT', '003-BC', '001-VIN', '028-HUM')
    ORDER BY c.client_code;
  `));

  console.log('\n--- The 3 typo pairs (6 rows) — sample first pair only for Phase 2a (rest later) ---');
  console.log(await pg(`
    SELECT g.id, g.gdo_number, c.client_code, c.name AS client_name,
           p.address, p.zip
    FROM gdos g
    JOIN clients c ON c.id = g.client_id
    JOIN properties p ON p.id = g.property_id
    WHERE g.gdo_number IN ('GDO-05180', 'GDO-08912', 'GDO-11433')
    ORDER BY g.gdo_number, g.id;
  `));
})().catch(e => console.error('FATAL', e));
