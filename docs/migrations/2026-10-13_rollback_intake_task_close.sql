-- ============================================================================
-- ROLLBACK of 2026-10-13_1235_intake_task_close
-- ============================================================================
-- Stops the sweeper and removes its objects. What it does NOT undo, on purpose:
--   - tasks it already ticked stay ticked in Jobber and in the Calendar; tasks it deleted stay deleted
--     (Jobber has no undelete; the old rows are in audit.logs, table calendar_tasks, app_source intake-task-sync).
--   - rows already completed_source = 'intake' are relabelled 'calendar' so the old CHECK can come back.
--     That rewrites how a completion is labelled, so run it only if the CHECK really must narrow again.
-- Also: undeploy the edge fn intake-task-sync (supabase functions delete intake-task-sync) and remove its
-- config.toml entry.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

SELECT cron.unschedule('intake-task-sync');
DROP FUNCTION public.fn_request_intake_task_sync();
DROP VIEW public.v_intake_task_actions;
DROP TABLE public.intake_task_closures;

UPDATE ops.calendar_tasks SET completed_source = 'calendar' WHERE completed_source = 'intake';
ALTER TABLE ops.calendar_tasks DROP CONSTRAINT calendar_tasks_completed_source_check;
ALTER TABLE ops.calendar_tasks ADD CONSTRAINT calendar_tasks_completed_source_check
  CHECK (completed_source = ANY (ARRAY['calendar'::text, 'jobber'::text]));

DO $s$
DECLARE
  d text := pg_get_functiondef('public.log_jobber_sync_health'::regproc);
  a text := ',' || chr(10) ||
    $b$      -- 2026-10-13_1235: intake-task-sync (cron intake-task-sync, every 5 minutes); 25 minutes = 4 missed runs.$b$ || chr(10) ||
    $b$      ('intake_task_sync',              interval '25 minutes')$b$;
BEGIN
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN
    RAISE EXCEPTION 'the intake_task_sync tuple is not in log_jobber_sync_health exactly once; remove it by hand'; END IF;
  EXECUTE replace(d, a, '');
END $s$;

NOTIFY pgrst, 'reload schema';
COMMIT;
