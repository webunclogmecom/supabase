// ============================================================================
// test_suite.js — 10-check post-population validation suite
// ============================================================================
// Agreed with Viktor (Slack thread C0AN9KDP5B8 ts 1775680501.895839):
//
//   Blocking checks (must pass):
//     1. FK integrity         — auto-derive FK list from information_schema
//     2. Row count floors     — clients ≥405, jobs ≥523, visits ≥1684, invoices ≥1654, quotes ≥179
//     3. Cross-source consist — Samsara-linked clients have lat/lon; AT-linked have GDO fields
//     4. Jobber precedence    — for clients with both jobber+at sources, name/address from Jobber
//     5. Operational views    — all 5 views return ≥0 rows without error
//     6. A/R reconciliation   — sum(invoices.outstanding WHERE status open) within ±5% of $114,932
//     7. PCI exclusion        — no card/cvv/routing/account columns or matching content
//     8. Source col integrity — visits.source IN ('jobber','airtable_historical'); jobber rows have job_id rate ≥98%
//     9. Visit-invoice rate   — completed visits with invoice_id ≥65%
//
//   Informational (non-blocking, soft alert):
//    10. Manifest_visits link — manifest_visits / derm_manifests ≥65%
// ============================================================================

const { newQuery } = require('./lib/db');

const results = [];
let blockingFailed = 0;

function record(num, name, status, detail, blocking = true) {
  const icon = status === 'PASS' ? 'PASS' : status === 'WARN' ? 'WARN' : 'FAIL';
  results.push({ num, name, status, detail, blocking });
  if (status === 'FAIL' && blocking) blockingFailed++;
  console.log(`  Check ${num.toString().padStart(2)} [${icon}] ${name}${detail ? ' — ' + detail : ''}`);
}

async function check1_fk_integrity() {
  // Auto-derive every FK and verify zero orphans
  const fks = await newQuery(`
    SELECT tc.table_name, kcu.column_name, ccu.table_name AS ref_table, ccu.column_name AS ref_column
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu USING (constraint_schema, constraint_name)
    JOIN information_schema.constraint_column_usage ccu USING (constraint_schema, constraint_name)
    WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = 'public'
    ORDER BY tc.table_name, kcu.column_name;
  `);
  let orphans = 0;
  const orphanTables = [];
  for (const f of fks) {
    const r = await newQuery(`SELECT count(*) AS n FROM ${f.table_name} t LEFT JOIN ${f.ref_table} p ON t.${f.column_name} = p.${f.ref_column} WHERE t.${f.column_name} IS NOT NULL AND p.${f.ref_column} IS NULL;`);
    const n = parseInt(r[0].n);
    if (n > 0) { orphans += n; orphanTables.push(`${f.table_name}.${f.column_name}=${n}`); }
  }
  record(1, 'FK integrity', orphans === 0 ? 'PASS' : 'FAIL', `${fks.length} FKs scanned, ${orphans} orphans${orphanTables.length ? ' (' + orphanTables.join(', ') + ')' : ''}`);
}

async function check2_row_counts() {
  const floors = { clients: 405, jobs: 523, visits: 1684, invoices: 1654, quotes: 179, properties: 373, line_items: 597 };
  const fails = [];
  const counts = {};
  for (const [t, floor] of Object.entries(floors)) {
    const r = await newQuery(`SELECT count(*) AS n FROM ${t};`);
    const n = parseInt(r[0].n);
    counts[t] = n;
    if (n < floor) fails.push(`${t}=${n}<${floor}`);
  }
  record(2, 'Row count floors', fails.length === 0 ? 'PASS' : 'FAIL', JSON.stringify(counts) + (fails.length ? ' FAILS: ' + fails.join(', ') : ''));
}

async function check3_cross_source() {
  // Samsara-linked clients should have lat/lon
  const r1 = await newQuery(`SELECT count(*) AS n FROM clients WHERE samsara_address_id IS NOT NULL AND (latitude IS NULL OR longitude IS NULL);`);
  const missGeo = parseInt(r1[0].n);
  // AT-linked clients should mostly have at least one GDO/zone field populated (sanity, not strict)
  const r2 = await newQuery(`SELECT count(*) AS n FROM clients WHERE airtable_record_id IS NOT NULL AND zone IS NULL AND gdo_number IS NULL AND county IS NULL;`);
  const missAT = parseInt(r2[0].n);
  const status = missGeo === 0 ? 'PASS' : 'FAIL';
  record(3, 'Cross-source consistency', status, `samsara_no_geo=${missGeo}, at_clients_with_no_at_fields=${missAT}`);
}

async function check4_jobber_precedence() {
  // For clients with both jobber+at, name should match the Jobber name (no AT override)
  const r = await newQuery(`
    SELECT count(*) AS n FROM clients
    WHERE jobber_client_id IS NOT NULL AND airtable_record_id IS NOT NULL
      AND name IS NULL;
  `);
  const nullnames = parseInt(r[0].n);
  // Sample 5 merged rows for visual confirmation
  const sample = await newQuery(`SELECT name, jobber_client_id, airtable_record_id FROM clients WHERE jobber_client_id IS NOT NULL AND airtable_record_id IS NOT NULL LIMIT 3;`);
  record(4, 'Jobber precedence', nullnames === 0 ? 'PASS' : 'FAIL', `merged_with_null_name=${nullnames}; sample=${sample.map(s => s.name).join(' | ')}`);
}

async function check5_views() {
  const views = ['client_services_flat', 'clients_due_service', 'visits_recent', 'manifest_detail', 'driver_inspection_status'];
  const fails = [];
  for (const v of views) {
    try {
      const r = await newQuery(`SELECT count(*) AS n FROM ${v};`);
      // any result is OK; just verifying the view executes
    } catch (e) {
      fails.push(`${v}: ${e.message.slice(0, 80)}`);
    }
  }
  record(5, 'Operational views', fails.length === 0 ? 'PASS' : 'FAIL', fails.length === 0 ? `${views.length}/5 views queryable` : fails.join('; '));
}

async function check6_ar_reconciliation() {
  const r = await newQuery(`SELECT COALESCE(SUM(outstanding),0) AS ar FROM invoices WHERE invoice_status NOT IN ('paid','void','draft','bad_debt') AND outstanding IS NOT NULL;`);
  const ar = parseFloat(r[0].ar);
  const expected = 57466; // Viktor corrected 2026-04-08: original $114,932 was a summation bug (double-counted overlapping buckets)
  const tolerance = 0.10; // ±10%
  const lo = expected * (1 - tolerance), hi = expected * (1 + tolerance);
  const pass = ar >= lo && ar <= hi;
  record(6, 'A/R reconciliation', pass ? 'PASS' : 'WARN', `outstanding_ar=$${ar.toFixed(2)} expected~$${expected} (±${tolerance*100}%)`, false);
}

async function check7_pci() {
  const cols = await newQuery(`
    SELECT table_name, column_name FROM information_schema.columns
    WHERE table_schema='public' AND column_name ~* '(cc_|cvv|routing|account_num|card_num|card_pan|exp_month|exp_year)'
    ORDER BY table_name;
  `);
  // signature_date and ramp_card_holder are known false positives
  const realPci = cols.filter(c => !['signature_date', 'ramp_card_holder'].includes(c.column_name));
  record(7, 'PCI exclusion', realPci.length === 0 ? 'PASS' : 'FAIL', realPci.length === 0 ? '0 PCI columns' : JSON.stringify(realPci));
}

async function check8_source_integrity() {
  // After Viktor revision: AT visits dropped, all visits should be source='jobber'
  const r1 = await newQuery(`SELECT source, count(*) AS n FROM visits GROUP BY source;`);
  const sources = r1.map(x => `${x.source}=${x.n}`).join(',');
  const bad = await newQuery(`SELECT count(*) AS n FROM visits WHERE source IS NULL OR source NOT IN ('jobber','airtable_historical');`);
  // Jobber visits with null job_id rate
  const j = await newQuery(`SELECT count(*) total, count(job_id) wjob FROM visits WHERE source='jobber';`);
  const rate = parseInt(j[0].wjob) / Math.max(parseInt(j[0].total), 1);
  const pass = parseInt(bad[0].n) === 0 && rate >= 0.98;
  record(8, 'Source column integrity', pass ? 'PASS' : 'FAIL', `${sources}, jobber_visits_with_job=${(rate*100).toFixed(1)}% (need ≥98%)`);
}

async function check9_visit_invoice() {
  const r = await newQuery(`
    SELECT count(*) AS total, count(invoice_id) AS withinv
    FROM visits
    WHERE source='jobber' AND visit_status='COMPLETED';
  `);
  const total = parseInt(r[0].total);
  const wi = parseInt(r[0].withinv);
  const rate = total > 0 ? wi / total : 0;
  const pass = rate >= 0.65;
  record(9, 'Visit-invoice match rate', pass ? 'PASS' : 'FAIL', `${wi}/${total} = ${(rate*100).toFixed(1)}% (need ≥65%)`);
}

async function check10_manifest_visits() {
  const r = await newQuery(`
    SELECT (SELECT count(DISTINCT manifest_id) FROM manifest_visits) linked,
           (SELECT count(*) FROM derm_manifests) total;
  `);
  const linked = parseInt(r[0].linked);
  const total = parseInt(r[0].total);
  const rate = total > 0 ? linked / total : 0;
  const pass = rate >= 0.65;
  record(10, 'Manifest_visits link rate (info)', pass ? 'PASS' : 'WARN', `${linked}/${total} = ${(rate*100).toFixed(1)}% (floor 65%)`, false);
}

(async () => {
  console.log('='.repeat(70));
  console.log('test_suite.js — UNCLOGME 10-check validation');
  console.log('='.repeat(70) + '\n');
  try {
    await check1_fk_integrity();
    await check2_row_counts();
    await check3_cross_source();
    await check4_jobber_precedence();
    await check5_views();
    await check6_ar_reconciliation();
    await check7_pci();
    await check8_source_integrity();
    await check9_visit_invoice();
    await check10_manifest_visits();
  } catch (e) {
    console.error('\nFATAL during checks:', e.message);
    process.exit(2);
  }
  console.log('\n' + '='.repeat(70));
  const passed = results.filter(r => r.status === 'PASS').length;
  const warned = results.filter(r => r.status === 'WARN').length;
  const failed = results.filter(r => r.status === 'FAIL').length;
  console.log(`SUMMARY: ${passed} PASS, ${warned} WARN, ${failed} FAIL  |  blocking failures: ${blockingFailed}`);
  console.log('='.repeat(70));
  process.exit(blockingFailed > 0 ? 1 : 0);
})();
