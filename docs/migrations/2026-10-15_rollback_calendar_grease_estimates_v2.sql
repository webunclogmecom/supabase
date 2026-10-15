-- ============================================================================
-- ROLLBACK of 2026-10-15_1540_calendar_grease_estimates_v2 (back to the 2026-10-15_1150 v1 behaviour)
-- ============================================================================
-- Restores the v1 function bodies (copied from pg_get_functiondef taken before v2, never retyped), drops the v2
-- objects, and gives the stored rows the v2 recompute replaced their v1 values back (their ids are in the sync_log
-- row 'calendar_grease_refreeze'). Rows the freezer stored after v2 keep their values: the v1 app sums only grease
-- trap rows, and v2 changed none of those. Publish the Calendar WITHOUT the v2 hover first: v1 does not return
-- pump_kinds. The pump_kinds column of ops.visit_grease_frozen is dropped and the v1 guard restored.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $r$
DECLARE j jsonb; ids bigint[];
BEGIN
  SELECT details INTO j FROM public.sync_log
   WHERE sync_source = 'calendar_grease_refreeze' AND details->>'migration' = '2026-10-15_1540'
   ORDER BY id DESC LIMIT 1;
  IF j IS NULL THEN RAISE EXCEPTION 'rollback: no calendar_grease_refreeze log for 2026-10-15_1540'; END IF;
  ids := ARRAY(SELECT (jsonb_array_elements_text(j->'superseded_ids'))::bigint);
  UPDATE ops.visit_grease_frozen cur SET superseded_at = now()
    FROM ops.visit_grease_frozen old
   WHERE old.id = ANY (ids) AND cur.visit_id = old.visit_id AND cur.visit_date = old.visit_date
     AND cur.superseded_at IS NULL AND cur.id <> old.id;
  INSERT INTO ops.visit_grease_frozen (visit_id, visit_date, pump_kind, vehicle_id, trap_size_gallons, gallons, basis, readings)
  SELECT o.visit_id, o.visit_date, o.pump_kind, o.vehicle_id, o.trap_size_gallons, o.gallons, o.basis, o.readings
    FROM ops.visit_grease_frozen o WHERE o.id = ANY (ids);
END $r$;

DROP FUNCTION ops.calendar_grease_estimates(date, date);
DROP FUNCTION ops.fn_grease_estimates_resolved(date, date);
DROP FUNCTION ops.fn_grease_estimates_live(date, date);
DROP VIEW ops.v_client_sludge_average;
DROP FUNCTION ops.fn_client_sludge_averages(date[]);

-- v1 bodies, verbatim from pg_get_functiondef
CREATE OR REPLACE FUNCTION ops.fn_visit_pump_kind(p_visit_id bigint, p_job_id bigint)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
  WITH own AS (
    SELECT sli.service_type, sli.location_target
      FROM public.line_items li
      JOIN public.service_line_items sli ON sli.code = lpad(substring(btrim(li.name), '^([0-9]+)'), 2, '0')
     WHERE li.visit_id = p_visit_id AND sli.schedulable
  ), coded AS (
    SELECT * FROM own
    UNION ALL
    SELECT sli.service_type, sli.location_target
      FROM public.line_items li
      JOIN public.service_line_items sli ON sli.code = lpad(substring(btrim(li.name), '^([0-9]+)'), 2, '0')
     WHERE li.job_id = p_job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND sli.schedulable
       AND NOT EXISTS (SELECT 1 FROM own)
  ), old_text AS (  -- dated exception: lines from before the codes, only when nothing is coded
    SELECT btrim(li.name) AS nm
      FROM public.line_items li
     WHERE (li.visit_id = p_visit_id OR (li.job_id = p_job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL))
       AND btrim(li.name) !~ '^[0-9]'
       AND NOT EXISTS (SELECT 1 FROM coded)
  ), k AS (
    SELECT CASE WHEN c.service_type = 'Pumping' AND c.location_target ~* 'grease trap' THEN 1
                WHEN c.service_type = 'Pumping' AND c.location_target ~* 'grey water' THEN 2
                WHEN c.service_type = 'Pumping' AND c.location_target ~* 'lift station' THEN 3 END AS r
      FROM coded c
    UNION ALL
    SELECT CASE WHEN o.nm ~* 'grease trap' THEN 1
                WHEN o.nm ~* 'grey water' THEN 2
                WHEN o.nm ~* '(lift|lyft) station' THEN 3 END
      FROM old_text o
  )
  SELECT CASE min(r) WHEN 1 THEN 'grease_trap' WHEN 2 THEN 'grey_water' WHEN 3 THEN 'lift_station' END FROM k
$function$;

DROP FUNCTION ops.fn_visit_pump_kinds(bigint, bigint);

CREATE OR REPLACE FUNCTION ops.fn_grease_estimates_live(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, pump_kind text, vehicle_id bigint, separates_water boolean, trap_size_gallons numeric, gallons numeric, basis text, readings integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
  WITH cfg AS (
    SELECT coalesce((SELECT array_agg(x::bigint)
                       FROM regexp_split_to_table(coalesce((SELECT c.value FROM public.app_config c
                                                             WHERE c.key = 'grease_separating_vehicle_ids'), ''),
                                                  '[^0-9]+') x
                      WHERE x <> ''), '{}'::bigint[]) AS sep
  ),
  rd AS MATERIALIZED (
    SELECT t.property_id, t.visit_date, t.visit_id, t.sludge_collected_gallons AS g
      FROM public.v_visit_tank_service t
      JOIN public.visits rv ON rv.id = t.visit_id
     WHERE t.visit_kind = 'volume' AND t.sludge_confidence IN ('high', 'medium')
       AND t.sludge_collected_gallons IS NOT NULL AND t.visit_date < p_to
       AND ops.fn_visit_pump_kind(t.visit_id, rv.job_id) = 'grease_trap'
  ),
  tv AS MATERIALIZED (
    SELECT cv.id, cv.visit_date, cv.vehicle_id, cv.equipment_size_gallons::numeric AS cap,
           coalesce(cv.property_id,
                    (SELECT p.id FROM public.properties p
                      WHERE p.client_id = cv.client_id AND p.is_primary AND p.deleted_at IS NULL
                      ORDER BY p.id LIMIT 1)) AS prop,
           ops.fn_visit_pump_kind(cv.id, cv.job_id) AS kind
      FROM ops.v_calendar_visit cv
     WHERE cv.visit_date BETWEEN p_from AND p_to
  )
  SELECT tv.id, tv.visit_date, tv.kind, tv.vehicle_id, s.sep, tv.cap,
         CASE WHEN tv.kind IS DISTINCT FROM 'grease_trap' THEN NULL
              WHEN s.sep AND r.n >= 1 THEN round(r.avg_g)
              ELSE round(tv.cap) END,
         CASE WHEN tv.kind IS NULL THEN 'not_pumping'
              WHEN tv.kind <> 'grease_trap' THEN 'other_pump'
              WHEN s.sep AND r.n >= 1 THEN 'measured'
              WHEN tv.cap IS NOT NULL THEN 'trap_size'
              ELSE 'unknown' END,
         CASE WHEN s.sep AND tv.kind = 'grease_trap' THEN r.n ELSE 0 END
    FROM tv
    CROSS JOIN cfg
    CROSS JOIN LATERAL (SELECT coalesce(tv.vehicle_id = ANY (cfg.sep), false) AS sep) s
    LEFT JOIN LATERAL (
      SELECT avg(x.g) AS avg_g, count(*)::int AS n
        FROM (SELECT rd.g FROM rd
               WHERE rd.property_id = tv.prop AND rd.visit_date < tv.visit_date
               ORDER BY rd.visit_date DESC, rd.visit_id DESC LIMIT 4) x
    ) r ON true
$function$;

CREATE OR REPLACE FUNCTION ops.calendar_grease_estimates(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, pump_kind text, gallons numeric, basis text, readings integer, frozen boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_role  text := coalesce(current_setting('role', true), 'none');
  v_today date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  IF v_role NOT IN ('authenticated', 'service_role', 'none') THEN
    RAISE EXCEPTION 'calendar_grease_estimates: not allowed for role %', v_role USING ERRCODE = '42501';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RAISE EXCEPTION 'calendar_grease_estimates: bad range % .. % (45 days at most)', p_from, p_to;
  END IF;
  RETURN QUERY
  SELECT x.visit_id, x.visit_date, x.pump_kind, x.gallons, x.basis, x.readings, x.frozen
    FROM (
      SELECT l.visit_id, l.visit_date,
             CASE WHEN f.id IS NOT NULL THEN f.pump_kind ELSE l.pump_kind END AS pump_kind,
             CASE WHEN f.id IS NOT NULL THEN f.gallons   ELSE l.gallons   END AS gallons,
             CASE WHEN f.id IS NOT NULL THEN f.basis     ELSE l.basis     END AS basis,
             CASE WHEN f.id IS NOT NULL THEN f.readings  ELSE l.readings  END AS readings,
             (f.id IS NOT NULL) AS frozen
        FROM ops.fn_grease_estimates_live(p_from, p_to) l
        LEFT JOIN ops.visit_grease_frozen f
          ON f.visit_id = l.visit_id AND f.visit_date = l.visit_date AND f.superseded_at IS NULL
         AND l.visit_date < v_today
    ) x
   WHERE x.pump_kind IS NOT NULL;
END $function$;

CREATE OR REPLACE FUNCTION ops.fn_freeze_grease_estimates()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
DECLARE
  v_today   date := (now() AT TIME ZONE 'America/New_York')::date;
  v_started timestamptz := clock_timestamp();
  n         integer := 0;
  v_err     text;
BEGIN
  BEGIN
    INSERT INTO ops.visit_grease_frozen (visit_id, visit_date, pump_kind, vehicle_id, trap_size_gallons, gallons, basis, readings)
    SELECT l.visit_id, l.visit_date, l.pump_kind, l.vehicle_id, l.trap_size_gallons, l.gallons, l.basis, l.readings
      FROM ops.fn_grease_estimates_live(date '2026-01-01', v_today - 1) l
     WHERE NOT EXISTS (SELECT 1 FROM ops.visit_grease_frozen f
                        WHERE f.visit_id = l.visit_id AND f.visit_date = l.visit_date AND f.superseded_at IS NULL);
    GET DIAGNOSTICS n = ROW_COUNT;
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, duration_seconds, rows_inserted, status, details)
    VALUES ('calendar_grease_freeze', v_started, clock_timestamp(),
            round(extract(epoch FROM clock_timestamp() - v_started)::numeric, 3), n, 'success',
            jsonb_build_object('frozen', n, 'through', v_today - 1));
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    n := 0;
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, duration_seconds, rows_errored, status, error_details, details)
    VALUES ('calendar_grease_freeze', v_started, clock_timestamp(),
            round(extract(epoch FROM clock_timestamp() - v_started)::numeric, 3), 1, 'error',
            jsonb_build_object('message', left(v_err, 300)), jsonb_build_object('through', v_today - 1));
  END;
  RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION ops.fn_visit_grease_frozen_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'ops', 'pg_temp'
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'ops.visit_grease_frozen is permanent: supersede a row instead of deleting it';
  END IF;
  IF OLD.superseded_at IS NOT NULL OR NEW.superseded_at IS NULL
     OR (NEW.visit_id, NEW.visit_date, NEW.pump_kind, NEW.vehicle_id, NEW.trap_size_gallons, NEW.gallons,
         NEW.basis, NEW.readings, NEW.frozen_at)
        IS DISTINCT FROM
        (OLD.visit_id, OLD.visit_date, OLD.pump_kind, OLD.vehicle_id, OLD.trap_size_gallons, OLD.gallons,
         OLD.basis, OLD.readings, OLD.frozen_at) THEN
    RAISE EXCEPTION 'ops.visit_grease_frozen rows never change: only superseded_at can be set, once';
  END IF;
  RETURN NEW;
END $function$;

ALTER TABLE ops.visit_grease_frozen DROP COLUMN pump_kinds;

REVOKE ALL ON FUNCTION ops.fn_visit_pump_kind(bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_grease_estimates_live(date, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_freeze_grease_estimates() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.calendar_grease_estimates(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.calendar_grease_estimates(date, date) TO authenticated, service_role;

DO $v$
DECLARE j jsonb;
BEGIN
  SELECT details INTO j FROM public.sync_log
   WHERE sync_source = 'calendar_grease_refreeze' AND details->>'migration' = '2026-10-15_1540' ORDER BY id DESC LIMIT 1;
  IF EXISTS (SELECT 1 FROM ops.visit_grease_frozen f
              WHERE f.superseded_at IS NULL
                AND EXISTS (SELECT 1 FROM ops.visit_grease_frozen o
                             WHERE o.id IN (SELECT (jsonb_array_elements_text(j->'superseded_ids'))::bigint)
                               AND o.visit_id = f.visit_id AND o.visit_date = f.visit_date)
                AND f.basis <> 'other_pump') THEN
    RAISE EXCEPTION 'rollback: a recomputed row is still current'; END IF;
  IF to_regprocedure('ops.fn_visit_pump_kinds(bigint,bigint)') IS NOT NULL OR to_regclass('ops.v_client_sludge_average') IS NOT NULL THEN
    RAISE EXCEPTION 'rollback: v2 objects remain'; END IF;
  IF NOT has_function_privilege('authenticated', 'ops.calendar_grease_estimates(date,date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'rollback: authenticated lost the reader'; END IF;
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
