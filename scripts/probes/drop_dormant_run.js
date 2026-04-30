// Run the drop_dormant_tables migration and verify each table is gone.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const { newQuery } = require('../populate/lib/db');

(async () => {
  const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/drop_dormant_tables_2026_04_30.sql'), 'utf8');

  // Strip comments, run statements one-by-one
  const stmts = sql
    .split(/;\s*\n/)
    .map(s => s.replace(/--.*$/gm, '').trim())
    .filter(s => s && !/^\s*BEGIN\s*$/i.test(s) && !/^\s*COMMIT\s*$/i.test(s));

  for (const s of stmts) {
    if (!s) continue;
    console.log(`Running: ${s.slice(0, 80)}...`);
    await newQuery(s + ';');
  }

  // Verify
  const dormant = ['routes', 'route_stops', 'receivables', 'leads', 'expenses'];
  const r = await newQuery(`
    SELECT table_name FROM information_schema.tables
    WHERE table_schema='public' AND table_name = ANY(ARRAY['routes','route_stops','receivables','leads','expenses']);
  `);
  const stillThere = r.map(x => x.table_name);

  console.log('\nVerification:');
  for (const t of dormant) {
    if (stillThere.includes(t)) console.log(`  ❌ ${t} STILL PRESENT — drop did not take effect`);
    else console.log(`  ✅ ${t} dropped successfully`);
  }
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
