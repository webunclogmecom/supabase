const fs = require('fs');
const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../../.env') });
const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
function pg(sql) { return new Promise((res, rej) => { const body = JSON.stringify({ query: sql }); const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>{try{res({status:r.statusCode,json:JSON.parse(d)})}catch(_){res({status:r.statusCode,raw:d})}})});req.on('error',rej);req.write(body);req.end();}); }
(async () => {
  console.log('--- APPLY 2026-05-25j ---');
  const sql = fs.readFileSync(path.resolve(__dirname, '../../../../docs/migrations/2026-05-25j_gdos_hardening.sql'), 'utf8');
  const a = await pg(sql);
  console.log('  status:', a.status, JSON.stringify(a.json || a.raw).slice(0, 200));

  console.log('\n--- VERIFY 1: Casa Neos GDOs ---');
  console.log((await pg(`SELECT id, gdo_number, status, notes FROM gdos WHERE property_id = 42 ORDER BY id;`)).json);

  console.log('\n--- VERIFY 2: property_id NOT NULL ---');
  console.log((await pg(`SELECT is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='gdos' AND column_name='property_id';`)).json);

  console.log('\n--- VERIFY 3: UNIQUE index in place ---');
  console.log((await pg(`SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename='gdos' ORDER BY indexname;`)).json);

  console.log('\n--- VERIFY 4: ACTIVE count is now 133 (was 135) ---');
  console.log((await pg(`SELECT COUNT(*) FILTER (WHERE status='ACTIVE')::int AS active, COUNT(*)::int AS total FROM gdos;`)).json);

  console.log('\n--- VERIFY 5: UNIQUE constraint rejects a 2nd active GDO for same property ---');
  const tryDup = await pg(`INSERT INTO gdos (client_id, gdo_number, property_id) VALUES (369, 'GDO-TEST123', 42) RETURNING id;`);
  console.log('  status:', tryDup.status);
  console.log('  result:', JSON.stringify(tryDup.json || tryDup.raw).slice(0, 200));

  console.log('\n--- VERIFY 6: audit rows captured for the 2 demotions ---');
  console.log((await pg(`
    SELECT changed_at::text, record_pk, operation, app_source,
           old_row->>'status' AS old_status, new_row->>'status' AS new_status
    FROM audit.logs
    WHERE table_name='gdos' AND changed_at > now() - INTERVAL '2 minutes'
    ORDER BY changed_at;
  `)).json);
})().catch(e => console.error('FATAL', e));
