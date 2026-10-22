-- ROLLBACK of 2026-10-21_2130: put back the 2026-10-21_2120 body (counts_in_totals false on the second visit of a
-- shared stop). Copied from the live definition before 2130.
BEGIN;
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
         -- 2026-10-21_2120: a truck stop shared by two visits is counted once in totals (the lowest visit id keeps it)
         NOT EXISTS (SELECT 1 FROM public.visit_vehicle_stops l1
                       JOIN public.visit_vehicle_stops l2 ON l2.vehicle_stop_id = l1.vehicle_stop_id AND l2.deleted_at IS NULL
                      WHERE l1.visit_id = b.visit_id AND l1.deleted_at IS NULL AND l2.visit_id < b.visit_id)
    FROM b
    JOIN public.clients c ON c.id = b.client_id
    LEFT JOIN d ON d.d_visit_id = b.visit_id
    LEFT JOIN public.employees e ON e.id = d.d_driver_id
   ORDER BY b.visit_date DESC, b.visit_id DESC;
END $function$;
COMMENT ON FUNCTION public.get_water_visits(date, date, bigint) IS 'Water per Moises pumping visit for the apps (Trello dGJ5aFrh); counts_in_totals is false for the second visit of a shared truck stop: arrived, highest, left, pumped (every fill), returned (every pump-back), several_fills, flags, grease kept. One visit: View in Visit Calendar or Admin Review; a period (<= 93 days): View in Admin Review. Over public.v_visit_water_balance. 2026-10-21_2045.';
COMMIT;
