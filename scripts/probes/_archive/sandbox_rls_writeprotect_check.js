require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${SBX}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res(JSON.parse(b)));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
(async () => {
  // Is RLS even enabled on the 5 writable canonical tables?
  const tables = ['photos','photo_links','notes','vehicle_telemetry_readings','jobber_oversized_attachments'];
  console.log('=== RLS enabled state on writable canonical tables ===');
  const rls = await pg(`
    SELECT c.relname AS tbl, c.relrowsecurity AS rls_enabled, c.relforcerowsecurity AS rls_forced
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relname IN (${tables.map(t=>`'${t}'`).join(',')})
    ORDER BY c.relname;`);
  console.log(JSON.stringify(rls, null, 2));

  console.log('\n=== Effective write policies per table (anon, authenticated) ===');
  for (const t of tables) {
    const pols = await pg(`
      SELECT policyname, cmd, roles::text, qual, with_check
      FROM pg_policies
      WHERE schemaname='public' AND tablename='${t}'
        AND cmd IN ('INSERT','UPDATE','DELETE','ALL')
      ORDER BY policyname;`);
    console.log(`\n--- ${t} ---`);
    if (!pols.length) { console.log('  (no write policies → if RLS enabled, all writes denied)'); continue; }
    for (const p of pols) console.log(`  ${p.policyname}: cmd=${p.cmd} roles=${p.roles} qual=${p.qual||'-'} check=${p.with_check||'-'}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
