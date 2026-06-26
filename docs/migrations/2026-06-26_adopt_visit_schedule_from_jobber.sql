-- ============================================================================
-- 2026-06-26_adopt_visit_schedule_from_jobber.sql
-- ADR 010: writes to already-audited public.visits (audit trigger fires) — the
--          adopt is INTENTIONALLY audited; ADR 016: attributed app_source='jobber'
--          via the caller's X-App-Source header. No new table.
-- ----------------------------------------------------------------------------
-- Gate #4 "adopt" — the Jobber->DB half of the drift reconciler.
--
-- "Calendar is master, but drivers/Diego use Jobber" (Fred). When the drift
-- watchdog finds a calendar/cron visit whose Jobber schedule diverges from our DB
-- AND the audit shows WE never edited it (reason 'no_our_edit'), Jobber is the
-- authoritative source (a driver/Diego scheduled it there). This RPC pulls Jobber's
-- schedule INTO our DB so the DB reflects reality and the drift self-resolves.
--
-- TWO safety properties:
--   (1) It must NOT echo back to Jobber. A normal UPDATE of visit_date/start_at on
--       a calendar/cron visit fires trg_push_visit_update -> fn_push_visit_to_jobber.
--       So this RPC sets a transaction-local GUC app.suppress_jobber_push='on' and
--       fn_push_visit_to_jobber (re-created below) RETURNs early when it sees it.
--       => adopt is DB-only; Jobber is never written, even if the target is wrong.
--   (2) It is AUDITED as coming from Jobber. The audit trigger on visits captures
--       the UPDATE; the Edge Function calls this RPC with header X-App-Source: jobber
--       so audit.logs.app_source='jobber' (the visit's Activity history shows
--       "updated from Jobber"), per Fred's request.
--
-- The caller (sync-jobber-visit-drift) computes the operating visit_date (overnight
-- aware) + start_at/end_at from Jobber's startAt/endAt and passes them in.
-- ============================================================================

-- (1) Adopt RPC -------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.adopt_visit_schedule_from_jobber(
  p_visit_id  bigint,
  p_visit_date date,
  p_start_at  timestamptz DEFAULT NULL,
  p_end_at    timestamptz DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_hit int;
BEGIN
  -- suppress the echo push for THIS transaction only
  PERFORM set_config('app.suppress_jobber_push', 'on', true);
  UPDATE public.visits
     SET visit_date = p_visit_date,
         start_at   = p_start_at,
         end_at     = p_end_at
   WHERE id = p_visit_id
     AND source IN ('visit-calendar', 'supabase_cron')   -- only DB-mastered visits
     AND visit_status = 'scheduled'
     AND deleted_at IS NULL
     AND (visit_date IS DISTINCT FROM p_visit_date
          OR start_at IS DISTINCT FROM p_start_at
          OR end_at   IS DISTINCT FROM p_end_at);
  GET DIAGNOSTICS v_hit = ROW_COUNT;
  RETURN v_hit > 0;
END;
$function$;

REVOKE ALL  ON FUNCTION public.adopt_visit_schedule_from_jobber(bigint, date, timestamptz, timestamptz) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.adopt_visit_schedule_from_jobber(bigint, date, timestamptz, timestamptz) TO service_role;

-- (2) Re-create fn_push_visit_to_jobber WITH the suppress guard --------------
-- Body is IDENTICAL to 2026-06-25_propagate_calendar_deletes_to_jobber.sql:38-82
-- (Origin fail-safe + cancel/delete op PRESERVED), plus the guard at the top.
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
  -- gate #4 adopt: a Jobber->DB adopt write sets this transaction-local GUC so the
  -- DB write does NOT echo back to Jobber (would be a redundant/possibly-wrong push).
  IF current_setting('app.suppress_jobber_push', true) = 'on' THEN
    RETURN NEW;
  END IF;

  v_op := CASE WHEN NEW.deleted_at IS NOT NULL OR NEW.visit_status = 'cancelled'
               THEN 'delete' ELSE 'upsert' END;

  -- Fail-safe: only propagate a DELETE of a Jobber-mastered visit (source not
  -- Calendar/cron) when a human did it in an app (browser Origin present).
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

NOTIFY pgrst, 'reload schema';
