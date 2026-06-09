// 34_calendar_drawer_data_audit.mjs
// Audit the calendar drawer data:
//   1. Find the $5,149 visit (and other suspiciously-high amounts)
//   2. Diagnose whether the amount comes from line_items sum (multi-visit invoice
//      inflation) vs service_configs.price_per_visit
//   3. Count visits with missing frequency/equipment_size/hours/etc.
//   4. Sample missing-data visits per client to figure out root cause
//      (no service_config? wrong service_type? missing property?)

import 'dotenv/config';

const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

console.log('=== 1. High-amount visits in May 2026 (sanity check) ===\n');
console.log(await pg(`
  SELECT id, visit_date, client_code, client_name, service_type, amount, frequency_days, equipment_size_gallons
  FROM ops.v_calendar_visit
  WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31'
    AND amount > 1500
  ORDER BY amount DESC
  LIMIT 20;
`));

console.log('\n=== 2. The $5,149 visit specifically ===');
console.log(await pg(`
  SELECT v.*, c.name AS canonical_client_name
  FROM ops.v_calendar_visit v
  JOIN public.clients c ON c.id = v.client_id
  WHERE amount BETWEEN 5140 AND 5160
  LIMIT 5;
`));

console.log('\n=== 3. Same invoice line-items breakdown ===');
console.log(await pg(`
  WITH target AS (
    SELECT id AS visit_id, client_id, visit_date, invoice_id, service_type
    FROM public.visits
    WHERE id IN (
      SELECT id FROM ops.v_calendar_visit
      WHERE amount BETWEEN 5140 AND 5160
        AND visit_date BETWEEN '2026-05-01' AND '2026-05-31'
      LIMIT 1
    )
  )
  SELECT t.visit_id, t.invoice_id, li.id AS line_item_id, li.name, li.quantity, li.unit_price, li.total_price
  FROM target t
  LEFT JOIN public.line_items li ON li.invoice_id = t.invoice_id
  ORDER BY li.id;
`));

console.log('\n=== 4. How many visits share that invoice? ===');
console.log(await pg(`
  WITH target AS (
    SELECT invoice_id FROM public.visits
    WHERE id IN (
      SELECT id FROM ops.v_calendar_visit
      WHERE amount BETWEEN 5140 AND 5160 LIMIT 1
    )
  )
  SELECT count(*)::int AS visits_on_invoice, sum(CASE WHEN visit_status='completed' THEN 1 ELSE 0 END)::int AS completed
  FROM public.visits v, target t WHERE v.invoice_id = t.invoice_id;
`));

console.log('\n=== 5. Missing-data counts on v_calendar_visit (May 2026) ===');
console.log(await pg(`
  SELECT
    count(*)::int AS total,
    sum(CASE WHEN frequency_days IS NULL THEN 1 ELSE 0 END)::int AS missing_frequency,
    sum(CASE WHEN equipment_size_gallons IS NULL THEN 1 ELSE 0 END)::int AS missing_equipment_size,
    sum(CASE WHEN access_hours_start IS NULL OR access_hours_end IS NULL THEN 1 ELSE 0 END)::int AS missing_hours,
    sum(CASE WHEN zone IS NULL THEN 1 ELSE 0 END)::int AS missing_zone,
    sum(CASE WHEN address IS NULL THEN 1 ELSE 0 END)::int AS missing_address,
    sum(CASE WHEN gdo_number IS NULL THEN 1 ELSE 0 END)::int AS missing_gdo,
    sum(CASE WHEN truck_name IS NULL THEN 1 ELSE 0 END)::int AS missing_truck,
    sum(CASE WHEN driver_name IS NULL THEN 1 ELSE 0 END)::int AS missing_driver,
    sum(CASE WHEN amount = 0 THEN 1 ELSE 0 END)::int AS zero_amount
  FROM ops.v_calendar_visit
  WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31';
`));

console.log('\n=== 6. Sample 5 visits with NULL frequency (root cause check) ===');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.client_code, v.client_name, v.service_type,
         v.frequency_days, v.equipment_size_gallons,
         (SELECT count(*) FROM public.service_configs sc
          WHERE sc.client_id = v.client_id) AS sc_total_for_client,
         (SELECT array_agg(service_type) FROM public.service_configs sc
          WHERE sc.client_id = v.client_id) AS sc_service_types
  FROM ops.v_calendar_visit v
  WHERE visit_date BETWEEN '2026-05-01' AND '2026-05-31'
    AND frequency_days IS NULL
  ORDER BY v.visit_date
  LIMIT 8;
`));
