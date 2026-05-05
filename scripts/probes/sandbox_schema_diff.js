// ============================================================================
// sandbox_schema_diff.js — list every schema element in Sandbox not in Prod
//
// Source-agnostic: doesn't care if Lovable, Viktor, or a human added it.
// Just reports what's different so you can decide what to promote.
//
// Output sections:
//   1. Tables in Sandbox missing from Production
//   2. Columns in Sandbox missing from Production (per canonical table)
//   3. Indexes in Sandbox missing from Production (per added/canonical table)
//   4. Views in Sandbox missing from Production
//   5. RLS status of new Sandbox tables (flag any without RLS)
//
// This is the INPUT to the (future) validator and extractor scripts.
// Read-only — no writes anywhere.
//
// Usage:
//   node scripts/probes/sandbox_schema_diff.js
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body); req.end();
  });
}
async function pg(projectId, sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${projectId}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;

const SQL = {
  tables: `SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1`,
  columns: (table) => `SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema='public' AND table_name='${table}' ORDER BY ordinal_position`,
  views: `SELECT viewname FROM pg_views WHERE schemaname='public' ORDER BY 1`,
  indexesForTables: (tableList) => `SELECT tablename, indexname, indexdef FROM pg_indexes WHERE schemaname='public' AND tablename IN (${tableList.map(t => `'${t}'`).join(',') || "''"}) ORDER BY tablename, indexname`,
  rls: (table) => `SELECT relrowsecurity AS enabled FROM pg_class WHERE relname='${table}' AND relnamespace=(SELECT oid FROM pg_namespace WHERE nspname='public')`,
  policies: (table) => `SELECT polname FROM pg_policy p JOIN pg_class c ON p.polrelid=c.oid WHERE c.relname='${table}'`,
};

const SECTION = (t) => console.log(`\n${'='.repeat(72)}\n${t}\n${'='.repeat(72)}`);

(async () => {
  if (!SBX) { console.error('SANDBOX_SUPABASE_PROJECT_ID not set in .env'); process.exit(2); }

  console.log(`Sandbox schema diff — ${new Date().toISOString()}`);
  console.log(`PROD: ${PROD}\nSBX:  ${SBX}`);

  // 1. TABLES
  SECTION('1. Tables in Sandbox missing from Production');
  const prodTables = new Set((await pg(PROD, SQL.tables)).map(r => r.table_name));
  const sbxTables = (await pg(SBX, SQL.tables)).map(r => r.table_name);
  const newTables = sbxTables.filter(t => !prodTables.has(t));
  console.log(`  ${newTables.length} new table(s) in Sandbox`);
  for (const t of newTables) console.log(`    + ${t}`);
  if (newTables.length === 0) console.log(`    (none — Sandbox tables match Production)`);

  // 2. COLUMNS per canonical table (i.e. tables that exist in BOTH)
  SECTION('2. Columns added to canonical tables in Sandbox');
  const sharedTables = sbxTables.filter(t => prodTables.has(t));
  let totalAddedCols = 0;
  for (const t of sharedTables) {
    const prodCols = new Set((await pg(PROD, SQL.columns(t))).map(c => c.column_name));
    const sbxCols = await pg(SBX, SQL.columns(t));
    const added = sbxCols.filter(c => !prodCols.has(c.column_name));
    if (added.length === 0) continue;
    console.log(`  ${t}: ${added.length} new column(s)`);
    for (const c of added) {
      const nullable = c.is_nullable === 'YES' ? 'NULL' : 'NOT NULL';
      const def = c.column_default ? ` DEFAULT ${c.column_default}` : '';
      console.log(`    + ${c.column_name} ${c.data_type} ${nullable}${def}`);
      totalAddedCols++;
    }
  }
  if (totalAddedCols === 0) console.log(`  (none — no Sandbox columns added to canonical tables)`);

  // 3. INDEXES on Sandbox-only tables OR new indexes on canonical tables
  SECTION('3. Indexes in Sandbox missing from Production');
  const allRelevantTables = [...newTables, ...sharedTables];
  if (allRelevantTables.length > 0) {
    const prodIdx = new Map(); // tablename → Set(indexname)
    for (const r of await pg(PROD, SQL.indexesForTables(sharedTables))) {
      if (!prodIdx.has(r.tablename)) prodIdx.set(r.tablename, new Set());
      prodIdx.get(r.tablename).add(r.indexname);
    }
    const sbxIdx = await pg(SBX, SQL.indexesForTables(allRelevantTables));
    const newIdx = sbxIdx.filter(i => {
      if (newTables.includes(i.tablename)) return true; // all indexes on new tables
      return !prodIdx.get(i.tablename)?.has(i.indexname);
    });
    if (newIdx.length === 0) console.log(`  (none)`);
    for (const i of newIdx) console.log(`  ${i.tablename}: + ${i.indexname}`);
  }

  // 4. VIEWS
  SECTION('4. Views in Sandbox missing from Production');
  const prodViews = new Set((await pg(PROD, SQL.views)).map(r => r.viewname));
  const sbxViews = (await pg(SBX, SQL.views)).map(r => r.viewname);
  const newViews = sbxViews.filter(v => !prodViews.has(v));
  if (newViews.length === 0) console.log(`  (none)`);
  for (const v of newViews) console.log(`  + ${v}`);

  // 5. RLS status of new Sandbox tables
  SECTION('5. RLS status of new Sandbox tables');
  if (newTables.length === 0) console.log(`  (no new tables to check)`);
  for (const t of newTables) {
    const rlsEnabled = (await pg(SBX, SQL.rls(t)))[0]?.enabled;
    const policies = await pg(SBX, SQL.policies(t));
    const status = rlsEnabled ? `RLS ON, ${policies.length} polic${policies.length === 1 ? 'y' : 'ies'}` : `❌ RLS OFF — VIOLATION`;
    console.log(`  ${t}: ${status}`);
  }

  // SUMMARY
  SECTION('SUMMARY');
  console.log(`  New tables:                ${newTables.length}`);
  console.log(`  Columns added on canonical:${totalAddedCols}`);
  console.log(`  New views:                 ${newViews.length}`);
  console.log(`
  Next steps:
    - If above is empty: Sandbox === Production schema, nothing to promote.
    - Otherwise: review each addition, run validator (TBD), extract migration.
  `);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
