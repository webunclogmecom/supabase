-- ============================================================================
-- ROLLBACK of 2026-10-16_1125_calendar_hours_estimates
-- Revert the Visit Calendar app FIRST (its Hours worked tile reads this function; without it the tile shows a dash).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION ops.calendar_hours_estimates(date, date);
DO $v$ BEGIN
  IF to_regprocedure('ops.calendar_hours_estimates(date,date)') IS NOT NULL THEN
    RAISE EXCEPTION 'rollback: the function is still there';
  END IF;
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
