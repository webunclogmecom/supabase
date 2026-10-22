-- 2026-10-21_2310 · Water sentences that were wrong on a few visits (water logic audit B2, B3; Fred: "Fix the wrong sentences")
--
-- Audit: Building Apps/Visit Calendar/docs/specs/2026-10-21-water-logic-audit.md.
-- B2: v_visit_water_balance.no_water_separated (shown as "No water was separated at this stop: the truck kept
--   everything it pumped.") also fired when the level rose 25 to 59 gal, because the zig-zag counts no change under
--   60 gal: 5918 (014-JOY, +47.6 gal held) and 6608 (031-KRU, +56.5 then -86.5). It now also requires highest minus
--   arrived under 25 gal. No total moves.
-- B3: get_water_visits gains levels_span_other_stop (appended, DROP + CREATE): true when the truck parked somewhere else
--   between the visit's own stops AND the levels do not add up (water_balance_closes false). Oct 1-21: 6218 (082-TFC:
--   182-PAL in between) and 5922 (015-FLA: a dump trip in between). The apps show one sentence for it.
-- Also: the function COMMENT now says grease kept is split by trap size (2130 said "equal"). Bodies copied from the live
--   definitions (md5 guards), one anchored change each. RULE 8: no table created or changed.
-- ROLLBACK: docs/migrations/2026-10-21_rollback_water_sentences.sql.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF md5(pg_get_viewdef('public.v_visit_water_balance'::regclass)) <> '8dca1ce3903875b3f2b13f69a187573d'
  OR md5(pg_get_functiondef('public.get_water_visits(date,date,bigint)'::regprocedure)) <> 'ff79fd1a188b8f4a8cd5078b8eca11b0' THEN
    RAISE EXCEPTION 'v_visit_water_balance or get_water_visits changed since this migration was written';
  END IF;
END $g$;

CREATE TEMP TABLE pre_gwv ON COMMIT DROP AS SELECT * FROM public.get_water_visits('2026-08-20', '2026-11-20');

CREATE OR REPLACE VIEW public.v_visit_water_balance AS
 SELECT t.visit_id,
    t.vehicle_id,
    t.client_id,
    t.property_id,
    t.visit_date,
    t.visit_kind,
    t.shared_stop,
    t.link_count,
    t.water_start_gallons,
        CASE
            WHEN (t.visit_kind = 'volume'::text) THEN t.water_refilled_gallons
            ELSE NULL::numeric
        END AS water_separated_gallons,
    t.water_peak_gallons,
        CASE
            WHEN (t.visit_kind = 'volume'::text) THEN t.water_used_gallons
            ELSE NULL::numeric
        END AS water_put_back_gallons,
    t.water_end_gallons,
        CASE
            WHEN (t.visit_kind = 'volume'::text) THEN GREATEST((t.water_used_gallons - t.water_refilled_gallons), (0)::numeric)
            ELSE NULL::numeric
        END AS water_brought_in_at_least_gallons,
        CASE
            WHEN (t.visit_kind = 'volume'::text) THEN GREATEST((t.water_refilled_gallons - t.water_used_gallons), (0)::numeric)
            ELSE NULL::numeric
        END AS water_left_in_truck_at_least_gallons,
        CASE
            WHEN (t.visit_kind = 'dump'::text) THEN ( SELECT round(sum(c.fallen_gallons), 1) AS round
               FROM (visit_vehicle_stops l
                 JOIN v_vehicle_stop_tank_changes c ON (((c.vehicle_stop_id = l.vehicle_stop_id) AND (c.contents = 'fresh_water'::text))))
              WHERE ((l.visit_id = t.visit_id) AND (l.deleted_at IS NULL)))
            ELSE NULL::numeric
        END AS water_moved_to_sludge_at_dump_gallons,
    t.sludge_collected_gallons AS grease_kept_gallons,
    t.sludge_confidence AS grease_confidence,
    t.sludge_change_after_leaving_gallons,
    t.water_change_after_leaving_gallons,
    t.departure_after_leaving,
    (t.water_peak_gallons >= (0.95 * wc.capacity_gallons)) AS water_tank_full,
    ((t.visit_kind = 'volume'::text) AND (t.sludge_collected_gallons >= (200)::numeric) AND (t.water_refilled_gallons < (25)::numeric) AND ((t.water_peak_gallons - t.water_start_gallons) < (25)::numeric)) AS no_water_separated,
        CASE
            WHEN (t.visit_kind = 'volume'::text) THEN (abs((((t.water_start_gallons + t.water_refilled_gallons) - t.water_used_gallons) - t.water_end_gallons)) <= ((0.05 * wc.capacity_gallons) + (1)::numeric))
            ELSE NULL::boolean
        END AS water_balance_closes,
        CASE
            WHEN (t.visit_kind = 'volume'::text) THEN round((t.water_end_gallons - ((t.water_start_gallons + t.water_refilled_gallons) - t.water_used_gallons)), 1)
            ELSE NULL::numeric
        END AS water_unexplained_gallons,
    t.ghost_readings_removed,
    t.water_confidence,
    t.water_reason
   FROM (v_visit_tank_service t
     LEFT JOIN LATERAL ( SELECT c.capacity_gallons
           FROM (vehicle_tanks vt
             JOIN vehicle_tank_configurations c ON (((c.vehicle_tank_id = vt.id) AND (c.superseded_at IS NULL))))
          WHERE ((vt.vehicle_id = t.vehicle_id) AND (vt.contents = 'fresh_water'::text) AND (vt.deleted_at IS NULL) AND (c.effective_from <= COALESCE(t.completed_at, now())))
          ORDER BY c.effective_from DESC NULLS LAST
         LIMIT 1) wc ON (true))
  WHERE (t.water_reason <> 'no_sensor'::text);

DROP FUNCTION public.get_water_visits(date, date, bigint);

CREATE FUNCTION public.get_water_visits(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_visit_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(visit_id bigint, visit_date date, client_id bigint, client_code text, client_name text, driver_id bigint, driver_name text, driver_color text, vehicle_id bigint, arrived_gallons integer, highest_gallons integer, left_gallons integer, pumped_gallons integer, returned_gallons integer, highest_minus_arrived_gallons integer, several_fills boolean, tank_full boolean, no_water_separated boolean, shared_stop boolean, grease_kept_gallons integer, water_tank_capacity_gallons integer, counts_in_totals boolean,
               levels_span_other_stop boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'ops', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
  IF p_visit_id IS NOT NULL THEN
    PERFORM hr.fn_require_any_app(ARRAY['visit_calendar', 'admin_review'], 'view');
  ELSE
    PERFORM hr.fn_require_app('admin_review', 'view');
    IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 93 THEN
      RAISE EXCEPTION 'Pick a period of at most 93 days.'
        USING ERRCODE = '22023', DETAIL = 'blocker=bad_range in public.get_water_visits';
    END IF;
  END IF;
  RETURN QUERY
  WITH b AS MATERIALIZED (
    SELECT w.* FROM public.v_visit_water_balance w
     WHERE w.visit_kind = 'volume'
       AND w.water_start_gallons IS NOT NULL AND w.water_peak_gallons IS NOT NULL AND w.water_end_gallons IS NOT NULL
       AND w.water_separated_gallons IS NOT NULL AND w.water_put_back_gallons IS NOT NULL
       AND (p_visit_id IS NULL OR w.visit_id = p_visit_id)
       AND (p_visit_id IS NOT NULL OR w.visit_date BETWEEN p_from AND p_to)
  ), d AS MATERIALIZED (
    SELECT cv.id AS d_visit_id, cv.driver_id AS d_driver_id
      FROM ops.v_calendar_visit cv WHERE cv.id IN (SELECT b.visit_id FROM b)
  )
  SELECT b.visit_id, b.visit_date, b.client_id, c.client_code, c.name, d.d_driver_id, e.full_name, e.color_hex, b.vehicle_id,
         round(b.water_start_gallons)::int, round(b.water_peak_gallons)::int, round(b.water_end_gallons)::int,
         round(b.water_separated_gallons)::int, round(b.water_put_back_gallons)::int,
         round(b.water_peak_gallons - b.water_start_gallons)::int,
         b.water_separated_gallons > b.water_peak_gallons - b.water_start_gallons + 10,
         coalesce(b.water_tank_full, false), coalesce(b.no_water_separated, false), coalesce(b.shared_stop, false),
         CASE WHEN b.grease_confidence IN ('high', 'medium') AND b.grease_kept_gallons >= 0
              THEN round(b.grease_kept_gallons)::int END,
         -- 2026-10-21_2100: the water tank's capacity in force that day (vehicle_tank_configurations), for the chart
         (SELECT round(tc.capacity_gallons)::int
            FROM public.vehicle_tanks vt
            JOIN public.vehicle_tank_configurations tc ON tc.vehicle_tank_id = vt.id AND tc.superseded_at IS NULL
           WHERE vt.vehicle_id = b.vehicle_id AND vt.contents = 'fresh_water' AND vt.deleted_at IS NULL
             AND tc.effective_from < (b.visit_date + 1)::timestamptz
           ORDER BY tc.effective_from DESC LIMIT 1),
         -- 2026-10-22_0420: every row counts. On a shared stop v_visit_water_balance already splits pumped, returned and
         -- grease kept equally between the visits (water_share), so the rows add up to the stop; kept for the apps
         true,
         -- 2026-10-21_2310: the truck parked somewhere else between this visit's own stops AND the levels do not add up
         -- (arrived + pumped - returned is not left), so Arrived / Left include water that moved at the other stop
         NOT coalesce(b.water_balance_closes, true) AND EXISTS (
           SELECT 1 FROM public.vehicle_stops s
            WHERE s.vehicle_id = b.vehicle_id AND s.superseded_at IS NULL
              AND s.arrived_at > (SELECT min(s1.arrived_at) FROM public.visit_vehicle_stops l1 JOIN public.vehicle_stops s1 ON s1.id = l1.vehicle_stop_id
                                   WHERE l1.visit_id = b.visit_id AND l1.deleted_at IS NULL)
              AND s.arrived_at < (SELECT max(s1.arrived_at) FROM public.visit_vehicle_stops l1 JOIN public.vehicle_stops s1 ON s1.id = l1.vehicle_stop_id
                                   WHERE l1.visit_id = b.visit_id AND l1.deleted_at IS NULL)
              AND NOT EXISTS (SELECT 1 FROM public.visit_vehicle_stops l2
                               WHERE l2.visit_id = b.visit_id AND l2.vehicle_stop_id = s.id AND l2.deleted_at IS NULL))
    FROM b
    JOIN public.clients c ON c.id = b.client_id
    LEFT JOIN d ON d.d_visit_id = b.visit_id
    LEFT JOIN public.employees e ON e.id = d.d_driver_id
   ORDER BY b.visit_date DESC, b.visit_id DESC;
END $function$;

REVOKE ALL ON FUNCTION public.get_water_visits(date, date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_water_visits(date, date, bigint) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_water_visits(date, date, bigint) IS 'Water per Moises pumping visit for the apps (Trello dGJ5aFrh): arrived, highest, left (the whole truck stop''s levels), pumped (every rise), returned (every fall), grease kept (high / medium confidence only); on a shared stop pumped and returned are the visit''s equal share and grease kept its trap-size share. several_fills = pumped > highest - arrived + 10 (the level went up and down more than once; it also fires on one fill preceded by a push-back). levels_span_other_stop = the truck parked elsewhere between the visit''s own stops and the levels do not add up. counts_in_totals is always true (kept for the apps). One visit: View in Visit Calendar or Admin Review; a period (<= 93 days): View in Admin Review. 2026-10-21_2045, _2100, _2120, _2130, _2310.';

-- VERIFY
DO $v$
DECLARE n int; s text;
BEGIN
  -- 1. the no-water line: exactly the five visits whose level did not rise (5918 and 6608 dropped)
  SELECT string_agg(visit_id::text, ',' ORDER BY visit_id) INTO s FROM public.get_water_visits('2026-10-01', '2026-10-21') WHERE no_water_separated;
  IF s IS DISTINCT FROM '6002,6276,6744,7029,8089' THEN RAISE EXCEPTION 'VERIFY 1 no_water_separated: %', s; END IF;
  -- control: the old rule had them
  IF (SELECT count(*) FROM pre_gwv WHERE no_water_separated AND visit_id IN (5918, 6608)) <> 2 THEN RAISE EXCEPTION 'VERIFY 1 control'; END IF;
  -- 2. the span flag: exactly 6218 and 5922
  SELECT string_agg(visit_id::text, ',' ORDER BY visit_id) INTO s FROM public.get_water_visits('2026-10-01', '2026-10-21') WHERE levels_span_other_stop;
  IF s IS DISTINCT FROM '5922,6218' THEN RAISE EXCEPTION 'VERIFY 2 levels_span_other_stop: %', s; END IF;
  -- 3. nothing else moved
  SELECT count(*) INTO n FROM (SELECT visit_id, visit_date, client_id, client_code, client_name, driver_id, driver_name, driver_color, vehicle_id, arrived_gallons, highest_gallons, left_gallons, pumped_gallons, returned_gallons, highest_minus_arrived_gallons, several_fills, tank_full, shared_stop, grease_kept_gallons, water_tank_capacity_gallons, counts_in_totals FROM public.get_water_visits('2026-08-20', '2026-11-20')
                               EXCEPT SELECT visit_id, visit_date, client_id, client_code, client_name, driver_id, driver_name, driver_color, vehicle_id, arrived_gallons, highest_gallons, left_gallons, pumped_gallons, returned_gallons, highest_minus_arrived_gallons, several_fills, tank_full, shared_stop, grease_kept_gallons, water_tank_capacity_gallons, counts_in_totals FROM pre_gwv) x;
  IF n <> 0 OR (SELECT count(*) FROM pre_gwv) <> (SELECT count(*) FROM public.get_water_visits('2026-08-20', '2026-11-20')) THEN
    RAISE EXCEPTION 'VERIFY 3: % rows differ', n;
  END IF;
  SELECT count(*) INTO n FROM public.get_water_visits('2026-08-20', '2026-11-20') g JOIN pre_gwv p USING (visit_id)
   WHERE g.no_water_separated IS DISTINCT FROM p.no_water_separated AND g.visit_id NOT IN (5918, 6608);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3b: % other flag changes', n; END IF;
  -- 4. grants and view ACL
  IF has_function_privilege('anon', 'public.get_water_visits(date,date,bigint)', 'EXECUTE')
  OR NOT has_function_privilege('authenticated', 'public.get_water_visits(date,date,bigint)', 'EXECUTE')
  OR (SELECT relacl::text FROM pg_class WHERE oid = 'public.v_visit_water_balance'::regclass)
     <> '{postgres=arwdDxtm/postgres,db_backup_reader=r/postgres,service_role=r/postgres}' THEN
    RAISE EXCEPTION 'VERIFY 4: grants';
  END IF;
END $v$;

COMMIT;
