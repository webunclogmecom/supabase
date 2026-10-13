-- ============================================================================
-- 2026-10-13_1235 A site survey form's Jobber task closes itself when the form is submitted or cancelled
-- ============================================================================
-- THE ASK (Trello QzHJYuNZ; plan docs/superpowers/specs/2026-10-13-intake-task-close-on-submit-and-cancel-plan.md)
--   The two version 1 gaps of the Schedule intake task: "Submitting the form doesn't complete the task. Someone
--   ticks it by hand." and "Cancelling a form doesn't remove its task." Fred's decisions, 2026-10-13:
--     cancelled form -> "Delete"  (the task)
--     any submit, even an Incomplete form -> "Yes" (tick it done)
--     close tasks 292 and 326 (forms 1042 and 1067, already submitted) on the first run -> "Yes"
--     an expired form -> NOT handled: Fred asked "Do they expire?" (yes, 60 days after scheduling); open.
--
-- WHAT CHANGES
--   1. ops.calendar_tasks_completed_source_check += 'intake', so a task the sweeper ticks says why it was ticked.
--      No view reads completed_source; the only live reader is the backup COPY (pg_stat_statements, 2026-10-13).
--      ⚠ ops.fn_record_calendar_task's error text still says "(calendar|jobber)"; the CHECK is the gate.
--   2. public.intake_task_closures: the sweeper's ledger, one row per form it acted on (done_at, outcome) or
--      tried and failed (last_error, attempts). done_at is what makes it act ONCE: a task a person reopens by
--      hand stays reopened. Rule 8: OPT-OUT of audit. It is a machine ledger written only by the sweeper, and
--      every action it records is itself audited on ops.calendar_tasks (the completion UPDATE, the delete's
--      old_row). service_role only.
--   3. public.v_intake_task_actions: the ONE definition of "this form's task needs closing": a submitted form
--      (-> complete) or a cancelled form (-> delete) whose task is still OPEN and not already handled.
--      A cancelled form whose task was already ticked done is left alone (it records work done). service_role only.
--   4. Backfill: the 4 submitted forms whose task was already ticked by hand get a ledger row
--      (outcome already_complete_at_install), so an untick later is not undone by the sweeper.
--   5. public.fn_request_intake_task_sync(): posts to edge fn intake-task-sync with the vault key, a copy of
--      fn_request_calendar_task_poll. It ALWAYS posts (the sweeper writes a sync_log row every run, which is
--      what lets the health check see a sweeper that stopped). EXECUTE revoked by name from staff roles.
--   6. cron intake-task-sync '3-59/5 * * * *', one minute after calendar-task-poll (2-57/5).
--   7. public.log_jobber_sync_health: ONE tuple added to its watched list, ('intake_task_sync', 25 minutes),
--      spliced into the live body (md5 pinned, anchor asserted once). It already sits in ops.v_health_items and
--      ops.v_health_status, so nothing else needs registering.
--
-- WHAT MOVES AT APPLY (measured 2026-10-13 12:30 ET): the view lists forms 1042 (task 292) and 1067 (task 326),
--   both 'complete'; the cron's first run ticks them in Jobber and in the Calendar (Fred: "Yes").
-- ORDER: deploy edge fn intake-task-sync FIRST (the cron starts calling it within 5 minutes of this commit).
-- HOW TO RUN: one call, one transaction. Rehearse: node scripts/probes/apply_sql_file.mjs <file> rehearse
-- ROLLBACK: 2026-10-13_rollback_intake_task_close.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';   -- the CHECK swap locks ops.calendar_tasks, read by the Visit Calendar

DO $g$
BEGIN
  IF md5(pg_get_functiondef('public.log_jobber_sync_health'::regproc)) <> '9d2afffd3740897fa6dbc43544a7a040' THEN
    RAISE EXCEPTION 'log_jobber_sync_health changed since 2026-10-13 12:30 ET: re-read it and re-pin'; END IF;
  IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'calendar_tasks_completed_source_check'))
     <> 'CHECK ((completed_source = ANY (ARRAY[''calendar''::text, ''jobber''::text])))' THEN
    RAISE EXCEPTION 'calendar_tasks_completed_source_check is not what this migration expects'; END IF;
END $g$;

-- 1 ---------------------------------------------------------------------------------------------------------
ALTER TABLE ops.calendar_tasks DROP CONSTRAINT calendar_tasks_completed_source_check;
ALTER TABLE ops.calendar_tasks ADD CONSTRAINT calendar_tasks_completed_source_check
  CHECK (completed_source = ANY (ARRAY['calendar'::text, 'jobber'::text, 'intake'::text]));

-- 2 ---------------------------------------------------------------------------------------------------------
CREATE TABLE public.intake_task_closures (
  intake_id       bigint PRIMARY KEY REFERENCES public.property_intakes(id) ON DELETE CASCADE,
  action          text NOT NULL CHECK (action IN ('complete', 'delete')),
  task_id         bigint NOT NULL,          -- no FK: a delete removes the task row, this keeps which one it was
  jobber_gid      text,
  outcome         text,                     -- completed | completed_elsewhere | gone_in_jobber | deleted | already_gone | already_complete_at_install
  done_at         timestamptz,
  last_error      text,
  attempts        integer NOT NULL DEFAULT 0,
  last_attempt_at timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((done_at IS NULL) = (outcome IS NULL))
);
COMMENT ON TABLE public.intake_task_closures IS
  'intake-task-sync''s ledger (2026-10-13_1235): one row per site survey form whose Jobber task it closed (done_at) or '
  'tried to (last_error). done_at makes it act once per form. Not audited: the actions are audited on ops.calendar_tasks.';
REVOKE ALL ON public.intake_task_closures FROM public, anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.intake_task_closures TO service_role;

-- 3 ---------------------------------------------------------------------------------------------------------
CREATE VIEW public.v_intake_task_actions AS
SELECT pi.id AS intake_id,
       CASE WHEN pi.cancelled_at IS NOT NULL THEN 'delete' ELSE 'complete' END AS action,
       t.id AS task_id,
       l.source_id AS jobber_gid,
       COALESCE(pi.cancelled_at, pi.submitted_at) AS since,
       c.attempts, c.last_error, c.last_attempt_at
  FROM public.property_intakes pi
  JOIN ops.calendar_tasks t ON t.id = pi.calendar_task_id
  LEFT JOIN public.entity_source_links l
         ON l.entity_type = 'calendar_task' AND l.source_system = 'jobber' AND l.entity_id = t.id
  LEFT JOIN public.intake_task_closures c ON c.intake_id = pi.id
 WHERE NOT t.is_complete
   AND (pi.cancelled_at IS NOT NULL OR pi.submitted_at IS NOT NULL)
   AND c.done_at IS NULL;
COMMENT ON VIEW public.v_intake_task_actions IS
  'Site survey forms whose Jobber task needs closing (2026-10-13_1235): submitted -> complete, cancelled -> delete. '
  'Open tasks only, forms not already handled. Read by edge fn intake-task-sync. Expired forms are not handled yet.';
REVOKE ALL ON public.v_intake_task_actions FROM public, anon, authenticated;
GRANT SELECT ON public.v_intake_task_actions TO service_role;

-- 4 ---------------------------------------------------------------------------------------------------------
INSERT INTO public.intake_task_closures (intake_id, action, task_id, jobber_gid, outcome, done_at)
SELECT pi.id, 'complete', t.id, l.source_id, 'already_complete_at_install', now()
  FROM public.property_intakes pi
  JOIN ops.calendar_tasks t ON t.id = pi.calendar_task_id
  LEFT JOIN public.entity_source_links l
         ON l.entity_type = 'calendar_task' AND l.source_system = 'jobber' AND l.entity_id = t.id
 WHERE pi.submitted_at IS NOT NULL AND t.is_complete;

-- 5 ---------------------------------------------------------------------------------------------------------
CREATE FUNCTION public.fn_request_intake_task_sync()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_key text;
BEGIN
  SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets
   WHERE name = 'edge_invoke_service_key';

  IF v_key IS NULL THEN
    RAISE EXCEPTION 'fn_request_intake_task_sync: vault secret edge_invoke_service_key is missing; the intake task sync did NOT run';
  END IF;

  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/intake-task-sync',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || v_key),
    body    := '{}'::jsonb,
    timeout_milliseconds := 60000);
END;
$function$;
REVOKE ALL ON FUNCTION public.fn_request_intake_task_sync() FROM public, anon, authenticated;

-- 6 ---------------------------------------------------------------------------------------------------------
SELECT cron.schedule('intake-task-sync', '3-59/5 * * * *', 'SELECT public.fn_request_intake_task_sync()');

-- 7 ---------------------------------------------------------------------------------------------------------
DO $s$
DECLARE
  d text := pg_get_functiondef('public.log_jobber_sync_health'::regproc);
  a text := $a$('tank_geometry_drift',           interval '2 hours')$a$;
BEGIN
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN
    RAISE EXCEPTION 'splice anchor not found exactly once in log_jobber_sync_health'; END IF;
  EXECUTE replace(d, a, a || ',' || chr(10) ||
    $b$      -- 2026-10-13_1235: intake-task-sync (cron intake-task-sync, every 5 minutes); 25 minutes = 4 missed runs.$b$ || chr(10) ||
    $b$      ('intake_task_sync',              interval '25 minutes')$b$);
END $s$;

-- VERIFY ----------------------------------------------------------------------------------------------------
DO $v$
DECLARE n int; s text;
BEGIN
  IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'calendar_tasks_completed_source_check'))
     NOT LIKE '%''intake''%' THEN RAISE EXCEPTION 'V1 the CHECK does not admit intake'; END IF;

  -- V2 the two forms Fred named are listed, as completions
  SELECT count(*) INTO n FROM public.v_intake_task_actions WHERE (intake_id, task_id, action) IN ((1042, 292, 'complete'), (1067, 326, 'complete'));
  IF n <> 2 THEN RAISE EXCEPTION 'V2 expected forms 1042 and 1067 in the view, found %', n; END IF;
  -- V3 the view never lists a completed task or an open (unsubmitted, uncancelled) form
  SELECT count(*) INTO n FROM public.v_intake_task_actions v JOIN ops.calendar_tasks t ON t.id = v.task_id WHERE t.is_complete;
  IF n <> 0 THEN RAISE EXCEPTION 'V3 the view lists % completed task(s)', n; END IF;
  SELECT count(*) INTO n FROM public.v_intake_task_actions v JOIN public.property_intakes pi ON pi.id = v.intake_id
   WHERE pi.submitted_at IS NULL AND pi.cancelled_at IS NULL;
  IF n <> 0 THEN RAISE EXCEPTION 'V3 the view lists % open form(s)', n; END IF;
  -- V3b control: open forms with open tasks exist, so V3 is not passing on an empty population
  SELECT count(*) INTO n FROM public.property_intakes pi JOIN ops.calendar_tasks t ON t.id = pi.calendar_task_id
   WHERE pi.submitted_at IS NULL AND pi.cancelled_at IS NULL AND NOT t.is_complete;
  IF n = 0 THEN RAISE EXCEPTION 'V3b control: no open form with an open task exists, V3 proved nothing'; END IF;

  -- V4 backfill = every submitted form whose task was already ticked
  SELECT count(*) INTO n FROM public.intake_task_closures WHERE outcome = 'already_complete_at_install';
  IF n <> (SELECT count(*) FROM public.property_intakes pi JOIN ops.calendar_tasks t ON t.id = pi.calendar_task_id
            WHERE pi.submitted_at IS NOT NULL AND t.is_complete) OR n = 0 THEN
    RAISE EXCEPTION 'V4 backfill wrote % rows', n; END IF;

  -- V5 an untick after closure is NOT re-listed (the "never fight a person" rule), rolled back
  BEGIN
    UPDATE ops.calendar_tasks SET is_complete = false, completed_at = NULL, completed_source = NULL
     WHERE id = (SELECT task_id FROM public.intake_task_closures WHERE outcome = 'already_complete_at_install' ORDER BY intake_id LIMIT 1);
    SELECT count(*) INTO n FROM public.v_intake_task_actions v JOIN public.intake_task_closures c USING (intake_id);
    IF n <> 0 THEN RAISE EXCEPTION 'V5 a reopened, already-closed task is listed again'; END IF;
    RAISE EXCEPTION 'v5_rollback';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'v5_rollback' THEN RAISE; END IF;
  END;

  -- V6 grants: service_role only
  IF has_table_privilege('authenticated', 'public.v_intake_task_actions', 'SELECT')
     OR has_table_privilege('anon', 'public.v_intake_task_actions', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.v_intake_task_actions', 'SELECT') THEN
    RAISE EXCEPTION 'V6 v_intake_task_actions grants wrong'; END IF;
  IF has_table_privilege('authenticated', 'public.intake_task_closures', 'SELECT')
     OR has_table_privilege('authenticated', 'public.intake_task_closures', 'INSERT')
     OR has_table_privilege('anon', 'public.intake_task_closures', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.intake_task_closures', 'UPDATE') THEN
    RAISE EXCEPTION 'V6 intake_task_closures grants wrong'; END IF;
  IF has_function_privilege('authenticated', 'public.fn_request_intake_task_sync()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.fn_request_intake_task_sync()', 'EXECUTE') THEN
    RAISE EXCEPTION 'V6 fn_request_intake_task_sync is callable by staff or anon'; END IF;

  -- V7 the health splice: the new tuple once, every old source still there
  s := pg_get_functiondef('public.log_jobber_sync_health'::regproc);
  IF (length(s) - length(replace(s, $q$('intake_task_sync',              interval '25 minutes')$q$, '')))
     / length($q$('intake_task_sync',              interval '25 minutes')$q$) <> 1 THEN
    RAISE EXCEPTION 'V7 intake_task_sync tuple not in the health body exactly once'; END IF;
  IF s NOT LIKE '%(''tank_geometry_drift'',           interval ''2 hours'')%' OR s NOT LIKE '%(''jobber_poll_pgcron'',%' THEN
    RAISE EXCEPTION 'V7 the splice lost an existing source'; END IF;

  -- V8 the cron
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'intake-task-sync' AND schedule = '3-59/5 * * * *' AND active) THEN
    RAISE EXCEPTION 'V8 cron intake-task-sync missing'; END IF;
END $v$;

-- The edge fn reads the new view through PostgREST, whose schema cache does not see it until reloaded.
-- (Added after the 2026-10-13 apply, where the first dry run failed "Could not find the table" until this ran.)
NOTIFY pgrst, 'reload schema';

COMMIT;
