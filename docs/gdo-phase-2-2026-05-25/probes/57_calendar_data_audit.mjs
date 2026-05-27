// 57_calendar_data_audit.mjs
// Cross-check Calendar UI data against canonical DB.
// UI shows: 146 visits, 19 unscheduled, May 2026 view.
// We verify:
//   - Count match
//   - Sample specific visible cells (client + date + price + truck letters)
//   - Identify the view powering the calendar (ops.v_calendar_visit)
//   - Status distribution so we can validate visual completion treatment

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

console.log('=== A. Does ops.v_calendar_visit exist? ===');
console.log(await pg(`
  SELECT table_schema, table_name, table_type
  FROM information_schema.tables
  WHERE table_name LIKE 'v_calendar%'
  ORDER BY table_schema, table_name;
`));

console.log('\n=== B. May 2026 visit counts in canonical ===');
console.log(await pg(`
  SELECT
    COUNT(*)                                                   AS total,
    COUNT(*) FILTER (WHERE visit_status = 'completed')         AS completed,
    COUNT(*) FILTER (WHERE visit_status = 'scheduled')         AS scheduled,
    COUNT(*) FILTER (WHERE visit_status = 'skipped')           AS skipped,
    COUNT(*) FILTER (WHERE visit_status = 'in_progress')       AS in_progress,
    COUNT(*) FILTER (WHERE visit_status IS NULL)               AS null_status,
    COUNT(*) FILTER (WHERE vehicle_id IS NULL)                 AS no_truck,
    COUNT(*) FILTER (WHERE source = 'visit-calendar')          AS created_via_calendar
  FROM public.visits
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01';
`));

console.log('\n=== C. May 2026 visit counts via ops.v_calendar_visit ===');
console.log(await pg(`
  SELECT
    COUNT(*) AS total_in_view,
    COUNT(*) FILTER (WHERE visit_status = 'completed') AS completed,
    COUNT(*) FILTER (WHERE visit_status = 'scheduled') AS scheduled,
    COUNT(*) FILTER (WHERE visit_status = 'skipped')   AS skipped
  FROM ops.v_calendar_visit
  WHERE visit_date >= '2026-05-01' AND visit_date < '2026-06-01';
`));

console.log('\n=== D. Sample visible cells from the May 2026 UI ===');
// Spot-check 5 visits that I can see on screen
console.log(await pg(`
  SELECT
    v.id, v.visit_date, v.visit_status, c.name AS client_name, c.client_code,
    vh.name AS truck, sc.price_per_visit
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  LEFT JOIN public.vehicles vh ON vh.id = v.vehicle_id
  LEFT JOIN public.service_configs sc ON sc.client_id = v.client_id AND sc.service_type = v.service_type
  WHERE v.visit_date >= '2026-05-01' AND v.visit_date < '2026-06-01'
    AND (c.name ILIKE '%Pura Vida Bakery%'
      OR c.name ILIKE '%Bagel Cove%'
      OR c.name ILIKE '%Mutra%'
      OR c.name ILIKE '%Maison Valentine%'
      OR c.name ILIKE '%Myka Brickell%')
  ORDER BY v.visit_date, c.name
  LIMIT 20;
`));

console.log('\n=== E. Source of visits in May 2026 (entity_source_links breakdown) ===');
console.log(await pg(`
  SELECT v.source AS visit_source_col, COUNT(*) AS n
  FROM public.visits v
  WHERE v.visit_date >= '2026-05-01' AND v.visit_date < '2026-06-01'
  GROUP BY v.source
  ORDER BY n DESC;
`));

console.log('\n=== F. Cross-source linkage for May 2026 visits ===');
console.log(await pg(`
  SELECT esl.source_system, COUNT(DISTINCT v.id) AS visits_linked
  FROM public.visits v
  LEFT JOIN public.entity_source_links esl
    ON esl.entity_type = 'visit' AND esl.entity_id = v.id
  WHERE v.visit_date >= '2026-05-01' AND v.visit_date < '2026-06-01'
  GROUP BY esl.source_system
  ORDER BY visits_linked DESC;
`));

console.log('\n=== G. Pura Vida Bakery May 1 visit detail (the one I clicked) ===');
console.log(await pg(`
  SELECT v.id, v.visit_date, v.visit_status, v.source,
         c.name, c.client_code,
         p.address AS property_address, p.city, p.county,
         vh.name AS truck, sc.price_per_visit,
         sc.frequency_days
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  LEFT JOIN public.properties p ON p.id = v.property_id
  LEFT JOIN public.vehicles vh ON vh.id = v.vehicle_id
  LEFT JOIN public.service_configs sc ON sc.client_id = v.client_id AND sc.service_type = v.service_type
  WHERE c.name = 'Pura Vida Bakery'
    AND v.visit_date = '2026-05-01';
`));

console.log('\n=== H. Total unscheduled count vs UI "19 unscheduled" ===');
console.log(await pg(`
  SELECT COUNT(*) AS unscheduled_count
  FROM public.visits v
  WHERE v.visit_date IS NULL
    AND v.visit_status IN ('scheduled');
`));
