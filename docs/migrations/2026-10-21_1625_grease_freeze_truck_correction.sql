-- 2026-10-21_1625 · Grease pumped step 8: a stored past day follows a later truck correction
--
-- Fred, 2026-10-21: "go ahead with step 8" (plan Building Apps/Visit Calendar/docs/specs/
-- 2026-10-21-grease-pumped-data-audit-and-plan.md, step 8).
--
-- WHAT: ops.fn_freeze_grease_estimates (the hourly cron calendar-grease-freeze) first supersedes every stored row
-- (ops.visit_grease_frozen) whose truck and the visit's effective truck today sit on different sides of the
-- separating line (app_config grease_separating_vehicle_ids = Moises vs David / Cloggy), then stores it again from
-- today's truck in the same run. Its sync_log details gain truck_corrected.
-- WHY IN THE FREEZER, NOT A TRIGGER ON visits.vehicle_id (the plan's first idea): the effective truck also changes when a
-- job's default truck changes, with no write to visits; the hourly sweep sees both. Latency: up to one hour.
-- Same-side changes (David <-> Cloggy) keep the row on purpose: same number, and a re-store could pick up a later trap
-- size edit, which must not move a past day (Fred 10-15).
-- REACH, measured 2026-10-21 16:20 ET: 6 stored rows carry a truck that changed since; 4 cross the line (1350 Feb 4
-- Moises -> David; 1467 Mar 9, 1600 Apr 9, 3927 May 6 David -> Moises). All 4 rebuild to the same gallons (no sensor
-- reading existed before those dates, so trap size either way); only the stored truck is corrected. 1311 and 6989
-- (David <-> Cloggy) stay as they are. This migration runs the freezer once so the 4 are corrected now.
-- RULE 8: no table created or changed. ROLLBACK: 2026-10-21_rollback_grease_freeze_truck_correction.sql

DO $g$ BEGIN
  IF md5(pg_get_functiondef('ops.fn_freeze_grease_estimates()'::regprocedure)) <> '9f5f22723d052ab6aa51927753f3effa' THEN
    RAISE EXCEPTION 'step 8: the freezer changed since the dry run, stop';
  END IF;
END $g$;

CREATE OR REPLACE FUNCTION ops.fn_freeze_grease_estimates()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
DECLARE
  v_today   date := (now() AT TIME ZONE 'America/New_York')::date;
  v_started timestamptz := clock_timestamp();
  v_from    date;
  v_through date;
  n         integer := 0;
  n_carried integer := 0;
  n_truck   integer := 0;
  v_err     text;
BEGIN
  BEGIN
    -- 2026-10-15_2230: yesterday is frozen after tonight's truck-from-GPS run (03:05 ET in summer, 02:05 in winter: the
    -- run itself is read, so DST cannot move it). Until then the hourly run freezes through the day before and freezes
    -- yesterday later.
    -- Day X is frozen only after a truck-from-GPS run (cron vehicle-gps-reconcile-nightly, nightly) on X+1 or later
    -- ran while GPS was live (it skips visits whose GPS is not all stored), so the newest such run decides; none in 7
    -- days falls back to the day before yesterday, so a broken truck job never stops the freeze for good. And never a
    -- day the feeds do not cover past its midnight (the least(); 'infinity' while live, so a healthy day is unchanged).
    v_through := least(
      coalesce((SELECT (max(d.start_time) AT TIME ZONE 'America/New_York')::date - 1
                  FROM cron.job_run_details d
                 WHERE d.jobid = (SELECT j.jobid FROM cron.job j WHERE j.jobname = 'vehicle-gps-reconcile-nightly')
                   AND d.status = 'succeeded'
                   AND d.start_time > now() - interval '7 days'
                   AND public.fn_samsara_data_complete_through('gps', d.start_time) = 'infinity'),
               v_today - 2),
      (least(coalesce(public.fn_samsara_data_complete_through('gps'), '-infinity'),
             coalesce(public.fn_samsara_data_complete_through('readings'), '-infinity'))
         AT TIME ZONE 'America/New_York')::date - 1);
    -- 2026-10-21_1625 (step 8): a stored past day follows a later truck correction. A stored row whose truck and the
    -- visit's truck today (the effective truck, so a changed job default counts too) sit on different sides of the
    -- separating line (Moises <-> David / Cloggy) is superseded, and the run below stores it again from today's truck.
    -- A change between two trucks on the same side keeps the row: the number would be the same, and storing it again
    -- could pick up a later trap size edit, which must not move a past day.
    WITH cfg AS (
      SELECT coalesce((SELECT array_agg(x::bigint)
                         FROM regexp_split_to_table(coalesce((SELECT c.value FROM public.app_config c
                                                               WHERE c.key = 'grease_separating_vehicle_ids'), ''),
                                                    '[^0-9]+') x
                        WHERE x <> ''), '{}'::bigint[]) AS sep
    ), x AS (
      SELECT f.id
        FROM ops.visit_grease_frozen f
        CROSS JOIN cfg
        JOIN ops.v_calendar_visit cv ON cv.id = f.visit_id AND cv.visit_date = f.visit_date
       WHERE f.superseded_at IS NULL AND f.pump_kind IS NOT NULL AND f.visit_date <= v_through
         AND coalesce(f.vehicle_id = ANY (cfg.sep), false) <> coalesce(cv.vehicle_id = ANY (cfg.sep), false)
    )
    UPDATE ops.visit_grease_frozen f SET superseded_at = now() FROM x WHERE f.id = x.id;
    GET DIAGNOSTICS n_truck = ROW_COUNT;
    -- only from the earliest past day that has a visit with no stored row (usually yesterday)
    SELECT min(cv.visit_date) INTO v_from
      FROM ops.v_calendar_visit cv
     WHERE cv.visit_date BETWEEN date '2026-01-01' AND v_through
       AND NOT EXISTS (SELECT 1 FROM ops.visit_grease_frozen f
                        WHERE f.visit_id = cv.id AND f.visit_date = cv.visit_date AND f.superseded_at IS NULL);
    IF v_from IS NOT NULL THEN
      WITH src AS MATERIALIZED (
        SELECT * FROM ops.fn_grease_estimates_resolved(v_from, v_through) r WHERE r.source <> 'frozen'
      ), ins AS (
        INSERT INTO ops.visit_grease_frozen (visit_id, visit_date, pump_kind, pump_kinds, vehicle_id, trap_size_gallons, gallons, basis, readings)
        SELECT s.visit_id, s.visit_date, s.pump_kind, s.pump_kinds, s.vehicle_id, s.trap_size_gallons, s.gallons, s.basis, s.readings
          FROM src s
        RETURNING 1
      )
      SELECT (SELECT count(*) FROM ins), (SELECT count(*) FROM src WHERE src.source = 'carried') INTO n, n_carried;
    END IF;
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, duration_seconds, rows_inserted, status, details)
    VALUES ('calendar_grease_freeze', v_started, clock_timestamp(),
            round(extract(epoch FROM clock_timestamp() - v_started)::numeric, 3), n, 'success',
            jsonb_build_object('frozen', n, 'carried', n_carried, 'truck_corrected', n_truck, 'from', v_from, 'through', v_through,
                               'held_back', v_through < v_today - 1));
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    n := 0;
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, duration_seconds, rows_errored, status, error_details, details)
    VALUES ('calendar_grease_freeze', v_started, clock_timestamp(),
            round(extract(epoch FROM clock_timestamp() - v_started)::numeric, 3), 1, 'error',
            jsonb_build_object('message', left(v_err, 300)), jsonb_build_object('through', coalesce(v_through, v_today - 1)));
  END;
  RETURN n;
END $function$;

REVOKE ALL ON FUNCTION ops.fn_freeze_grease_estimates() FROM PUBLIC, anon, authenticated, service_role;

-- run once now, then VERIFY
DO $v$
DECLARE n_before int; n_after int; n_cross int; r jsonb; n_second int;
BEGIN
  SELECT count(*) INTO n_before FROM ops.visit_grease_frozen WHERE superseded_at IS NULL;
  PERFORM ops.fn_freeze_grease_estimates();
  SELECT details INTO r FROM public.sync_log WHERE sync_source = 'calendar_grease_freeze' ORDER BY id DESC LIMIT 1;
  IF (r->>'truck_corrected') IS NULL THEN RAISE EXCEPTION 'VERIFY 1: freezer run did not log truck_corrected (%)', r; END IF;
  IF (r->>'truck_corrected')::int < 4 THEN RAISE EXCEPTION 'VERIFY 1b: expected at least 4 truck corrections, got %', r->>'truck_corrected'; END IF;
  -- the 4 now carry today's truck and the same gallons
  IF EXISTS (SELECT 1 FROM (VALUES (1350, date '2026-02-04', 3, 25), (1467, date '2026-03-09', 1, 1400),
                                   (1600, date '2026-04-09', 1, 50), (3927, date '2026-05-06', 1, 895)) e(vid, d, veh, g)
              WHERE NOT EXISTS (SELECT 1 FROM ops.visit_grease_frozen f
                                 WHERE f.visit_id = e.vid AND f.visit_date = e.d AND f.superseded_at IS NULL
                                   AND f.vehicle_id = e.veh AND f.gallons = e.g)) THEN
    RAISE EXCEPTION 'VERIFY 2: a corrected row is missing or changed its gallons';
  END IF;
  -- the same-side ones were left alone (negative control)
  IF NOT EXISTS (SELECT 1 FROM ops.visit_grease_frozen WHERE visit_id = 1311 AND superseded_at IS NULL AND vehicle_id = 3)
  OR NOT EXISTS (SELECT 1 FROM ops.visit_grease_frozen WHERE visit_id = 6989 AND superseded_at IS NULL AND vehicle_id = 3) THEN
    RAISE EXCEPTION 'VERIFY 3: a same-side truck change was re-stored';
  END IF;
  -- nothing crosses the line any more, and nothing went missing
  WITH cfg AS (SELECT coalesce((SELECT array_agg(x::bigint) FROM regexp_split_to_table(coalesce((SELECT value FROM public.app_config WHERE key = 'grease_separating_vehicle_ids'), ''), '[^0-9]+') x WHERE x <> ''), '{}'::bigint[]) AS sep)
  SELECT count(*) INTO n_cross FROM ops.visit_grease_frozen f CROSS JOIN cfg
    JOIN ops.v_calendar_visit cv ON cv.id = f.visit_id AND cv.visit_date = f.visit_date
   WHERE f.superseded_at IS NULL AND f.pump_kind IS NOT NULL
     AND coalesce(f.vehicle_id = ANY (cfg.sep), false) <> coalesce(cv.vehicle_id = ANY (cfg.sep), false);
  IF n_cross <> 0 THEN RAISE EXCEPTION 'VERIFY 4: % stored rows still cross the line', n_cross; END IF;
  SELECT count(*) INTO n_after FROM ops.visit_grease_frozen WHERE superseded_at IS NULL;
  IF n_after < n_before THEN RAISE EXCEPTION 'VERIFY 5: live stored rows fell % -> %', n_before, n_after; END IF;
  -- a second run corrects nothing (no loop)
  PERFORM ops.fn_freeze_grease_estimates();
  SELECT (details->>'truck_corrected')::int INTO n_second FROM public.sync_log WHERE sync_source = 'calendar_grease_freeze' ORDER BY id DESC LIMIT 1;
  IF n_second <> 0 THEN RAISE EXCEPTION 'VERIFY 6: second run corrected % rows', n_second; END IF;
END $v$;
