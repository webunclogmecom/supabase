-- 2026-10-21_2045 · Water per Moises visit: the apps' read path (Trello dGJ5aFrh)
--
-- Yan (Oct 13 huddle): per visit the water when the truck arrives, the highest level and when it leaves; "he pumped
-- 700 and he rejected 800". Fred 2026-10-22: pumped and returned count EVERY fill cycle (the sum of every rise / fall,
-- public.v_visit_water_balance), shown in the Visit Calendar drawer and the Admin Review visit page, plus an Admin
-- Review "Water by driver" page (mockups A, C, D: https://claude.ai/artifact/SqQJ3rwCpu9JopHE3h1VUY). Plan:
-- Building Apps/Visit Calendar/docs/specs/2026-10-22-moises-water-per-visit-and-driver-plan.md.
--
-- WHAT: public.get_water_visits(p_from, p_to, p_visit_id), SECURITY DEFINER over v_visit_water_balance (which stays
-- service_role only). One visit (p_visit_id): View in the Visit Calendar OR Admin Review. A period (driver page): View in
-- Admin Review, at most 93 days. Rows only for pumping visits with all five water figures. Whole gallons; the app never
-- computes: highest_minus_arrived_gallons and several_fills (pumped more than highest minus arrived + 10 gal, i.e. the
-- crew filled, pumped back and filled again) come from here. grease_kept_gallons only when its confidence is high or
-- medium and it is not negative (else NULL). Driver = ops.v_calendar_visit.driver_id (COALESCE(actual, assigned)).
-- RULE 8: no table created or changed. EXECUTE: authenticated + service_role, revoked by name from PUBLIC and anon.
-- ROLLBACK: drop function public.get_water_visits(date, date, bigint);

CREATE FUNCTION public.get_water_visits(p_from date DEFAULT NULL, p_to date DEFAULT NULL, p_visit_id bigint DEFAULT NULL)
 RETURNS TABLE(visit_id bigint, visit_date date, client_id bigint, client_code text, client_name text,
               driver_id bigint, driver_name text, driver_color text, vehicle_id bigint,
               arrived_gallons integer, highest_gallons integer, left_gallons integer,
               pumped_gallons integer, returned_gallons integer, highest_minus_arrived_gallons integer,
               several_fills boolean, tank_full boolean, no_water_separated boolean, shared_stop boolean,
               grease_kept_gallons integer)
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
              THEN round(b.grease_kept_gallons)::int END
    FROM b
    JOIN public.clients c ON c.id = b.client_id
    LEFT JOIN d ON d.d_visit_id = b.visit_id
    LEFT JOIN public.employees e ON e.id = d.d_driver_id
   ORDER BY b.visit_date DESC, b.visit_id DESC;
END $function$;

REVOKE ALL ON FUNCTION public.get_water_visits(date, date, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_water_visits(date, date, bigint) TO authenticated, service_role;
COMMENT ON FUNCTION public.get_water_visits(date, date, bigint) IS 'Water per Moises pumping visit for the apps (Trello dGJ5aFrh): arrived, highest, left, pumped (every fill), returned (every pump-back), several_fills, flags, grease kept. One visit: View in Visit Calendar or Admin Review; a period (<= 93 days): View in Admin Review. Over public.v_visit_water_balance. 2026-10-21_2045.';

-- VERIFY (runs as postgres: no request claims, so the access check passes, as for timed jobs)
DO $v$
DECLARE n_fn int; n_view int; n_diff int; r record;
BEGIN
  SELECT count(*) INTO n_fn FROM public.get_water_visits('2026-09-01', '2026-11-30');
  SELECT count(*) INTO n_view FROM public.v_visit_water_balance w
   WHERE w.visit_kind = 'volume' AND w.visit_date BETWEEN '2026-09-01' AND '2026-11-30'
     AND w.water_start_gallons IS NOT NULL AND w.water_peak_gallons IS NOT NULL AND w.water_end_gallons IS NOT NULL
     AND w.water_separated_gallons IS NOT NULL AND w.water_put_back_gallons IS NOT NULL;
  IF n_fn <> n_view OR n_fn < 50 THEN RAISE EXCEPTION 'VERIFY 1: % rows from the function, % in the view', n_fn, n_view; END IF;
  SELECT count(*) INTO n_diff FROM public.get_water_visits('2026-09-01', '2026-11-30') f
    JOIN public.v_visit_water_balance w ON w.visit_id = f.visit_id
   WHERE f.pumped_gallons <> round(w.water_separated_gallons) OR f.returned_gallons <> round(w.water_put_back_gallons)
      OR f.arrived_gallons <> round(w.water_start_gallons) OR f.highest_gallons <> round(w.water_peak_gallons)
      OR f.left_gallons <> round(w.water_end_gallons);
  IF n_diff <> 0 THEN RAISE EXCEPTION 'VERIFY 2: % rows differ from the view', n_diff; END IF;
  SELECT * INTO r FROM public.get_water_visits(p_visit_id => 6570);
  IF r.arrived_gallons <> 302 OR r.highest_gallons <> 971 OR r.left_gallons <> 219 OR r.pumped_gallons <> 872
     OR r.returned_gallons <> 954 OR NOT r.several_fills OR r.highest_minus_arrived_gallons <> 669 OR r.driver_name <> 'Michael Escobar' THEN
    RAISE EXCEPTION 'VERIFY 3: visit 6570 reads %', row_to_json(r);
  END IF;
  SELECT * INTO r FROM public.get_water_visits(p_visit_id => 8089);
  IF r.pumped_gallons <> 0 OR r.several_fills OR NOT r.no_water_separated THEN RAISE EXCEPTION 'VERIFY 4: visit 8089 reads %', row_to_json(r); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.visits v WHERE v.vehicle_id = 3 AND v.visit_status = 'completed' AND v.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'VERIFY 5a: no completed David visit to test with';
  END IF;
  IF EXISTS (SELECT 1 FROM public.get_water_visits(p_visit_id => (SELECT v.id FROM public.visits v WHERE v.vehicle_id = 3 AND v.visit_status = 'completed' AND v.deleted_at IS NULL ORDER BY v.id DESC LIMIT 1))) THEN
    RAISE EXCEPTION 'VERIFY 5: a David visit returned water';
  END IF;
  IF (SELECT count(*) FROM public.get_water_visits('2026-09-01', '2026-11-30') WHERE several_fills) < 5 THEN
    RAISE EXCEPTION 'VERIFY 6: positive control, several_fills visits expected';
  END IF;
  BEGIN
    PERFORM public.get_water_visits('2026-01-01', '2026-12-31');
    RAISE EXCEPTION 'VERIFY 7: a 364-day range was accepted';
  EXCEPTION WHEN sqlstate '22023' THEN NULL;
  END;
  IF has_function_privilege('anon', 'public.get_water_visits(date,date,bigint)', 'EXECUTE')
  OR NOT has_function_privilege('authenticated', 'public.get_water_visits(date,date,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 8: grants';
  END IF;
END $v$;
