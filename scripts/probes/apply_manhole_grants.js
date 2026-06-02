require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX1 = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const FP = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;
function pg(sql, project) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${project}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({s: x.statusCode, b})); });
    req.on('error', rej);
    req.write(JSON.stringify({query: sql}));
    req.end();
  });
}
const sql = fs.readFileSync(require('path').resolve(__dirname, '../../docs/migrations/2026-05-15d_anon_update_manhole_columns.sql'), 'utf8');

(async () => {
  for (const [name, id] of [['Prod', PROD], ['Sandbox #1', SBX1], ['Field Portal', FP]]) {
    const r = await pg(sql, id);
    console.log(name + ': →', r.s, r.s >= 300 ? r.b.slice(0,200) : 'OK');
  }
  console.log('\n=== Verify column-level UPDATE grants on Prod ===');
  const v = await pg(`SELECT table_name, column_name FROM information_schema.column_privileges WHERE grantee='anon' AND table_schema='public' AND table_name IN ('visits','properties') AND privilege_type='UPDATE' ORDER BY table_name;`, PROD);
  console.log(v.b);
  console.log('\n=== anon-update RLS policies ===');
  const p = await pg(`SELECT tablename, policyname, cmd FROM pg_policies WHERE schemaname='public' AND tablename IN ('visits','properties') AND cmd='UPDATE' ORDER BY tablename;`, PROD);
  console.log(p.b);
})();
