-- ============================================================================
-- 2026-10-21_0600 Grease pumped step 5: the RPC also returns the truck and the visit's own measurement
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-21: "go ahead with step 5" (plan Building Apps/Visit Calendar/docs/specs/
--   2026-10-21-grease-pumped-data-audit-and-plan.md, step 5: "Past days: add the measured amount to the hover; the
--   number stays"). A past day shows the estimate made before it (frozen), which can be 0 to about 2x what Moises
--   really pumped. The stored number stays; the hover will add what was measured (wording on a mockup first).
-- WHAT
--   ops.calendar_grease_estimates gets two LAST columns: vehicle_id (the truck the row's rule used, frozen with the
--   day) and measured_gallons (the visit's own trusted sludge reading on that date, rounded; high/medium confidence,
--   40 to 3,840 gal, the averages' rule; read live from public.v_visit_tank_service, never frozen; NULL when not
--   measured: David, Cloggy, a future visit, or an untrusted reading). Nothing else changes: same rows, same values.
--   A return-type change needs DROP + CREATE; the body is the live one (md5 guard) plus the CTE, the access check
--   line (hr.fn_require_app, access phase 5) is kept, and the grants are restored exactly
--   (authenticated + service_role EXECUTE, nothing for PUBLIC or anon). No view or function depends on it.
-- ROLLBACK: 2026-10-21_rollback_grease_measured_column.sql (the previous body and grants).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF md5(pg_get_functiondef('ops.calendar_grease_estimates'::regproc)) <> 'e28adea7f643f8bc9f80853cc1ce42d5' THEN
    RAISE EXCEPTION 'calendar_grease_estimates changed since it was read';
  END IF;
END $g$;

CREATE TEMP TABLE before_rpc ON COMMIT DROP AS
  SELECT * FROM ops.calendar_grease_estimates('2026-09-01', '2026-10-15')
  UNION ALL SELECT * FROM ops.calendar_grease_estimates('2026-10-16', '2026-11-30');

DROP FUNCTION ops.calendar_grease_estimates(date, date);
CREATE FUNCTION ops.calendar_grease_estimates(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, pump_kind text, pump_kinds text[], gallons numeric, basis text, readings integer, frozen boolean, vehicle_id bigint, measured_gallons numeric)
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
         r.vehicle_id, m.m_gallons
    FROM ops.fn_grease_estimates_resolved(p_from, p_to) r
    LEFT JOIN m ON m.m_visit_id = r.visit_id AND m.m_date = r.visit_date
   WHERE r.pump_kind IS NOT NULL;
END $function$;

REVOKE ALL ON FUNCTION ops.calendar_grease_estimates(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.calendar_grease_estimates(date, date) TO authenticated, service_role;

DO $v$ DECLARE n int; BEGIN
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'ops.calendar_grease_estimates'::regproc)
     <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' THEN RAISE EXCEPTION 'V1: grants differ'; END IF;
  -- same rows and same values as before (only the two new columns are new)
  SELECT count(*) INTO n FROM (
    (SELECT visit_id, visit_date, pump_kind, pump_kinds, gallons, basis, readings, frozen FROM ops.calendar_grease_estimates('2026-09-01', '2026-10-15')
     UNION ALL SELECT visit_id, visit_date, pump_kind, pump_kinds, gallons, basis, readings, frozen FROM ops.calendar_grease_estimates('2026-10-16', '2026-11-30'))
    EXCEPT ALL (SELECT * FROM before_rpc)) x;
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % rows differ from before', n; END IF;
  SELECT count(*) INTO n FROM before_rpc;
  IF n <> (SELECT count(*) FROM ops.calendar_grease_estimates('2026-09-01', '2026-10-15')) + (SELECT count(*) FROM ops.calendar_grease_estimates('2026-10-16', '2026-11-30')) THEN
    RAISE EXCEPTION 'V3: row count changed'; END IF;
  -- positive controls: 241-WYN on Sep 1 measured 1,171; 034-LG on Sep 22 measured 352; a future visit has none
  IF (SELECT measured_gallons FROM ops.calendar_grease_estimates('2026-09-01', '2026-09-01') WHERE visit_id = 6968) IS DISTINCT FROM 1171 THEN RAISE EXCEPTION 'V4: 6968'; END IF;
  IF (SELECT measured_gallons FROM ops.calendar_grease_estimates('2026-09-22', '2026-09-22') WHERE visit_id = 6008) IS DISTINCT FROM 352 THEN RAISE EXCEPTION 'V5: 6008'; END IF;
  IF (SELECT measured_gallons FROM ops.calendar_grease_estimates('2026-10-23', '2026-10-23') WHERE visit_id = 6969) IS NOT NULL THEN RAISE EXCEPTION 'V6: future visit measured'; END IF;
  IF (SELECT count(*) FROM ops.calendar_grease_estimates('2026-09-01', '2026-10-15') WHERE measured_gallons IS NOT NULL AND vehicle_id IS DISTINCT FROM 1) > 0 THEN
    RAISE EXCEPTION 'V7: a measurement on a truck that is not Moises'; END IF;
END $v$;
COMMIT;
