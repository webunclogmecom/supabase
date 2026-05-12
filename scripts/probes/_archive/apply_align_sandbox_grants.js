// Apply align_sandbox_canonical_grants_2026_05_11.sql to Sandbox.
// Then verify the resulting GRANT state matches the intended end-state.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');

const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${SBX}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({status: x.statusCode, body: b})); });
    req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
  });
}

(async () => {
  const sqlPath = path.resolve(__dirname, '../migrations/align_sandbox_canonical_grants_2026_05_11.sql');
  const sql = fs.readFileSync(sqlPath, 'utf8');
  console.log(`Applying ${path.basename(sqlPath)} to Sandbox (${SBX})...`);
  const r = await pg(sql);
  if (r.status >= 300) {
    console.error('FAILED:', r.status, r.body.slice(0, 500));
    process.exit(2);
  }
  console.log('  ✓ migration applied');

  // Verify
  console.log('\nPost-migration GRANT state on the 5 tables:');
  const verify = await pg(`
    SELECT table_name, grantee, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privs
    FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND grantee IN ('anon', 'authenticated', 'service_role')
      AND table_name IN ('photos','photo_links','notes','vehicle_telemetry_readings','jobber_oversized_attachments')
    GROUP BY table_name, grantee
    ORDER BY table_name, grantee;`);
  const rows = JSON.parse(verify.body);
  console.log('  table_name                  | grantee        | privs');
  console.log('  ' + '-'.repeat(85));
  for (const r of rows) {
    console.log(`  ${r.table_name.padEnd(27)} | ${r.grantee.padEnd(14)} | ${r.privs}`);
  }

  // Sanity-check: confirm anon has SELECT-only and authenticated has SELECT (+INSERT on photo_links only)
  console.log('\n=== Validation ===');
  const anonExpected = { photos: ['SELECT'], photo_links: ['SELECT'], notes: ['SELECT'], vehicle_telemetry_readings: ['SELECT'], jobber_oversized_attachments: ['SELECT'] };
  const authExpected = { photos: ['SELECT'], photo_links: ['INSERT', 'SELECT'], notes: ['SELECT'], vehicle_telemetry_readings: ['SELECT'], jobber_oversized_attachments: ['SELECT'] };
  let fail = 0;
  for (const r of rows) {
    if (r.grantee === 'service_role') continue;
    const expected = r.grantee === 'anon' ? anonExpected[r.table_name] : authExpected[r.table_name];
    const got = r.privs.split(', ').sort();
    if (JSON.stringify(got) !== JSON.stringify(expected)) {
      console.log(`  ✗ ${r.grantee} on ${r.table_name}: expected ${expected.join(',')} got ${got.join(',')}`);
      fail++;
    }
  }
  if (fail === 0) console.log('  ✓ all 10 (anon×5 + auth×5) grant rows match expected end-state');
  else { console.error(`  ${fail} mismatches`); process.exit(2); }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
