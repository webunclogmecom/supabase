-- Rollback of 2026-10-21_0530: removes the trap-size-health check, its cron and its entries in the two health views.
-- Its sync_log rows stay (history); v_health_items / v_health_status stop reading them.
BEGIN;
SET LOCAL lock_timeout = '3s';
SELECT cron.unschedule('trap-size-health');
DO $s$
DECLARE v text;
BEGIN
  v := pg_get_viewdef('ops.v_health_items'::regclass);
  v := regexp_replace(v, ',[[:space:]]*''trap-size-health''::text', '', 'g');
  v := regexp_replace(v, '[[:space:]]*WHEN ''trap-size-health''::text THEN COALESCE[(][(]la[.]details -> ''items''::text[)], ''[[][]]''::jsonb[)]', '');
  IF position('trap-size-health' in v) > 0 THEN RAISE EXCEPTION 'v_health_items still names trap-size-health'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_health_items AS ' || v;
  v := pg_get_viewdef('ops.v_health_status'::regclass);
  v := regexp_replace(v, ',[[:space:]]*''trap-size-health''::text', '', 'g');
  v := regexp_replace(v, '[[:space:]]*WHEN ''trap-size-health''::text THEN COALESCE[(][(]l[.]details -> ''items''::text[)], ''[[][]]''::jsonb[)]', '');
  IF position('trap-size-health' in v) > 0 THEN RAISE EXCEPTION 'v_health_status still names trap-size-health'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_health_status AS ' || v;
END $s$;
DROP FUNCTION public.log_trap_size_health();
COMMIT;
