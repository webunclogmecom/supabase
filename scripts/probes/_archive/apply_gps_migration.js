// Apply add_gps_to_telemetry_2026_04_30.sql and verify each change took effect.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const { newQuery } = require('../populate/lib/db');

(async () => {
  const sql = fs.readFileSync(path.resolve(__dirname, '../migrations/add_gps_to_telemetry_2026_04_30.sql'), 'utf8');

  // Split on `;` at end of line, strip BEGIN/COMMIT (newQuery handles its own tx) + comments
  const stmts = sql
    .split(/;\s*$/m)
    .map(s => s.replace(/--.*$/gm, '').trim())
    .filter(s => s && !/^\s*BEGIN\s*$/i.test(s) && !/^\s*COMMIT\s*$/i.test(s));

  for (const s of stmts) {
    if (!s) continue;
    const head = s.slice(0, 80).replace(/\s+/g, ' ');
    console.log(`Running: ${head}...`);
    try {
      await newQuery(s + ';');
    } catch (e) {
      // 'already exists' on column/constraint is fine for ADD ... IF NOT EXISTS
      if (/already exists/i.test(e.message)) {
        console.log(`  (already in place — skipping)`);
        continue;
      }
      throw e;
    }
  }

  // Verify columns exist
  console.log('\nVerification:');
  const cols = await newQuery(`
    SELECT column_name, data_type, is_nullable
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='vehicle_telemetry_readings'
    ORDER BY ordinal_position;
  `);
  for (const c of cols) console.log(`  ${c.column_name.padEnd(28)} ${c.data_type}  null=${c.is_nullable}`);

  // Verify unique constraint
  const uniq = await newQuery(`
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.vehicle_telemetry_readings'::regclass AND contype = 'u';
  `);
  console.log(`\nUnique constraints: ${uniq.map(x => x.conname).join(', ') || '(none)'}`);

  // Verify view
  const view = await newQuery(`
    SELECT viewname FROM pg_views WHERE schemaname='public' AND viewname='v_vehicle_telemetry_latest';
  `);
  console.log(`View v_vehicle_telemetry_latest: ${view.length ? 'exists' : 'MISSING'}`);

  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
