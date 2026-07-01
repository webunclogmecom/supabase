-- 2026-07-01b_operating_date_trigger_carry_end_at.sql
-- ============================================================================
-- ROOT-CAUSE FIX for the end_at desync found by the 2026-07-01 health check.
--
-- Symptom: 6 visits had end_at exactly 24h BEFORE start_at (span -1380 min), so
-- Jobber rejected every schedule push with "startAt needs to be before endAt"
-- (5 stuck sync_state='failed', incl. two future 7/03 visits). The bad rows were
-- repaired (end_at + 24h) and re-pushed to Jobber (200 ok) separately.
--
-- Cause: fn_reconcile_visit_operating_date (2026-07-01_visit_operating_date_trigger.sql)
--   BRANCH 2 (pure date-drag: visit_date changed, start_at NOT) recomputes
--   NEW.start_at onto the new operating night but NEVER moved NEW.end_at — so a
--   visit_date bump slid start_at +1 day and left end_at behind. Confirmed via the
--   audit trail: the corrupting writes all preserved the ET wall-clock and moved
--   start_at +1 day (Branch 2's exact signature). This fires on EVERY Calendar
--   date-drag of a TIMED visit (drag-drop sends visit_date without start_at) → a
--   live recurring corruption, not a one-off.
--
-- Fix:
--   1. Branch 2 now carries end_at by the SAME delta as start_at (duration held),
--      unless the writer set its own new end_at.
--   2. Defensive tail on Branch 3 / INSERT: if end_at ends up <= start_at and the
--      writer did NOT deliberately edit end_at, snap it to start_at + prior duration
--      (catches the "shift start_at alone" class too).
--   3. CHECK constraint visits_end_after_start_chk: end_at can never be <= start_at
--      again by ANY path (incl. an end_at-only edit the trigger doesn't watch).
--
-- Audit (ADR 010): no new table; visits already audited. updated_at trigger-managed.
-- Verified: rolled-back tx tests (Branch 2 date-drag carries end; start-only shift
-- snaps end; explicit end edit respected) + 0 live rows violate the CHECK.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_reconcile_visit_operating_date()
RETURNS trigger LANGUAGE plpgsql AS $f$
DECLARE
  c_cutoff CONSTANT time := time '06:00:00';
  v_et_ts     timestamp;
  v_et_date   date;
  v_et_time   time;
  v_op_date   date;
  v_new_start timestamptz;
  v_dur       interval;
BEGIN
  -- Branch 1: all-day (start_at NULL) -> visit_date authoritative, leave alone.
  IF NEW.start_at IS NULL THEN
    RETURN NEW;
  END IF;

  -- Prior duration (for the end_at carry / defensive snap); NULL on INSERT.
  IF TG_OP = 'UPDATE' AND OLD.start_at IS NOT NULL AND OLD.end_at IS NOT NULL THEN
    v_dur := OLD.end_at - OLD.start_at;
  END IF;

  -- Fast exit: UPDATE that changed neither field we care about.
  IF TG_OP = 'UPDATE'
     AND NEW.start_at  IS NOT DISTINCT FROM OLD.start_at
     AND NEW.visit_date IS NOT DISTINCT FROM OLD.visit_date THEN
    RETURN NEW;
  END IF;

  -- Branch 2: pure date-drag (visit_date changed, start_at did NOT) ->
  -- preserve the ET wall-clock, move start_at onto the new operating day, AND
  -- carry end_at by the same delta so the visit duration is preserved.
  IF TG_OP = 'UPDATE'
     AND NEW.visit_date IS DISTINCT FROM OLD.visit_date
     AND NEW.start_at  IS NOT DISTINCT FROM OLD.start_at THEN
    v_et_time := (OLD.start_at AT TIME ZONE 'America/New_York')::time;
    v_new_start := (
      (CASE WHEN v_et_time > time '00:00:00' AND v_et_time < c_cutoff
            THEN (NEW.visit_date + 1)
            ELSE NEW.visit_date END)
      + v_et_time
    ) AT TIME ZONE 'America/New_York';
    -- carry end_at ONLY if the writer didn't set its own new end_at
    IF OLD.end_at IS NOT NULL AND NEW.end_at IS NOT DISTINCT FROM OLD.end_at THEN
      NEW.end_at := NEW.end_at + (v_new_start - OLD.start_at);
    END IF;
    NEW.start_at := v_new_start;
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

  -- Defensive: if end_at was left behind (now <= start_at) and the writer did NOT
  -- deliberately edit end_at, snap it to preserve the prior duration. Catches a
  -- writer that shifts start_at alone (the class behind the 2026-07-01 desync).
  IF NEW.end_at IS NOT NULL AND NEW.end_at <= NEW.start_at
     AND (TG_OP = 'INSERT' OR NEW.end_at IS NOT DISTINCT FROM OLD.end_at) THEN
    NEW.end_at := NEW.start_at + CASE WHEN v_dur > interval '0' THEN v_dur ELSE interval '1 hour' END;
  END IF;

  RETURN NEW;
END $f$;

-- Hard guard: end_at can never be <= start_at again, by any writer or path.
-- (All-day placeholder rows use start_at + ~23:59, so end_at > start_at holds.)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'visits_end_after_start_chk') THEN
    ALTER TABLE public.visits
      ADD CONSTRAINT visits_end_after_start_chk
      CHECK (end_at IS NULL OR start_at IS NULL OR end_at > start_at);
  END IF;
END $$;
