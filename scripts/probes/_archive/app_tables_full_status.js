// Full state-check on the app_* tables migration. Walks every step of the
// rollout and reports what's actually deployed in each project.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SB   = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT  = process.env.SUPABASE_PAT;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(project, sql) {
  for (let i = 0; i < 3; i++) {
    const r = await http({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${project}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
    }, JSON.stringify({ query: sql }));
    if (r.status < 300) return JSON.parse(r.body);
    if (r.status >= 500 || r.status === 429) { await new Promise(rs => setTimeout(rs, 4000 * (i+1))); continue; }
    throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  }
  throw new Error('5xx');
}

const SECTION = (n, t) => console.log(`\n${'='.repeat(72)}\n${n}. ${t}\n${'='.repeat(72)}`);

async function projectState(label, project) {
  console.log(`\n--- ${label} (${project}) ---`);

  // Tables
  const tables = await pg(project, `
    SELECT table_name FROM information_schema.tables
    WHERE table_schema='public'
      AND table_name IN ('app_visit_reviews','app_shift_reviews')
    ORDER BY table_name;
  `);
  console.log(`  Tables: ${tables.map(t => t.table_name).join(', ') || '(none)'}`);

  // Views
  const views = await pg(project, `
    SELECT viewname FROM pg_views
    WHERE schemaname='public' AND viewname IN ('visits_with_review','inspections_with_review')
    ORDER BY viewname;
  `);
  console.log(`  Views:  ${views.map(v => v.viewname).join(', ') || '(none)'}`);

  // CHECK constraints
  const checks = await pg(project, `
    SELECT conname, pg_get_constraintdef(oid) AS def
    FROM pg_constraint
    WHERE conrelid IN ('public.app_visit_reviews'::regclass, 'public.app_shift_reviews'::regclass)
      AND contype='c'
    ORDER BY conname;
  `);
  console.log(`  CHECK constraints (${checks.length}):`);
  for (const c of checks) console.log(`    ${c.conname}: ${c.def}`);

  // RLS policies
  const policies = await pg(project, `
    SELECT polrelid::regclass::text AS tbl, polname, polcmd,
      polroles::regrole[]::text[] AS roles
    FROM pg_policy
    WHERE polrelid IN ('public.app_visit_reviews'::regclass, 'public.app_shift_reviews'::regclass)
    ORDER BY polrelid::regclass::text, polname;
  `);
  console.log(`  RLS policies (${policies.length}):`);
  for (const p of policies) {
    const cmd = ({r:'SELECT',a:'INSERT',w:'UPDATE',d:'DELETE','*':'ALL'})[p.polcmd] || p.polcmd;
    console.log(`    ${p.tbl.padEnd(28)} ${p.polname.padEnd(45)} ${cmd.padEnd(7)} ${p.roles.join(',')}`);
  }

  // View definition (so we can see if it's the 3-way COALESCE override or basic Prod-compat)
  const viewDef = await pg(project, `SELECT pg_get_viewdef('public.visits_with_review'::regclass, true) AS def`);
  if (viewDef[0]?.def) {
    const has3WayCoalesce = /COALESCE.+v\.review_status/.test(viewDef[0].def);
    console.log(`  visits_with_review uses 3-way COALESCE (v.review_status fallback): ${has3WayCoalesce ? 'YES (Sandbox-style)' : 'no (Prod-style)'}`);
  }

  // Row counts + last activity
  const counts = await pg(project, `
    SELECT 'app_visit_reviews' AS t, COUNT(*) AS n,
      MAX(updated_at)::text AS last_updated
    FROM app_visit_reviews
    UNION ALL
    SELECT 'app_shift_reviews', COUNT(*),
      MAX(updated_at)::text
    FROM app_shift_reviews;
  `);
  console.log(`  Row counts:`);
  for (const c of counts) console.log(`    ${c.t.padEnd(20)} rows=${String(c.n).padStart(4)}  last_updated=${c.last_updated || '(never)'}`);

  // Verify view returns same row count as canonical
  const viewVerify = await pg(project, `
    SELECT
      (SELECT COUNT(*) FROM visits)               AS visits,
      (SELECT COUNT(*) FROM visits_with_review)   AS view_visits,
      (SELECT COUNT(*) FROM inspections)          AS inspections,
      (SELECT COUNT(*) FROM inspections_with_review) AS view_inspections;
  `);
  const v = viewVerify[0];
  const visMatch = v.visits === v.view_visits;
  const inspMatch = v.inspections === v.view_inspections;
  console.log(`  View row counts match canonical:`);
  console.log(`    visits ${v.visits} vs visits_with_review ${v.view_visits}: ${visMatch ? '✓' : '⚠️ mismatch'}`);
  console.log(`    inspections ${v.inspections} vs inspections_with_review ${v.view_inspections}: ${inspMatch ? '✓' : '⚠️ mismatch'}`);

  return { project, tables, views, counts };
}

(async () => {
  SECTION(1, 'Project-by-project deployment state');
  await projectState('PROD', PROD);
  await projectState('SANDBOX', SB);

  SECTION(2, 'Sandbox: 8 canonical review/bonus columns on visits (still present until cleanup)');
  const cols = await pg(SB, `
    SELECT column_name, data_type, column_default, is_nullable
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='visits'
      AND column_name IN ('review_status','reviewed_at','reviewed_by','bonus_status','bonus_decided_at','bonus_decided_by','bonus_denial_note','quality_flag_note')
    ORDER BY ordinal_position;
  `);
  console.log(`  ${cols.length} of 8 expected — present in Sandbox.visits:`);
  for (const c of cols) console.log(`    ${c.column_name.padEnd(20)} ${c.data_type.padEnd(28)} default=${c.column_default || '(none)'}  nullable=${c.is_nullable}`);

  SECTION(3, 'Sandbox: rows on canonical visits where review/bonus is non-default (= what the cleanup will copy)');
  const stillThere = await pg(SB, `
    SELECT id, visit_date::text, review_status, bonus_status, reviewed_by, bonus_decided_by
    FROM visits
    WHERE review_status <> 'pending' OR bonus_status <> 'pending'
       OR reviewed_at IS NOT NULL OR reviewed_by IS NOT NULL
       OR bonus_decided_at IS NOT NULL OR bonus_decided_by IS NOT NULL
       OR bonus_denial_note IS NOT NULL OR quality_flag_note IS NOT NULL
    ORDER BY id;
  `);
  console.log(`  ${stillThere.length} non-default rows on visits (should already be backfilled into app_visit_reviews):`);
  for (const r of stillThere) console.log(`    visit ${r.id}  date=${r.visit_date}  review=${r.review_status}  bonus=${r.bonus_status}`);

  SECTION(4, 'Sandbox: smoke-test view correctness for visit 1610');
  const v1610 = await pg(SB, `SELECT id, review_status, bonus_status, reviewed_at::text FROM visits_with_review WHERE id=1610`);
  console.log(`  ${JSON.stringify(v1610[0] || '(no row)')}`);

  SECTION(5, 'Sandbox refresh: would app_* tables survive the next refresh?');
  // sandbox_refresh.sh has a CANONICAL_TABLES list. Tables NOT in that list are untouched.
  // Just verifying the new tables aren't in the refresh's truncate list.
  const fs = require('fs');
  const refreshScript = fs.readFileSync(require('path').resolve(__dirname, '../sync/sandbox_refresh.sh'), 'utf8');
  const inCanonical = /app_visit_reviews|app_shift_reviews/.test(refreshScript);
  console.log(`  app_* tables referenced in sandbox_refresh.sh CANONICAL_TABLES list? ${inCanonical ? '⚠️ YES (would be wiped)' : '✓ no — safe across refresh'}`);

  SECTION(6, 'Lovable activity: have any UI writes hit app_* yet?');
  const today = await pg(SB, `
    SELECT 'app_visit_reviews' AS t, COUNT(*) AS rows_today, MAX(updated_at)::text AS latest
    FROM app_visit_reviews WHERE updated_at >= CURRENT_DATE
    UNION ALL
    SELECT 'app_shift_reviews', COUNT(*), MAX(updated_at)::text
    FROM app_shift_reviews WHERE updated_at >= CURRENT_DATE;
  `);
  for (const r of today) console.log(`  ${r.t.padEnd(20)} rows_today=${r.rows_today}  latest_today=${r.latest || '(none yet)'}`);

  SECTION(7, 'Cleanup migration ready check');
  const cleanupPath = require('path').resolve(__dirname, '../migrations/yannick_sandbox_cleanup_2026_05_05.sql');
  console.log(`  Cleanup file: ${cleanupPath}`);
  console.log(`  Exists: ${fs.existsSync(cleanupPath) ? '✓' : '⚠️ MISSING'}`);
  if (fs.existsSync(cleanupPath)) {
    const lines = fs.readFileSync(cleanupPath, 'utf8').split('\n').length;
    console.log(`  Lines: ${lines}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
