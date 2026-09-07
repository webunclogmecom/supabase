-- ============================================================================================
-- 2026-09-07_1420_billing_observe_schedule.sql
--
-- Make billing observation STANDING: a request wrapper and a daily cron.
-- The COUNT-ONLY health numbers are the companion migration 2026-09-07_1440; this one only
-- schedules the observer. The reasoning below about count-only applies to that companion and is
-- kept here because it is the reason this migration adds no alerting of its own.
--
-- 🛑 COUNT-ONLY, AND NO ALERT ITEM. DELIBERATE.
-- This adds numbers to log_jobber_sync_health()'s `details` and appends NOTHING to `items`, so it
-- cannot raise an alert, cannot change the check's status, and cannot mail anyone. Three reasons:
--   1. Fred set this precedent for the 15 drift counters on 2026-09-03: a week of numbers before
--      any threshold. Thresholds picked before there is data are guesses.
--   2. Measured drift is ZERO across 483 observed jobs, so a per-job alert stream would today be a
--      stream of nothing, and the first thing it reported would set the calibration.
--   3. 🛑 EVERY PHASE-A FINDING IS UNRESOLVABLE BY CONSTRUCTION. The only writer of these columns
--      is fn_record_client_job, and the operator's obvious move (re-save in the Client App) derives
--      billing from the job TITLE and pushes OUR value over Jobber's. An alert with no safe button
--      is how calendar-task-poll re-reported one item 3,008 times in 11 days. Phase B has to answer
--      "who is authoritative" before a finding has anywhere to go.
--
-- ⚠ WHEN AN ALERT ITEM IS EVENTUALLY ADDED, it must be keyed `billing_drift:<job_id>:<field>`, not
--   a flat kind. ops.v_health_items derives item_key from
--   COALESCE(visit_id, dump_folder, kind, client_code, value::text), so a flat kind collapses every
--   drifted job into ONE item and fixing one job would read as resolving all of them. And a
--   DUPLICATE item_key raises 21000 inside the view, which would silently kill the daily email for
--   ALL FIVE health checks, not just this one.
--
-- ⚠ THE STALENESS WATCH IS NOT ADDED HERE, ON PURPOSE. Adding
--   ('jobber_billing_observe', interval '26 hours') to the watched() list in the same migration
--   would fire immediately, because the sync_stalled arm fires on `last_run is null` and the cron
--   has not run yet. It goes in a follow-up after the first green scheduled run.
--
-- SCHEDULE: 0 6 * * * UTC = 02:00 EDT / 01:00 EST. Measured near-dead for app writes (01:00-05:00
-- ET runs 0-13 writes/hour against peaks of 1,136 and 1,291). It is 7 hours before jobber-sync-health
-- at 13:13 UTC, so the daily verdict always reads a fresh observation.
-- ⚠ DST: pinned in UTC, so the ET hour shifts by one in November. That is a documentation matter
--   here, not a correctness one: nothing about this depends on the local hour beyond being quiet.
--
-- COST: ~2,900 points of a 10,000 bucket, 5 requests, measured 4-5 seconds end to end.
--
-- RULE 8: no schema change. One SECDEF request wrapper, one cron entry, and a body replacement of
-- log_jobber_sync_health (already SECDEF, already audited-table-free).
-- ============================================================================================

BEGIN;

-- ── 1. The vault-bearer request wrapper, same shape as fn_request_health_escalation ─────────
CREATE OR REPLACE FUNCTION public.fn_request_billing_observe()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE v_key text;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'edge_invoke_service_key vault secret missing; skipping billing observation';
    RETURN;
  END IF;
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-billing-observe',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body    := '{}'::jsonb,
    timeout_milliseconds := 120000);
END $fn$;

REVOKE ALL ON FUNCTION public.fn_request_billing_observe() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_request_billing_observe() TO service_role;

-- ── 2. Daily cron ───────────────────────────────────────────────────────────────────────────
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'jobber-billing-observe';
SELECT cron.schedule('jobber-billing-observe', '0 6 * * *',
                     $c$SELECT public.fn_request_billing_observe()$c$);

COMMIT;

-- ============================================================================================
-- VERIFY (outside the transaction: cron.schedule is visible either way, and this asserts the
-- committed state rather than the in-flight one)
-- ============================================================================================
DO $verify$
DECLARE
  v_sched text;
  v_fresh record;
BEGIN
  SELECT schedule INTO v_sched FROM cron.job WHERE jobname = 'jobber-billing-observe';
  IF v_sched IS DISTINCT FROM '0 6 * * *' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: cron schedule is "%", expected "0 6 * * *"', coalesce(v_sched,'(absent)');
  END IF;

  -- CONTROL: the function the cron calls must exist and be service_role-only, or the schedule is
  -- a no-op that reports success forever.
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname='public' AND p.proname='fn_request_billing_observe') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the cron calls a function that does not exist.';
  END IF;
  IF has_function_privilege('anon', 'public.fn_request_billing_observe()', 'EXECUTE')
  OR has_function_privilege('authenticated', 'public.fn_request_billing_observe()', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: anon or authenticated can trigger the observer.';
  END IF;

  -- 3. The observation lane is already producing evidence, so the cron has something to keep
  --    fresh rather than something to start. If this is NO_EVIDENCE the manual runs did not land.
  SELECT * INTO v_fresh FROM sync.v_billing_observation_freshness;
  IF v_fresh.verdict = 'NO_EVIDENCE' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: no successful observation run on record, so scheduling one '
                    'is premature. Invoke the function by hand first.';
  END IF;
  RAISE NOTICE 'ALL VERIFY PASSED (freshness %, % of % observed)',
    v_fresh.verdict, v_fresh.jobs_returned, v_fresh.jobs_requested;
END
$verify$;
