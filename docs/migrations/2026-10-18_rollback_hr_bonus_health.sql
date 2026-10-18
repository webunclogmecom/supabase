-- Rollback of 2026-10-18_1626_hr_bonus_health: remove the cron, take hr-bonus-health back out of the two
-- health views (spliced from the live text), drop the function. sync_log rows stay (history).
BEGIN;
SET LOCAL lock_timeout = '3s';
SELECT cron.unschedule('hr-bonus-health');
DO $s$
DECLARE v text;
BEGIN
  v := pg_get_viewdef('ops.v_health_items'::regclass);
  v := replace(v, ', ''hr-bonus-health''::text]))', ']))');
  v := replace(v, ' WHEN ''hr-bonus-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)', '');
  IF position('hr-bonus-health' in v) > 0 THEN RAISE EXCEPTION 'v_health_items still names hr-bonus-health'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_health_items AS ' || v;
  v := pg_get_viewdef('ops.v_health_status'::regclass);
  v := replace(v, ', ''hr-bonus-health''::text]))', ']))');
  v := replace(v, ' WHEN ''hr-bonus-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)', '');
  IF position('hr-bonus-health' in v) > 0 THEN RAISE EXCEPTION 'v_health_status still names hr-bonus-health'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_health_status AS ' || v;
END $s$;
DROP FUNCTION public.log_hr_bonus_health();
COMMIT;
