-- 2026-07-29e  Take the x-sync-key literal out of cron.job.command (part 1 of 2: the plumbing)
--
-- Fred, 2026-07-29: "You can go ahead with the x-sync-key rotation."
--
-- WHAT IS WRONG TODAY. Three pg_cron jobs carry a 48-char shared secret as a PLAINTEXT literal
-- inside cron.job.command:
--     jobid 5  jobber-poll-sync             */5   -> /functions/v1/sync-jobber-poll
--     jobid 4  jobber-upcoming-visits-sync  */15  -> /functions/v1/sync-jobber-upcoming-visits
--     jobid 8  jobber-visit-drift-reconcile */30  -> /functions/v1/sync-jobber-visit-drift
-- cron.job is postgres-only, so this is NOT an anon-reachable leak. The exposure is that the value
-- is UNMASKED in every query result, log line, screenshot and session transcript that touches the
-- table -- and both of this workspace's git repos are PUBLIC. It landed in a transcript on
-- 2026-07-29, which is how it surfaced.
--
-- ⚠ AND THERE IS A SECOND, WORSE PROBLEM THAT THE ROTATION MUST CLOSE. All three functions gate on:
--       const TRIGGER_KEY = Deno.env.get('SYNC_TRIGGER_KEY') ?? ''
--       if (TRIGGER_KEY && req.headers.get('x-sync-key') !== TRIGGER_KEY) return 403
-- That is FAIL-OPEN. If SYNC_TRIGGER_KEY is ever empty or unset, the check is skipped entirely, and
-- all three are verify_jwt=false, i.e. wide open to the internet. config.toml already calls this out
-- by name ("never the fail-OPEN idiom in sync-jobber-visit-drift"). So merely moving the value to
-- Vault would fix the lesser half of the problem and leave the greater half standing.
--
-- THE END STATE, which is the pattern this repo ALREADY uses correctly twice
-- (fn_request_jobber_push -> jobber-push-visit, fn_request_blackout_sweep -> redact-manifest-sheet):
--   * cron calls a SECURITY DEFINER function; the function reads the key from Vault
--   * the call carries Authorization: Bearer <service_role JWT>
--   * the target function is verify_jwt=true so the GATEWAY verifies the signature
--   * the handler ALSO decodes the JWT and requires role=service_role
-- The last point is not optional. verify_jwt=true alone is satisfied by the PUBLIC anon key, so
-- without the handler's own role check, flipping the gateway on would be close to no protection.
-- config.toml documents exactly this for jobber-push-visit.
--
-- Net effect when part 2 lands: there is no bespoke sync secret at all. The leaked value stops
-- working because nothing checks it any more. That is a retirement rather than a rotation, and it is
-- better: one less secret to hold, and the fail-open goes with it.
--
-- ⚠ WHY THIS FILE CHANGES NOTHING LIVE. It creates the Vault entry and the wrapper. It does NOT
-- touch cron. The wrapper is invoked and proven against a real HTTP response FIRST; the cron rewrite
-- is 2026-07-29f. Splitting them is deliberate: the next scheduled run is at most 5 minutes away, so
-- a broken wrapper wired straight into cron would take inbound Jobber sync down before anyone looked.
--
-- VERIFIED BEFORE WRITING (facts, not assumptions):
--   * cron is the ONLY caller of the three functions. Zero DB functions reference the URLs
--     (pg_get_functiondef ILIKE '%sync-jobber%' -> 0 rows, prokind='f'); the only repo hits outside
--     the function bodies are docs, config.toml, and two GitHub workflows whose references are
--     COMMENTS saying the work moved to pg_cron (both are workflow_dispatch-only and run node
--     scripts, not the edge functions). Nothing in Building Apps or Slack calls them.
--     This is what makes flipping verify_jwt in part 2 safe.
--   * edge_invoke_service_key and jobber_push_service_key are the SAME value (identical md5), a
--     service_role JWT: {"iss":"supabase","role":"service_role","exp":2090741091} -> expires 2036.
--   * all three cron jobs run as `postgres`, same as jobid 10 (redact-manifest-sweep), which is the
--     working precedent for postgres-owned cron calling a SECDEF fn that reads Vault.
--   * pg_cron is 1.6.4, where cron.schedule(jobname,...) UPSERTS by name -- no duplicate-job risk
--     in part 2.
--   * all three jobs were at full cadence and succeeding at the time of writing (3h window:
--     jobid 5 = 36 runs, jobid 4 = 12, jobid 8 = 6, all 'succeeded').
--
-- ⚠ NOTE ON HOW *NOT* TO VERIFY PART 2. cron.job_run_details.status = 'succeeded' only means the
-- net.http_post QUEUE INSERT succeeded. pg_net is fire-and-forget: the transaction commits before
-- Jobber (or the gateway) ever replies, so a 401/403 still records 'succeeded'. Verification MUST
-- read net._http_response for the request id returned by net.http_post. This is the single most
-- likely way this change ends with sync silently dead.
--
-- RULE 8 (ADR 010): no table or column change, no new business table. Nothing to opt in or out of.
-- RULE 1: no source-prefixed columns.

-- ---------------------------------------------------------------------------
-- 1. Copy the CURRENT key into Vault, derived in SQL so the literal never appears in this file,
--    in any tool output, or in the repo. Idempotent: re-running is a no-op.
--    Verified beforehand that the regex extracts a 48-char value from all three jobs and that all
--    three carry the SAME key (one md5 across jobids 4/5/8).
--    This entry is TEMPORARY. 2026-07-29f-cleanup drops it once the handlers stop checking it.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_key text;
BEGIN
  IF EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'sync_trigger_key') THEN
    RAISE NOTICE 'sync_trigger_key already present in vault; leaving as-is';
    RETURN;
  END IF;

  SELECT (regexp_match(command, '''x-sync-key''\s*,\s*''([^'']+)'''))[1]
    INTO v_key
    FROM cron.job
   WHERE jobid = 5;

  -- Fail LOUD rather than storing an empty/short secret, which would fail open at the far end.
  IF v_key IS NULL OR length(v_key) < 16 THEN
    RAISE EXCEPTION 'could not extract x-sync-key from cron job 5 (got %L chars); aborting',
      coalesce(length(v_key), 0);
  END IF;

  PERFORM vault.create_secret(
    v_key,
    'sync_trigger_key',
    'TEMPORARY (2026-07-29e). Legacy x-sync-key for the 3 jobber sync edge fns, moved here out of '
    || 'cron.job.command. Retired by 2026-07-29f-cleanup once the handlers require a service_role '
    || 'bearer instead. Do not add new consumers.'
  );
END
$do$;

-- ---------------------------------------------------------------------------
-- 2. The wrapper. One function, whitelisted target, so there is a single place to maintain.
--
--    ⚠ IT SENDS BOTH HEADERS ON PURPOSE. During the transition the handlers still check x-sync-key
--    (verify_jwt is still false), so the Bearer is ignored and the sync keeps working exactly as it
--    does today. After part 2 deploys, the Bearer is what authenticates and x-sync-key is ignored.
--    At no point is there a window where neither works. That is the whole reason for the ordering.
--
--    ⚠ jsonb_strip_nulls IS LOAD-BEARING. When sync_trigger_key is later dropped from Vault, v_sync
--    goes NULL and the x-sync-key header DISAPPEARS from the request with no code change. The
--    cleanup step is therefore a one-line vault delete, not another function rewrite.
--
--    ⚠ RAISE EXCEPTION, NOT THE PRECEDENT'S WARNING+RETURN. fn_request_jobber_push and
--    fn_request_blackout_sweep both `RAISE WARNING ... RETURN` on a missing Vault secret, which
--    SKIPS the work silently -- a warning goes to the Postgres log that nothing reads. A missing
--    bearer here means inbound Jobber sync is dead, and dead sync has to be visible. Raising makes
--    cron.job_run_details record status='failed', which is the only place anyone would notice.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_request_jobber_sync(p_target text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_url    text;
  v_bearer text;
  v_sync   text;
BEGIN
  -- Whitelist. p_target is never caller-supplied in practice (cron only), but the function is
  -- SECDEF, so it does not get to trust its input.
  v_url := CASE p_target
    WHEN 'poll'     THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-poll'
    WHEN 'upcoming' THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-upcoming-visits'
    WHEN 'drift'    THEN 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-visit-drift'
    ELSE NULL
  END;

  IF v_url IS NULL THEN
    RAISE EXCEPTION 'fn_request_jobber_sync: unknown target %', p_target;
  END IF;

  SELECT decrypted_secret INTO v_bearer
    FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';

  IF v_bearer IS NULL THEN
    RAISE EXCEPTION
      'fn_request_jobber_sync: edge_invoke_service_key missing from vault; % NOT sent', p_target;
  END IF;

  -- May be NULL after the cleanup step. stripped below when it is.
  SELECT decrypted_secret INTO v_sync
    FROM vault.decrypted_secrets WHERE name = 'sync_trigger_key';

  PERFORM net.http_post(
    url     := v_url,
    headers := jsonb_strip_nulls(jsonb_build_object(
                 'Content-Type',  'application/json',
                 'Authorization', 'Bearer ' || v_bearer,
                 'x-sync-key',    v_sync)),
    body    := '{}'::jsonb);
END;
$function$;

-- Supabase's ALTER DEFAULT PRIVILEGES hands new public functions to anon/authenticated/service_role
-- without anyone writing a grant (see CLAUDE.md "Grants, views and functions" + memory
-- reference_supabase_function_default_privileges). This one triggers Jobber syncs and holds the
-- service_role key internally, so nothing but the owner may call it. cron runs as `postgres`, the
-- owner, so no grant is needed at all.
REVOKE ALL ON FUNCTION public.fn_request_jobber_sync(text) FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Post-conditions to check after applying (part 1):
--   1. secret exists, value never printed:
--        SELECT count(*) FROM vault.secrets WHERE name='sync_trigger_key';                  -- 1
--   2. it matches what the cron jobs are still sending:
--        SELECT md5(decrypted_secret) FROM vault.decrypted_secrets WHERE name='sync_trigger_key';
--        -- must equal the md5 of the regexp_match against cron.job 4/5/8
--   3. nobody but the owner can execute it:
--        SELECT has_function_privilege('anon','public.fn_request_jobber_sync(text)','EXECUTE'),
--               has_function_privilege('authenticated','public.fn_request_jobber_sync(text)','EXECUTE'),
--               has_function_privilege('service_role','public.fn_request_jobber_sync(text)','EXECUTE');
--        -- all false
--   4. a real invocation returns HTTP 200 (NOT via cron.job_run_details -- see the note above):
--        SELECT public.fn_request_jobber_sync('poll');   -- capture the net request id, then
--        SELECT status_code FROM net._http_response WHERE id = <id>;
--      Do this for all three targets before applying 2026-07-29f.
-- ---------------------------------------------------------------------------
