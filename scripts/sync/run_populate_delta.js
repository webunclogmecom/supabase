// ============================================================================
// run_populate_delta.js — Phase 5 delta populate runner
// ============================================================================
// Reads which raw.jobber_pull_* tables have needs_populate=TRUE rows and runs
// the corresponding populate.js steps. Populate.js is idempotent and always
// processes the full raw.* table, so we don't need to surgically pass row IDs —
// we just run the right step(s), then clear the flags on success.
//
// Non-breaking: populate.js is untouched. This wrapper only orchestrates.
//
// Flags:
//   --dry-run  (default) show what would run, don't call populate.js
//   --execute  actually spawn populate.js --execute --confirm --step=N
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const { spawnSync } = require('child_process');
const path = require('path');
const { newQuery } = require('../populate/lib/db');

const args = process.argv.slice(2);
const DRY_RUN = !args.includes('--execute');

// raw table -> populate.js step number (see populate.js header comment)
const RAW_TO_STEP = {
  jobber_pull_clients:    1,
  jobber_pull_properties: 4,
  jobber_pull_jobs:       7,
  jobber_pull_invoices:   8,
  jobber_pull_line_items: 9,
  jobber_pull_visits:     10,
  jobber_pull_quotes:     6,
  jobber_pull_users:      2, // employees step merges jobber users
};

(async () => {
  console.log('='.repeat(70));
  console.log('run_populate_delta.js');
  console.log(`Mode: ${DRY_RUN ? 'DRY-RUN' : 'EXECUTE'}`);
  console.log('='.repeat(70));

  // Scan flag counts
  const counts = await newQuery(`
    SELECT 'jobber_pull_clients'    AS t, COUNT(*) FILTER (WHERE needs_populate) AS pending FROM raw.jobber_pull_clients
    UNION ALL SELECT 'jobber_pull_properties', COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_properties
    UNION ALL SELECT 'jobber_pull_jobs',       COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_jobs
    UNION ALL SELECT 'jobber_pull_visits',     COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_visits
    UNION ALL SELECT 'jobber_pull_invoices',   COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_invoices
    UNION ALL SELECT 'jobber_pull_quotes',     COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_quotes
    UNION ALL SELECT 'jobber_pull_line_items', COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_line_items
    UNION ALL SELECT 'jobber_pull_users',      COUNT(*) FILTER (WHERE needs_populate) FROM raw.jobber_pull_users;
  `);
  console.table(counts);

  const pending = counts.filter(r => Number(r.pending) > 0);
  if (pending.length === 0) {
    console.log('No flagged rows. Nothing to do.');
    return;
  }

  // Unique set of steps to run, sorted ascending to preserve FK dependency order
  const steps = [...new Set(pending.map(r => RAW_TO_STEP[r.t]).filter(Boolean))].sort((a, b) => a - b);
  console.log(`\nSteps to run: ${steps.join(', ')}`);

  if (DRY_RUN) {
    for (const s of steps) console.log(`  DRY-RUN: populate.js --step=${s} --execute --confirm`);
    console.log('\nRe-run with --execute to actually process.');
    return;
  }

  const populateJs = path.resolve(__dirname, '../populate/populate.js');
  for (const s of steps) {
    console.log(`\n--- populate.js --step=${s} ---`);
    const r = spawnSync('node', [populateJs, `--step=${s}`, '--execute', '--confirm'], {
      stdio: 'inherit',
      cwd: path.resolve(__dirname, '../..'),
    });
    if (r.status !== 0) {
      console.error(`Step ${s} FAILED with exit ${r.status}. Flags NOT cleared. Aborting.`);
      process.exit(1);
    }
  }

  // Clear flags on the tables we processed
  console.log('\nClearing needs_populate flags...');
  for (const row of pending) {
    await newQuery(`UPDATE raw.${row.t} SET needs_populate = FALSE WHERE needs_populate = TRUE;`);
  }
  console.log('Done.');
})();
