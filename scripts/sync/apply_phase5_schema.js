// Apply Phase 5 schema migration via Supabase Management API.
// Idempotent. Safe to re-run.
const fs = require('fs');
const path = require('path');
const { newQuery } = require('../populate/lib/db');

(async () => {
  const sql = fs.readFileSync(path.join(__dirname, '01_phase5_schema.sql'), 'utf8');
  console.log('Applying Phase 5 schema migration...');
  const r = await newQuery(sql);
  console.log('Result:', JSON.stringify(r).slice(0, 400));

  // Verify
  const cursors = await newQuery('SELECT entity, last_synced_at, last_run_status FROM public.sync_cursors ORDER BY entity;');
  console.log('\nsync_cursors:');
  console.table(cursors);

  const cols = await newQuery(`
    SELECT table_name, column_name
    FROM information_schema.columns
    WHERE table_schema='raw'
      AND column_name IN ('ingested_at','needs_populate')
    ORDER BY table_name, column_name;
  `);
  console.log(`\nFlag columns added: ${cols.length} (expect 16 = 8 tables * 2 cols)`);
})();
