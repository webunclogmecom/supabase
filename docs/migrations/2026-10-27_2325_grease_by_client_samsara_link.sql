-- 2026-10-27_2325_grease_by_client_samsara_link.sql
-- Trello 6M9WvSYp, Admin Review "Grease by client" page (spec: Building Apps/Admin Review/docs/specs/
-- 2026-10-27-grease-by-client-page.md).
-- Fred, 2026-10-27, on the mockups: "when displaying the readings of a client, it shows the visit, but i also want to
-- have there like a button good styled to open that visit in Samsara and to include the driver, even if there was none."
-- He then picked layout A on a laptop or wider screen and layout B on smaller ones.
--
-- WHAT CHANGES: public.get_grease_by_client() gains five columns at the END, so the page builds no link and no time
-- window of its own:
--   arrived_at, left_at   = visits.actual_arrival_at / actual_departure_at (the time on site), may be NULL
--   completed_at          = when the visit was marked done
--   samsara_url           = the truck's Samsara page from 15 minutes before arrived_at to 15 minutes after left_at (the
--                           link the 11 AM time-on-site alert uses, checked by Fred 2026-10-12); with no time on site,
--                           the hour before completed_at. No Samsara truck: the client's Samsara place for the 31 days
--                           ending that visit day (ET). Neither: NULL.
--   samsara_link_kind     = 'truck' | 'place' | NULL (the button's label)
-- The 23 existing columns and every row are unchanged: VERIFY compares them with the old function's rows, taken in this
-- same transaction before the DROP.
-- Body: the live body (md5 pinned below) with three anchored additions; nothing retyped. The return type changes, so it
-- is DROP + CREATE (no app reads it yet; scripts/checks/grease_by_client.sql selects *). Grants re-applied by name.
-- Reads only. visits.actual_arrival_at / actual_departure_at are held by the visit-duration re-check session (vpF5PLQj):
-- READ here, never written. Rule 8: no table touched.
-- Rollback: 2026-10-27_rollback_grease_by_client_samsara_link.sql (the previous body, verbatim).
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$ BEGIN
  IF md5(pg_get_functiondef('public.get_grease_by_client()'::regprocedure)) <> 'eeac40eeb1c11e0540e4dd3cecb68aa6' THEN
    RAISE EXCEPTION 'public.get_grease_by_client changed since this migration was written: rebuild it from the live body';
  END IF;
END $pin$;

CREATE TEMP TABLE _old_grease ON COMMIT DROP AS SELECT * FROM public.get_grease_by_client();

DROP FUNCTION public.get_grease_by_client();

CREATE FUNCTION public.get_grease_by_client()
 RETURNS TABLE(client_id bigint, client_code text, client_name text, property_id bigint, property_address text, pump_kind text, trap_size_gallons integer, avg_gallons integer, readings_in_average integer, min_gallons integer, max_gallons integer, last_reading_date date, visit_id bigint, visit_date date, vehicle_id bigint, truck_name text, truck_color text, driver_name text, driver_color text, gallons integer, in_average boolean, note text, above_trap_size boolean, arrived_at timestamp with time zone, left_at timestamp with time zone, completed_at timestamp with time zone, samsara_url text, samsara_link_kind text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'ops', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
  PERFORM hr.fn_require_app('admin_review', 'view');
  RETURN QUERY
  WITH t AS MATERIALIZED (
    SELECT s.*, ops.fn_visit_pump_kind(s.visit_id, v.job_id) AS kind,
           v.actual_arrival_at AS on_arr, v.actual_departure_at AS on_dep
      FROM public.v_visit_tank_service s
      JOIN public.visits v ON v.id = s.visit_id
     WHERE s.visit_kind = 'volume'
       AND NOT EXISTS (SELECT 1 FROM public.v_non_customer_clients n WHERE n.client_id = s.client_id)
  ), a AS MATERIALIZED (
    -- the Calendar's average, as of tomorrow ET so today's readings are in (ops.v_client_sludge_average does the same)
    SELECT f.property_id, f.pump_kind, f.readings_n, f.avg_gallons, f.last_reading_date, f.readings
      FROM ops.fn_client_sludge_averages(ARRAY[(now() AT TIME ZONE 'America/New_York')::date + 1]) f
  ), d AS MATERIALIZED (
    SELECT cv.id AS d_visit_id, cv.driver_id AS d_driver_id
      FROM ops.v_calendar_visit cv WHERE cv.id IN (SELECT t.visit_id FROM t)
  )
  SELECT t.client_id, c.client_code, c.name,
         t.property_id, p.address, t.kind, NULLIF(p.grease_trap_size_gallons, 0)::int,
         a.avg_gallons::int, a.readings_n,
         (SELECT min((r->>'gallons')::numeric) FROM jsonb_array_elements(a.readings) r)::int,
         (SELECT max((r->>'gallons')::numeric) FROM jsonb_array_elements(a.readings) r)::int,
         a.last_reading_date,
         t.visit_id, t.visit_date, t.vehicle_id, vh.name, vh.color_hex,
         e.full_name, e.color_hex,
         CASE WHEN t.sludge_collected_gallons > 0 THEN round(t.sludge_collected_gallons)::int END,
         COALESCE(a.readings @> jsonb_build_array(jsonb_build_object('visit_id', t.visit_id)), false),
         CASE
           -- in the average: only a note when the reading is a little less certain
           WHEN COALESCE(a.readings @> jsonb_build_array(jsonb_build_object('visit_id', t.visit_id)), false) THEN
             CASE t.sludge_reason
               WHEN 'shared_stop_allocated' THEN 'Shared truck stop: the reading is split with the other visit.'
               WHEN 'window_match' THEN 'Matched to the truck stop by time.'
               WHEN 'no_pump_signal' THEN 'No engine data to confirm the pump ran.'
               ELSE NULL END
           WHEN t.vehicle_id IS NULL THEN 'No truck on this visit.'
           WHEN t.sludge_reason = 'no_sensor' THEN 'No sensor on this truck.'
           WHEN t.sludge_reason = 'no_stop' THEN 'No truck stop was found for this visit.'
           WHEN t.sludge_reason IN ('no_config', 'edge_missing') THEN 'The tank level before or after the visit is missing.'
           WHEN t.sludge_reason = 'too_short' THEN 'The truck stop was too short to measure.'
           WHEN t.sludge_reason = 'below_resolution' THEN 'Too small for the sensor to measure on a trap this size.'
           WHEN t.sludge_reason = 'tank_at_ceiling' THEN 'The truck''s tank was full, so the reading may be low.'
           WHEN t.sludge_reason = 'pumped_no_rise' THEN 'The pump ran but the tank level did not go up.'
           WHEN t.sludge_reason = 'rise_without_pump' THEN 'The tank level went up but the pump did not run.'
           WHEN t.sludge_collected_gallons IS NULL THEN 'No reading.'
           WHEN t.sludge_collected_gallons < 40 THEN 'Less than 40 gal, too small to count.'
           WHEN t.sludge_collected_gallons > 3840 THEN 'More than the truck holds (3,840 gal).'
           WHEN t.kind IS NULL THEN 'No pumping service on this visit''s lines.'
           ELSE 'Older than the last 6 readings, so not in the average.'
         END,
         COALESCE(t.sludge_above_trap_size, false),
         t.on_arr, t.on_dep, t.completed_at,
         sl.url, sl.link_kind
    FROM t
    JOIN public.clients c ON c.id = t.client_id
    LEFT JOIN public.properties p ON p.id = t.property_id
    LEFT JOIN a ON a.property_id = t.property_id AND a.pump_kind = t.kind
    LEFT JOIN public.vehicles vh ON vh.id = t.vehicle_id
    LEFT JOIN d ON d.d_visit_id = t.visit_id
    LEFT JOIN public.employees e ON e.id = d.d_driver_id
    -- Samsara (2026-10-27): the truck's page over the time on site, 15 minutes either side (the link the 11 AM
    -- time-on-site alert uses); no time on site = the hour before the completion. No truck: the client's Samsara place.
    LEFT JOIN LATERAL (SELECT l.source_id FROM public.entity_source_links l
                        WHERE l.entity_type = 'vehicle' AND l.source_system = 'samsara' AND l.entity_id = t.vehicle_id
                        ORDER BY l.id LIMIT 1) vl ON true
    LEFT JOIN LATERAL (SELECT l.source_id FROM public.entity_source_links l
                        WHERE l.entity_type = 'property' AND l.source_system = 'samsara' AND l.entity_id = t.property_id
                        ORDER BY l.id LIMIT 1) pl ON true
    LEFT JOIN LATERAL (
      SELECT CASE WHEN vl.source_id IS NOT NULL AND w.wf IS NOT NULL THEN
                    format('https://cloud.samsara.com/o/6009037/devices/%s/vehicle?end_ms=%s&duration=%s', vl.source_id,
                           (extract(epoch FROM w.wt) * 1000)::bigint, least(86400, round(extract(epoch FROM w.wt - w.wf)))::bigint)
                  WHEN pl.source_id IS NOT NULL THEN
                    format('https://cloud.samsara.com/o/6009037/fleet/places/%s?duration=2678399.999&end_ms=%s', pl.source_id,
                           (extract(epoch FROM ((t.visit_date + 1)::timestamp AT TIME ZONE 'America/New_York')) * 1000)::bigint - 1)
             END AS url,
             CASE WHEN vl.source_id IS NOT NULL AND w.wf IS NOT NULL THEN 'truck' WHEN pl.source_id IS NOT NULL THEN 'place' END AS link_kind
        FROM (SELECT COALESCE(t.on_arr, t.completed_at - interval '1 hour') - interval '15 minutes' AS wf,
                     COALESCE(t.on_dep, t.completed_at) + interval '15 minutes' AS wt) w
    ) sl ON true
   ORDER BY c.client_code NULLS LAST, t.property_id, t.kind NULLS LAST, t.visit_date DESC, t.visit_id DESC;
END $function$;

REVOKE ALL ON FUNCTION public.get_grease_by_client() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_grease_by_client() TO authenticated, service_role;
COMMENT ON FUNCTION public.get_grease_by_client() IS
  'Admin Review "Grease by client" (Trello 6M9WvSYp): one row per completed pumping visit since the Moises sensor, with the Calendar''s average for its place and pump kind (ops.fn_client_sludge_averages), whether the reading is in it, a plain note when not, the time on site and a Samsara link. View in Admin Review.';

DO $verify$
DECLARE n_old int; n_new int; d1 int; d2 int; n_truck int; n_truck_exp int; n_bad int;
BEGIN
  IF has_function_privilege('anon', 'public.get_grease_by_client()', 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: anon can execute'; END IF;
  IF NOT has_function_privilege('authenticated', 'public.get_grease_by_client()', 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: authenticated cannot execute'; END IF;
  IF NOT has_function_privilege('service_role', 'public.get_grease_by_client()', 'EXECUTE') THEN RAISE EXCEPTION 'VERIFY: service_role cannot execute'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a WHERE p.oid = 'public.get_grease_by_client()'::regprocedure AND a.grantee = 0) THEN
    RAISE EXCEPTION 'VERIFY: PUBLIC holds EXECUTE'; END IF;

  CREATE TEMP TABLE _new_grease ON COMMIT DROP AS SELECT * FROM public.get_grease_by_client();
  SELECT count(*) INTO n_old FROM _old_grease;
  SELECT count(*) INTO n_new FROM _new_grease;
  IF n_new <> n_old OR n_new < 200 THEN RAISE EXCEPTION 'VERIFY: % rows now, % before', n_new, n_old; END IF;
  -- nothing else moved: the 23 old columns, row for row
  SELECT count(*) INTO d1 FROM (SELECT client_id, client_code, client_name, property_id, property_address, pump_kind, trap_size_gallons, avg_gallons, readings_in_average, min_gallons, max_gallons, last_reading_date, visit_id, visit_date, vehicle_id, truck_name, truck_color, driver_name, driver_color, gallons, in_average, note, above_trap_size FROM _new_grease EXCEPT ALL SELECT * FROM _old_grease) x;
  SELECT count(*) INTO d2 FROM (SELECT * FROM _old_grease EXCEPT ALL SELECT client_id, client_code, client_name, property_id, property_address, pump_kind, trap_size_gallons, avg_gallons, readings_in_average, min_gallons, max_gallons, last_reading_date, visit_id, visit_date, vehicle_id, truck_name, truck_color, driver_name, driver_color, gallons, in_average, note, above_trap_size FROM _new_grease) x;
  IF d1 + d2 > 0 THEN RAISE EXCEPTION 'VERIFY: % / % old-column rows differ', d1, d2; END IF;

  -- every visit whose truck is in Samsara and has a time gets a truck link (computed independently)
  SELECT count(*) FILTER (WHERE samsara_link_kind = 'truck'),
         count(*) FILTER (WHERE coalesce(arrived_at, completed_at) IS NOT NULL AND EXISTS (
           SELECT 1 FROM public.entity_source_links l WHERE l.entity_type = 'vehicle' AND l.source_system = 'samsara' AND l.entity_id = g.vehicle_id))
    INTO n_truck, n_truck_exp FROM _new_grease g;
  IF n_truck <> n_truck_exp OR n_truck < 200 THEN RAISE EXCEPTION 'VERIFY: % truck links, expected %', n_truck, n_truck_exp; END IF;

  -- truck links: right shape, 30 min to 24 h long, ending 15 minutes after the visit left (or was completed)
  SELECT count(*) INTO n_bad FROM _new_grease g
   WHERE samsara_link_kind = 'truck'
     AND (samsara_url NOT LIKE 'https://cloud.samsara.com/o/6009037/devices/%/vehicle?end_ms=%&duration=%'
          OR split_part(samsara_url, 'duration=', 2)::bigint NOT BETWEEN 1800 AND 86400
          OR abs(split_part(split_part(samsara_url, 'end_ms=', 2), '&', 1)::bigint
                 - (extract(epoch FROM coalesce(left_at, completed_at) + interval '15 minutes') * 1000)::bigint) > 1);
  IF n_bad > 0 THEN RAISE EXCEPTION 'VERIFY: % truck links malformed', n_bad; END IF;

  SELECT count(*) INTO n_bad FROM _new_grease
   WHERE (samsara_link_kind = 'place' AND samsara_url NOT LIKE 'https://cloud.samsara.com/o/6009037/fleet/places/%?duration=2678399.999&end_ms=%')
      OR (samsara_link_kind IS NULL) <> (samsara_url IS NULL)
      OR samsara_link_kind NOT IN ('truck', 'place');
  IF n_bad > 0 THEN RAISE EXCEPTION 'VERIFY: % place links or kinds wrong', n_bad; END IF;

  -- a row with no link has no Samsara truck with a time and no Samsara place
  SELECT count(*) INTO n_bad FROM _new_grease g
   WHERE samsara_link_kind IS NULL
     AND (EXISTS (SELECT 1 FROM public.entity_source_links l WHERE l.entity_type = 'property' AND l.source_system = 'samsara' AND l.entity_id = g.property_id)
          OR (coalesce(arrived_at, completed_at) IS NOT NULL AND EXISTS (
              SELECT 1 FROM public.entity_source_links l WHERE l.entity_type = 'vehicle' AND l.source_system = 'samsara' AND l.entity_id = g.vehicle_id)));
  IF n_bad > 0 THEN RAISE EXCEPTION 'VERIFY: % rows missing a link they could have', n_bad; END IF;

  -- left before arrived would make a negative window
  SELECT count(*) INTO n_bad FROM _new_grease WHERE left_at < arrived_at;
  IF n_bad > 0 THEN RAISE EXCEPTION 'VERIFY: % rows leave before they arrive', n_bad; END IF;

  RAISE NOTICE 'VERIFY ok: % rows, % truck links', n_new, n_truck;
END $verify$;

COMMIT;
