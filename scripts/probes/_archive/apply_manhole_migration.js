// Apply add_manhole_count_2026_04_30.sql + verify.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const { newQuery } = require('../populate/lib/db');

(async () => {
  const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/add_manhole_count_2026_04_30.sql'), 'utf8');
  const stmts = sql
    .split(/;\s*$/m)
    .map(s => s.replace(/--.*$/gm, '').trim())
    .filter(s => s && !/^\s*BEGIN\s*$/i.test(s) && !/^\s*COMMIT\s*$/i.test(s));

  for (const s of stmts) {
    if (!s) continue;
    console.log('Running:', s.slice(0, 80).replace(/\s+/g, ' '));
    await newQuery(s + ';');
  }

  // Verify
  const r = await newQuery(`
    SELECT column_name, data_type, column_default, is_nullable
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='properties' AND column_name='grease_trap_manhole_count';
  `);
  console.log('\nVerification:', JSON.stringify(r, null, 2));

  const c = await newQuery(`
    SELECT
      COUNT(*) FILTER (WHERE grease_trap_manhole_count = 1)::int AS at_default,
      COUNT(*) FILTER (WHERE grease_trap_manhole_count > 1)::int AS multi_manhole,
      COUNT(*)::int AS total
    FROM properties;
  `);
  console.log('Distribution:', JSON.stringify(c[0]));

  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
