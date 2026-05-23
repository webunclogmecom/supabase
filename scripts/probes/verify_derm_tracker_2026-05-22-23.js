// Verification probe for DERM Tracker changes 2026-05-22 + 2026-05-23.
// Mirrors the 7 areas in:
//   Building Apps/DERM Tracker/docs/supabase-verify-2026-05-22-23.md
//
// Read-only. Reports findings against the doc's expected outcomes.
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const SUPA_URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  if (!r.ok) throw new Error(`SQL ${r.status} ${await r.text()}`);
  return r.json();
}

function section(n, title) {
  console.log(`\n${'='.repeat(72)}\n§${n}  ${title}\n${'='.repeat(72)}`);
}
function row(label, val) { console.log(`  ${label.padEnd(36)} ${val}`); }

(async () => {
  // §1 — Multi-file photo upload
  section(1, 'Multi-file photo upload (Storage naming + DB columns)');

  const s1a = await sql(`
    SELECT name, created_at
    FROM storage.objects
    WHERE bucket_id = 'GT - Visits Images'
      AND name LIKE 'derm/%'
    ORDER BY created_at DESC
    LIMIT 30;
  `);
  console.log(`  Last 30 derm/* Storage objects:`);
  const seqPattern = /(manifest|address)_(\d+)\.(jpg|jpeg|png|pdf|heic)/i;
  let seqCount = 0, legacyCount = 0;
  for (const o of s1a) {
    const m = seqPattern.test(o.name);
    if (m) seqCount++; else legacyCount++;
  }
  row('Sequential naming (manifest_N/address_N):', seqCount);
  row('Legacy / other names:', legacyCount);
  console.log('  Sample (last 10):');
  s1a.slice(0, 10).forEach(o => console.log(`    ${o.name}`));

  const s1b = await sql(`
    SELECT id, white_manifest_number, yellow_ticket_number,
           CASE WHEN derm_manifest_url IS NULL THEN '∅' ELSE 'set' END AS mu,
           CASE WHEN derm_address_url  IS NULL THEN '∅' ELSE 'set' END AS au,
           created_at::date AS created
    FROM derm_manifests
    WHERE created_at > '2026-05-22'
    ORDER BY created_at DESC
    LIMIT 10;
  `);
  console.log(`\n  Recent manifests since 2026-05-22 (${s1b.length}):`);
  s1b.forEach(r => console.log(`    #${r.id} wm=${r.white_manifest_number || '∅'} yt=${r.yellow_ticket_number || '∅'} mu=${r.mu} au=${r.au} ${r.created}`));

  // §2 — derm_required flag correctness
  section(2, 'derm_required flag correctness');

  const s2a = await sql(`
    SELECT derm_required, COUNT(*)::int AS n
    FROM visits
    WHERE visit_status = 'completed'
    GROUP BY derm_required
    ORDER BY 1;
  `);
  console.log('  Visits by derm_required (completed only):');
  s2a.forEach(r => row(`derm_required=${r.derm_required}`, `${r.n}`));

  const s2b = await sql(`
    SELECT v.id, v.visit_date, c.client_code, c.name AS client_name,
           v.derm_required, v.service_type
    FROM visits v
    JOIN clients c ON c.id = v.client_id
    WHERE v.derm_required = false
      AND v.visit_status = 'completed'
    ORDER BY v.visit_date DESC
    LIMIT 20;
  `);
  console.log(`\n  Sample derm_required=false visits (${s2b.length}):`);
  s2b.forEach(r => console.log(`    v${r.id} ${r.visit_date} ${r.client_code} ${r.client_name} [${r.service_type || '∅'}]`));
  const looksGT = s2b.filter(r => /^GT/i.test(r.service_type || '') || /grease/i.test(r.client_name || ''));
  row('Looks-GT among derm_required=false:', looksGT.length);

  const s2c = await sql(`SELECT pg_get_viewdef('derm.visits'::regclass, true) AS def;`);
  const def = s2c[0].def;
  const filtersDermReq = /derm_required/i.test(def);
  const filtersCompleted = /completed/i.test(def);
  row('derm.visits filters derm_required:', filtersDermReq ? 'YES' : 'NO');
  row('derm.visits filters completed:', filtersCompleted ? 'YES' : 'NO');

  // §3 — derm.visits dedup
  section(3, 'derm.visits view deduplication');

  const s3a = await sql(`SELECT COUNT(*)::int AS total, COUNT(DISTINCT id)::int AS distinct_ids FROM derm.visits;`);
  row('Total rows:', s3a[0].total);
  row('Distinct ids:', s3a[0].distinct_ids);
  row('Dedup OK:', s3a[0].total === s3a[0].distinct_ids ? 'YES' : 'NO');

  const s3b = await sql(`SELECT id, COUNT(*)::int AS cnt FROM derm.visits GROUP BY id HAVING COUNT(*) > 1 LIMIT 10;`);
  row('Duplicate id groups (first 10):', s3b.length);

  // §4 — Jurisdiction INSERT mapping
  section(4, 'Jurisdiction INSERT mapping');

  const s4a = await sql(`
    SELECT id, white_manifest_number AS wm, yellow_ticket_number AS yt,
           disposal_facility_id AS dfid, dump_ticket_date, created_at::date AS created
    FROM derm_manifests
    WHERE created_at > '2026-05-22'
    ORDER BY created_at DESC
    LIMIT 10;
  `);
  console.log(`  Recent manifests jurisdiction map (${s4a.length}):`);
  s4a.forEach(r => {
    const j = r.wm && !r.yt ? 'Dade' : r.yt && !r.wm ? 'Broward' : (r.wm && r.yt) ? '!! BOTH' : '!! NEITHER';
    console.log(`    #${r.id} wm=${r.wm || '∅'} yt=${r.yt || '∅'} dfid=${r.dfid || '∅'} dump=${r.dump_ticket_date || '∅'} [${j}]`);
  });

  const s4b = await sql(`
    SELECT id, white_manifest_number, yellow_ticket_number, created_at::date AS created
    FROM derm_manifests
    WHERE white_manifest_number IS NOT NULL
      AND yellow_ticket_number IS NOT NULL
    ORDER BY created_at DESC
    LIMIT 10;
  `);
  row('Manifests with BOTH numbers set:', s4b.length);
  if (s4b.length) s4b.forEach(r => console.log(`    !! #${r.id} wm=${r.white_manifest_number} yt=${r.yellow_ticket_number} ${r.created}`));

  // §5 — Disposal facilities
  section(5, 'Disposal facilities populated');
  const s5 = await sql(`SELECT id, name, address, city, state, zip FROM disposal_facilities ORDER BY id;`);
  s5.forEach(r => row(`#${r.id} ${r.name}:`, `${r.address || '∅'} | ${r.city || '∅'}, ${r.state || '∅'} ${r.zip || '∅'}`));

  // §6 — Field Portal cross-check
  section(6, 'Field Portal customer.work_orders inverse mapping');
  const s6a = await sql(`
    SELECT id, visit_date,
           CASE WHEN derm_manifest_url IS NULL THEN '∅' ELSE 'set' END AS dmu,
           CASE WHEN wwtp_receipt_url  IS NULL THEN '∅' ELSE 'set' END AS wru
    FROM customer.work_orders
    WHERE derm_manifest_url IS NOT NULL OR wwtp_receipt_url IS NOT NULL
    ORDER BY visit_date DESC
    LIMIT 10;
  `);
  console.log(`  Latest 10 work_orders with any URL:`);
  s6a.forEach(r => console.log(`    v${r.id} ${r.visit_date} dermFOG=${r.dmu} wwtp=${r.wru}`));

  const s6b = await sql(`SELECT pg_get_viewdef('customer.work_orders'::regclass, true) AS def;`);
  const wo = s6b[0].def;
  const hasInverseDerm = /derm_address_url\s+AS\s+derm_manifest_url/i.test(wo);
  const hasInverseWwtp = /derm_manifest_url\s+AS\s+wwtp_receipt_url/i.test(wo);
  row('Inverse: derm_address_url → derm_manifest_url:', hasInverseDerm ? 'YES' : 'NO');
  row('Inverse: derm_manifest_url → wwtp_receipt_url:', hasInverseWwtp ? 'YES' : 'NO');

  // §7 — manifest_visits linkage health
  section(7, 'manifest_visits linkage health');

  const s7a = await sql(`
    SELECT mv.manifest_id, mv.visit_id
    FROM manifest_visits mv
    LEFT JOIN derm_manifests dm ON dm.id = mv.manifest_id
    WHERE dm.id IS NULL
    LIMIT 20;
  `);
  row('Orphaned manifest_visits (no manifest):', s7a.length);
  if (s7a.length) s7a.forEach(r => console.log(`    !! m=${r.manifest_id} v=${r.visit_id}`));

  const s7b = await sql(`
    SELECT mv.manifest_id, mv.visit_id
    FROM manifest_visits mv
    LEFT JOIN visits v ON v.id = mv.visit_id
    WHERE v.id IS NULL
    LIMIT 20;
  `);
  row('Orphaned manifest_visits (no visit):', s7b.length);
  if (s7b.length) s7b.forEach(r => console.log(`    !! m=${r.manifest_id} v=${r.visit_id}`));

  const s7c = await sql(`
    SELECT
      DATE_TRUNC('week', v.visit_date)::date AS week,
      COUNT(*)::int AS total_visits,
      COUNT(DISTINCT mv.visit_id)::int AS linked,
      ROUND(100.0 * COUNT(DISTINCT mv.visit_id) / NULLIF(COUNT(*), 0), 1) AS pct
    FROM visits v
    LEFT JOIN manifest_visits mv ON mv.visit_id = v.id
    WHERE v.visit_status = 'completed'
      AND v.derm_required IS NOT FALSE
      AND v.service_type ILIKE '%GT%'
      AND v.visit_date >= CURRENT_DATE - INTERVAL '8 weeks'
    GROUP BY 1
    ORDER BY 1 DESC;
  `);
  console.log('\n  Linkage coverage (GT visits, last 8 weeks):');
  console.log('  week        total  linked   pct');
  s7c.forEach(r => console.log(`  ${r.week}  ${String(r.total_visits).padStart(5)}  ${String(r.linked).padStart(6)}   ${String(r.pct).padStart(5)}%`));

  const s7d = await sql(`SELECT health_state, COUNT(*)::int AS n FROM derm.manifest_health GROUP BY 1 ORDER BY 1;`);
  console.log('\n  derm.manifest_health buckets:');
  s7d.forEach(r => row(r.health_state + ':', r.n));

  console.log('\n' + '='.repeat(72));
  console.log('Verification complete.');
  console.log('='.repeat(72));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
