-- ROLLBACK of 2026-10-21_1625_grease_freeze_truck_correction.sql: the freezer without the truck-correction step.
-- Rows it already re-stored stay (they carry the right truck); nothing else to undo.
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
            jsonb_build_object('frozen', n, 'carried', n_carried, 'from', v_from, 'through', v_through,
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
DO $v$ BEGIN
  IF md5(pg_get_functiondef('ops.fn_freeze_grease_estimates()'::regprocedure)) <> '9f5f22723d052ab6aa51927753f3effa' THEN
    RAISE EXCEPTION 'rollback: freezer body does not match the pre-step-8 md5';
  END IF;
END $v$;
