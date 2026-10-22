-- 2026-10-21_2130 · get_water_visits: every row counts in the driver totals (fixes 2026-10-21_2120)
--
-- 2026-10-21_2120 made counts_in_totals false for the second visit of a shared truck stop, on the belief that each
-- visit carried the WHOLE stop's water. It does not: v_visit_tank_service splits a shared stop's pumped, returned and
-- grease kept EQUALLY between its visits (water_share = 1 / visits on the stop; only arrived / highest / left are the
-- whole stop's levels). Measured: stop 1247 (Oct 6, 059-SK + 025-GRO) rose 799 gal, each visit reads 400; the Admin
-- Review Water by driver page therefore dropped half a stop per shared pair (Michael, October: 19,632 shown, 20,032
-- right). Found while preparing the raw-readings check for Yan (Trello dGJ5aFrh, "Verify").
-- WHAT: counts_in_totals is TRUE on every row. The column stays (same return type, CREATE OR REPLACE) because the live
-- Admin Review bundle filters on it; with it always true the page sums every row and its "counted once" chip never
-- shows. Body copied from the live definition (md5 guard), one anchored change.
-- RULE 8: no table created or changed. ROLLBACK: docs/migrations/2026-10-21_rollback_water_visits_shared_stop_split.sql.

BEGIN;

DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.get_water_visits(date,date,bigint)'::regprocedure)) <> 'b443aff433db4778615f19bb8abe65af' THEN
    RAISE EXCEPTION 'get_water_visits changed since this migration was written';
  END IF;
END $g$;

CREATE TEMP TABLE pre_gwv ON COMMIT DROP AS SELECT * FROM public.get_water_visits('2026-08-20', '2026-11-20');

CREATE OR REPLACE FUNCTION public.get_water_visits(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_visit_id bigint DEFAULT NULL::bigint)
 RETURNS TABLE(visit_id bigint, visit_date date, client_id bigint, client_code text, client_name text, driver_id bigint, driver_name text, driver_color text, vehicle_id bigint, arrived_gallons integer, highest_gallons integer, left_gallons integer, pumped_gallons integer, returned_gallons integer, highest_minus_arrived_gallons integer, several_fills boolean, tank_full boolean, no_water_separated boolean, shared_stop boolean, grease_kept_gallons integer, water_tank_capacity_gallons integer, counts_in_totals boolean)
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
         true
    FROM b
    JOIN public.clients c ON c.id = b.client_id
    LEFT JOIN d ON d.d_visit_id = b.visit_id
    LEFT JOIN public.employees e ON e.id = d.d_driver_id
   ORDER BY b.visit_date DESC, b.visit_id DESC;
END $function$;

COMMENT ON FUNCTION public.get_water_visits(date, date, bigint) IS 'Water per Moises pumping visit for the apps (Trello dGJ5aFrh): arrived, highest, left (the whole truck stop''s levels), pumped (every fill), returned (every pump-back), grease kept (on a shared stop these three are the visit''s equal share, so rows add up), several_fills, flags, tank capacity; counts_in_totals is always true (kept for the apps). One visit: View in Visit Calendar or Admin Review; a period (<= 93 days): View in Admin Review. Over public.v_visit_water_balance. 2026-10-21_2045, _2100, _2120, _2130.';

-- VERIFY
DO $v$
DECLARE n int; r record;
BEGIN
  -- 1. every row counts
  SELECT count(*) INTO n FROM public.get_water_visits('2026-08-20', '2026-11-20') WHERE NOT counts_in_totals;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 1: % rows still excluded', n; END IF;
  -- 2. nothing else moved: every other column equals the output before the change
  SELECT count(*) INTO n FROM (
    SELECT visit_id, visit_date, client_id, client_code, client_name, driver_id, driver_name, driver_color, vehicle_id,
           arrived_gallons, highest_gallons, left_gallons, pumped_gallons, returned_gallons, highest_minus_arrived_gallons,
           several_fills, tank_full, no_water_separated, shared_stop, grease_kept_gallons, water_tank_capacity_gallons
      FROM public.get_water_visits('2026-08-20', '2026-11-20')
    EXCEPT
    SELECT visit_id, visit_date, client_id, client_code, client_name, driver_id, driver_name, driver_color, vehicle_id,
           arrived_gallons, highest_gallons, left_gallons, pumped_gallons, returned_gallons, highest_minus_arrived_gallons,
           several_fills, tank_full, no_water_separated, shared_stop, grease_kept_gallons, water_tank_capacity_gallons
      FROM pre_gwv) x;
  IF n <> 0 OR (SELECT count(*) FROM pre_gwv) <> (SELECT count(*) FROM public.get_water_visits('2026-08-20', '2026-11-20')) THEN
    RAISE EXCEPTION 'VERIFY 2: % rows differ from before', n;
  END IF;
  -- 3. independent control: the visits sharing stop 1247 add up to the stop's own rise and fall (the old rule kept
  --    one visit, 400 of 799, and fails this)
  SELECT round(tl.fill_fraction_risen * 1200) AS risen, round(tl.fill_fraction_fallen * 1200) AS fallen,
         (SELECT sum(g.pumped_gallons) FROM public.get_water_visits('2026-10-06', '2026-10-06') g
           WHERE g.counts_in_totals AND g.visit_id IN (SELECT l.visit_id FROM public.visit_vehicle_stops l
                                                        WHERE l.vehicle_stop_id = 1247 AND l.deleted_at IS NULL)) AS p,
         (SELECT sum(g.returned_gallons) FROM public.get_water_visits('2026-10-06', '2026-10-06') g
           WHERE g.counts_in_totals AND g.visit_id IN (SELECT l.visit_id FROM public.visit_vehicle_stops l
                                                        WHERE l.vehicle_stop_id = 1247 AND l.deleted_at IS NULL)) AS rt
    INTO r
    FROM public.vehicle_stop_tank_levels tl
    JOIN public.vehicle_tanks vt ON vt.id = tl.vehicle_tank_id AND vt.contents = 'fresh_water'
   WHERE tl.vehicle_stop_id = 1247 AND tl.superseded_at IS NULL;
  IF r.risen IS NULL OR r.p IS NULL OR abs(r.p - r.risen) > 2 OR abs(r.rt - r.fallen) > 2 THEN
    RAISE EXCEPTION 'VERIFY 3: stop 1247 rose % fell %, its visits add to % / %', r.risen, r.fallen, r.p, r.rt;
  END IF;
  -- 4. 6570 unchanged
  SELECT * INTO r FROM public.get_water_visits(p_visit_id => 6570);
  IF r.pumped_gallons <> 872 OR r.returned_gallons <> 954 OR NOT r.counts_in_totals THEN
    RAISE EXCEPTION 'VERIFY 4: %', row_to_json(r);
  END IF;
  -- 5. grants unchanged
  IF has_function_privilege('anon', 'public.get_water_visits(date,date,bigint)', 'EXECUTE')
  OR NOT has_function_privilege('authenticated', 'public.get_water_visits(date,date,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 5: grants';
  END IF;
END $v$;

COMMIT;
