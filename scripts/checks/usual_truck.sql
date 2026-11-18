-- Standing check for the suggested truck in ops.v_calendar_visit (Trello alpHmTtL, migration 2026-10-29_1700; truck
-- categories since Trello #170, migration 2026-11-18_1330).
-- Run as postgres (Management API). Healthy = ONE row: problem = 'ok'. Any other row names what broke.
-- The rule, recomputed here on its own:
--   * a visit needs the truck categories of its line items (its own, else its job's, else those of its service type);
--   * a visit with no stored truck, scheduled, dated today (ET) or later, shows the most frequent ACTIVE truck OF A
--     NEEDED CATEGORY among the last 6 completed visits at the same property and service (all trucks count towards
--     the 6); a tie goes to the truck that went last; with no truck of a needed category there, the line-item default;
--   * every other visit keeps the old rule (stored truck, else the line-item default) and never says 'usual';
--   * an assigned truck of another category is flagged; a pumping visit reads P, a cleaning visit C.
WITH today AS (SELECT (now() AT TIME ZONE 'America/New_York')::date d),
li AS (
  SELECT l.visit_id, l.job_id, l.invoice_id, s.truck_category
    FROM public.line_items l
    JOIN public.service_line_items s ON s.code = lpad(substring(btrim(l.name) FROM '^([0-9]+)'), 2, '0')
   WHERE s.truck_category IS NOT NULL),
need AS (
  SELECT v.id,
         coalesce((SELECT array_agg(DISTINCT x.truck_category ORDER BY x.truck_category) FROM li x WHERE x.visit_id = v.id),
                  (SELECT array_agg(DISTINCT x.truck_category ORDER BY x.truck_category) FROM li x
                    WHERE x.job_id = v.job_id AND x.visit_id IS NULL AND x.invoice_id IS NULL),
                  (SELECT array_agg(DISTINCT s.truck_category ORDER BY s.truck_category) FROM public.service_line_items s
                    WHERE s.service_type = v.service_type AND s.truck_category IS NOT NULL)) cats
    FROM public.visits v WHERE v.deleted_at IS NULL),
gate AS (
  SELECT v.id, v.property_id, v.service_type, n.cats FROM public.visits v JOIN need n ON n.id = v.id, today
   WHERE v.vehicle_id IS NULL AND v.visit_status = 'scheduled' AND v.visit_date >= today.d),
hist AS (
  SELECT hv.property_id, hv.service_type, hv.vehicle_id, t.truck_category,
         row_number() OVER (PARTITION BY hv.property_id, hv.service_type ORDER BY hv.visit_date DESC, hv.id DESC) rn
    FROM public.visits hv JOIN public.vehicles t ON t.id = hv.vehicle_id AND t.status = 'ACTIVE'
   WHERE hv.deleted_at IS NULL AND hv.visit_status = 'completed'),
expect AS (
  SELECT g.id,
         (SELECT h.vehicle_id FROM hist h
           WHERE h.property_id = g.property_id AND h.service_type = g.service_type AND h.rn <= 6
             AND (g.cats IS NULL OR h.truck_category = ANY (g.cats))
           GROUP BY h.vehicle_id ORDER BY count(*) DESC, min(h.rn) LIMIT 1) usual
    FROM gate g),
cv AS (SELECT c.id, c.vehicle_id, c.assigned_vehicle_id, c.vehicle_source, c.default_truck_basis, c.default_truck_reason,
              c.needed_truck_categories, c.truck_category, c.truck_category_mismatch, c.service_type, c.service_letter,
              e.id IS NOT NULL in_gate, e.usual, n.cats
         FROM ops.v_calendar_visit c LEFT JOIN expect e ON e.id = c.id LEFT JOIN need n ON n.id = c.id),
fails AS (
  SELECT 'usual truck differs from the recount' AS problem, id::text AS detail FROM cv
   WHERE in_gate AND usual IS NOT NULL AND (vehicle_id IS DISTINCT FROM usual OR default_truck_basis IS DISTINCT FROM 'usual')
  UNION ALL
  SELECT 'usual truck shown outside the rule', id::text FROM cv
   WHERE default_truck_basis = 'usual' AND (NOT in_gate OR usual IS NULL)
  UNION ALL
  SELECT 'a usual truck of the wrong category', id::text FROM cv
   WHERE default_truck_basis = 'usual' AND cats IS NOT NULL AND NOT (truck_category = ANY (cats))
  UNION ALL
  SELECT 'needed categories differ from the recount', id::text FROM cv
   WHERE needed_truck_categories IS DISTINCT FROM cats
  UNION ALL
  SELECT 'a mismatch flag differs from the recount', id::text FROM cv
   WHERE truck_category_mismatch IS DISTINCT FROM (CASE WHEN assigned_vehicle_id IS NULL OR cats IS NULL OR truck_category IS NULL THEN NULL
                                                        ELSE NOT (truck_category = ANY (cats)) END)
  UNION ALL
  SELECT 'a P / C letter differs', id::text FROM cv
   WHERE service_letter IS DISTINCT FROM (CASE service_type WHEN 'Pumping' THEN 'P' WHEN 'Cleaning' THEN 'C' END)
  UNION ALL
  SELECT 'an ACTIVE truck has no category', name FROM public.vehicles WHERE status = 'ACTIVE' AND truck_category IS NULL
  UNION ALL
  SELECT 'an assigned visit carries a default reason', id::text FROM cv
   WHERE assigned_vehicle_id IS NOT NULL AND (default_truck_basis IS NOT NULL OR default_truck_reason IS NOT NULL)
  UNION ALL
  SELECT 'an assigned truck is not the stored one', id::text FROM cv
   WHERE assigned_vehicle_id IS NOT NULL AND vehicle_id IS DISTINCT FROM assigned_vehicle_id
  UNION ALL
  SELECT 'a default truck with no sentence', id::text FROM cv
   WHERE assigned_vehicle_id IS NULL AND vehicle_id IS NOT NULL AND coalesce(default_truck_reason, '') = ''
  UNION ALL
  SELECT 'a usual truck not marked default', id::text FROM cv
   WHERE default_truck_basis = 'usual' AND vehicle_source IS DISTINCT FROM 'default'
  UNION ALL
  -- positive controls: each rule must be live somewhere, or every line above passes for nothing
  SELECT 'no usual truck anywhere (control)', NULL WHERE NOT EXISTS (SELECT 1 FROM cv WHERE default_truck_basis = 'usual')
  UNION ALL
  SELECT 'no visit needs a category (control)', NULL WHERE NOT EXISTS (SELECT 1 FROM cv WHERE needed_truck_categories IS NOT NULL)
  UNION ALL
  SELECT 'no P letter anywhere (control)', NULL WHERE NOT EXISTS (SELECT 1 FROM cv WHERE service_letter = 'P'))
SELECT problem, count(*) AS n, (array_agg(detail ORDER BY detail))[1:10] AS examples FROM fails GROUP BY 1
UNION ALL
SELECT 'ok', (SELECT count(*) FROM cv WHERE default_truck_basis = 'usual'), NULL WHERE NOT EXISTS (SELECT 1 FROM fails);
