-- 2026-07-01_visit_operating_date_trigger.sql
-- ============================================================================
-- SAFEGUARD: keep visits.visit_date (the ET OPERATING date) consistent with
-- start_at (UTC timestamptz), so the +1 / desync class of bug can never be
-- saved again — by ANY writer (edge fn, Lovable app PATCH, scripts).
--
-- Operating-date rule (owner-confirmed): a commercial overnight route scheduled
-- for day D is worked ~8pm into ~6am, so visit_date = the night the route is FOR.
--   * start_at NULL (all-day)      -> visit_date is authoritative, untouched.
--   * ET-midnight 00:00:00         -> that ET date (all-day-with-placeholder time).
--   * genuine early-AM 00:00:01-05:59 ET -> PRIOR ET date (prior night's route).
--   * evening / daytime            -> the ET date.
-- OVERNIGHT_CUTOFF = 06:00 ET — matches webhook-jobber.operatingDateET +
-- sync-jobber-visit-drift.adoptTarget so all three share ONE convention.
--
-- BIDIRECTIONAL (intent-aware), so it does NOT fight a legitimate Calendar
-- date-drag: the field the writer actually changed signals intent.
--   Branch 2: visit_date changed, start_at not -> preserve the ET wall-clock,
--             move start_at's calendar day onto the new operating night.
--   Branch 3: start_at touched (or INSERT) -> start_at authoritative, derive date.
-- Named trg_aa_* so it fires FIRST in the BEFORE phase (alphabetical), before
-- trg_mark_visit_sync_pending diffs OLD/NEW -> the corrected pair is what gets
-- marked pending + pushed (one push, no fight, no duplicate).
--
-- Audit (ADR 010): no new TABLE; visits is already audited. No opt-in needed.
-- Verified: compiles, all branches simulated in rolled-back tx; DST spring-forward
-- 02:00-02:59 ET reconstruction in branch 2 is a known rare follow-up (1 night/yr).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_reconcile_visit_operating_date()
RETURNS trigger LANGUAGE plpgsql AS $f$
DECLARE
  c_cutoff CONSTANT time := time '06:00:00';
  v_et_ts   timestamp;
  v_et_date date;
  v_et_time time;
  v_op_date date;
BEGIN
  -- Branch 1: all-day (start_at NULL) -> visit_date authoritative, leave alone.
  IF NEW.start_at IS NULL THEN
    RETURN NEW;
  END IF;

  -- Fast exit: UPDATE that changed neither field we care about.
  IF TG_OP = 'UPDATE'
     AND NEW.start_at  IS NOT DISTINCT FROM OLD.start_at
     AND NEW.visit_date IS NOT DISTINCT FROM OLD.visit_date THEN
    RETURN NEW;
  END IF;

  -- Branch 2: pure date-drag (visit_date changed, start_at did NOT) ->
  -- preserve the ET wall-clock, move start_at onto the new operating day.
  IF TG_OP = 'UPDATE'
     AND NEW.visit_date IS DISTINCT FROM OLD.visit_date
     AND NEW.start_at  IS NOT DISTINCT FROM OLD.start_at THEN
    v_et_time := (OLD.start_at AT TIME ZONE 'America/New_York')::time;
    NEW.start_at := (
      (CASE WHEN v_et_time > time '00:00:00' AND v_et_time < c_cutoff
            THEN (NEW.visit_date + 1)
            ELSE NEW.visit_date END)
      + v_et_time
    ) AT TIME ZONE 'America/New_York';
    RETURN NEW;
  END IF;

  -- Branch 3: INSERT, or any write that touched start_at -> start_at authoritative,
  -- derive visit_date = the ET operating date.
  v_et_ts   := NEW.start_at AT TIME ZONE 'America/New_York';
  v_et_date := v_et_ts::date;
  v_et_time := v_et_ts::time;
  v_op_date := CASE
    WHEN v_et_time = time '00:00:00'                          THEN v_et_date
    WHEN v_et_time > time '00:00:00' AND v_et_time < c_cutoff THEN v_et_date - 1
    ELSE v_et_date END;
  NEW.visit_date := v_op_date;
  RETURN NEW;
END $f$;

DROP TRIGGER IF EXISTS trg_aa_reconcile_operating_date ON public.visits;
CREATE TRIGGER trg_aa_reconcile_operating_date
  BEFORE INSERT OR UPDATE OF start_at, visit_date ON public.visits
  FOR EACH ROW EXECUTE FUNCTION public.fn_reconcile_visit_operating_date();
