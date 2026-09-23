-- 2026-09-23_1259_inbound_file_drain_cron.sql
--
-- WHY
-- ---
-- The inbound file queue had no drainer schedule, so a Fillout submission's photos would sit
-- pending forever. This is the last piece of the intake path.
--
-- SCHEDULE: every 5 minutes, and the interval is a MEASURED choice rather than a cautious guess.
-- Measured 2026-09-23 on the real submission: Fillout serves its uploads from
--   prod-fillout-oregon-s3.s3.us-west-2.amazonaws.com/...
-- with NO query string, i.e. unsigned public S3 objects, not presigned links. Both test files
-- fetched HTTP 200 with the right content-type. So there is no expiry racing us and no reason to
-- hammer it. ⚠ That is an observation about Fillout today, not a promise: the drainer still treats
-- 404/403/410 as a link that has gone, and the queue's `error` rows surface in
-- public.v_inbound_file_queue_health if that ever changes.
--
-- THROUGHPUT: BATCH is 3 per invocation, so 5 minutes clears 36 files an hour. A full shift
-- inspection carries up to 17 attachments, and there are at most a handful of submissions a day
-- (2 shifts x 2 forms), so the steady state is minutes of lag, not hours. Raising BATCH is the wrong
-- first move if it ever backs up: each row is a download plus an upload in one edge invocation, and
-- this estate has already paid for a function that tried to do too much in one run.
--
-- 🛑 NO HTTP CALL WHEN THERE IS NOTHING TO DO. The wrapper checks the queue first and returns.
-- That is the same shape as city-email-sweep and it is what makes a 5-minute cadence cheap: an idle
-- queue costs one index scan, not an edge invocation.
--
-- RULE 8: nothing new to audit; this adds a function and a cron entry, no table.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_request_inbound_file_drain()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_key     text;
  v_pending integer;
BEGIN
  -- Cheap early return. An empty queue is the normal, healthy state.
  SELECT count(*) INTO v_pending
    FROM sync.inbound_file_queue
   WHERE status = 'pending'
      OR (status = 'claimed' AND claimed_at < now() - interval '10 minutes');
  IF v_pending = 0 THEN
    RETURN;
  END IF;

  SELECT decrypted_secret INTO v_key
    FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'edge_invoke_service_key vault secret missing; skipping inbound-file-drain';
    RETURN;
  END IF;

  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/inbound-file-drain',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body    := '{}'::jsonb,
    timeout_milliseconds := 60000);
END
$fn$;

COMMENT ON FUNCTION public.fn_request_inbound_file_drain() IS
  'pg_cron entry point for inbound-file-drain. Returns without an HTTP call when the queue is '
  'empty, so an idle schedule costs one index scan. Reclaims a stale claim the same way the drainer '
  'does, so a worker killed mid-fetch does not keep the cron quiet about its own backlog.';

REVOKE ALL ON FUNCTION public.fn_request_inbound_file_drain() FROM PUBLIC, anon, authenticated;

SELECT cron.schedule('inbound-file-drain', '*/5 * * * *',
                     'SELECT public.fn_request_inbound_file_drain()');

DO $verify$
DECLARE
  v_sched TEXT;
  v_active BOOLEAN;
BEGIN
  SELECT schedule, active INTO v_sched, v_active FROM cron.job WHERE jobname = 'inbound-file-drain';
  IF v_sched IS NULL THEN
    RAISE EXCEPTION 'the cron entry was not created';
  END IF;
  IF v_sched <> '*/5 * * * *' OR NOT v_active THEN
    RAISE EXCEPTION 'cron is % active=%, expected */5 and active', v_sched, v_active;
  END IF;

  IF has_function_privilege('authenticated','public.fn_request_inbound_file_drain()','EXECUTE')
     OR has_function_privilege('anon','public.fn_request_inbound_file_drain()','EXECUTE') THEN
    RAISE EXCEPTION 'an app role can trigger the drainer';
  END IF;

  -- EXERCISE the body on an empty queue: it must return without raising and without calling out.
  -- PL/pgSQL is not parsed at creation time, so this is the only proof the function runs at all.
  PERFORM public.fn_request_inbound_file_drain();

  RAISE NOTICE 'VERIFY passed: cron */5 active, app roles cannot execute, body runs on an empty queue';
END
$verify$;

COMMIT;
