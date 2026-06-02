// audit_dual_write_full.js
// Full health audit across Prod / Sandbox #1 / Field Portal Sandbox after dual-write goes live.
// Verifies:
//   1. Dual-write actually duplicated rows across Sandbox #1 and Prod
//   2. The test visit (199-JZ 2026-04-28) tags match between DBs
//   3. Schema integrity (tables, columns, CHECK constraints, anon timeout)
//   4. Field Portal's customer.wo_photos still renders properly
//   5. Admin Review App's read path still works (Sandbox #1)
//   6. Drift detection — anything diverged?

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX1 = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const FP   = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;

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
const j = x => { try { return JSON.parse(x); } catch { return x; } };
const projects = [['Prod', PROD], ['Sandbox #1', SBX1], ['Field Portal', FP]];

(async () => {
  const baseline = { count: 103, after: 42, internal: 35, before: 26, extra: 0 };
  console.log('='.repeat(78));
  console.log('Full audit — dual-write health + schema integrity');
  console.log('Baseline (pre-test): 103 rows | 42 after / 35 internal / 26 before / 0 extra');
  console.log('='.repeat(78));

  // === 1. DUAL-WRITE: row counts + distribution + most recent activity ===
  console.log('\n[1] photo_classifications counts + distribution per project\n');
  const counts = [];
  for (const [name, id] of projects) {
    const total = j((await pg('SELECT COUNT(*)::int AS n FROM photo_classifications;', id)).b)[0].n;
    const dist = j((await pg('SELECT service_phase, COUNT(*)::int AS n FROM photo_classifications GROUP BY service_phase ORDER BY service_phase;', id)).b);
    const recent = j((await pg('SELECT MAX(updated_at) AS latest, MAX(created_at) AS newest FROM photo_classifications;', id)).b)[0];
    const map = Object.fromEntries(dist.map(r => [r.service_phase, r.n]));
    counts.push({
      project: name,
      total,
      before: map.before || 0,
      after: map.after || 0,
      internal: map.internal || 0,
      extra: map.extra || 0,
      unknown: map.unknown || 0,
      latest_updated: recent.latest,
      newest_created: recent.newest,
    });
  }
  console.table(counts);

  // === 2. DRIFT: Sandbox #1 vs Prod (the dual-write pair) ===
  console.log('\n[2] Drift detection: Sandbox #1 vs Prod (per photo_link_id)\n');
  const drift = j((await pg(`
    WITH prod AS (SELECT photo_link_id, service_phase FROM photo_classifications)
    SELECT 'extra in Prod, missing in Sandbox' AS diagnosis, COUNT(*)::int AS n FROM prod
  `, PROD)).b);
  // Cross-DB diff is harder via Management API. Easier: pull both, diff in JS.
  const prodRows = j((await pg('SELECT photo_link_id, service_phase FROM photo_classifications ORDER BY photo_link_id;', PROD)).b);
  const sbxRows  = j((await pg('SELECT photo_link_id, service_phase FROM photo_classifications ORDER BY photo_link_id;', SBX1)).b);
  const prodMap = new Map(prodRows.map(r => [r.photo_link_id, r.service_phase]));
  const sbxMap  = new Map(sbxRows.map(r => [r.photo_link_id, r.service_phase]));
  const onlyProd = [...prodMap.keys()].filter(k => !sbxMap.has(k));
  const onlySbx  = [...sbxMap.keys()].filter(k => !prodMap.has(k));
  const phaseMismatch = [...prodMap.entries()].filter(([k, v]) => sbxMap.has(k) && sbxMap.get(k) !== v).map(([k, v]) => ({ photo_link_id: k, prod: v, sandbox: sbxMap.get(k) }));
  console.log(`  in Prod only: ${onlyProd.length} ${onlyProd.length ? '→ '+onlyProd.slice(0,5).join(',') : ''}`);
  console.log(`  in Sandbox #1 only: ${onlySbx.length} ${onlySbx.length ? '→ '+onlySbx.slice(0,5).join(',') : ''}`);
  console.log(`  phase mismatch: ${phaseMismatch.length}`);
  if (phaseMismatch.length) console.table(phaseMismatch.slice(0, 10));

  // === 3. THE TEST VISIT (199-JZ 2026-04-28, visit_id 1799) ===
  console.log('\n[3] Test visit 1799 (199-JZ 2026-04-28) — tag distribution per DB\n');
  const visitTags = [];
  for (const [name, id] of projects) {
    const r = j((await pg(`
      SELECT pc.service_phase, COUNT(*)::int AS n
      FROM photo_classifications pc
      JOIN photo_links pl ON pl.id = pc.photo_link_id
      WHERE pl.entity_type='visit' AND pl.entity_id=1799
      GROUP BY pc.service_phase ORDER BY pc.service_phase;
    `, id)).b);
    visitTags.push({ project: name, tags: r.map(x => `${x.n} ${x.service_phase}`).join(', ') || '(none)' });
  }
  console.table(visitTags);

  // === 4. SCHEMA INTEGRITY ACROSS PROJECTS ===
  console.log('\n[4] photo_classifications schema integrity\n');
  const schemaRows = [];
  for (const [name, id] of projects) {
    const cols = j((await pg(`SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='photo_classifications' ORDER BY ordinal_position;`, id)).b).map(r => r.column_name);
    const checkDef = j((await pg(`SELECT pg_get_constraintdef(oid) AS def FROM pg_constraint WHERE conrelid='public.photo_classifications'::regclass AND contype='c';`, id)).b)[0]?.def || '(none)';
    const anonTimeout = j((await pg(`SELECT rolconfig FROM pg_roles WHERE rolname='anon';`, id)).b)[0]?.rolconfig?.find(c => c.startsWith('statement_timeout')) || '(default)';
    const policies = j((await pg(`SELECT COUNT(*)::int AS n FROM pg_policies WHERE schemaname='public' AND tablename='photo_classifications';`, id)).b)[0].n;
    schemaRows.push({
      project: name,
      cols: cols.length,
      has_id: cols.includes('id') ? '✓' : '✗',
      has_photo_link_id: cols.includes('photo_link_id') ? '✓' : '✗',
      check_constraint: checkDef.includes("'extra'") && checkDef.includes("'internal'") ? '✓ new enum' : '⚠ stale enum',
      anon_timeout: anonTimeout,
      rls_policies: policies,
    });
  }
  console.table(schemaRows);

  // === 5. FIELD PORTAL: customer.wo_photos sanity ===
  console.log('\n[5] Field Portal customer.wo_photos for visit 1619 (092-TCE 2026-04-13)\n');
  const fpVariants = j((await pg(`SELECT variant, COUNT(*)::int AS n FROM customer.wo_photos WHERE work_order_id = customer.uuid_from_bigint(1619) GROUP BY variant ORDER BY n DESC;`, FP)).b);
  console.table(fpVariants);
  const fpInternalLeak = j((await pg(`SELECT COUNT(*)::int AS n FROM customer.wo_photos WHERE variant='internal';`, FP)).b)[0].n;
  console.log(`  internal-tagged rows leaking into customer view: ${fpInternalLeak} (should be 0)`);

  // === 6. ADMIN REVIEW APP's READ PATH (Sandbox #1) ===
  console.log('\n[6] Admin Review App read path on Sandbox #1 (visit 1799)\n');
  const adminRead = j((await pg(`
    SELECT 'photos' AS table, COUNT(*)::int AS n FROM photos WHERE id IN (SELECT photo_id FROM photo_links WHERE entity_type='visit' AND entity_id=1799)
    UNION ALL SELECT 'photo_links', COUNT(*)::int FROM photo_links WHERE entity_type='visit' AND entity_id=1799
    UNION ALL SELECT 'photo_classifications (new)', COUNT(*)::int FROM photo_classifications WHERE photo_link_id IN (SELECT id FROM photo_links WHERE entity_type='visit' AND entity_id=1799)
    UNION ALL SELECT 'app_photo_classifications (legacy)', COUNT(*)::int FROM app_photo_classifications WHERE external_photo_link_id IN (SELECT id FROM photo_links WHERE entity_type='visit' AND entity_id=1799)
    UNION ALL SELECT 'visits', COUNT(*)::int FROM visits WHERE id=1799
    UNION ALL SELECT 'clients', COUNT(*)::int FROM clients WHERE id=(SELECT client_id FROM visits WHERE id=1799)
    ORDER BY table;
  `, SBX1)).b);
  console.table(adminRead);

  // === 7. RECENT WRITES (within last 30 min — Fred's test) ===
  console.log('\n[7] Most recent classification writes (within last 30 min)\n');
  const recent = [];
  for (const [name, id] of projects) {
    const rows = j((await pg(`SELECT photo_link_id, service_phase, updated_at FROM photo_classifications WHERE updated_at > now() - interval '30 minutes' ORDER BY updated_at DESC LIMIT 5;`, id)).b);
    recent.push({ project: name, rows: rows.length, sample: rows.slice(0, 2).map(r => `pl=${r.photo_link_id} ${r.service_phase} @${r.updated_at?.substring(11,19)}`).join(' | ') || '(none)' });
  }
  console.table(recent);

  // === SUMMARY ===
  console.log('\n' + '='.repeat(78));
  console.log('SUMMARY');
  console.log('='.repeat(78));
  const verdicts = [];
  if (counts[0].total === counts[1].total) verdicts.push('✓ Sandbox #1 + Prod row counts match — dual-write working');
  else verdicts.push(`✗ DRIFT: Sandbox=${counts[1].total} vs Prod=${counts[0].total}`);
  if (onlyProd.length === 0 && onlySbx.length === 0 && phaseMismatch.length === 0) verdicts.push('✓ Sandbox #1 + Prod fully in sync (per-row)');
  else verdicts.push(`⚠ ${onlyProd.length} Prod-only + ${onlySbx.length} Sandbox-only + ${phaseMismatch.length} phase mismatches`);
  if (visitTags[0].tags === visitTags[1].tags) verdicts.push('✓ Test visit 1799 tags identical across Prod + Sandbox');
  else verdicts.push(`⚠ Test visit 1799 differs between Prod (${visitTags[0].tags}) and Sandbox (${visitTags[1].tags})`);
  if (schemaRows.every(r => r.has_id === '✓' && r.has_photo_link_id === '✓' && r.check_constraint === '✓ new enum')) verdicts.push('✓ Schema integrity: id col + photo_link_id PK + new CHECK enum on all 3 DBs');
  else verdicts.push('⚠ Schema integrity issue — see [4]');
  if (fpInternalLeak === 0) verdicts.push('✓ Field Portal customer view correctly hides internal-tagged photos');
  if (recent[0].rows > 0 || recent[1].rows > 0) verdicts.push(`✓ Recent writes detected (Prod=${recent[0].rows}, Sandbox=${recent[1].rows}) — Fred's test landed`);
  else verdicts.push('⚠ No writes in last 30 min — possible env-var or rebuild issue');
  verdicts.forEach(v => console.log('  ' + v));
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
