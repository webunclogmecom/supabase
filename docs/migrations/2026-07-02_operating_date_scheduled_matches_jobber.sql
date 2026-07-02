-- ============================================================================
-- 2026-07-02 — Operating-date rule: SCHEDULED visits match Jobber's clock date
-- ============================================================================
-- Yannick/Fred: the Calendar showed 239-COM (Courtyard Marriott, a Service Call) on
-- Sun Jul 5 while Jobber shows it Mon Jul 6 at ~5 AM — "why is the calendar one day
-- before even though it has the same hours? fix it to match jobber."
--
-- Root cause: fn_reconcile_visit_operating_date (the 2026-07-01 operating-date rule)
-- derived visit_date = PRIOR ET day for ANY visit whose start_at ET falls in 00:00-06:00.
-- That is correct for a COMPLETED overnight grease-trap route (actual completion times —
-- the owner-confirmed 07-01 behavior), but it was ALSO applied to SCHEDULED visits, which
-- the office places on a specific clock date in Jobber. 239-COM's scheduled 04:45 ET
-- Mon-6 visit got pushed to Sun-5. 4 scheduled future visits were affected (all early-AM):
-- 239-COM (SC 04:45), 127-PC (SA GreaseTrap 04:15), 214-MYK (SA GreyWater 03:00), + 1 orphan.
--
-- Fix: the operating-night shift now applies ONLY to visit_status='completed'. SCHEDULED
-- visits take the ET CLOCK date, so the Calendar day == the Jobber day. The date-drag branch
-- drops its matching +1 so dropping a visit on calendar day D keeps start_at on D. Completed
-- overnight-route attribution (130 visits) is unchanged. Start_at/end_at are NOT touched
-- (only the derived visit_date), so Jobber schedules stay identical — no re-push needed.
-- Idempotent (CREATE OR REPLACE + a self-correcting reconcile).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_reconcile_visit_operating_date()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
  c_cutoff CONSTANT time := time '06:00:00';
  v_et_ts     timestamp;
  v_et_date   date;
  v_et_time   time;
  v_op_date   date;
  v_new_start timestamptz;
  v_dur       interval;
BEGIN
  IF NEW.start_at IS NULL THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.start_at IS NOT NULL AND OLD.end_at IS NOT NULL THEN
    v_dur := OLD.end_at - OLD.start_at;
  END IF;

  IF TG_OP = 'UPDATE'
     AND NEW.start_at  IS NOT DISTINCT FROM OLD.start_at
     AND NEW.visit_date IS NOT DISTINCT FROM OLD.visit_date THEN
    RETURN NEW;
  END IF;

  -- Branch 2: pure date-drag (visit_date changed, start_at did NOT). CLOCK-DATE semantics:
  -- drop on day D -> start_at on D at same ET wall-clock (NO +1). end_at carried by delta.
  IF TG_OP = 'UPDATE'
     AND NEW.visit_date IS DISTINCT FROM OLD.visit_date
     AND NEW.start_at  IS NOT DISTINCT FROM OLD.start_at THEN
    v_et_time := (OLD.start_at AT TIME ZONE 'America/New_York')::time;
    v_new_start := ((NEW.visit_date + v_et_time)) AT TIME ZONE 'America/New_York';
    IF OLD.end_at IS NOT NULL AND NEW.end_at IS NOT DISTINCT FROM OLD.end_at THEN
      NEW.end_at := NEW.end_at + (v_new_start - OLD.start_at);
    END IF;
    NEW.start_at := v_new_start;
    RETURN NEW;
  END IF;

  -- Branch 3: derive visit_date. Operating-night shift ONLY for COMPLETED visits.
  v_et_ts   := NEW.start_at AT TIME ZONE 'America/New_York';
  v_et_date := v_et_ts::date;
  v_et_time := v_et_ts::time;
  v_op_date := CASE
    WHEN NEW.visit_status = 'completed'
         AND v_et_time > time '00:00:00' AND v_et_time < c_cutoff THEN v_et_date - 1
    ELSE v_et_date END;
  NEW.visit_date := v_op_date;

  IF NEW.end_at IS NOT NULL AND NEW.end_at <= NEW.start_at
     AND (TG_OP = 'INSERT' OR NEW.end_at IS NOT DISTINCT FROM OLD.end_at) THEN
    NEW.end_at := NEW.start_at + CASE WHEN v_dur > interval '0' THEN v_dur ELSE interval '1 hour' END;
  END IF;

  RETURN NEW;
END $function$;

-- Reconcile existing shifted SCHEDULED visits to their ET clock date (push-suppressed;
-- start_at unchanged so Jobber already matches). Self-correcting / safe to re-run.
DO $$
BEGIN
  PERFORM set_config('app.suppress_jobber_push','on',true);
  UPDATE public.visits
     SET visit_date = (start_at AT TIME ZONE 'America/New_York')::date
   WHERE deleted_at IS NULL AND start_at IS NOT NULL AND visit_status='scheduled'
     AND visit_date >= current_date
     AND visit_date <> (start_at AT TIME ZONE 'America/New_York')::date;
END $$;
