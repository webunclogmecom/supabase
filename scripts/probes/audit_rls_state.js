// Audit RLS state on PRODUCTION — find tables with RLS enabled but no
// policies, and tables with RLS disabled. Compare to what Yannick fixed in
// Sandbox.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const target = (process.argv.find(a => a.startsWith('--target=')) || '--target=main').split('=')[1];
const projectId = target === 'sandbox'
  ? process.env.SANDBOX_SUPABASE_PROJECT_ID
  : process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${projectId}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log(`[target=${target}] project=${projectId}\n`);

  console.log('=== RLS state per public table ===');
  console.table(await q(`
    SELECT
      c.relname AS table_name,
      c.relrowsecurity AS rls_enabled,
      c.relforcerowsecurity AS force_rls,
      (SELECT COUNT(*) FROM pg_policies p
        WHERE p.schemaname='public' AND p.tablename=c.relname) AS policy_count
    FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind='r'
    ORDER BY c.relname;
  `));

  console.log('\n=== Tables with RLS enabled but ZERO policies (effectively locked) ===');
  console.table(await q(`
    SELECT c.relname AS table_name
    FROM pg_class c
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity
      AND NOT EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname='public' AND p.tablename=c.relname
      )
    ORDER BY c.relname;
  `));

  console.log('\n=== Storage bucket policies (objects) ===');
  console.table(await q(`
    SELECT policyname, cmd, roles, permissive, qual, with_check
    FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
    ORDER BY policyname;
  `));

  console.log('\n=== All public-table policies (what existing roles can do) ===');
  console.table(await q(`
    SELECT tablename, policyname, cmd, roles
    FROM pg_policies
    WHERE schemaname='public'
    ORDER BY tablename, policyname;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
