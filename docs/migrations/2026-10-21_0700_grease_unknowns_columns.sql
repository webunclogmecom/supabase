-- ============================================================================
-- 2026-10-21_0700 Grease pumped step 6: the RPC says what the tile does not know
-- ============================================================================
-- Fred, 2026-10-21: "go ahead with step 6" (plan Building Apps/Visit Calendar/docs/specs/
-- 2026-10-21-grease-pumped-data-audit-and-plan.md, step 6). The hover is to name the stops the number cannot be sure
-- of: stops with no figure (basis unknown, gallons NULL: already in the output), stops whose truck is only the
-- service's DEFAULT (no truck assigned yet, so the rule assumes it), and stops whose estimate is more than the truck's
-- tank holds. ops.calendar_grease_estimates gets three LAST columns: vehicle_source (from ops.v_calendar_visit, live),
-- truck_capacity_gallons (public.vehicles.grease_tank_capacity_gallons of the row's truck) and over_truck_capacity.
-- Nothing is capped: whether to cap at the truck's tank is Fred's open question; this only reports.
-- DROP + CREATE (return type); body = live (md5 guard) + the columns; grants restored; same rows and values.
-- ROLLBACK: 2026-10-21_rollback_grease_unknowns_columns.sql (the 0630 shape).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF md5(pg_get_functiondef('ops.calendar_grease_estimates'::regproc)) <> '68a543716e31315998bfe0f7ef188dcc' THEN
    RAISE EXCEPTION 'calendar_grease_estimates changed since it was read';
  END IF;
END $g$;

CREATE TEMP TABLE before_rpc ON COMMIT DROP AS
  SELECT * FROM ops.calendar_grease_estimates('2026-09-01', '2026-10-15')
  UNION ALL SELECT * FROM ops.calendar_grease_estimates('2026-10-16', '2026-11-30');

DROP FUNCTION ops.calendar_grease_estimates(date, date);
CREATE FUNCTION ops.calendar_grease_estimates(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, pump_kind text, pump_kinds text[], gallons numeric, basis text, readings integer, frozen boolean, vehicle_id bigint, measured_gallons numeric, measurable boolean, vehicle_source text, truck_capacity_gallons numeric, over_truck_capacity boolean)
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
       AND t.sludge_collected_gallons BETWEEN 40 AND 3840),
  cv AS MATERIALIZED (
    SELECT v.id AS vs_id, v.visit_date AS vs_date, v.vehicle_source AS vs_source
      FROM ops.v_calendar_visit v WHERE v.visit_date BETWEEN p_from AND p_to)
  SELECT r.visit_id, r.visit_date, r.pump_kind, r.pump_kinds, r.gallons, r.basis, r.readings, r.source <> 'live',
         r.vehicle_id, m.m_gallons,
         -- 2026-10-21_0630: the stop's truck separates water and carries the tank sensor (app_config), the same list
         -- fn_grease_estimates_live uses, so the app never decides which truck can be measured
         coalesce(r.vehicle_id = ANY (coalesce((SELECT array_agg(x::bigint)
                                                  FROM regexp_split_to_table(coalesce((SELECT c.value FROM public.app_config c
                                                                                        WHERE c.key = 'grease_separating_vehicle_ids'), ''),
                                                                             '[^0-9]+') x
                                                 WHERE x <> ''), '{}'::bigint[])), false),
         -- 2026-10-21_0700 (step 6): where today's truck comes from ('assigned' / 'default' / 'none', the visit's live
         -- source, meaningful for today and later) and whether the stop's estimate is more than its truck's tank holds
         cv.vs_source, vh.grease_tank_capacity_gallons,
         coalesce(r.gallons > vh.grease_tank_capacity_gallons, false)
    FROM ops.fn_grease_estimates_resolved(p_from, p_to) r
    LEFT JOIN m ON m.m_visit_id = r.visit_id AND m.m_date = r.visit_date
    LEFT JOIN cv ON cv.vs_id = r.visit_id AND cv.vs_date = r.visit_date
    LEFT JOIN public.vehicles vh ON vh.id = r.vehicle_id
   WHERE r.pump_kind IS NOT NULL;
END $function$;

REVOKE ALL ON FUNCTION ops.calendar_grease_estimates(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.calendar_grease_estimates(date, date) TO authenticated, service_role;

DO $v$ DECLARE n int; BEGIN
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'ops.calendar_grease_estimates'::regproc)
     <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' THEN RAISE EXCEPTION 'V1: grants differ'; END IF;
  SELECT count(*) INTO n FROM (
    (SELECT visit_id, visit_date, pump_kind, pump_kinds, gallons, basis, readings, frozen, vehicle_id, measured_gallons, measurable FROM ops.calendar_grease_estimates('2026-09-01', '2026-10-15')
     UNION ALL SELECT visit_id, visit_date, pump_kind, pump_kinds, gallons, basis, readings, frozen, vehicle_id, measured_gallons, measurable FROM ops.calendar_grease_estimates('2026-10-16', '2026-11-30'))
    EXCEPT ALL (SELECT * FROM before_rpc)) x;
  IF n <> 0 THEN RAISE EXCEPTION 'V2: % rows differ from before', n; END IF;
  IF (SELECT count(*) FROM before_rpc) <> (SELECT count(*) FROM ops.calendar_grease_estimates('2026-09-01', '2026-10-15')) + (SELECT count(*) FROM ops.calendar_grease_estimates('2026-10-16', '2026-11-30')) THEN
    RAISE EXCEPTION 'V3: row count changed'; END IF;
  -- controls: 031-KRU 6844 on 10-28 (375 gal on Cloggy, 126 gal tank) is over; 072-TCE 6175 on 11-30 rides on a default truck
  IF NOT (SELECT over_truck_capacity FROM ops.calendar_grease_estimates('2026-10-28', '2026-10-28') WHERE visit_id = 6844) THEN RAISE EXCEPTION 'V4: 6844 not over'; END IF;
  IF (SELECT vehicle_source FROM ops.calendar_grease_estimates('2026-11-30', '2026-11-30') WHERE visit_id = 6175) IS DISTINCT FROM 'default' THEN RAISE EXCEPTION 'V5: 6175 source'; END IF;
  IF (SELECT count(*) FROM ops.calendar_grease_estimates('2026-10-21', '2026-11-30') WHERE vehicle_source IS NULL) > 0 THEN RAISE EXCEPTION 'V6: a row with no vehicle_source'; END IF;
END $v$;
COMMIT;
