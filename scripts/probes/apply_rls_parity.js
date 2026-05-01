// Apply rls_parity_with_sandbox_2026_04_30.sql to Production.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const PROJECT_ID = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,800)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('=== BEFORE — Production tables with zero policies ===');
  console.table(await q(`
    SELECT c.relname AS table_name
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity
      AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname='public' AND p.tablename=c.relname)
    ORDER BY c.relname;
  `));

  const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/rls_parity_with_sandbox_2026_04_30.sql'), 'utf8');
  console.log('\n=== Applying migration ===');
  await q(sql);
  console.log('  ✓ committed');

  console.log('\n=== AFTER — Production tables with zero policies ===');
  console.table(await q(`
    SELECT c.relname AS table_name
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind='r' AND c.relrowsecurity
      AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname='public' AND p.tablename=c.relname)
    ORDER BY c.relname;
  `));

  console.log('\n=== Production: anon-key reads on photos / photo_links / employees now ===');
  // verify employees no longer anon-readable
  console.table(await q(`
    SELECT tablename, policyname, cmd, array_to_string(roles,',') AS roles
    FROM pg_policies WHERE schemaname='public'
      AND tablename IN ('employees','photos','photo_links','notes')
    ORDER BY tablename, policyname;
  `));

  console.log('\n=== Storage policies on GT - Visits Images (Production) ===');
  console.table(await q(`
    SELECT policyname, cmd, array_to_string(roles,',') AS roles
    FROM pg_policies WHERE schemaname='storage' AND tablename='objects'
    ORDER BY policyname;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
