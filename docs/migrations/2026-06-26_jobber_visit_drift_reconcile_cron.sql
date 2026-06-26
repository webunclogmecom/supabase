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
-- TWO-WAY + ON BY DEFAULT (heal-direction policy set 2026-06-26). Reconciles by
-- direction, classified from audit.logs: HEAL (DB->Jobber via fn_request_jobber_push)
-- only when audit proves OUR push failed (we set the current DB date AND Jobber holds
-- the exact pre-edit value); ADOPT (Jobber->DB via adopt_visit_schedule_from_jobber,
-- push-suppressed + AUDITED app_source='jobber') when we never edited it (a driver/
-- Diego scheduled it in Jobber); SURFACE (log only) when ambiguous. Reconcile writes
-- are ON by default; kill-switch env DRIFT_HEAL_DISABLED=1 (or header x-no-heal:1) ->
-- detect-only. Full spec: docs/jobber-calendar-job-migration/2026-06-26_gate4-drift-watchdog.md
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
