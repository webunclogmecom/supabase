-- 2026-07-10_jobber_push_completion_group.sql
-- Two-way completion sync Calendar -> Jobber (Fred 2026-07-10: uncompleting a visit in the
-- Calendar changed only our DB, never Jobber). ROOT CAUSE: fn_push_visit_to_jobber built NO
-- `changed` group for a visit_status completed<->scheduled flip, so jobber-push-visit received
-- changed:[] and no-op'd. Completion was Jobber-INBOUND-authoritative only (via
-- cron_jobber_reconcile_completion), so office-side complete/uncomplete dead-ended.
--
-- THIS MIGRATION (DB half): add a 'completion' group to the trigger's on-purpose diff when
-- visit_status flips into 'completed' or 'scheduled'. cancelled/skipped are NOT completion —
-- they already set v_op='delete' above (Jobber visitDelete), unchanged.
-- The edge half (supabase/functions/jobber-push-visit): a wantsStrict('completion') block that
-- calls Jobber visitComplete({completedAt}) / visitUncomplete, idempotent (reads Jobber's current
-- completedAt, acts only on a diff) + verified from the returned payload (no false success).
--
-- ADDITIVE + SURGICAL: only a NEW field-group is added; schedule/title/notes/crew/lineitems and
-- the delete path are byte-for-byte unchanged (rest of the body copied verbatim from the live
-- def). No schema/column change. SECURITY DEFINER unchanged. Audit unaffected (ADR-010: this is
-- the push trigger fn, writes no business data). Re-runnable (CREATE OR REPLACE).
--
-- ECHO-SAFE: wantsStrict means the completion push fires ONLY on a deliberate office flip, never
-- on a reconciler HEAL / legacy null `changed`; and the inbound completion-reconcile keys on
-- visit_status='completed' + SET LOCAL app.suppress_jobber_push='on', so DB<->Jobber converge
-- without oscillation.

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

  v_op := CASE WHEN NEW.deleted_at IS NOT NULL OR NEW.visit_status IN ('cancelled','skipped')
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
    -- NEW 2026-07-10: completion is a two-way field-group. A deliberate complete/uncomplete
    -- (visit_status flips into 'completed' or 'scheduled') must reach Jobber via visitComplete/
    -- visitUncomplete. cancelled/skipped are NOT here (they set v_op='delete' above).
    IF NEW.visit_status IS DISTINCT FROM OLD.visit_status
       AND NEW.visit_status IN ('completed','scheduled') THEN
      v_changed := v_changed || to_jsonb('completion'::text);
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
