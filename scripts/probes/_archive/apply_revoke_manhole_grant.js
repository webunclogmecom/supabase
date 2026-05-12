require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs'); const path = require('path'); const https = require('https');
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${SBX}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res({status:x.statusCode,body:b}));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
(async () => {
  const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/revoke_lingering_manhole_grant_2026_05_11.sql'), 'utf8');
  const r = await pg(sql);
  if (r.status >= 300) { console.error('FAILED:', r.status, r.body.slice(0, 300)); process.exit(2); }
  console.log('✓ Revoke migration applied');

  const verify = await pg(`
    SELECT grantee, column_name, privilege_type FROM information_schema.column_privileges
    WHERE table_schema='public' AND table_name='properties'
      AND grantee IN ('anon','authenticated') AND privilege_type IN ('UPDATE','INSERT','DELETE');`);
  const rows = JSON.parse(verify.body);
  if (rows.length === 0) console.log('✓ Verified: 0 anon/auth write grants on properties columns');
  else { console.log('⚠ Still present:', JSON.stringify(rows, null, 2)); process.exit(2); }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
