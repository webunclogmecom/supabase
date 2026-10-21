-- Rollback of 2026-10-21_0700: the 0630 shape (no vehicle_source / truck_capacity_gallons / over_truck_capacity) and grants.
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION ops.calendar_grease_estimates(date, date);
CREATE FUNCTION ops.calendar_grease_estimates(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, pump_kind text, pump_kinds text[], gallons numeric, basis text, readings integer, frozen boolean, vehicle_id bigint, measured_gallons numeric, measurable boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_role text := coalesce(current_setting('role', true), 'none');
BEGIN
  perform hr.fn_require_app('visit_calendar', 'view');   -- 2026-10-21_0900 access phase 5
  IF v_role NOT IN ('authenticated', 'service_role', 'none') THEN
    RAISE EXCEPTION 'calendar_grease_estimates: not allowed for role %', v_role USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RAISE EXCEPTION 'calendar_grease_estimates: bad range % .. % (45 days at most)', p_from, p_to;
  END IF;
  RETURN QUERY
  -- 2026-10-21_0600 (step 5): the visit's own trusted sludge reading on that date, read live and never frozen, so a
  -- past day can show what was really measured next to its stored estimate. Same trust rule as the averages.
  WITH m AS MATERIALIZED (
    SELECT t.visit_id AS m_visit_id, t.visit_date AS m_date, round(t.sludge_collected_gallons) AS m_gallons
      FROM public.v_visit_tank_service t
     WHERE t.visit_date BETWEEN p_from AND p_to
       AND t.visit_kind = 'volume' AND t.sludge_confidence IN ('high', 'medium')
       AND t.sludge_collected_gallons BETWEEN 40 AND 3840)
  SELECT r.visit_id, r.visit_date, r.pump_kind, r.pump_kinds, r.gallons, r.basis, r.readings, r.source <> 'live',
         r.vehicle_id, m.m_gallons,
         -- 2026-10-21_0630: the stop's truck separates water and carries the tank sensor (app_config), the same list
         -- fn_grease_estimates_live uses, so the app never decides which truck can be measured
         coalesce(r.vehicle_id = ANY (coalesce((SELECT array_agg(x::bigint)
                                                  FROM regexp_split_to_table(coalesce((SELECT c.value FROM public.app_config c
                                                                                        WHERE c.key = 'grease_separating_vehicle_ids'), ''),
                                                                             '[^0-9]+') x
                                                 WHERE x <> ''), '{}'::bigint[])), false)
    FROM ops.fn_grease_estimates_resolved(p_from, p_to) r
    LEFT JOIN m ON m.m_visit_id = r.visit_id AND m.m_date = r.visit_date
   WHERE r.pump_kind IS NOT NULL;
END $function$;
REVOKE ALL ON FUNCTION ops.calendar_grease_estimates(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.calendar_grease_estimates(date, date) TO authenticated, service_role;
COMMIT;
