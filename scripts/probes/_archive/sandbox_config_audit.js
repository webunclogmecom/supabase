// Pre-change audit of Sandbox configuration. Run BEFORE proposing any
// permission changes so we know exactly what state we're starting from
// and don't break anything Lovable legitimately needs.
//
// Checks:
//   1. Role-table privileges on canonical tables (what anon/authenticated CAN do today)
//   2. Column-level privileges (already in place?)
//   3. _prod_schema_baseline content (what does refresh think is canonical?)
//   4. Per-table write activity since last refresh (who's been writing what?)
//   5. Recent app_* table data (what's Lovable actually persisting?)
//   6. Storage buckets in Sandbox
//   7. Tables I might have missed
//   8. RLS policy details on canonical tables Lovable might write to

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql, projectId) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${projectId}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(JSON.parse(b))); });
    req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
  });
}

const banner = (s) => console.log('\n' + '─'.repeat(70) + '\n  ' + s + '\n' + '─'.repeat(70));

(async () => {
  // -------------------------------------------------------------------------
  banner('1. CANONICAL TABLES — current role-table privileges');
  // -------------------------------------------------------------------------
  const tablePrivs = await pg(`
    SELECT table_name, grantee, privilege_type
    FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND grantee IN ('anon', 'authenticated', 'service_role')
      AND table_name IN (
        'clients','properties','client_contacts','service_configs','jobs','visits',
        'visit_assignments','invoices','line_items','quotes','notes','photos',
        'photo_links','derm_manifests','manifest_visits','inspections','employees',
        'vehicles','vehicle_telemetry_readings','entity_source_links','jobber_oversized_attachments'
      )
    ORDER BY table_name, grantee, privilege_type;`, SBX);

  // Pivot: one row per (table, grantee), with privileges as a list
  const pivot = {};
  for (const r of tablePrivs) {
    const k = `${r.table_name}\t${r.grantee}`;
    pivot[k] = (pivot[k] || []).concat(r.privilege_type);
  }
  console.log('  table_name              | grantee           | privileges');
  console.log('  ' + '-'.repeat(75));
  for (const [k, privs] of Object.entries(pivot).sort()) {
    const [t, g] = k.split('\t');
    console.log(`  ${t.padEnd(23)} | ${g.padEnd(17)} | ${privs.sort().join(', ')}`);
  }

  // -------------------------------------------------------------------------
  banner('2. CANONICAL TABLES — any COLUMN-level privileges already in place?');
  // -------------------------------------------------------------------------
  const colPrivs = await pg(`
    SELECT table_name, column_name, grantee, privilege_type
    FROM information_schema.column_privileges
    WHERE table_schema = 'public'
      AND grantee IN ('anon', 'authenticated', 'service_role')
    ORDER BY table_name, column_name, grantee;`, SBX);
  if (!colPrivs.length) {
    console.log('  (no column-level privileges currently set anywhere — all grants are table-wide)');
  } else {
    console.log(`  ${colPrivs.length} column-level grants exist:`);
    for (const r of colPrivs.slice(0, 50)) {
      console.log(`    ${r.table_name}.${r.column_name}  ${r.grantee}  ${r.privilege_type}`);
    }
    if (colPrivs.length > 50) console.log(`    ...and ${colPrivs.length - 50} more`);
  }

  // -------------------------------------------------------------------------
  banner('3. APP_* TABLES — current privileges (these SHOULD allow anon writes)');
  // -------------------------------------------------------------------------
  const appPrivs = await pg(`
    SELECT table_name, grantee, privilege_type
    FROM information_schema.role_table_grants
    WHERE table_schema = 'public'
      AND grantee IN ('anon', 'authenticated', 'service_role')
      AND table_name LIKE 'app_%'
    ORDER BY table_name, grantee, privilege_type;`, SBX);
  const appPivot = {};
  for (const r of appPrivs) {
    const k = `${r.table_name}\t${r.grantee}`;
    appPivot[k] = (appPivot[k] || []).concat(r.privilege_type);
  }
  for (const [k, privs] of Object.entries(appPivot).sort()) {
    const [t, g] = k.split('\t');
    console.log(`  ${t.padEnd(23)} | ${g.padEnd(17)} | ${privs.sort().join(', ')}`);
  }

  // -------------------------------------------------------------------------
  banner('4. _prod_schema_baseline — what does refresh consider canonical?');
  // -------------------------------------------------------------------------
  const baseline = await pg(`
    SELECT table_name, COUNT(*) AS n_cols,
      MIN(recorded_at) AS earliest, MAX(recorded_at) AS latest
    FROM _prod_schema_baseline
    GROUP BY table_name ORDER BY table_name;`, SBX);
  console.log(`  ${baseline.length} canonical tables tracked, ${baseline.reduce((s,r)=>s+Number(r.n_cols),0)} total cols`);
  if (baseline.length) {
    console.log(`  Most recent baseline timestamp: ${baseline[0].latest}`);
  }

  // -------------------------------------------------------------------------
  banner('5. Write activity since last stats reset — who has been writing to what?');
  // -------------------------------------------------------------------------
  const writes = await pg(`
    SELECT relname, n_tup_ins, n_tup_upd, n_tup_del,
      n_live_tup, n_dead_tup,
      to_char(last_vacuum, 'YYYY-MM-DD HH24:MI:SS') AS last_vacuum,
      to_char(last_analyze, 'YYYY-MM-DD HH24:MI:SS') AS last_analyze
    FROM pg_stat_user_tables
    WHERE schemaname='public'
      AND (n_tup_ins > 0 OR n_tup_upd > 0 OR n_tup_del > 0)
    ORDER BY (n_tup_ins + n_tup_upd + n_tup_del) DESC
    LIMIT 30;`, SBX);
  console.log(`  table_name                  | ins      | upd      | del      | live      | dead`);
  console.log('  ' + '-'.repeat(80));
  for (const r of writes) {
    console.log(`  ${r.relname.padEnd(27)} | ${String(r.n_tup_ins).padStart(8)} | ${String(r.n_tup_upd).padStart(8)} | ${String(r.n_tup_del).padStart(8)} | ${String(r.n_live_tup).padStart(9)} | ${String(r.n_dead_tup).padStart(8)}`);
  }
  console.log('\n  ⚠ Note: pg_stat counters accumulate since last RESET. Refresh TRUNCATEs but');
  console.log('    truncate counts don\'t appear here. UPDATEs on canonical tables are still telling.');

  // -------------------------------------------------------------------------
  banner('6. Storage buckets in Sandbox');
  // -------------------------------------------------------------------------
  const buckets = await pg(`
    SELECT id, name, public, created_at, updated_at, file_size_limit
    FROM storage.buckets ORDER BY created_at;`, SBX);
  for (const b of buckets) {
    console.log(`  ${b.name.padEnd(40)} public=${b.public}  size_limit=${b.file_size_limit||'∞'}  created=${b.created_at.slice(0,10)}`);
  }
  if (!buckets.length) console.log('  (no buckets)');

  // Storage objects per bucket (rough usage)
  const bucketUsage = await pg(`
    SELECT bucket_id, COUNT(*) AS n_objs, ROUND(SUM(COALESCE((metadata->>'size')::bigint, 0))::numeric/1024/1024, 1) AS mb
    FROM storage.objects GROUP BY bucket_id ORDER BY n_objs DESC;`, SBX);
  console.log('\n  Storage object usage per bucket:');
  for (const r of bucketUsage) console.log(`    ${r.bucket_id.padEnd(40)} ${r.n_objs} objects, ${r.mb} MB`);

  // -------------------------------------------------------------------------
  banner('7. All public tables (sanity check for anything I missed)');
  // -------------------------------------------------------------------------
  const allTables = await pg(`
    SELECT t.table_name,
      (SELECT COUNT(*) FROM information_schema.columns c
        WHERE c.table_schema='public' AND c.table_name=t.table_name) AS n_cols
    FROM information_schema.tables t
    WHERE t.table_schema='public' AND t.table_type='BASE TABLE'
    ORDER BY t.table_name;`, SBX);
  console.log(`  ${allTables.length} tables total`);
  for (const r of allTables) {
    const flag = /^app_|^_/.test(r.table_name) ? ' ★' : '';
    console.log(`    ${r.table_name.padEnd(35)} ${String(r.n_cols).padStart(3)} cols${flag}`);
  }

  // -------------------------------------------------------------------------
  banner('8. RLS policies on photo_links (the table Lovable was about to overload)');
  // -------------------------------------------------------------------------
  const phPolicies = await pg(`
    SELECT policyname, cmd, roles, qual, with_check
    FROM pg_policies
    WHERE schemaname='public' AND tablename='photo_links'
    ORDER BY policyname;`, SBX);
  for (const p of phPolicies) {
    console.log(`  ${p.policyname}`);
    console.log(`    cmd=${p.cmd}  roles=${p.roles}`);
    console.log(`    qual: ${p.qual || '(none)'}`);
    console.log(`    with_check: ${p.with_check || '(none)'}`);
  }

  // -------------------------------------------------------------------------
  banner('9. Recent app_visit_reviews + app_shift_reviews rows');
  // -------------------------------------------------------------------------
  const reviews = await pg(`SELECT * FROM app_visit_reviews ORDER BY updated_at DESC NULLS LAST LIMIT 5;`, SBX);
  console.log('  app_visit_reviews recent:');
  for (const r of reviews) console.log(`    ${JSON.stringify(r)}`);
  const shifts = await pg(`SELECT * FROM app_shift_reviews ORDER BY updated_at DESC NULLS LAST LIMIT 5;`, SBX);
  console.log('\n  app_shift_reviews recent:');
  for (const r of shifts) console.log(`    ${JSON.stringify(r)}`);

  // -------------------------------------------------------------------------
  banner('10. SUMMARY for change planning');
  // -------------------------------------------------------------------------
  const canonWrites = {};
  for (const [k, privs] of Object.entries(pivot)) {
    const [t, g] = k.split('\t');
    if (g === 'service_role') continue;
    const writes = privs.filter(p => ['INSERT','UPDATE','DELETE'].includes(p));
    if (writes.length) canonWrites[`${t} (${g})`] = writes;
  }
  console.log(`  CANONICAL tables where anon/authenticated currently has write access:`);
  for (const [k, w] of Object.entries(canonWrites).sort()) {
    console.log(`    ${k}: ${w.join(', ')}`);
  }
  console.log(`\n  These are the grants we'd revoke and replace with column-level grants for Yannick-added columns.`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
