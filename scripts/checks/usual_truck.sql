-- Standing check for the usual truck in ops.v_calendar_visit (Trello alpHmTtL, migration 2026-10-29_1700).
-- Run as postgres (Management API). Healthy = ONE row: problem = 'ok'. Any other row names what broke.
-- The rule, recomputed here on its own: a visit with no stored truck, scheduled, dated today (ET) or later, shows the
-- most frequent ACTIVE truck of the last 6 completed visits at the same property and service; a tie goes to the truck
-- that went last. Every other visit keeps the old rule (stored truck, else the line-item default) and never says 'usual'.
WITH today AS (SELECT (now() AT TIME ZONE 'America/New_York')::date d),
gate AS (
  SELECT v.id, v.property_id, v.service_type FROM public.visits v, today
   WHERE v.deleted_at IS NULL AND v.vehicle_id IS NULL AND v.visit_status = 'scheduled' AND v.visit_date >= today.d),
hist AS (
  SELECT hv.property_id, hv.service_type, hv.vehicle_id,
         row_number() OVER (PARTITION BY hv.property_id, hv.service_type ORDER BY hv.visit_date DESC, hv.id DESC) rn
    FROM public.visits hv JOIN public.vehicles t ON t.id = hv.vehicle_id AND t.status = 'ACTIVE'
   WHERE hv.deleted_at IS NULL AND hv.visit_status = 'completed'),
agg AS (SELECT property_id, service_type, vehicle_id, count(*) n, min(rn) last_rn FROM hist WHERE rn <= 6 GROUP BY 1, 2, 3),
best AS (SELECT DISTINCT ON (property_id, service_type) property_id, service_type, vehicle_id
           FROM agg ORDER BY property_id, service_type, n DESC, last_rn),
expect AS (SELECT g.id, b.vehicle_id usual FROM gate g
             LEFT JOIN best b ON b.property_id = g.property_id AND b.service_type = g.service_type),
cv AS (SELECT c.id, c.vehicle_id, c.assigned_vehicle_id, c.vehicle_source, c.default_truck_basis, c.default_truck_reason,
              e.id IS NOT NULL in_gate, e.usual
         FROM ops.v_calendar_visit c LEFT JOIN expect e ON e.id = c.id),
fails AS (
  SELECT 'usual truck differs from the recount' AS problem, id::text AS detail FROM cv
   WHERE in_gate AND usual IS NOT NULL AND (vehicle_id IS DISTINCT FROM usual OR default_truck_basis IS DISTINCT FROM 'usual')
  UNION ALL
  SELECT 'usual truck shown outside the rule', id::text FROM cv
   WHERE default_truck_basis = 'usual' AND (NOT in_gate OR usual IS NULL)
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
  -- positive control: the rule must be live somewhere, or every line above passes for nothing
  SELECT 'no usual truck anywhere (control)', NULL WHERE NOT EXISTS (SELECT 1 FROM cv WHERE default_truck_basis = 'usual'))
SELECT problem, count(*) AS n, (array_agg(detail ORDER BY detail))[1:10] AS examples FROM fails GROUP BY 1
UNION ALL
SELECT 'ok', (SELECT count(*) FROM cv WHERE default_truck_basis = 'usual'), NULL WHERE NOT EXISTS (SELECT 1 FROM fails);
