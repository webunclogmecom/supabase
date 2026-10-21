-- Rollback of 2026-10-21_0600: the previous return shape (no vehicle_id / measured_gallons) and grants.
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION ops.calendar_grease_estimates(date, date);
CREATE FUNCTION ops.calendar_grease_estimates(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, pump_kind text, pump_kinds text[], gallons numeric, basis text, readings integer, frozen boolean)
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
  SELECT r.visit_id, r.visit_date, r.pump_kind, r.pump_kinds, r.gallons, r.basis, r.readings, r.source <> 'live'
    FROM ops.fn_grease_estimates_resolved(p_from, p_to) r
   WHERE r.pump_kind IS NOT NULL;
END $function$;
REVOKE ALL ON FUNCTION ops.calendar_grease_estimates(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.calendar_grease_estimates(date, date) TO authenticated, service_role;
COMMIT;
