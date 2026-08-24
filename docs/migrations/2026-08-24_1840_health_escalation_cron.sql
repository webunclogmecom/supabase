-- 2026-08-24_1840_health_escalation_cron.sql
-- ---------------------------------------------------------------------------
-- Run the health escalation once a day. Completes 2026-08-24_1820.
--
-- Fred: "3 days, email only." The Slack digest shipped this morning is retired in
-- the same cycle (.github/workflows/health-digest.yml and scripts/alerts/health_digest.js
-- are deleted) so there is exactly ONE watchdog channel and no dead schedule left
-- running. Bringing Slack back is `git revert` on that commit, not a rewrite.
--
-- ⚠ TIMING IS LOAD-BEARING. The four checks write at these ET times:
--     calendar-push-health  03:30    rpa-derm-health   05:00
--     sa-schedule-gap-check 06:15    blackout-health   08:00
--   ops.v_health_items reads the LATEST run of each, so escalating before 08:00 ET
--   reports a blackout verdict that is a day stale. 13:30 UTC = 09:30 ET (summer) /
--   08:30 ET (winter) clears all four, and sits 30 min after daily-no-photo-alert so
--   the two do not contend.
--   ⚠ In WINTER this lands 08:30 ET, only 30 minutes after blackout-health. If that
--     cron ever slips or slows, the escalation reads yesterday's blackout row and
--     says nothing changed. If blackout-health moves, move this too.
--
-- The database cannot email: RESEND_API_KEY is an EDGE secret and is not in vault.
-- So this posts to the edge function with edge_invoke_service_key, exactly like the
-- four existing fn_request_* helpers.
--
-- Audit (Rule 8): one function + one cron entry. No table, column, or grant on any
-- audited table changes.
--
-- @Building Apps. Claimed in WORKING-NOW.md.

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_request_health_escalation()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE v_key text;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'edge_invoke_service_key vault secret missing; skipping health escalation';
    RETURN;
  END IF;
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/health-escalate',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body    := '{}'::jsonb,
    timeout_milliseconds := 30000);
END $fn$;

COMMENT ON FUNCTION public.fn_request_health_escalation() IS
  'Daily trigger for the health escalation email. Posts to the health-escalate edge function with edge_invoke_service_key, because RESEND_API_KEY is an edge secret and Postgres cannot reach Resend itself. The edge function emails ONLY when something is new or has been open 3+ days unacknowledged; silence is the normal outcome.';

REVOKE ALL ON FUNCTION public.fn_request_health_escalation() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_request_health_escalation() TO service_role;

COMMIT;

-- cron.schedule is not transactional; run it after the COMMIT.
-- ⚠ Plain single-quoted command, NOT dollar-quoting. Applying this through a shell
--   or a JS template mangles $$ and you get "syntax error at or near $". Cost one
--   failed apply on 2026-08-24.
SELECT cron.schedule('health-escalation', '30 13 * * *', 'select public.fn_request_health_escalation();');
-- Applied 2026-08-24: jobid 30, active.

-- VERIFY (run after applying)
--
-- 1. the job exists, is active, and runs AFTER all four checks
--    select jobname, schedule, active from cron.job where jobname='health-escalation';
--    -- expect '30 13 * * *', active=true
--
-- 2. it is the ONLY watchdog schedule (the Slack digest must be gone)
--    -- there is no DB-side Slack job; confirm in the repo that
--    -- .github/workflows/health-digest.yml no longer exists.
--
-- 3. POSITIVE CONTROL that the wiring works end to end. This SENDS a real email if
--    anything is new or stale, so expect either a mail or a documented silence:
--    select public.fn_request_health_escalation();
--    -- then, a few seconds later:
--    select status_code, left(content,200) from net._http_response order by id desc limit 1;
--    -- expect 200 and either {"sent":true,...} or {"sent":false,"reason":"nothing new or stale"}
--    ⚠ A 401 here means the vault key is wrong; a 403 means the handler's role gate
--      rejected it. Both are silent from the caller's side, which is why this control
--      reads the RESPONSE and not just the absence of an error.
