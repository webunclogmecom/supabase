-- ============================================================================
-- 2026-06-11 — push Calendar-cancelled visits to Jobber as deletes
-- ============================================================================
-- Gap found while smoke-testing the visit→Jobber push: the Calendar app's
-- "Delete visit" sets visit_status='cancelled' (soft-cancel, reversible per its
-- own UI copy) — it does NOT set deleted_at. The push trigger only watched
-- deleted_at, so a cancelled visit stayed on Jobber's schedule (orphan).
-- Fix: fn_push_visit_to_jobber maps visit_status='cancelled' → op 'delete',
-- and trg_push_visit_update also fires on visit_status transitions.
-- Un-cancel (cancelled → scheduled) pushes an upsert, which re-creates the
-- Jobber visit (jobber-push-visit now unlinks ESL after a successful delete,
-- so the re-create path is clean).
-- Still gated to client_id = 381 (112-YA) until go-live.
-- Audit: trigger-def change only; visits auditing unchanged (opt-in stays).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_push_visit_to_jobber()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_op  text;
  v_key text;
BEGIN
  v_op := CASE WHEN NEW.deleted_at IS NOT NULL OR NEW.visit_status = 'cancelled'
               THEN 'delete' ELSE 'upsert' END;
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'jobber_push_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'jobber_push_service_key vault secret missing; skipping push for visit %', NEW.id;
    RETURN NEW;
  END IF;
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/jobber-push-visit',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := jsonb_build_object('op', v_op, 'visit_id', NEW.id)
  );
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_push_visit_update ON public.visits;
CREATE TRIGGER trg_push_visit_update
  AFTER UPDATE ON public.visits
  FOR EACH ROW
  WHEN (
    new.source = ANY (ARRAY['visit-calendar'::text, 'supabase_cron'::text])
    AND new.client_id = 381
    AND (
      old.visit_date           IS DISTINCT FROM new.visit_date OR
      old.start_at             IS DISTINCT FROM new.start_at OR
      old.end_at               IS DISTINCT FROM new.end_at OR
      old.title                IS DISTINCT FROM new.title OR
      old.job_id               IS DISTINCT FROM new.job_id OR
      old.service_line_item_id IS DISTINCT FROM new.service_line_item_id OR
      old.deleted_at           IS DISTINCT FROM new.deleted_at OR
      old.visit_status         IS DISTINCT FROM new.visit_status
    )
  )
  EXECUTE FUNCTION public.fn_push_visit_to_jobber();
