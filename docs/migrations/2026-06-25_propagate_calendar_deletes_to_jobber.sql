-- ============================================================================
-- 2026-06-25 — Propagate Calendar deletes to Jobber for ANY-source visit
-- ----------------------------------------------------------------------------
-- Problem: deleting a JOBBER-born visit (source='jobber') in the Calendar did
-- not remove it from Jobber. The push trigger trg_push_visit_update was gated
-- to source IN ('visit-calendar','supabase_cron'), so a soft-delete of a
-- Jobber-born visit never fired fn_push_visit_to_jobber. (Burned 2026-06-25:
-- visit 5828, the 099-PV "Service Call [OLD]" duplicate, had to be deleted by
-- hand.) Fred's requirement: a delete in the Calendar must delete in Jobber.
--
-- Fix has TWO parts:
--   (1) Widen trg_push_visit_update so a soft-delete OR cancel of ANY visit
--       fires the push (Jobber-born deletes now reach fn_push_visit_to_jobber).
--       Edits/reschedules of Jobber-born visits stay Jobber-mastered (NOT
--       pushed) — only DELETES cross the source gate, matching the ownership
--       model (jobs-visits-calendar-workflow): Jobber-born visits are
--       Jobber-mastered for schedule, but a Calendar delete is an explicit
--       human removal that must propagate.
--   (2) Add a FAIL-SAFE gate inside fn_push_visit_to_jobber: a Jobber-born
--       visit is only deleted in Jobber when a HUMAN deletes it in an app
--       (browser Origin header present, e.g. https://calendar.unclogme.app).
--       A service/sync soft-delete must NOT echo a visitDelete back to Jobber.
--
-- Why part (2) is required: cron_jobber_reconcile_anomalies.js soft-deletes
-- Jobber-sourced visits that are ORPHANED (already removed in Jobber) to keep
-- our DB in sync. Without the gate, the widened trigger would echo a
-- visitDelete back to Jobber for every orphan (failed "not found" calls =
-- error noise + wasted throttle), and would be a data-loss footgun for any
-- future reconcile that soft-deletes a still-live Jobber visit. The reconcile
-- (and all sync/cron) run as node/service calls with NO browser Origin, so the
-- Origin gate blocks them by default — verified against audit.logs:
-- visit-calendar writes carry origin https://calendar.unclogme.app (44/47);
-- app_source='jobber-reconcile' / 'sql' / 'service-agreement-cron' = 0 origin.
-- Calendar/cron-born visits are excluded from the gate and push as before.
-- ============================================================================

-- (2) Fail-safe gate added to the push function -----------------------------
CREATE OR REPLACE FUNCTION public.fn_push_visit_to_jobber()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op     text;
  v_key    text;
  v_origin text;
BEGIN
  v_op := CASE WHEN NEW.deleted_at IS NOT NULL OR NEW.visit_status = 'cancelled'
               THEN 'delete' ELSE 'upsert' END;

  -- Fail-safe: only propagate a DELETE of a Jobber-mastered visit (source not
  -- Calendar/cron) when a human did it in an app (browser Origin present). A
  -- service/sync soft-delete (e.g. the anomaly-reconcile cleaning up a visit
  -- already removed in Jobber) must NOT echo a visitDelete back to Jobber.
  -- Calendar/cron-born visits are Calendar-mastered and always push (unchanged).
  IF v_op = 'delete'
     AND NEW.source IS DISTINCT FROM 'visit-calendar'
     AND NEW.source IS DISTINCT FROM 'supabase_cron' THEN
    BEGIN
      v_origin := NULLIF(current_setting('request.headers', true), '')::jsonb ->> 'origin';
    EXCEPTION WHEN OTHERS THEN
      v_origin := NULL;
    END;
    IF v_origin IS NULL OR v_origin NOT LIKE 'http%' THEN
      RETURN NEW;  -- non-interactive (sync/cron/SQL) delete of a Jobber visit -> do not echo
    END IF;
  END IF;

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

-- (1) Widen the update-push trigger -----------------------------------------
DROP TRIGGER IF EXISTS trg_push_visit_update ON public.visits;

CREATE TRIGGER trg_push_visit_update
AFTER UPDATE ON public.visits
FOR EACH ROW
WHEN (
  -- (A) Calendar/cron-mastered visit: push schedule/title/job/line-item/status
  --     edits AND deletes (unchanged behavior).
  (
    (NEW.source = ANY (ARRAY['visit-calendar'::text, 'supabase_cron'::text]))
    AND (
         (OLD.visit_date            IS DISTINCT FROM NEW.visit_date)
      OR (OLD.start_at              IS DISTINCT FROM NEW.start_at)
      OR (OLD.end_at                IS DISTINCT FROM NEW.end_at)
      OR (OLD.title                 IS DISTINCT FROM NEW.title)
      OR (OLD.job_id                IS DISTINCT FROM NEW.job_id)
      OR (OLD.service_line_item_id  IS DISTINCT FROM NEW.service_line_item_id)
      OR (OLD.deleted_at            IS DISTINCT FROM NEW.deleted_at)
      OR (OLD.visit_status          IS DISTINCT FROM NEW.visit_status)
    )
  )
  -- (B) A soft-delete or cancel of ANY visit (incl. Jobber-born) fires the
  --     push; fn_push_visit_to_jobber then applies the Origin fail-safe gate
  --     so only human/app deletes actually reach Jobber.
  OR (
    (OLD.deleted_at IS DISTINCT FROM NEW.deleted_at) AND (NEW.deleted_at IS NOT NULL)
  )
  OR (
    (OLD.visit_status IS DISTINCT FROM NEW.visit_status) AND (NEW.visit_status = 'cancelled')
  )
)
EXECUTE FUNCTION fn_push_visit_to_jobber();
