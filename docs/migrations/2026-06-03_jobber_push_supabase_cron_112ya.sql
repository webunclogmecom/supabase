-- Migration: extend Calendar->Jobber auto-push to cron-generated visits (112-YA test scope)
-- Date:   2026-06-03
-- Author: Claude, directed by Fred
--
-- Per Fred: mirror BOTH manual ('visit-calendar') AND cron-generated ('supabase_cron')
-- visits into Jobber, so generated Service Agreement visits show up in Jobber.
--
-- ** TEST SCOPE: limited to client_id = 381 (112-YA) while Fred sets up the other
--    clients' Jobber Jobs + Line Items. To enable for ALL clients, drop the
--    `AND NEW.client_id = 381` guard from BOTH triggers below. **
--
-- The jobber-push-visit Edge Function's own source guard (index.ts line ~147) is
-- updated in the same change to accept 'supabase_cron' and redeployed -- both the
-- trigger AND the function gate on source, so both must change.

DROP TRIGGER IF EXISTS trg_push_visit_insert ON public.visits;
CREATE TRIGGER trg_push_visit_insert AFTER INSERT ON public.visits
  FOR EACH ROW WHEN (NEW.source IN ('visit-calendar', 'supabase_cron') AND NEW.client_id = 381)
  EXECUTE FUNCTION public.fn_push_visit_to_jobber();

DROP TRIGGER IF EXISTS trg_push_visit_update ON public.visits;
CREATE TRIGGER trg_push_visit_update AFTER UPDATE ON public.visits
  FOR EACH ROW WHEN (
    NEW.source IN ('visit-calendar', 'supabase_cron') AND NEW.client_id = 381 AND (
      OLD.visit_date           IS DISTINCT FROM NEW.visit_date OR
      OLD.start_at             IS DISTINCT FROM NEW.start_at OR
      OLD.end_at               IS DISTINCT FROM NEW.end_at OR
      OLD.title                IS DISTINCT FROM NEW.title OR
      OLD.job_id               IS DISTINCT FROM NEW.job_id OR
      OLD.service_line_item_id IS DISTINCT FROM NEW.service_line_item_id OR
      OLD.deleted_at           IS DISTINCT FROM NEW.deleted_at
    )
  )
  EXECUTE FUNCTION public.fn_push_visit_to_jobber();
