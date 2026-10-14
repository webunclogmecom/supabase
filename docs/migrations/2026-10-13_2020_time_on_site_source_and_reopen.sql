-- ============================================================================
-- 2026-10-13_2020 Time on site, step 2a: record which rule wrote a visit's time, and clear it when a visit is reopened
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-13: "go ahead with step 2" of samsara-checks/time_on_site_fix_plan_2026-10-13.md (outside the repos,
--   it names clients), defaults approved ("go with your defaults"). Step 2 = label every writer, stop the bad
--   overwrites, the truck guesser rule, clear on reopen, the 11 AM run stops measuring today. This file is the schema
--   half; 2026-10-13_2025 changes the writers.
--
-- WHAT CHANGES
--   1. public.visits.time_on_site_source (text, CHECK): which rule produced duration_minutes / actual_arrival_at /
--      actual_departure_at. gps_150m_cluster (fn_compute_time_on_site), gps_150m_any_truck (fn_fill_blank_time_on_site),
--      stop_at_completion and dump_site_dwell (fn_fill_time_on_site_from_stops), review and reviewed_blank (a person,
--      steps 4 and 5). NULL = written before this column existed. The 1,293 existing values are NOT rewritten.
--      Audit (rule 8): public.visits is already audited; a new column is captured in the full-row JSON automatically.
--      Jobber: the column is in neither fn_push_visit_to_jobber's WHEN list nor fn_mark_visit_sync_pending (checked
--      2026-10-13), so writing it never pushes and never marks a visit pending.
--   2. Trigger trg_zz_clear_time_on_site_on_reopen (BEFORE UPDATE OF visit_status): when a visit leaves 'completed',
--      its automatic time (any source except review / reviewed_blank) is cleared in the same write, so the reopen and
--      the clearing are one audited row attributed to whoever reopened it. Visit 6564 (001-VIN) was reopened on 10-13
--      and kept a 10-minute time from Oct 11 that the Calendar showed. Only a status change clears: a changed
--      completed_at on a visit that stays completed is left alone (the nightly job re-measures recent visits; older
--      ones keep their value).
--   3. The one reopened visit that still holds a time today (6564) is cleared, labelled time-on-site-cleanup.
--
-- HOW TO RUN: one call. Rehearse with apply_sql_file.mjs <file> rehearse. The ALTER holds an exclusive lock on visits
--   until COMMIT, so the checks below are small (a few rows in rolled-back subtransactions).
-- ROLLBACK: 2026-10-13_rollback_time_on_site_source_and_reopen.sql (roll 2026-10-13_2025 back first: its writers set
--   the column).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

ALTER TABLE public.visits ADD COLUMN time_on_site_source text;
ALTER TABLE public.visits ADD CONSTRAINT visits_time_on_site_source_chk CHECK (time_on_site_source IN
  ('gps_150m_cluster', 'gps_150m_any_truck', 'stop_at_completion', 'dump_site_dwell', 'review', 'reviewed_blank'));
COMMENT ON COLUMN public.visits.time_on_site_source IS 'Which rule produced duration_minutes / actual_arrival_at / actual_departure_at: gps_150m_cluster (fn_compute_time_on_site), gps_150m_any_truck (fn_fill_blank_time_on_site), stop_at_completion or dump_site_dwell (fn_fill_time_on_site_from_stops), review or reviewed_blank (a person). NULL = written before 2026-10-13_2020. Cleared with the time when a visit is reopened (except review / reviewed_blank).';

CREATE OR REPLACE FUNCTION public.fn_clear_time_on_site_on_reopen()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
-- A visit that leaves 'completed' loses the time measured while it was completed (2026-10-13_2020). A value a person
-- reviewed is kept: it is a decision, not a measurement.
begin
  if coalesce(OLD.time_on_site_source, '') not in ('review', 'reviewed_blank')
     and (OLD.duration_minutes is not null or OLD.actual_arrival_at is not null or OLD.actual_departure_at is not null) then
    NEW.duration_minutes := null;
    NEW.actual_arrival_at := null;
    NEW.actual_departure_at := null;
    NEW.time_on_site_source := null;
  end if;
  return NEW;
end $function$;
REVOKE ALL ON FUNCTION public.fn_clear_time_on_site_on_reopen() FROM public, anon, authenticated;

CREATE TRIGGER trg_zz_clear_time_on_site_on_reopen
  BEFORE UPDATE OF visit_status ON public.visits
  FOR EACH ROW
  WHEN (OLD.visit_status = 'completed' AND NEW.visit_status IS DISTINCT FROM 'completed')
  EXECUTE FUNCTION public.fn_clear_time_on_site_on_reopen();

-- 3. the reopened visit that still holds a time (labelled; restored after)
DO $c$
DECLARE v_hdr text := current_setting('request.headers', true); n int;
BEGIN
  PERFORM set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
    || jsonb_build_object('x-app-source', 'time-on-site-cleanup',
         'x-change-reason', 'The visit was reopened, so the time on site measured while it was completed no longer applies.'))::text, true);
  UPDATE public.visits SET duration_minutes = null, actual_arrival_at = null, actual_departure_at = null
   WHERE deleted_at IS NULL AND visit_status <> 'completed'
     AND (duration_minutes IS NOT NULL OR actual_arrival_at IS NOT NULL OR actual_departure_at IS NOT NULL);
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM set_config('request.headers', coalesce(v_hdr, ''), true);
  IF n > 3 THEN RAISE EXCEPTION 'cleanup: % reopened visits hold a time, expected 1 (6564): look before clearing', n; END IF;
END $c$;

DO $v$
DECLARE r record; n int;
BEGIN
  -- V1 the column refuses a value outside the list
  BEGIN
    UPDATE public.visits SET time_on_site_source = 'guess' WHERE id = 1468;
    RAISE EXCEPTION 'V1: the CHECK accepted a bad value';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  -- V2 the trigger clears an automatic time on reopen, and keeps a reviewed one (112-YA test visit 1468, rolled back)
  BEGIN
    PERFORM set_config('app.suppress_jobber_push', 'on', true);
    UPDATE public.visits SET time_on_site_source = 'gps_150m_cluster' WHERE id = 1468;
    UPDATE public.visits SET visit_status = 'scheduled' WHERE id = 1468;
    SELECT duration_minutes, actual_arrival_at, time_on_site_source INTO r FROM public.visits WHERE id = 1468;
    IF r.duration_minutes IS NOT NULL OR r.actual_arrival_at IS NOT NULL OR r.time_on_site_source IS NOT NULL THEN
      RAISE EXCEPTION 'V2: reopen kept the automatic time %', r; END IF;
    UPDATE public.visits SET visit_status = 'completed', duration_minutes = 30, time_on_site_source = 'review' WHERE id = 1468;
    UPDATE public.visits SET visit_status = 'scheduled' WHERE id = 1468;
    SELECT duration_minutes INTO n FROM public.visits WHERE id = 1468;
    IF n IS DISTINCT FROM 30 THEN RAISE EXCEPTION 'V2: reopen cleared a reviewed time'; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0901', MESSAGE = 'probe rolled back';
  EXCEPTION WHEN SQLSTATE 'P0901' THEN NULL;
  END;
  IF (SELECT duration_minutes FROM public.visits WHERE id = 1468) IS NULL THEN RAISE EXCEPTION 'V2: probe leaked'; END IF;

  -- V3 no live visit outside 'completed' holds a time any more
  SELECT count(*) INTO n FROM public.visits WHERE deleted_at IS NULL AND visit_status <> 'completed'
     AND (duration_minutes IS NOT NULL OR actual_arrival_at IS NOT NULL OR actual_departure_at IS NOT NULL);
  IF n <> 0 THEN RAISE EXCEPTION 'V3: % non-completed visits still hold a time', n; END IF;

  -- V4 nothing else was labelled: every existing value still has a NULL source
  IF EXISTS (SELECT 1 FROM public.visits WHERE time_on_site_source IS NOT NULL) THEN RAISE EXCEPTION 'V4: a source was set'; END IF;
END $v$;

COMMIT;
