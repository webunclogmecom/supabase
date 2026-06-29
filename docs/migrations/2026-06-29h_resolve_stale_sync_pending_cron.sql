-- Migration: 2026-06-29h_resolve_stale_sync_pending_cron
-- Author: Claude (Opus 4.8) for Fred
-- Audit: pg_cron job; no table writes of its own (it re-invokes fn_request_jobber_push).
--
-- WHY: backstop for visits.sync_state (2026-06-29g). A visit gets stuck 'pending' only if the
-- jobber-push-visit edge fn dies AFTER pushing but BEFORE flipping sync_state -> then DB==Jobber
-- (no drift) so the */30 drift watchdog won't touch it, and it stays 'pending' forever. This cron
-- re-pushes any visit pending > 3 min; the re-push is idempotent (re-asserts schedule/title/lineitems;
-- crew/notes are NOT pushed on a null `changed` per the on-purpose guard, so no driver clobber) and
-- the edge fn then sets confirmed/failed. Bounded to 50/run.
--
-- Idempotent: unschedule-if-exists then schedule.
SELECT cron.unschedule('resolve-stale-visit-sync-pending')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname='resolve-stale-visit-sync-pending');
SELECT cron.schedule('resolve-stale-visit-sync-pending', '*/3 * * * *', $job$
  SELECT public.fn_request_jobber_push(id, 'upsert') FROM public.visits
   WHERE sync_state='pending' AND source IN ('visit-calendar','supabase_cron')
     AND deleted_at IS NULL AND visit_status='scheduled' AND updated_at < now() - interval '3 minutes'
   ORDER BY updated_at LIMIT 50
$job$);
