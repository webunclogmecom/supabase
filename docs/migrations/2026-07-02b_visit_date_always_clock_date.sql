-- ============================================================================
-- 2026-07-02b — visit_date = the ET CLOCK date, ALWAYS (no operating-night shift)
--               SUPERSEDES 2026-07-02_operating_date_scheduled_matches_jobber.sql
-- ============================================================================
-- Fred (2026-07-02): the operating-night concept (an early-AM visit belongs to the prior
-- night's shift) is for UNDERSTANDING which shift did the work — it must NEVER move a visit's
-- date. A visit's date is its real clock date and must match Jobber, for BOTH scheduled and
-- completed visits. The earlier fix only un-shifted scheduled visits; this removes the shift
-- entirely (completed too).
--
-- fn_reconcile_visit_operating_date Branch 3 now sets visit_date = (start_at AT TIME ZONE ET)::date
-- with no -1 early-AM shift. Branch 2 (date-drag) already uses clock-date semantics; the end_at
-- carry / defensive snap are preserved. start_at is never touched here, so Jobber schedules are
-- unaffected (no re-push).
--
-- Reconcile: 130 completed visits were off their ET clock date — 5 from the operating-night
-- shift + 125 leftover from the pre-07-01 "+1" UTC-date-slice bug (the ~126 historical rows the
-- 07-01 webhook fix corrected going-forward but never backfilled). All realigned to the ET clock
-- date = Jobber's date. Idempotent / self-correcting.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_reconcile_visit_operating_date()
 RETURNS trigger LANGUAGE plpgsql AS $function$
DECLARE
  v_et_time   time;
  v_new_start timestamptz;
  v_dur       interval;
BEGIN
  IF NEW.start_at IS NULL THEN RETURN NEW; END IF;  -- all-day: visit_date authoritative
  IF TG_OP='UPDATE' AND OLD.start_at IS NOT NULL AND OLD.end_at IS NOT NULL THEN v_dur := OLD.end_at - OLD.start_at; END IF;
  IF TG_OP='UPDATE' AND NEW.start_at IS NOT DISTINCT FROM OLD.start_at AND NEW.visit_date IS NOT DISTINCT FROM OLD.visit_date THEN RETURN NEW; END IF;
  -- Branch 2: pure date-drag -> start_at onto the new day at the same ET wall-clock (NO shift); carry end_at.
  IF TG_OP='UPDATE' AND NEW.visit_date IS DISTINCT FROM OLD.visit_date AND NEW.start_at IS NOT DISTINCT FROM OLD.start_at THEN
    v_et_time := (OLD.start_at AT TIME ZONE 'America/New_York')::time;
    v_new_start := ((NEW.visit_date + v_et_time)) AT TIME ZONE 'America/New_York';
    IF OLD.end_at IS NOT NULL AND NEW.end_at IS NOT DISTINCT FROM OLD.end_at THEN NEW.end_at := NEW.end_at + (v_new_start - OLD.start_at); END IF;
    NEW.start_at := v_new_start; RETURN NEW;
  END IF;
  -- Branch 3: visit_date = the ET CLOCK date of start_at. Operating-night is conceptual metadata
  -- only and must NOT move the date (Fred 2026-07-02). Matches Jobber (which displays by ET clock date).
  NEW.visit_date := (NEW.start_at AT TIME ZONE 'America/New_York')::date;
  IF NEW.end_at IS NOT NULL AND NEW.end_at <= NEW.start_at AND (TG_OP='INSERT' OR NEW.end_at IS NOT DISTINCT FROM OLD.end_at) THEN
    NEW.end_at := NEW.start_at + CASE WHEN v_dur > interval '0' THEN v_dur ELSE interval '1 hour' END;
  END IF;
  RETURN NEW;
END $function$;

DO $$ BEGIN
  PERFORM set_config('app.suppress_jobber_push','on',true);
  UPDATE public.visits SET visit_date = (start_at AT TIME ZONE 'America/New_York')::date
   WHERE deleted_at IS NULL AND start_at IS NOT NULL
     AND visit_date <> (start_at AT TIME ZONE 'America/New_York')::date;
END $$;
