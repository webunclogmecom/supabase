-- 2026-06-23_widen_jobber_push_all_clients.sql
-- GO-LIVE (Fred 2026-06-23): widen the Calendar→Jobber visit push from the 112-YA-only test gate
-- to ALL clients. The push now fires for any visit with source IN ('visit-calendar','supabase_cron');
-- the client_id=381 restriction is removed. Safe with Jobber inbound ON: webhook-jobber.handleVisit
-- has a loop-guard (skips clobbering a row whose source='visit-calendar'), so pushed visits stay
-- calendar-mastered (no source-flip, no loop). Mechanism (fn_push_visit_to_jobber → jobber-push-visit)
-- unchanged. Only NEW inserts/qualifying updates push — existing rows are not retro-pushed.
-- Audit (ADR 010): triggers on the already-audited public.visits; not audit triggers themselves.

DROP TRIGGER IF EXISTS trg_push_visit_insert ON public.visits;
CREATE TRIGGER trg_push_visit_insert
  AFTER INSERT ON public.visits
  FOR EACH ROW
  WHEN (NEW.source = ANY (ARRAY['visit-calendar'::text, 'supabase_cron'::text]))
  EXECUTE FUNCTION fn_push_visit_to_jobber();

DROP TRIGGER IF EXISTS trg_push_visit_update ON public.visits;
CREATE TRIGGER trg_push_visit_update
  AFTER UPDATE ON public.visits
  FOR EACH ROW
  WHEN (
    NEW.source = ANY (ARRAY['visit-calendar'::text, 'supabase_cron'::text])
    AND (
         OLD.visit_date           IS DISTINCT FROM NEW.visit_date
      OR OLD.start_at             IS DISTINCT FROM NEW.start_at
      OR OLD.end_at               IS DISTINCT FROM NEW.end_at
      OR OLD.title                IS DISTINCT FROM NEW.title
      OR OLD.job_id               IS DISTINCT FROM NEW.job_id
      OR OLD.service_line_item_id IS DISTINCT FROM NEW.service_line_item_id
      OR OLD.deleted_at           IS DISTINCT FROM NEW.deleted_at
      OR OLD.visit_status         IS DISTINCT FROM NEW.visit_status
    )
  )
  EXECUTE FUNCTION fn_push_visit_to_jobber();
