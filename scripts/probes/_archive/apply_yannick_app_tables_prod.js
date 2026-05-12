// Apply yannick_app_tables_2026_05_05.sql to Prod and verify.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/yannick_app_tables_2026_05_05.sql'), 'utf8');

async function pg(query) {
  for (let i = 0; i < 3; i++) {
    const r = await new Promise((res, rej) => {
      const req = https.request({
        hostname: 'api.supabase.com',
        path: `/v1/projects/${PROD}/database/query`,
        method: 'POST',
        headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
      }, x => { let b = ''; x.on('data', d => b += d); x.on('end', () => res({ status: x.statusCode, body: b })); });
      req.on('error', rej);
      req.write(JSON.stringify({ query }));
      req.end();
    });
    if (r.status < 300) return JSON.parse(r.body);
    if (r.status >= 500 || r.status === 429) {
      await new Promise(rs => setTimeout(rs, 4000 * (i + 1)));
      continue;
    }
    throw new Error(`PG ${r.status}: ${r.body.slice(0, 400)}`);
  }
  throw new Error('5xx exhausted');
}

(async () => {
  console.log(`Applying yannick_app_tables_2026_05_05.sql to PROD (${PROD})...`);
  await pg(sql);
  console.log('  ✓ migration applied\n');

  const objs = await pg(`
    SELECT 'table' AS kind, table_name AS name FROM information_schema.tables
      WHERE table_schema = 'public' AND table_name IN ('app_visit_reviews', 'app_shift_reviews')
    UNION ALL
    SELECT 'view', viewname FROM pg_views
      WHERE schemaname = 'public' AND viewname IN ('visits_with_review', 'inspections_with_review')
    ORDER BY 1, 2;
  `);
  console.log('  Objects created in Prod:');
  for (const r of objs) console.log(`    ${r.kind}: public.${r.name}`);

  const counts = await pg(`
    SELECT 'app_visit_reviews'        AS t, COUNT(*)::int AS n FROM app_visit_reviews UNION ALL
    SELECT 'app_shift_reviews',           COUNT(*)::int    FROM app_shift_reviews UNION ALL
    SELECT 'visits_with_review',          COUNT(*)::int    FROM visits_with_review UNION ALL
    SELECT 'inspections_with_review',     COUNT(*)::int    FROM inspections_with_review UNION ALL
    SELECT 'visits (canonical)',          COUNT(*)::int    FROM visits UNION ALL
    SELECT 'inspections (canonical)',     COUNT(*)::int    FROM inspections;
  `);
  console.log('\n  Row counts:');
  for (const r of counts) console.log(`    ${r.t.padEnd(28)} ${r.n}`);

  const policies = await pg(`
    SELECT polname, polcmd, polroles::regrole[]::text[] AS roles
    FROM pg_policy
    WHERE polrelid IN ('public.app_visit_reviews'::regclass, 'public.app_shift_reviews'::regclass)
    ORDER BY 1;
  `);
  console.log('\n  RLS policies on new tables:');
  for (const p of policies) {
    const cmd = ({ r: 'SELECT', a: 'INSERT', w: 'UPDATE', d: 'DELETE', '*': 'ALL' })[p.polcmd] || p.polcmd;
    console.log(`    ${p.polname.padEnd(40)} ${cmd.padEnd(7)} roles=${p.roles.join(',')}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
