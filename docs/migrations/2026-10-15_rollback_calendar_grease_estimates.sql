-- ============================================================================
-- ROLLBACK of 2026-10-15_1150_calendar_grease_estimates
-- ============================================================================
-- Removes the Grease pumped estimates. ⚠ DROPPING ops.visit_grease_frozen LOSES every stored past-day value, which
-- cannot be recomputed as it was (sensor readings and trap sizes keep changing): export it first
-- (select * from ops.visit_grease_frozen) if it may be needed. The Calendar must be published WITHOUT the tile
-- before this runs, or its day cards show a dash for the grease read (the rest of the card is unaffected).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

SELECT cron.unschedule('calendar-grease-freeze');

DO $s$
DECLARE
  d text := pg_get_functiondef('public.log_jobber_sync_health'::regproc);
  a text := ',' || chr(10) ||
    $b$      -- 2026-10-15_1150: Calendar grease freezer (cron calendar-grease-freeze, hourly at :05); 3 hours = 2 missed runs.$b$ || chr(10) ||
    $b$      ('calendar_grease_freeze',        interval '3 hours')$b$;
BEGIN
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN
    RAISE EXCEPTION 'rollback: the health tuple is not in log_jobber_sync_health exactly once'; END IF;
  EXECUTE replace(d, a, '');
END $s$;

DROP FUNCTION ops.calendar_grease_estimates(date, date);
DROP FUNCTION ops.fn_freeze_grease_estimates();
DROP TABLE ops.visit_grease_frozen;
DROP FUNCTION ops.fn_visit_grease_frozen_guard();
DROP FUNCTION ops.fn_grease_estimates_live(date, date);
DROP FUNCTION ops.fn_visit_pump_kind(bigint, bigint);
DELETE FROM public.app_config WHERE key = 'grease_separating_vehicle_ids';

DO $v$
BEGIN
  IF md5(pg_get_functiondef('public.log_jobber_sync_health'::regproc)) <> 'a41322fe76deff3223ccdff2aff97612' THEN
    RAISE EXCEPTION 'rollback: log_jobber_sync_health is not back to its 2026-10-15 11:40 definition'; END IF;
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
