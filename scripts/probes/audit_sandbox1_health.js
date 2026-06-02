// audit_sandbox1_health.js
// Focused audit: is Sandbox #1 healthy enough for the Admin Review App
// workflow given everything we changed in the last 24h?
//
// Checks:
//   1. Schema drift: Prod columns/tables NOT in Sandbox #1 (refresh will fail)
//   2. app_photo_classifications health (table, data, CHECK constraint)
//   3. RLS / anon access on the Admin Review App's read+write tables
//   4. End-to-end smoke test: the read pattern the Admin Review App uses
//   5. Any leftover 'completion' values that the new CHECK rejects
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX1 = process.env.SANDBOX_SUPABASE_PROJECT_ID;

function pg(sql, project) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${project}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({s: x.statusCode, b})); });
    req.on('error', rej);
    req.write(JSON.stringify({query: sql}));
    req.end();
  });
}
const j = (x) => { try { return JSON.parse(x); } catch { return x; } };

const REFRESH_TABLES = [
  'clients','properties','client_contacts','service_configs','jobs','visits',
  'visit_assignments','invoices','line_items','quotes','notes','photos','photo_links',
  'derm_manifests','manifest_visits','inspections','employees','vehicles',
  'vehicle_telemetry_readings','entity_source_links','jobber_oversized_attachments'
];

(async () => {
  console.log('='.repeat(72));
  console.log('Sandbox #1 health audit — Admin Review App readiness');
  console.log('='.repeat(72));

  // --- 1. SCHEMA DRIFT: Prod tables/columns missing in Sandbox #1 ---
  console.log('\n[1] Schema drift on REFRESH-LIST tables (will the next sandbox refresh fail?)\n');

  const prodColsRes = await pg(`
    SELECT table_name, column_name FROM information_schema.columns
    WHERE table_schema='public' AND table_name = ANY(ARRAY[${REFRESH_TABLES.map(t=>`'${t}'`).join(',')}])
    ORDER BY table_name, ordinal_position;
  `, PROD);
  const sbxColsRes = await pg(`
    SELECT table_name, column_name FROM information_schema.columns
    WHERE table_schema='public' AND table_name = ANY(ARRAY[${REFRESH_TABLES.map(t=>`'${t}'`).join(',')}])
    ORDER BY table_name, ordinal_position;
  `, SBX1);
  const prodCols = new Map();
  j(prodColsRes.b).forEach(r => { if (!prodCols.has(r.table_name)) prodCols.set(r.table_name, new Set()); prodCols.get(r.table_name).add(r.column_name); });
  const sbxCols = new Map();
  j(sbxColsRes.b).forEach(r => { if (!sbxCols.has(r.table_name)) sbxCols.set(r.table_name, new Set()); sbxCols.get(r.table_name).add(r.column_name); });

  const driftRows = [];
  for (const t of REFRESH_TABLES) {
    const p = prodCols.get(t) || new Set();
    const s = sbxCols.get(t) || new Set();
    const missing = [...p].filter(c => !s.has(c));
    if (missing.length) driftRows.push({ table: t, missing_in_sandbox: missing.join(', ') });
  }
  if (driftRows.length) {
    console.log('   ⚠️  Sandbox #1 is MISSING these columns Prod has → next refresh COPY will fail:');
    console.table(driftRows);
  } else {
    console.log('   ✓ No drift on canonical tables. Refresh will succeed schema-wise.');
  }

  // New canonical tables in Prod not in Sandbox #1?
  const prodTablesRes = await pg(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1;`, PROD);
  const sbxTablesRes = await pg(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1;`, SBX1);
  const prodT = new Set(j(prodTablesRes.b).map(r => r.table_name));
  const sbxT  = new Set(j(sbxTablesRes.b).map(r => r.table_name));
  const newProdTables = [...prodT].filter(t => !sbxT.has(t)).filter(t => !t.startsWith('_'));
  console.log('\n   New canonical tables in Prod NOT in Sandbox #1:');
  console.log('   ', newProdTables.length ? newProdTables.join(', ') : '(none)');
  console.log('   (These are NOT in REFRESH_TABLES so refresh ignores them. Only matters if Yannick needs them.)');

  // Sandbox-only tables (Yannick's app_* set)
  const yannickTables = [...sbxT].filter(t => !prodT.has(t)).filter(t => !t.startsWith('_'));
  console.log('\n   Yannick-only tables in Sandbox #1 (preserved through refresh):');
  console.log('   ', yannickTables.length ? yannickTables.join(', ') : '(none)');

  // --- 2. app_photo_classifications HEALTH ---
  console.log('\n[2] app_photo_classifications health\n');
  const apcExists = j((await pg(`SELECT COUNT(*)::int AS n FROM information_schema.tables WHERE table_schema='public' AND table_name='app_photo_classifications';`, SBX1)).b)[0].n;
  if (!apcExists) {
    console.log('   ❌ TABLE MISSING. Admin Review App is broken.');
  } else {
    const apcCols = j((await pg(`SELECT column_name, data_type, is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='app_photo_classifications' ORDER BY ordinal_position;`, SBX1)).b);
    console.table(apcCols);
    const dist = j((await pg(`SELECT service_phase, COUNT(*)::int AS n FROM app_photo_classifications GROUP BY service_phase ORDER BY n DESC;`, SBX1)).b);
    console.log('\n   service_phase distribution:');
    console.table(dist);
    if (dist.some(d => d.service_phase === 'completion')) {
      console.log('   ⚠️  Found legacy "completion" rows. Should have been migrated to "internal".');
    }
    const checkDef = j((await pg(`SELECT pg_get_constraintdef(oid) AS def FROM pg_constraint WHERE conrelid='public.app_photo_classifications'::regclass AND contype='c';`, SBX1)).b);
    console.log('\n   CHECK constraints:');
    console.log('   ', JSON.stringify(checkDef));
  }

  // --- 3. RLS on Admin Review App's tables ---
  console.log('\n[3] RLS / anon access on Admin Review App tables\n');
  const policies = j((await pg(`
    SELECT tablename, policyname, roles, cmd, qual
    FROM pg_policies
    WHERE schemaname='public' AND tablename IN ('app_photo_classifications','photo_links','photos','visits','clients')
    ORDER BY tablename, policyname;
  `, SBX1)).b);
  console.table(policies);

  const grants = j((await pg(`
    SELECT table_name, grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privs
    FROM information_schema.role_table_grants
    WHERE table_schema='public' AND grantee IN ('anon','authenticated','service_role')
      AND table_name IN ('app_photo_classifications','photo_links','photos','visits','clients')
    GROUP BY table_name, grantee
    ORDER BY table_name, grantee;
  `, SBX1)).b);
  console.table(grants);

  // --- 4. SMOKE TEST: simulate the Admin Review App's read pattern ---
  console.log('\n[4] Smoke test: Admin Review App read pattern on visit 1799 (199-JZ 2026-04-28, 14 classifications)\n');

  const smokeVisit = j((await pg(`SELECT id, visit_date, client_id FROM visits WHERE id=1799;`, SBX1)).b);
  console.log('   visit:', smokeVisit);
  const smokeLinks = j((await pg(`SELECT id, photo_id, role FROM photo_links WHERE entity_type='visit' AND entity_id=1799 LIMIT 3;`, SBX1)).b);
  console.log('   first 3 photo_links for visit:', smokeLinks);
  const smokeClass = j((await pg(`SELECT external_photo_link_id, service_phase FROM app_photo_classifications WHERE external_photo_link_id IN (SELECT id FROM photo_links WHERE entity_type='visit' AND entity_id=1799);`, SBX1)).b);
  console.log('   classifications for those photos:');
  console.table(smokeClass);

  // --- 5. Try inserting a test row + rollback to confirm the new CHECK works ---
  console.log('\n[5] Sanity: can the app save new enum values? (each test rolls back)\n');
  for (const phase of ['before','after','internal','extra','unknown','completion']) {
    const r = await pg(`BEGIN; INSERT INTO app_photo_classifications (external_photo_link_id, service_phase) VALUES (-1, '${phase}'); ROLLBACK;`, SBX1);
    const failureReason = r.s >= 300 ? r.b.match(/ERROR:\s+\d+\w*:\s+([^\\]+)/)?.[1] || 'unknown' : 'OK';
    console.log(`   ${phase.padEnd(12)}: ${r.s === 201 ? '✓ accepted' : `❌ rejected — ${failureReason}`}`);
  }

  // --- 6. Recommendations ---
  console.log('\n' + '='.repeat(72));
  console.log('Recommendations');
  console.log('='.repeat(72));
  if (driftRows.length) {
    console.log('\n   ⚠️  CRITICAL: Apply additive migration 14 (canonical column adds) to Sandbox #1');
    console.log('      BEFORE the next sandbox refresh, or the refresh COPY will fail.');
    console.log('      Run: docs/migrations/2026-05-14_field_portal_canonical_additions.sql against Sandbox #1.');
  }
  console.log('\n   Done.');
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
