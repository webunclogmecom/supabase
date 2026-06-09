// Pick 10 broader samples (3 Casa Neos already known + 7 diverse)
const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });
const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
function pg(sql) { return new Promise((res, rej) => { const body = JSON.stringify({ query: sql }); const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>{try{res(JSON.parse(d))}catch(_){res(d)}})});req.on('error',rej);req.write(body);req.end();}); }
(async () => {
  console.log('--- 7 simple GDOs (diverse, single-tenant) ---');
  console.log(await pg(`
    SELECT g.id, g.gdo_number, c.client_code, c.name AS client_name,
           p.address, p.zip, g.permit_expiration::text
    FROM gdos g
    JOIN clients c ON c.id = g.client_id
    JOIN properties p ON p.id = g.property_id
    WHERE g.status = 'ACTIVE'
      AND g.property_id NOT IN (SELECT property_id FROM gdos GROUP BY property_id HAVING COUNT(*) > 1)
      AND p.address IS NOT NULL
      AND c.status IN ('ACTIVE','RECURRING')
      AND g.id NOT IN (63, 64, 65, 66, 85, 29, 102, 7, 104)  -- not Casa Neos or typo pairs
    ORDER BY random()
    LIMIT 7;
  `));
})().catch(e => console.error('FATAL', e));
