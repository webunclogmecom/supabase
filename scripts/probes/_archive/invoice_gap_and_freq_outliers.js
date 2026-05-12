// Two follow-up probes (Fred 2026-04-29):
//  1. Invoice gap — Jobber visits in 2026 with no invoice_id (current data only)
//  2. Service-config frequency outliers — anything > 180 days flagged for Yan
//
// Older-than-2026 data deliberately excluded per Fred's scope reduction.
// "Older may be reviewed manually later, not now."

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const { newQuery } = require('../populate/lib/db');

async function probeInvoiceGap2026() {
  console.log('--- 1. JOBBER VISITS WITHOUT invoice_id (2026 only) ---\n');

  const summary = await newQuery(`
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE v.visit_status = 'COMPLETED')::int AS completed,
      COUNT(*) FILTER (WHERE v.visit_status != 'COMPLETED' OR v.visit_status IS NULL)::int AS not_complete
    FROM visits v
    WHERE v.invoice_id IS NULL
      AND v.start_at >= '2026-01-01'::timestamptz
      AND EXISTS (
        SELECT 1 FROM entity_source_links esl
        WHERE esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
      );
  `);
  const r = summary[0];
  console.log(`Total 2026 Jobber visits without invoice_id: ${r.total}`);
  console.log(`  Status=COMPLETED (should have invoice): ${r.completed}`);
  console.log(`  Status!=COMPLETED (legitimately no invoice): ${r.not_complete}`);

  if (r.completed === 0) {
    console.log('\n  All 2026 completed visits have invoices. The 273 old gap is pre-2026 only.');
    return;
  }

  console.log('\n  Top 30 completed-no-invoice visits, 2026 YTD:');
  const detail = await newQuery(`
    SELECT
      v.id,
      v.visit_date,
      v.start_at,
      v.completed_at,
      v.title,
      c.name AS client_name,
      esl.source_id AS jobber_visit_gid
    FROM visits v
    JOIN clients c ON c.id = v.client_id
    JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    WHERE v.invoice_id IS NULL
      AND v.visit_status = 'COMPLETED'
      AND v.start_at >= '2026-01-01'::timestamptz
    ORDER BY v.start_at DESC
    LIMIT 30;
  `);

  for (const row of detail) {
    const date = row.visit_date.toISOString ? row.visit_date.toISOString().slice(0,10) : String(row.visit_date).slice(0,10);
    const title = (row.title || '').slice(0, 50);
    const name = (row.client_name || '').slice(0, 40);
    console.log(`    ${date}  visit_id=${row.id}  client="${name}"  title="${title}"`);
  }
}

async function probeFrequencyOutliers() {
  console.log('\n\n--- 2. SERVICE_CONFIGS FREQUENCY OUTLIERS (>180 days = >6 months) ---\n');

  const all = await newQuery(`
    SELECT
      sc.id,
      sc.client_id,
      c.name AS client_name,
      c.client_code,
      sc.service_type,
      sc.frequency_days,
      sc.price_per_visit,
      sc.last_visit,
      ROUND(sc.frequency_days::numeric / 30.0, 1) AS months_equiv,
      ROUND(sc.frequency_days::numeric / 365.0, 1) AS years_equiv,
      CASE
        WHEN sc.frequency_days % 30 = 0 AND sc.frequency_days >= 900
          THEN 'multiple of 30; possible "× 30 typo" by Yannick (entered months as days)'
        WHEN sc.frequency_days >= 1000 THEN 'almost certainly Airtable data error'
        WHEN sc.frequency_days >= 365  THEN 'over 1 year — verify with Yan'
        ELSE 'borderline (6-12 months); verify if this client really has annual service'
      END AS suspicion
    FROM service_configs sc
    JOIN clients c ON c.id = sc.client_id
    WHERE sc.frequency_days > 180
    ORDER BY sc.frequency_days DESC;
  `);

  console.log(`${all.length} configs with frequency_days > 180 (>6 months):\n`);

  // Group by suspicion level
  const buckets = { 'almost certainly Airtable data error': [], 'multiple of 30; possible "× 30 typo" by Yannick (entered months as days)': [], 'over 1 year — verify with Yan': [], 'borderline (6-12 months); verify if this client really has annual service': [] };
  for (const r of all) {
    if (!buckets[r.suspicion]) buckets[r.suspicion] = [];
    buckets[r.suspicion].push(r);
  }

  for (const [bucket, rows] of Object.entries(buckets)) {
    if (!rows.length) continue;
    console.log(`\n[${rows.length} rows] ${bucket}:`);
    for (const r of rows) {
      const lastVisit = r.last_visit ? (r.last_visit.toISOString ? r.last_visit.toISOString().slice(0,10) : String(r.last_visit).slice(0,10)) : '(never)';
      console.log(`  ${r.client_code || ''} ${r.service_type}  freq=${r.frequency_days}d (${r.months_equiv}mo / ${r.years_equiv}yr)  last=${lastVisit}  price=$${r.price_per_visit ?? '?'}  client="${r.client_name}"`);
    }
  }
}

(async () => {
  console.log('=== POST-REPOP FOLLOW-UP PROBES (2026-04-29) ===\n');
  console.log('Scope: 2026 YTD only for visits. Older data deliberately excluded.\n');
  await probeInvoiceGap2026();
  await probeFrequencyOutliers();
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
