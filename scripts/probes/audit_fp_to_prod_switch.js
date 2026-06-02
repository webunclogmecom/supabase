// audit_fp_to_prod_switch.js
// Pre-flight audit: is Prod's customer schema 100% drop-in compatible
// with what the Field Portal app currently reads from Field Portal Sandbox?
//
// Checks (in order):
//   1. customer.* views exist with identical definitions on both
//   2. Helper functions (uuid_from_bigint, bigint_from_uuid, public_url) match
//   3. Anon grants on customer.* views match
//   4. RLS policies on customer.* views match (if any)
//   5. Anon grants on the public canonical tables referenced by views
//   6. Data sanity sample: each view returns sensible rows on Prod
//   7. Public schema exposure check (so we can spot what'd break if FP was
//      reading raw public.* — it shouldn't, but verify)
//
// Output: PASS/WARN/FAIL per check. Recommend remediations.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const FP   = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;

function pg(sql, project) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${project}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(b)); });
    req.on('error', rej);
    req.write(JSON.stringify({query: sql}));
    req.end();
  });
}
const j = x => { try { return JSON.parse(x); } catch { return x; } };

const findings = [];
const log = (level, check, detail) => findings.push({ level, check, detail });

(async () => {
  console.log('='.repeat(78));
  console.log('PRE-FLIGHT AUDIT — Field Portal switch to Prod customer schema');
  console.log('='.repeat(78));

  // === 1. customer.* views: exist + same definition ===
  console.log('\n[1] customer.* view definitions parity');
  for (const view of ['work_orders','wo_photos','client_access_photos','inspection_items','permits','recommendations','scheduled_visits','clients']) {
    const prodDef = j(await pg(`SELECT pg_get_viewdef('customer.${view}'::regclass, true) AS def;`, PROD))[0]?.def?.replace(/\s+/g, ' ').trim();
    const fpDef   = j(await pg(`SELECT pg_get_viewdef('customer.${view}'::regclass, true) AS def;`, FP))[0]?.def?.replace(/\s+/g, ' ').trim();
    if (!prodDef || !fpDef) {
      log('FAIL', `view ${view} existence`, `Prod has: ${!!prodDef}, FP has: ${!!fpDef}`);
      console.log(`  ${view}: ✗ missing on one or both DBs`);
    } else if (prodDef === fpDef) {
      log('PASS', `view ${view}`, 'identical');
      console.log(`  ${view}: ✓ identical`);
    } else {
      log('WARN', `view ${view}`, `definitions differ — Prod len=${prodDef.length}, FP len=${fpDef.length}`);
      console.log(`  ${view}: ⚠ differs (Prod ${prodDef.length} chars vs FP ${fpDef.length} chars)`);
    }
  }

  // === 2. helper functions ===
  console.log('\n[2] customer.* helper function parity');
  for (const fn of ['uuid_from_bigint','bigint_from_uuid','public_url']) {
    const prodSrc = j(await pg(`SELECT pg_get_functiondef(p.oid) AS def FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='customer' AND p.proname='${fn}';`, PROD))[0]?.def?.replace(/\s+/g, ' ').trim();
    const fpSrc   = j(await pg(`SELECT pg_get_functiondef(p.oid) AS def FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='customer' AND p.proname='${fn}';`, FP))[0]?.def?.replace(/\s+/g, ' ').trim();
    if (!prodSrc || !fpSrc) {
      log('FAIL', `fn ${fn} existence`, `Prod has: ${!!prodSrc}, FP has: ${!!fpSrc}`);
      console.log(`  ${fn}: ✗ missing on one or both`);
    } else if (prodSrc === fpSrc) {
      log('PASS', `fn ${fn}`, 'identical');
      console.log(`  ${fn}: ✓ identical`);
    } else {
      log('WARN', `fn ${fn}`, `differs — Prod len=${prodSrc.length}, FP len=${fpSrc.length}`);
      console.log(`  ${fn}: ⚠ differs`);
    }
  }

  // === 3. customer.* anon grants ===
  console.log('\n[3] customer.* anon grants parity');
  const grants = (db) => pg(`SELECT table_name, string_agg(privilege_type, ',' ORDER BY privilege_type) AS privs FROM information_schema.role_table_grants WHERE table_schema='customer' AND grantee='anon' GROUP BY table_name ORDER BY 1;`, db);
  const prodG = j(await grants(PROD));
  const fpG = j(await grants(FP));
  const prodGmap = new Map(prodG.map(r => [r.table_name, r.privs]));
  const fpGmap = new Map(fpG.map(r => [r.table_name, r.privs]));
  const allViews = new Set([...prodGmap.keys(), ...fpGmap.keys()]);
  for (const v of allViews) {
    const p = prodGmap.get(v) || '(none)';
    const f = fpGmap.get(v) || '(none)';
    if (p === f) {
      log('PASS', `grant ${v}`, p);
      console.log(`  ${v}: ✓ anon = ${p}`);
    } else {
      log('FAIL', `grant ${v}`, `Prod=${p}, FP=${f}`);
      console.log(`  ${v}: ✗ Prod=${p}, FP=${f}`);
    }
  }

  // === 4. customer.* RLS policies ===
  console.log('\n[4] customer.* RLS policies (typically none — views run as owner)');
  for (const [name, id] of [['Prod', PROD], ['FP', FP]]) {
    const r = j(await pg(`SELECT tablename, policyname FROM pg_policies WHERE schemaname='customer';`, id));
    console.log(`  ${name}: ${r.length} policies`);
    if (r.length) log('WARN', `${name} customer RLS`, JSON.stringify(r));
  }

  // === 5. anon grants on public.* canonical tables the views read from ===
  console.log('\n[5] anon SELECT on canonical tables (customer.* views are owner-run so should not matter, but check)');
  for (const t of ['clients','properties','visits','visit_assignments','vehicles','employees','photo_links','photos','photo_classifications','derm_manifests','manifest_visits','inspections','service_configs','visit_recommendations']) {
    const p = j(await pg(`SELECT privilege_type FROM information_schema.role_table_grants WHERE grantee='anon' AND table_schema='public' AND table_name='${t}' AND privilege_type='SELECT';`, PROD)).length > 0;
    const f = j(await pg(`SELECT privilege_type FROM information_schema.role_table_grants WHERE grantee='anon' AND table_schema='public' AND table_name='${t}' AND privilege_type='SELECT';`, FP)).length > 0;
    const symP = p ? '✓' : '✗';
    const symF = f ? '✓' : '✗';
    if (p === f) console.log(`  ${t}: Prod ${symP} | FP ${symF} ${p===f ? '' : '⚠'}`);
    else { console.log(`  ${t}: Prod ${symP} | FP ${symF} ⚠ MISMATCH`); log('WARN', `anon SELECT ${t}`, `Prod=${p}, FP=${f}`); }
  }

  // === 6. Data sanity ===
  console.log('\n[6] Data sanity: customer.* row counts + sample row Prod');
  for (const view of ['work_orders','wo_photos','client_access_photos','inspection_items','permits','recommendations','scheduled_visits','clients']) {
    const p = j(await pg(`SELECT COUNT(*)::int AS n FROM customer.${view};`, PROD))[0].n;
    const f = j(await pg(`SELECT COUNT(*)::int AS n FROM customer.${view};`, FP))[0].n;
    console.log(`  ${view}: Prod=${p}, FP=${f}`);
    if (p === 0 && f > 0) log('WARN', `data ${view}`, `Prod empty but FP has ${f}`);
  }

  // === 7. Try a customer.work_orders query like the app would ===
  console.log('\n[7] Sample Prod customer.work_orders row (092-TCE 2026-05-04)');
  console.log(j(await pg(`SELECT id, client_id, visit_date, driver, truck, manholes, derm_manifest_number, derm_manifest_url IS NOT NULL AS has_dm, wwtp_receipt_url IS NOT NULL AS has_wwtp FROM customer.work_orders WHERE id = customer.uuid_from_bigint(3915);`, PROD)));

  // === 8. Public schema exposure (the bit that needs Fred-Dashboard action) ===
  console.log('\n[8] Customer schema PostgREST exposure on Prod (Fred-Dashboard pending)');
  console.log('  This check is from migration source records — actual exposure status is set in Supabase Dashboard.');
  console.log('  Last test via REST API (earlier in session): "Only public, graphql_public exposed" — customer NOT yet exposed.');

  // === SUMMARY ===
  console.log('\n' + '='.repeat(78));
  console.log('SUMMARY');
  console.log('='.repeat(78));
  const counts = findings.reduce((a, x) => (a[x.level] = (a[x.level] || 0) + 1, a), {});
  console.log(`  PASS: ${counts.PASS || 0}  WARN: ${counts.WARN || 0}  FAIL: ${counts.FAIL || 0}`);
  if (counts.FAIL || counts.WARN) {
    console.log('\nNon-PASS findings:');
    findings.filter(f => f.level !== 'PASS').forEach(f => console.log(`  [${f.level}] ${f.check}: ${f.detail}`));
  }
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
