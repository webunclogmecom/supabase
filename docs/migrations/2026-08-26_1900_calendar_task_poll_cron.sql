-- 2026-08-26_1900_calendar_task_poll_cron.sql
--
-- WHAT: public.fn_request_calendar_task_poll() + the 'calendar-task-poll' pg_cron entry that calls
--       the poll-calendar-tasks edge function every 5 minutes.
--
-- 🛑 APPLY THIS ONLY AFTER poll-calendar-tasks IS DEPLOYED AND VERIFIED BY HAND. The wrapper is
--    deliberately blind (see below), so scheduling it against a function that is not there yet
--    produces a job that reports success forever while doing nothing at all.
--
-- ============================================================================================
-- WHY THE SCHEDULE IS 2-57/5 AND NOT */5
-- ============================================================================================
-- Measured: 22 cron jobs, all active, all running as postgres, and FOUR already sit on exactly
-- */5 * * * * -- jobber-poll-sync, redact-manifest-sweep, dump-driver-truck-refresh and
-- calendar-push-auto-retry. DB-side contention is negligible (0.04-0.17s each). The contention that
-- matters is downstream: jobber-poll-sync calls the JOBBER API on that same tick, so putting a
-- second Jobber consumer on */5 doubles concurrent Jobber load at every five-minute boundary, and
-- Jobber sheds load with an HTML waiting room at HTTP 200. This codebase already has a stagger
-- idiom for exactly this (sheet-row-ocr-sweep at 5-55/10 against sheet-number-ocr-sweep's */10;
-- jobber-job-drift-reconcile at 15,45 against jobber-visit-drift-reconcile's */30). 2-57/5 keeps
-- the five-minute cadence and lands two minutes off every existing tick.
--
-- ============================================================================================
-- WHY THE SECRET IS READ FROM VAULT AND NOT FROM A FUNCTION
-- ============================================================================================
-- `public.edge_invoke_service_key()` IS NOT A FUNCTION. Measured: functions matching %edge_invoke%
-- = 0, against controls of 3,762 rows in pg_proc and 7 public.fn_request* functions, so the
-- instrument sees positives and the zero is real. `edge_invoke_service_key` is a VAULT SECRET NAME.
-- vault.secrets holds exactly two rows: this one and jobber_push_service_key.
-- ⚠ Do NOT copy the sync_trigger_key limb from fn_request_jobber_sync. That secret is no longer in
--   vault, so its v_sync is NULL and jsonb_strip_nulls silently drops the x-sync-key header.
--
-- ============================================================================================
-- WHY THE MISSING-KEY PATH RAISES RATHER THAN WARNS
-- ============================================================================================
-- Six of the seven fn_request_* functions RAISE WARNING and RETURN when the key is absent. That
-- makes the cron run report SUCCEEDED while nothing was sent. RAISE EXCEPTION is the only lever
-- that marks a cron run failed, and fn_request_jobber_sync already uses it. Given the whole point
-- of this job is to be a safety net, a silently-not-running safety net is the worst outcome
-- available, so it raises.
--
-- ============================================================================================
-- 🛑 AND THE WRAPPER STILL CANNOT TELL YOU IT WORKED. THIS IS NOT FIXABLE HERE.
-- ============================================================================================
-- net.http_post only ENQUEUES. The cron run therefore succeeds whatever the edge function does --
-- including a 401, a 500, or never being reached. Measured across the full history:
-- cron.job_run_details holds 99,697 'succeeded' against exactly 1 'failed'.
-- And after the fact there is no trace either: net._http_response has columns
-- (id, status_code, content_type, headers, content, timed_out, error_msg, created) and NO url
-- column -- the url lives only in net.http_request_queue, which is drained on send -- with roughly
-- six hours of retention (238 rows spanning a 6h window when measured).
-- ⇒ Which is why the VERIFY block below does SELECT ... INTO a request id and reads
--   net._http_response.status_code back. A 2xx there is the ONLY proof the request reached the
--   function, and it has to be run inside the retention window to mean anything.
-- ⇒ And why poll-calendar-tasks writes its OWN public.sync_log row (sync_source =
--   'calendar-task-poll'; the column is sync_source, NOT source). That is the steady-state
--   observability. Without it the job is green forever and the missing-task list is seen by nobody.
--
-- ⚠ timeout_milliseconds DEFAULTS TO 5000 and is passed explicitly here. All 13 status_code IS NULL
--   rows in net._http_response are 'Timeout of 5000 ms reached'. This function paginates Jobber and
--   may binary-search completion timestamps (measured: 5.07s for one task), so 5s is far too short.
--
-- ⚠ The body is ALWAYS passed even though it is empty: net.http_post(text,jsonb,jsonb,jsonb,integer)
--   has `body` as the SECOND POSITIONAL argument with default '{}'::jsonb. Named arguments only.
--
-- ⚠ Plain single-quoted function body, NOT dollar-quoting. Applying dollar-quoted SQL through a
--   shell or a JS template mangles $$ into a syntax error at or near $. That cost one failed apply
--   on 2026-08-24 and is the same escaping-in-transit class that keeps biting this estate.
--
-- ⚠ cron.schedule is NOT transactional, so it goes AFTER the COMMIT.
--
-- Template: docs/migrations/2026-08-24_1840_health_escalation_cron.sql

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_request_calendar_task_poll()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS '
DECLARE
  v_key text;
BEGIN
  SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets
   WHERE name = ''edge_invoke_service_key'';

  IF v_key IS NULL THEN
    RAISE EXCEPTION ''fn_request_calendar_task_poll: vault secret edge_invoke_service_key is missing; the calendar-task poll did NOT run'';
  END IF;

  PERFORM net.http_post(
    url     := ''https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/poll-calendar-tasks'',
    headers := jsonb_build_object(
                 ''Content-Type'', ''application/json'',
                 ''Authorization'', ''Bearer '' || v_key),
    body    := ''{}''::jsonb,
    timeout_milliseconds := 60000);
END;
';

-- 🛑 REVOKE FROM PUBLIC IS NOT ENOUGH, AND THE VERIFY BLOCK BELOW CAUGHT THIS.
-- pg_default_acl for FUNCTIONS in schema public holds TWO rows, one per grantor (measured):
--   grantor supabase_admin: {postgres,anon,authenticated,service_role}=X
--   grantor postgres:       {postgres,authenticated,service_role}=X      <- NO anon
-- The one that applies is the grantor's, and these migrations are applied as postgres, so a new
-- function here is born with DIRECT EXECUTE grants to `authenticated` and `service_role` -- plus
-- the implicit EXECUTE that PUBLIC gets on every function.
-- ⇒ `REVOKE ... FROM PUBLIC` removes the PUBLIC one, and that is what covers anon. It does NOT
--   touch the two DIRECT grants, which is why this file names the roles explicitly.
-- ⚠ CORRECTION to an earlier version of this comment, which said the default privileges grant to
--   "anon, authenticated AND service_role". Wrong in the safe direction: anon is not granted
--   DIRECTLY when postgres creates the function, and revoking from PUBLIC does close anon's path.
--   The two grants that genuinely survive a PUBLIC-only revoke are authenticated and service_role.
-- The first version of this file had only the PUBLIC revoke and CONTROL 2 failed the apply outright.
-- ⇒ This is also the answer to a standing puzzle: fn_request_health_escalation carries an EXECUTE
--   grant to `authenticated` that its own migration never wrote. Nothing widened it after the fact
--   -- it was never revoked, and the default privileges granted it at birth. The two wrappers that
--   ARE postgres-only (fn_request_jobber_sync, fn_request_blackout_sweep) revoked explicitly.
REVOKE ALL ON FUNCTION public.fn_request_calendar_task_poll()
  FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION public.fn_request_calendar_task_poll() IS
  'Invokes the poll-calendar-tasks edge function. Called by the calendar-task-poll cron job at '
  '2-57/5 (staggered off the four existing */5 jobs, one of which also calls Jobber). Raises when '
  'the vault key is missing, because net.http_post only enqueues and a cron run otherwise reports '
  'succeeded whatever happens next. Steady-state observability is the function''s own '
  'public.sync_log row (sync_source=''calendar-task-poll''), not this wrapper.';

-- =============================================================================================
-- VERIFY -- capture the request id and read the RESPONSE back. "No error" proves nothing here:
-- net.http_post enqueues and returns a bigint whatever happens downstream, and every existing
-- wrapper throws that id away with PERFORM.
-- =============================================================================================
DO $verify$
DECLARE
  v_key    text;
  v_req_id bigint;
  v_status int;
  v_err    text;
  v_owner  text;
BEGIN
  -- CONTROL 1: the secret must actually be readable, or the 2xx below could never happen and a
  -- failure would be indistinguishable from a missing key.
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL OR length(v_key) < 40 THEN
    RAISE EXCEPTION 'CONTROL 1 FAILED: vault secret edge_invoke_service_key is missing or too short';
  END IF;

  -- CONTROL 2: the grant surface must be postgres-only. fn_request_health_escalation somehow
  -- carries an EXECUTE grant to authenticated that its own migration never wrote; do not inherit it.
  IF has_function_privilege('authenticated', 'public.fn_request_calendar_task_poll()', 'EXECUTE')
  OR has_function_privilege('anon', 'public.fn_request_calendar_task_poll()', 'EXECUTE')
  OR has_function_privilege('service_role', 'public.fn_request_calendar_task_poll()', 'EXECUTE') THEN
    RAISE EXCEPTION 'CONTROL 2 FAILED: EXECUTE is wider than postgres-only';
  END IF;

  SELECT pg_get_userbyid(proowner) INTO v_owner FROM pg_proc
   WHERE oid = 'public.fn_request_calendar_task_poll()'::regprocedure;
  IF v_owner <> 'postgres' THEN
    RAISE EXCEPTION 'CONTROL 3 FAILED: owner is %, want postgres (SECURITY DEFINER runs as the owner)', v_owner;
  END IF;

  RAISE NOTICE 'VERIFY (pre-commit) OK: the vault key is readable, EXECUTE is postgres-only, owner is postgres.';
END
$verify$;

COMMIT;

-- =============================================================================================
-- 🛑 THE HTTP INVOCATION CHECK IS A SEPARATE FILE, AND IT HAS TO BE.
-- =============================================================================================
-- net.http_post ENQUEUES: it inserts into net.http_request_queue and the pg_net background worker
-- drains that queue only once the transaction COMMITS. So a block that posts and then waits for its
-- own response is waiting for something that cannot happen until the block itself has ended. A DO
-- block is a single statement and therefore atomic, so wrapping the post and the read together
-- guarantees a NULL no matter where in the file it sits. Three dead request ids (6146, 6147, 6150)
-- before splitting it into two submissions (6152) worked: HTTP 200 with a fresh sync_log row.
-- ⇒ Verify the invocation by applying 2026-08-26_1901_calendar_task_poll_verify.sql as its OWN
--   submission -- in fact as its own TWO submissions -- once this file has been applied. Do it
--   promptly: net._http_response has no url column and roughly six hours of retention.
--
-- ⚠⚠ A CORRECTION, RECORDED BECAUSE THE WRONG VERSION WAS COMMITTED HERE FIRST AND IS THE MORE
--    DANGEROUS OF THE TWO. An earlier version of this comment claimed "the Management API wraps an
--    entire submitted body in ONE transaction, so a mid-body COMMIT; releases nothing". **THAT IS
--    FALSE.** Measured directly afterwards with a controlled probe: submitting
--        BEGIN; CREATE TABLE public.zz_commit_atomicity_probe(id int); COMMIT;
--        DO $x$ BEGIN RAISE EXCEPTION 'deliberate post-commit failure'; END $x$;
--    and then querying from a second submission returns survived_the_later_failure = TRUE. The
--    table was there; the probe was dropped afterwards. A mid-body COMMIT; genuinely commits and
--    starts a new transaction.
--    ⇒ THE REAL CONSEQUENCE IS THE OPPOSITE OF WHAT I FIRST WROTE, AND IT IS SHARPER:
--      **A MIGRATION CONTAINING `COMMIT;` IS NOT ATOMIC. A failure after that COMMIT leaves the
--      first half APPLIED.** Plan for a partial apply -- make the pre-COMMIT half independently
--      safe, and never assume a failed migration left nothing behind.
--    ⇒ What misled me was a single incidental observation (the function appearing absent after one
--      failed attempt) taken while the file itself was being edited between attempts, i.e. an
--      uncontrolled reading. The controlled experiment above outranks it, which is the estate's own
--      rule about an artefact only one state could produce.



-- cron.schedule is NOT transactional, so it lives after the COMMIT.
SELECT cron.schedule('calendar-task-poll', '2-57/5 * * * *',
                     'SELECT public.fn_request_calendar_task_poll()');
