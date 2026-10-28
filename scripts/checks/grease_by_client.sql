-- Standing check for public.get_grease_by_client() (Admin Review "Grease by client", Trello 6M9WvSYp).
-- Run as postgres (Management API). Healthy = ONE row: problem = 'ok'. Any other row names what broke.
-- The page must show the Calendar's average (ops.v_client_sludge_average), never a number of its own.
WITH g AS (SELECT * FROM public.get_grease_by_client()),
grp AS (
  SELECT property_id, pump_kind, max(avg_gallons) av, max(readings_in_average) n, max(last_reading_date) last_d,
         count(*) FILTER (WHERE in_average) k, round(avg(gallons) FILTER (WHERE in_average)) recomputed
    FROM g WHERE avg_gallons IS NOT NULL GROUP BY 1, 2),
fails AS (
  SELECT 'average differs from the Calendar' AS problem, x.property_id::text AS detail
    FROM grp x LEFT JOIN ops.v_client_sludge_average v ON v.property_id = x.property_id AND v.pump_kind = x.pump_kind
   WHERE v.avg_gallons IS DISTINCT FROM x.av OR v.readings_n IS DISTINCT FROM x.n OR v.last_reading_date IS DISTINCT FROM x.last_d
  UNION ALL
  SELECT 'listed readings do not add up to the average', property_id::text FROM grp WHERE n <> k OR abs(av - recomputed) > 1
  UNION ALL
  SELECT 'a Calendar average is missing from the page', v.property_id::text
    FROM ops.v_client_sludge_average v
   WHERE NOT EXISTS (SELECT 1 FROM grp WHERE grp.property_id = v.property_id AND grp.pump_kind = v.pump_kind)
     AND NOT EXISTS (SELECT 1 FROM public.v_non_customer_clients n WHERE n.client_id = v.client_id)
  UNION ALL
  SELECT 'left-out visit with no reason', visit_id::text FROM g WHERE NOT in_average AND note IS NULL
  UNION ALL
  SELECT 'a reading shown as 0', visit_id::text FROM g WHERE gallons = 0
  UNION ALL
  -- the Samsara button (2026-10-27_2325): a visit whose truck is in Samsara and has a time must get the truck link
  SELECT 'no Samsara truck link although the truck is in Samsara', g.visit_id::text FROM g
   WHERE g.samsara_link_kind IS DISTINCT FROM 'truck' AND coalesce(g.arrived_at, g.completed_at) IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.entity_source_links l
                  WHERE l.entity_type = 'vehicle' AND l.source_system = 'samsara' AND l.entity_id = g.vehicle_id)
  UNION ALL
  -- positive control: the instrument is pointed at real data
  SELECT 'control: fewer than 100 counted Moises readings', NULL
   WHERE (SELECT count(*) FROM g WHERE truck_name = 'Moises' AND in_average) < 100
)
SELECT problem, detail FROM fails
UNION ALL
SELECT 'ok', (SELECT count(*) FROM g)::text || ' visits' WHERE NOT EXISTS (SELECT 1 FROM fails);
