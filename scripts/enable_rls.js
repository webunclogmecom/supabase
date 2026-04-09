/**
 * Enable Row Level Security (RLS) on all public tables in BOTH Supabase projects
 *
 * Why: Supabase flagged tables as publicly accessible via the anon key.
 * Fix: Enable + FORCE RLS so only service_role can read/write.
 *      No policies needed — service_role bypasses RLS by Supabase design,
 *      and we have no frontend / authenticated users to grant access to.
 *
 * Run: node scripts/enable_rls.js
 */

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });

const PAT = process.env.SUPABASE_PAT;
const NEW_PROJECT_ID = process.env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';
const OLD_PROJECT_ID = 'infbofuilnqqviyjlwul';

const RLS_SQL = `
DO $$
DECLARE
  tbl TEXT;
  schema_name TEXT;
BEGIN
  FOR schema_name, tbl IN
    SELECT schemaname, tablename
    FROM pg_tables
    WHERE schemaname IN ('public')
  LOOP
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY;', schema_name, tbl);
    EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY;', schema_name, tbl);
    RAISE NOTICE 'RLS enabled+forced on %.%', schema_name, tbl;
  END LOOP;
END $$;
`;

const VERIFY_SQL = `
SELECT
  n.nspname AS schemaname,
  c.relname AS tablename,
  c.relrowsecurity AS rls_enabled,
  c.relforcerowsecurity AS rls_forced
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname = 'public'
ORDER BY c.relname;
`;

async function runSQL(projectId, sql, label) {
  const url = `https://api.supabase.com/v1/projects/${projectId}/database/query`;
  const resp = await fetch(url, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${PAT}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ query: sql })
  });

  const text = await resp.text();
  if (!resp.ok) {
    console.error(`FAIL [${label}]: ${resp.status} ${text}`);
    return null;
  }

  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

async function fixProject(projectId, projectName) {
  console.log(`\n========================================`);
  console.log(`Fixing: ${projectName} (${projectId})`);
  console.log(`========================================\n`);

  console.log('Step 1: Enabling + forcing RLS on all public tables...');
  const result = await runSQL(projectId, RLS_SQL, `${projectName} ENABLE RLS`);
  if (result === null) {
    console.error(`Skipping verification — fix failed on ${projectName}`);
    return false;
  }
  console.log('Step 1 complete.\n');

  console.log('Step 2: Verifying RLS status on all tables...');
  const verifyResult = await runSQL(projectId, VERIFY_SQL, `${projectName} VERIFY`);
  if (verifyResult && Array.isArray(verifyResult)) {
    console.log(`\n${'TABLE'.padEnd(30)} ${'RLS'.padEnd(8)} ${'FORCED'.padEnd(8)}`);
    console.log('-'.repeat(50));
    let allGood = true;
    for (const row of verifyResult) {
      const rls = row.rls_enabled ? 'YES' : 'NO';
      const forced = row.rls_forced ? 'YES' : 'NO';
      console.log(`${row.tablename.padEnd(30)} ${rls.padEnd(8)} ${forced.padEnd(8)}`);
      if (!row.rls_enabled || !row.rls_forced) allGood = false;
    }
    console.log('-'.repeat(50));
    console.log(allGood ? '\nAll tables locked down.' : '\nWARNING: Some tables still unprotected!');
    return allGood;
  }
  return true;
}

async function main() {
  if (!PAT) {
    console.error('ERROR: SUPABASE_PAT not set in .env');
    process.exit(1);
  }

  console.log('Supabase RLS Fix — Locking down public tables');
  console.log('Strategy: ENABLE + FORCE RLS, no policies (service_role only)');

  const newOk = await fixProject(NEW_PROJECT_ID, 'Dev - Unclogme (NEW)');
  const oldOk = await fixProject(OLD_PROJECT_ID, 'Dev - Database (OLD)');

  console.log(`\n========================================`);
  console.log(`SUMMARY`);
  console.log(`========================================`);
  console.log(`New project: ${newOk ? 'FIXED' : 'FAILED'}`);
  console.log(`Old project: ${oldOk ? 'FIXED' : 'FAILED'}`);
  console.log();

  if (newOk && oldOk) {
    console.log('Both projects locked down. Sync scripts (using service_role) continue to work.');
    console.log('Public anon key now returns empty for all queries.');
  }
}

main().catch(err => {
  console.error('FATAL:', err);
  process.exit(1);
});
