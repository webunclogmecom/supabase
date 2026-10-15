-- ============================================================================
-- 2026-10-15_1150 Calendar day card: "Grease pumped" estimates, frozen once a day is over
-- ============================================================================
-- THE ASK (Trello wv4xwPoG, Yan on the Oct 13 call, Fred's answers 2026-10-14/15): a new tile on each Calendar day
-- card with the day's grease pumped: for each grease trap pumping add the average grease pumped at that place;
-- "if there has been no previous record of pumped grease ... use the Grease trap size as fallback instead of null or 0";
-- "David and Cloggy can't push the water back, only Moises, besides the sensors are in Moises"; "Only the grease";
-- the droplet (Grease trap capacity) "should only count the visits that will be pumps", with a hover of how many
-- grease traps, grey water and lift stations. Past days never change.
-- Plan: Building Apps/Visit Calendar/docs/specs/2026-10-14-grease-pumped-icon-plan.md
--
-- WHAT IT ADDS
--   1. app_config 'grease_separating_vehicle_ids' = '1' (Moises): the trucks that push the water back and carry the
--      tank sensors. Data, not a name match in code.
--   2. ops.fn_visit_pump_kind(visit_id, job_id): 'grease_trap' | 'grey_water' | 'lift_station' | NULL, from the
--      visit's own schedulable coded lines, else its job's open ones (the lookup ops.v_calendar_visit uses for
--      sa_group), read from public.service_line_items (service_type 'Pumping' + location_target), never a code list.
--      DATED EXCEPTION for the Jan to Jul 2026 lines that carry no code ("Grease Trap Pumping", "Lyft station",
--      "Grey Water Pumping"): matched by text only when the visit and its job have no coded line at all.
--   3. ops.fn_grease_estimates_live(from, to): one row per live calendar visit. Grease trap on a separating truck:
--      the average of the last 4 trusted sensor readings at that property before the day (high/medium confidence,
--      'volume' visits, readings from grease trap pumpings), else the trap size. Any other truck or no truck: the
--      trap size. No trap size and no reading: 'unknown' (no number). Trap size = the droplet's own
--      ops.v_calendar_visit.equipment_size_gallons; property = the visit's, else the client's primary.
--   4. ops.visit_grease_frozen: one stored row per past visit (keyed visit_id + visit_date), never changed: a
--      trigger refuses DELETE and any UPDATE except setting superseded_at once (corrections = a dated migration that
--      supersedes and inserts). Rule 8: OPT-OUT of audit (machine-written, append-only, itself the record).
--   5. ops.fn_freeze_grease_estimates() + cron 'calendar-grease-freeze' at :05 every hour: stores the missing rows for
--      every past day (ET) since 2026-01-01; one sync_log row per run ('calendar_grease_freeze', success / error).
--   6. ops.calendar_grease_estimates(from, to): what the Calendar reads. SECURITY DEFINER, authenticated only, same
--      role and range guards as ops.calendar_drive_days (45 days at most). Returns only pumping visits: visit_id,
--      visit_date, pump_kind, gallons (grease traps only), basis, readings, frozen. Stored row for a past day,
--      live value otherwise. No raw sensor value leaves the DB.
--   7. public.log_jobber_sync_health: ONE tuple ('calendar_grease_freeze', 3 hours) spliced into its watched list
--      (md5 pinned, anchor asserted once), so a stopped or failing freezer reaches the health email.
-- NOT CHANGED: ops.v_calendar_visit, public.v_visit_tank_service (read only), the droplet's own value (the app
-- filters it by pump_kind), anything the other session owns.
-- ⚠ DEPENDENCY: fn_grease_estimates_live reads ops.v_calendar_visit (vehicle_id, equipment_size_gallons,
-- property_id, client_id, job_id, visit_date) and public.v_visit_tank_service (visit_id, property_id, visit_date,
-- visit_kind, sludge_confidence, sludge_collected_gallons). A rename there breaks it at the next call; the freezer
-- then logs 'error' and the health email says so.
--
-- HOW TO RUN: one call, one transaction. Rehearse: node scripts/probes/apply_sql_file.mjs <file> rehearse
-- ROLLBACK: 2026-10-15_rollback_calendar_grease_estimates.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF md5(pg_get_functiondef('public.log_jobber_sync_health'::regproc)) <> 'a41322fe76deff3223ccdff2aff97612' THEN
    RAISE EXCEPTION 'log_jobber_sync_health changed since 2026-10-15 11:40 ET: re-read it and re-pin'; END IF;
END $g$;

-- 1 ---------------------------------------------------------------------------------------------------------
INSERT INTO public.app_config (key, value) VALUES ('grease_separating_vehicle_ids', '1')
ON CONFLICT (key) DO NOTHING;

-- 2 ---------------------------------------------------------------------------------------------------------
CREATE FUNCTION ops.fn_visit_pump_kind(p_visit_id bigint, p_job_id bigint) RETURNS text
LANGUAGE sql STABLE SET search_path = ops, public, pg_temp AS $f$
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
$f$;

-- 3 ---------------------------------------------------------------------------------------------------------
CREATE FUNCTION ops.fn_grease_estimates_live(p_from date, p_to date)
RETURNS TABLE (visit_id bigint, visit_date date, pump_kind text, vehicle_id bigint, separates_water boolean,
               trap_size_gallons numeric, gallons numeric, basis text, readings integer)
LANGUAGE sql STABLE SET search_path = ops, public, pg_temp AS $f$
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
$f$;

-- 4 ---------------------------------------------------------------------------------------------------------
CREATE TABLE ops.visit_grease_frozen (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  visit_id          bigint NOT NULL,
  visit_date        date NOT NULL,
  pump_kind         text CHECK (pump_kind IN ('grease_trap', 'grey_water', 'lift_station')),
  vehicle_id        bigint,
  trap_size_gallons numeric,
  gallons           numeric,
  basis             text NOT NULL CHECK (basis IN ('measured', 'trap_size', 'unknown', 'other_pump', 'not_pumping')),
  readings          integer NOT NULL DEFAULT 0,
  frozen_at         timestamptz NOT NULL DEFAULT now(),
  superseded_at     timestamptz
);
CREATE UNIQUE INDEX visit_grease_frozen_live_key ON ops.visit_grease_frozen (visit_id, visit_date) WHERE superseded_at IS NULL;
CREATE INDEX visit_grease_frozen_date_idx ON ops.visit_grease_frozen (visit_date);
ALTER TABLE ops.visit_grease_frozen ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE ops.visit_grease_frozen IS
  'The Calendar Grease pumped estimate of each past visit, stored once its day is over (2026-10-15_1150). Never '
  'changed: corrections only by a dated migration that sets superseded_at and inserts. Read through '
  'ops.calendar_grease_estimates. Not audited (rule 8 opt-out: machine-written, append-only).';

CREATE FUNCTION ops.fn_visit_grease_frozen_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path = ops, pg_temp AS $f$
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
END $f$;
CREATE TRIGGER visit_grease_frozen_guard BEFORE UPDATE OR DELETE ON ops.visit_grease_frozen
  FOR EACH ROW EXECUTE FUNCTION ops.fn_visit_grease_frozen_guard();

-- 5 ---------------------------------------------------------------------------------------------------------
CREATE FUNCTION ops.fn_freeze_grease_estimates() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ops, public, pg_temp AS $f$
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
END $f$;

SELECT cron.schedule('calendar-grease-freeze', '5 * * * *', 'SELECT ops.fn_freeze_grease_estimates()');

-- 6 ---------------------------------------------------------------------------------------------------------
CREATE FUNCTION ops.calendar_grease_estimates(p_from date, p_to date)
RETURNS TABLE (visit_id bigint, visit_date date, pump_kind text, gallons numeric, basis text, readings integer, frozen boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ops, public, pg_temp AS $f$
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
END $f$;
COMMENT ON FUNCTION ops.calendar_grease_estimates(date, date) IS
  'Calendar day card (2026-10-15_1150): per pumping visit, its pump kind and, for grease traps, the estimated grease '
  'pumped (Moises: sensor average at that place, else trap size; other trucks: trap size). Stored value for a past '
  'day, live otherwise. 45 days at most.';

-- grants: revoke by name (ops default privileges give authenticated SELECT on new tables; functions default to PUBLIC)
REVOKE ALL ON ops.visit_grease_frozen FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_visit_pump_kind(bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_grease_estimates_live(date, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_visit_grease_frozen_guard() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.fn_freeze_grease_estimates() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION ops.calendar_grease_estimates(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.calendar_grease_estimates(date, date) TO authenticated, service_role;

-- 7 ---------------------------------------------------------------------------------------------------------
DO $s$
DECLARE
  d text := pg_get_functiondef('public.log_jobber_sync_health'::regproc);
  a text := $a$('intake_task_sync',              interval '25 minutes')$a$;
BEGIN
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN
    RAISE EXCEPTION 'splice anchor not found exactly once in log_jobber_sync_health'; END IF;
  EXECUTE replace(d, a, a || ',' || chr(10) ||
    $b$      -- 2026-10-15_1150: Calendar grease freezer (cron calendar-grease-freeze, hourly at :05); 3 hours = 2 missed runs.$b$ || chr(10) ||
    $b$      ('calendar_grease_freeze',        interval '3 hours')$b$);
END $s$;

-- VERIFY ----------------------------------------------------------------------------------------------------
DO $v$
DECLARE n int; s text; g numeric; k text;
BEGIN
  -- V1 grants
  IF has_table_privilege('authenticated', 'ops.visit_grease_frozen', 'SELECT') OR has_table_privilege('anon', 'ops.visit_grease_frozen', 'SELECT') THEN
    RAISE EXCEPTION 'V1 visit_grease_frozen readable by staff or anon'; END IF;
  IF has_function_privilege('authenticated', 'ops.fn_grease_estimates_live(date,date)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'ops.fn_freeze_grease_estimates()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'ops.fn_visit_pump_kind(bigint,bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'ops.calendar_grease_estimates(date,date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'ops.calendar_grease_estimates(date,date)', 'EXECUTE') THEN
    RAISE EXCEPTION 'V1 function grants wrong'; END IF;

  -- V2 the pump kinds come out of the catalogue: 01 grease trap, 03 grey water, 04 lift station, 05 not a pump
  SELECT ops.fn_visit_pump_kind(v.id, v.job_id) INTO k FROM public.visits v
   WHERE v.id = (SELECT li.visit_id FROM public.line_items li WHERE btrim(li.name) LIKE '03 -%' AND li.visit_id IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM public.line_items l2 WHERE l2.visit_id = li.visit_id AND btrim(l2.name) ~ '^(01|02|09) ')
                 ORDER BY li.visit_id DESC LIMIT 1);
  IF k IS DISTINCT FROM 'grey_water' THEN RAISE EXCEPTION 'V2 a code 03 visit reads %, expected grey_water', k; END IF;

  -- V3 Oct 15 (all grease traps, all Moises): the reader equals an independent sum written here
  SELECT count(*), sum(gallons) INTO n, g FROM ops.calendar_grease_estimates('2026-10-15', '2026-10-15') WHERE pump_kind = 'grease_trap';
  IF n <> 6 THEN RAISE EXCEPTION 'V3 Oct 15 has % grease trap rows, expected 6', n; END IF;
  IF g IS DISTINCT FROM (
       SELECT sum(CASE WHEN r.n >= 1 THEN round(r.a) ELSE round(cv.equipment_size_gallons) END)
         FROM ops.v_calendar_visit cv
         LEFT JOIN LATERAL (SELECT avg(t.sludge_collected_gallons) a, count(*) n FROM (
                 SELECT t.sludge_collected_gallons FROM public.v_visit_tank_service t
                  WHERE t.property_id = cv.property_id AND t.visit_kind = 'volume' AND t.sludge_confidence IN ('high','medium')
                    AND t.sludge_collected_gallons IS NOT NULL AND t.visit_date < cv.visit_date
                  ORDER BY t.visit_date DESC, t.visit_id DESC LIMIT 4) t) r ON true
        WHERE cv.visit_date = '2026-10-15' AND cv.vehicle_id = 1
          AND ops.fn_visit_pump_kind(cv.id, cv.job_id) = 'grease_trap') THEN
    RAISE EXCEPTION 'V3 Oct 15 reader sum % differs from the independent sum', g; END IF;

  -- V4 a non-separating truck never uses readings: every David / Cloggy grease trap row is trap_size or unknown
  SELECT count(*) INTO n FROM ops.fn_grease_estimates_live('2026-09-01', '2026-10-31')
   WHERE pump_kind = 'grease_trap' AND NOT separates_water AND basis NOT IN ('trap_size', 'unknown');
  IF n <> 0 THEN RAISE EXCEPTION 'V4 % non-Moises grease trap rows used readings', n; END IF;
  -- V4b a known trap size is never reported as unknown, and unknown never carries gallons
  SELECT count(*) INTO n FROM ops.fn_grease_estimates_live('2026-09-01', '2026-10-31')
   WHERE (basis = 'unknown' AND (gallons IS NOT NULL OR trap_size_gallons IS NOT NULL)) OR (basis = 'trap_size' AND gallons IS DISTINCT FROM round(trap_size_gallons));
  IF n <> 0 THEN RAISE EXCEPTION 'V4b % rows break the fallback rule', n; END IF;

  -- V5 the range guard
  BEGIN
    PERFORM * FROM ops.calendar_grease_estimates('2026-01-01', '2026-03-01');
    RAISE EXCEPTION 'V5 a 59-day range went through';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'calendar_grease_estimates: bad range%' THEN RAISE; END IF;
  END;

  -- V6 the guard: a stored row cannot change or go; superseding works once (rolled back)
  BEGIN
    INSERT INTO ops.visit_grease_frozen (visit_id, visit_date, basis) VALUES (-1, '2026-01-01', 'not_pumping');
    BEGIN
      UPDATE ops.visit_grease_frozen SET gallons = 1 WHERE visit_id = -1;
      RAISE EXCEPTION 'V6 an UPDATE of gallons went through';
    EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'ops.visit_grease_frozen rows never change%' THEN RAISE; END IF;
    END;
    BEGIN
      DELETE FROM ops.visit_grease_frozen WHERE visit_id = -1;
      RAISE EXCEPTION 'V6 a DELETE went through';
    EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'ops.visit_grease_frozen is permanent%' THEN RAISE; END IF;
    END;
    UPDATE ops.visit_grease_frozen SET superseded_at = now() WHERE visit_id = -1;
    BEGIN
      UPDATE ops.visit_grease_frozen SET superseded_at = now() WHERE visit_id = -1;
      RAISE EXCEPTION 'V6 a second supersede went through';
    EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'ops.visit_grease_frozen rows never change%' THEN RAISE; END IF;
    END;
    RAISE EXCEPTION 'v6_rollback';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'v6_rollback' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM ops.visit_grease_frozen) THEN RAISE EXCEPTION 'V6 left a row behind'; END IF;

  -- V7 the cron and the health tuple
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'calendar-grease-freeze' AND schedule = '5 * * * *') THEN
    RAISE EXCEPTION 'V7 cron calendar-grease-freeze missing'; END IF;
  s := pg_get_functiondef('public.log_jobber_sync_health'::regproc);
  IF (length(s) - length(replace(s, $q$('calendar_grease_freeze',        interval '3 hours')$q$, '')))
     / length($q$('calendar_grease_freeze',        interval '3 hours')$q$) <> 1 THEN
    RAISE EXCEPTION 'V7 health tuple not in the body exactly once'; END IF;
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
