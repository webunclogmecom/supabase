const fs = require('fs');
const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../../.env') });
const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
function pg(sql) { return new Promise((res, rej) => { const body = JSON.stringify({ query: sql }); const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>{try{res({status:r.statusCode,json:JSON.parse(d)})}catch(_){res({status:r.statusCode,raw:d})}})});req.on('error',rej);req.write(body);req.end();}); }
(async () => {
  const sql = fs.readFileSync(path.resolve(__dirname, '../../../../docs/migrations/2026-05-25i_gdos_max_frequency_days.sql'), 'utf8');
  console.log('--- APPLY 2026-05-25i ---');
  const a = await pg(sql);
  console.log('  status:', a.status, JSON.stringify(a.json || a.raw).slice(0,200));

  console.log('\n--- VERIFY column shape ---');
  console.log((await pg(`SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='gdos' AND column_name='max_frequency_days';`)).json);

  console.log('\n--- VERIFY CHECK constraint exists ---');
  console.log((await pg(`SELECT conname FROM pg_constraint WHERE conname='gdos_max_frequency_days_positive';`)).json);

  console.log('\n--- VERIFY all 135 rows have NULL max_frequency_days (pre-backfill) ---');
  console.log((await pg(`SELECT COUNT(*) FILTER (WHERE max_frequency_days IS NULL)::int AS still_null, COUNT(*)::int AS total FROM gdos;`)).json);

  console.log('\n--- VERIFY CHECK works: try setting -5 on a sample row (should fail) ---');
  const tryNegative = await pg(`UPDATE gdos SET max_frequency_days = -5 WHERE id = (SELECT id FROM gdos LIMIT 1) RETURNING id;`);
  console.log('  status:', tryNegative.status);
  console.log('  result:', JSON.stringify(tryNegative.json || tryNegative.raw).slice(0,200));
})().catch(e => console.error('FATAL', e));
