// Deploy app_* tables to Sandbox in correct order:
//   1. Main migration  (creates tables + views + RLS authenticated)
//   2. CHECK constraints (review/bonus enums)
//   3. Sandbox-only anon RLS (matches Option B pattern)
//   4. Sandbox-only view override (3-way COALESCE during transition)
//   5. Data backfill (visits.* → app_visit_reviews for non-default rows)
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs'); const path = require('path'); const https = require('https');

const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

const FILES = [
  ['scripts/migrations/yannick_app_tables_2026_05_05.sql',                      'Main migration: tables + views + authenticated RLS'],
  ['scripts/migrations/yannick_app_tables_check_constraints_2026_05_07.sql',    'CHECK constraints: review/bonus enums'],
  ['scripts/migrations/yannick_app_tables_sandbox_anon_2026_05_07.sql',         'Sandbox-only: anon RLS for app_* tables'],
  ['scripts/migrations/yannick_app_tables_sandbox_view_override_2026_05_07.sql','Sandbox-only: view override (3-way COALESCE)'],
  ['scripts/migrations/yannick_app_tables_backfill_2026_05_07.sql',             'Data backfill: visits.* → app_visit_reviews'],
];

async function pg(query) {
  for (let i = 0; i < 3; i++) {
    const r = await new Promise((res, rej) => {
      const req = https.request({
        hostname: 'api.supabase.com',
        path: `/v1/projects/${SB}/database/query`,
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
  console.log(`Deploying app_* migration set to SANDBOX (${SB})\n`);
  for (const [file, label] of FILES) {
    const sql = fs.readFileSync(path.resolve(__dirname, '../..', file), 'utf8');
    process.stdout.write(`  ${label} ... `);
    await pg(sql);
    console.log('✓');
  }

  console.log('\n--- Verification ---');

  const objs = await pg(`
    SELECT 'table' AS kind, table_name AS name FROM information_schema.tables
      WHERE table_schema='public' AND table_name IN ('app_visit_reviews','app_shift_reviews')
    UNION ALL
    SELECT 'view', viewname FROM pg_views
      WHERE schemaname='public' AND viewname IN ('visits_with_review','inspections_with_review')
    ORDER BY 1, 2;
  `);
  console.log('Objects:');
  for (const r of objs) console.log(`  ${r.kind}: public.${r.name}`);

  const counts = await pg(`
    SELECT 'app_visit_reviews'  AS t, COUNT(*)::int AS n FROM app_visit_reviews UNION ALL
    SELECT 'app_shift_reviews',     COUNT(*)::int    FROM app_shift_reviews UNION ALL
    SELECT 'visits_with_review',    COUNT(*)::int    FROM visits_with_review UNION ALL
    SELECT 'visits (canonical)',    COUNT(*)::int    FROM visits;
  `);
  console.log('\nRow counts:');
  for (const r of counts) console.log(`  ${r.t.padEnd(28)} ${r.n}`);

  const policies = await pg(`
    SELECT polname, polcmd, polroles::regrole[]::text[] AS roles
    FROM pg_policy
    WHERE polrelid IN ('public.app_visit_reviews'::regclass, 'public.app_shift_reviews'::regclass)
    ORDER BY polrelid::regclass::text, polname;
  `);
  console.log('\nRLS policies on app_* tables:');
  for (const p of policies) {
    const cmd = ({ r: 'SELECT', a: 'INSERT', w: 'UPDATE', d: 'DELETE', '*': 'ALL' })[p.polcmd] || p.polcmd;
    console.log(`  ${p.polname.padEnd(45)} ${cmd.padEnd(7)} roles=${p.roles.join(',')}`);
  }

  // Verify the view actually returns visit 1610 with the existing approved values via 3-way COALESCE
  const test = await pg(`
    SELECT id, review_status, bonus_status, reviewed_at::text, bonus_decided_at::text
    FROM visits_with_review WHERE id = 1610;
  `);
  console.log('\nSmoke test — visit 1610 (existing approved row):');
  for (const t of test) console.log(`  ${JSON.stringify(t)}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
