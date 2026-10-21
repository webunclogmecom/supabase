-- ============================================================================
-- 2026-10-21_0630 Grease pumped step 5: the RPC says which stops can be measured
-- ============================================================================
-- Fred picked option C on the mockup (https://claude.ai/artifact/5CYRaAn9PUdnvcqz8sU95f): on a past day the hover lists
-- each Moises stop with its estimate and what was measured ("go with C, but then remove the [count lines] ... Just add a
-- GT GW or LS chip in the clients name"). The list needs every stop on a water-separating truck, measured or not, and
-- Calendar rule 16 forbids deciding the truck rule in the browser. So ops.calendar_grease_estimates gets a LAST column
-- measurable (the row's truck is in app_config.grease_separating_vehicle_ids, the list fn_grease_estimates_live uses).
-- DROP + CREATE (return type); body = live (md5 guard) + one column; grants restored; same rows and values.
-- ROLLBACK: 2026-10-21_rollback_grease_measurable_column.sql (the 0600 shape).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF md5(pg_get_functiondef('ops.calendar_grease_estimates'::regproc)) <> '07eb53fedcee327cfcb66335c8f576fa' THEN
    RAISE EXCEPTION 'calendar_grease_estimates changed since it was read';
  END IF;
END $g$;

CREATE TEMP TABLE before_rpc ON COMMIT DROP AS
  SELECT * FROM ops.calendar_grease_estimates('2026-09-01', '2026-10-15')
  UNION ALL SELECT * FROM ops.calendar_grease_estimates('2026-10-16', '2026-11-30');

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

DO $v$ DECLARE n int; BEGIN
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'ops.calendar_grease_estimates'::regproc)
     <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' THEN RAISE EXCEPTION 'V1: grants differ'; END IF;
  SELECT count(*) INTO n FROM (
    (SELECT visit_id, visit_date, pump_kind, pump_kinds, gallons, basis, readings, frozen, vehicle_id, measured_gallons FROM ops.calendar_grease_estimates('2026-09-01', '2026-10-15')
     UNION ALL SELECT visit_id, visit_date, pump_kind, pump_kinds, gallons, basis, readings, frozen, vehicle_id, measured_gallons FROM ops.calendar_grease_estimates('2026-10-16', '2026-11-30'))
    EXCEPT ALL (SELECT * FROM before_rpc)) x;
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % rows differ from before', n; END IF;
  IF (SELECT count(*) FROM before_rpc) <> (SELECT count(*) FROM ops.calendar_grease_estimates('2026-09-01', '2026-10-15')) + (SELECT count(*) FROM ops.calendar_grease_estimates('2026-10-16', '2026-11-30')) THEN
    RAISE EXCEPTION 'V3: row count changed'; END IF;
  -- Mon Oct 19: 5 measurable (Moises) stops, David's 8816 is not
  IF (SELECT count(*) FILTER (WHERE measurable) FROM ops.calendar_grease_estimates('2026-10-19', '2026-10-19')) <> 5 THEN RAISE EXCEPTION 'V4: Oct 19 measurable count'; END IF;
  IF (SELECT measurable FROM ops.calendar_grease_estimates('2026-10-19', '2026-10-19') WHERE visit_id = 8816) THEN RAISE EXCEPTION 'V5: 8816 (David) measurable'; END IF;
  IF (SELECT count(*) FROM ops.calendar_grease_estimates('2026-09-01', '2026-10-15') WHERE measured_gallons IS NOT NULL AND NOT measurable) > 0 THEN
    RAISE EXCEPTION 'V6: a measurement on a stop that is not measurable'; END IF;
END $v$;
COMMIT;
