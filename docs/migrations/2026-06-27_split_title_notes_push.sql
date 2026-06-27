-- 2026-06-27_split_title_notes_push.sql
-- ============================================================================
-- Close the VISIT-INSTRUCTIONS clobber (found by the 2026-06-27 audit) — same class as the
-- driver/crew clobber. The push 'title' group bundled title + instructions: a title-only Calendar
-- edit pushed instructions=null and would WIPE a Jobber visit instruction (all cron visits have
-- notes=NULL). Fix: the trigger now emits 'title' and 'notes' as SEPARATE groups; the push edits
-- title ONLY when title changed and instructions ONLY when notes changed (see jobber-push-visit).
-- Only the v_changed computation differs from 2026-06-27_jobber_push_on_purpose.sql.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_push_visit_to_jobber()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op      text;
  v_key     text;
  v_origin  text;
  v_changed jsonb := '[]'::jsonb;
BEGIN
  IF current_setting('app.suppress_jobber_push', true) = 'on' THEN
    RETURN NEW;
  END IF;

  v_op := CASE WHEN NEW.deleted_at IS NOT NULL OR NEW.visit_status = 'cancelled'
               THEN 'delete' ELSE 'upsert' END;

  IF v_op = 'delete'
     AND NEW.source IS DISTINCT FROM 'visit-calendar'
     AND NEW.source IS DISTINCT FROM 'supabase_cron' THEN
    BEGIN
      v_origin := NULLIF(current_setting('request.headers', true), '')::jsonb ->> 'origin';
    EXCEPTION WHEN OTHERS THEN
      v_origin := NULL;
    END;
    IF v_origin IS NULL OR v_origin NOT LIKE 'http%' THEN
      RETURN NEW;
    END IF;
  END IF;

  -- "On-purpose" diff. title and notes are now SEPARATE groups so a title-only edit never
  -- touches the Jobber instruction (and vice-versa).
  IF TG_OP = 'UPDATE' THEN
    IF NEW.visit_date IS DISTINCT FROM OLD.visit_date
       OR NEW.start_at IS DISTINCT FROM OLD.start_at
       OR NEW.end_at   IS DISTINCT FROM OLD.end_at THEN
      v_changed := v_changed || to_jsonb('schedule'::text);
    END IF;
    IF NEW.title IS DISTINCT FROM OLD.title THEN
      v_changed := v_changed || to_jsonb('title'::text);
    END IF;
    IF NEW.notes IS DISTINCT FROM OLD.notes THEN
      v_changed := v_changed || to_jsonb('notes'::text);
    END IF;
    IF NEW.team_rev IS DISTINCT FROM OLD.team_rev THEN
      v_changed := v_changed || to_jsonb('crew'::text);
    END IF;
    IF NEW.line_items_rev IS DISTINCT FROM OLD.line_items_rev
       OR NEW.service_line_item_id IS DISTINCT FROM OLD.service_line_item_id THEN
      v_changed := v_changed || to_jsonb('lineitems'::text);
    END IF;
  ELSE
    v_changed := '["schedule","title","notes","crew","lineitems"]'::jsonb;  -- INSERT: full initial push
  END IF;

  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'jobber_push_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'jobber_push_service_key vault secret missing; skipping push for visit %', NEW.id;
    RETURN NEW;
  END IF;
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/jobber-push-visit',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := jsonb_build_object('op', v_op, 'visit_id', NEW.id, 'changed', v_changed)
  );
  RETURN NEW;
END;
$function$;
