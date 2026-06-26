-- ============================================================================
-- 2026-06-26_jobber_visit_drift_reconcile_cron.sql
-- ADR 010: cron registration only; no table/data change -> audit OPT-OUT.
-- ----------------------------------------------------------------------------
-- Gate #4 — Calendar->Jobber schedule-drift watchdog schedule.
--
-- Every 30 min, pg_cron net.http_post's the sync-jobber-visit-drift Edge Function,
-- which reconciles each calendar/cron-mastered, scheduled, Jobber-linked visit's
-- DB date against Jobber's actual startAt (the silent-cascade-push-failure blind
-- spot that ops.v_calendar_push_health cannot see). It writes ONE public.sync_log
-- row per run (sync_source='jobber_visit_drift'); status='attention' when drift is
-- detected.
--
-- SAFE-BY-DEFAULT: DETECT + LOG only. It HEALS (re-pushes DB->Jobber via
-- public.fn_request_jobber_push) ONLY when env DRIFT_HEAL_ENABLED=1 or a per-call
-- `x-heal: 1` header is set. Auto-heal is OFF because a state reconcile cannot
-- distinguish a failed OUR-push (DB right) from a deliberate JOBBER-side edit
-- (Jobber right); the first scan (2026-06-26) surfaced 3 ambiguous divergences
-- (cron visits DB=06/25 vs Jobber=06/26). Flip DRIFT_HEAL_ENABLED on only after a
-- heal-direction policy is set (or push-intent is tracked).
--
-- NOTE: applied via the Management API (cron.* requires elevated perms the
-- migration role lacks). This file is the canonical RECORD of the job. The
-- x-sync-key secret value lives in Supabase Functions secrets (SYNC_TRIGGER_KEY)
-- + the cron.job command, NOT here.
-- ============================================================================
SELECT cron.schedule('jobber-visit-drift-reconcile', '*/30 * * * *', $cmd$
  SELECT net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-visit-drift',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-key', '<SYNC_TRIGGER_KEY>'),
    body    := '{}'::jsonb
  );
$cmd$);
