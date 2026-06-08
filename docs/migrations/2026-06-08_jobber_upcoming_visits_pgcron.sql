-- ============================================================================
-- 2026-06-08 — Reliable upcoming-visit poll via pg_cron
-- ============================================================================
-- Replaces the GitHub Actions */15 cron for Jobber upcoming-visit ingestion, which
-- GitHub throttled/skipped unreliably. Our Jobber integration is POLL-BASED (no
-- real-time webhooks — the dev app has no webhook subscriptions; the crons pull from
-- Jobber and replay through webhook-jobber), so this poll cadence is what determines
-- how fast a newly-added Jobber visit reaches our DB.
--
-- This pg_cron job runs INSIDE the database (immune to GitHub's scheduler) every 15 min
-- and calls the sync-jobber-upcoming-visits Edge Function via pg_net. The function pulls
-- Jobber's materialized upcoming visits, replays each through webhook-jobber (handleVisit
-- upsert/promote/dedup), then VERIFIES every eligible visit is in our DB and records the
-- residual gap to public.sync_log (sync_source='jobber_upcoming_visits_pgcron').
--
-- Audit (ADR 010): infra job, no business table -> not applicable.
--
-- NOTE: applied via the Management API (cron.* requires elevated perms that the migration
-- role lacks). This file is the canonical RECORD of the job. The x-sync-key secret value
-- lives in Supabase Functions secrets (SYNC_TRIGGER_KEY) + the cron.job command, NOT here.
--
-- Reproduce (replace <SYNC_TRIGGER_KEY> with the value in Functions secrets):
-- ============================================================================

SELECT cron.schedule(
  'jobber-upcoming-visits-sync',
  '*/15 * * * *',
  $cmd$
    SELECT net.http_post(
      url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/sync-jobber-upcoming-visits',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-key', '<SYNC_TRIGGER_KEY>'),
      body    := '{}'::jsonb
    )
  $cmd$
);

-- Inspect:    SELECT jobid, jobname, schedule, active FROM cron.job WHERE jobname = 'jobber-upcoming-visits-sync';
-- Health:     SELECT finished_at, status, details FROM public.sync_log WHERE sync_source = 'jobber_upcoming_visits_pgcron' ORDER BY finished_at DESC LIMIT 10;
-- Watchdog:   node scripts/probes/audit_jobber_upcoming_vs_db.js   (independent Jobber-vs-DB gap check)
-- Unschedule: SELECT cron.unschedule('jobber-upcoming-visits-sync');
