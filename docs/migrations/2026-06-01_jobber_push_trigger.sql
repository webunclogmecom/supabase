-- ============================================================================
-- 2026-06-01_jobber_push_trigger.sql
-- Realtime Calendar -> Jobber push. On INSERT/UPDATE of a source='visit-calendar'
-- visit, asynchronously call the jobber-push-visit Edge Function via pg_net.
--
-- Auth: the service-role key is read from Vault (secret 'jobber_push_service_key',
--   stored separately by the deploy script) — never hardcoded. The trigger fn is
--   SECURITY DEFINER (only it can read the vault secret; anon/app cannot).
-- Loop-safety: the UPDATE trigger only fires when a Jobber-relevant field actually
--   changed; combined with the webhook-jobber guard (won't clobber visit-calendar
--   visits) the read-sync echo can't bounce back. net.http_post is async (fire-and-
--   forget) so the Calendar app's insert never blocks on Jobber.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_push_visit_to_jobber()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op  text;
  v_key text;
BEGIN
  v_op := CASE WHEN NEW.deleted_at IS NOT NULL THEN 'delete' ELSE 'upsert' END;
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
$$;

DROP TRIGGER IF EXISTS trg_push_visit_insert ON public.visits;
CREATE TRIGGER trg_push_visit_insert AFTER INSERT ON public.visits
  FOR EACH ROW WHEN (NEW.source = 'visit-calendar')
  EXECUTE FUNCTION public.fn_push_visit_to_jobber();

DROP TRIGGER IF EXISTS trg_push_visit_update ON public.visits;
CREATE TRIGGER trg_push_visit_update AFTER UPDATE ON public.visits
  FOR EACH ROW WHEN (
    NEW.source = 'visit-calendar' AND (
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
