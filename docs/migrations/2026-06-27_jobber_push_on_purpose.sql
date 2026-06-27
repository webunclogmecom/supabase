-- 2026-06-27_jobber_push_on_purpose.sql
-- ============================================================================
-- Calendar -> Jobber "on-purpose" push (Stage 1 of the driver-clobber fix).
-- ----------------------------------------------------------------------------
-- BUG (confirmed 2026-06-27): jobber-push-visit re-pushed assignedUsers (crew) on
-- EVERY linked-visit update. 695/697 scheduled linked visits have an empty visit_team
-- in our DB, so any qualifying edit pushed assignedUserIds:[] -> wiped Jobber's driver.
-- The Calendar drawer's full-form save re-sends the (empty) team_ids -> team_rev bumps
-- -> trigger fires -> crew clobbered. Diego saw drivers disappearing.
--
-- FIX (per Fred): the push mirrors to Jobber ONLY the field-group the office actually
-- edited in the Calendar; crew is sent ONLY when the team was edited on purpose.
-- This file = 2 of the 4 coordinated changes:
--   #1 edit_calendar_visit: bump team_rev ONLY when the team SET actually changes
--      (a full-form save that re-sends the unchanged team no longer looks like a team edit).
--   #2 fn_push_visit_to_jobber(): compute which field-groups changed (schedule/title/
--      crew/lineitems) from OLD vs NEW and pass them to the push as `changed`.
-- (#3 = jobber-push-visit honors `changed`; #4 = hour-sync suppression — both shipped
--  alongside this migration.)
-- Additive/idempotent: CREATE OR REPLACE of two existing functions. No data change.
-- ============================================================================

-- #1 ----------------------------------------------------------------------------
-- edit_calendar_visit: only touch visit_team + bump team_rev when the incoming
-- team_ids SET differs from the stored set. Everything else identical to the prior
-- definition (patch-based field updates, catalog + arbitrary line-item paths).
CREATE OR REPLACE FUNCTION public.edit_calendar_visit(p_visit_id bigint, p_patch jsonb)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_visit visits; v_ids bigint[]; v_primary bigint; v_stype text; v_derm boolean;
BEGIN
  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'edit_calendar_visit: visit % not found or deleted', p_visit_id; END IF;
  IF p_patch IS NULL OR p_patch = '{}'::jsonb THEN RETURN v_visit; END IF;

  UPDATE visits SET
    notes              = CASE WHEN p_patch ? 'notes'      THEN NULLIF(p_patch->>'notes','')        ELSE notes END,
    start_at           = CASE WHEN p_patch ? 'start_at'   THEN (p_patch->>'start_at')::timestamptz ELSE start_at END,
    end_at             = CASE WHEN p_patch ? 'end_at'     THEN (p_patch->>'end_at')::timestamptz   ELSE end_at END,
    visit_date         = CASE WHEN p_patch ? 'visit_date' THEN (p_patch->>'visit_date')::date      ELSE visit_date END,
    title              = CASE WHEN p_patch ? 'title'      THEN NULLIF(p_patch->>'title','')        ELSE title END,
    vehicle_id         = CASE WHEN p_patch ? 'vehicle_id' THEN (p_patch->>'vehicle_id')::bigint    ELSE vehicle_id END,
    assigned_driver_id = CASE WHEN p_patch ? 'driver_id'  THEN (p_patch->>'driver_id')::bigint     ELSE assigned_driver_id END
  WHERE id = p_visit_id;

  -- Team: replace visit_team + bump team_rev ONLY when the SET actually changes, so a
  -- full-form save that re-sends the unchanged (often empty) team is NOT seen as a team
  -- edit and never clobbers Jobber's crew. team_rev is the push's "on purpose" signal.
  IF p_patch ? 'team_ids' THEN
    DECLARE
      v_incoming bigint[];
      v_current  bigint[];
    BEGIN
      SELECT COALESCE(array_agg(DISTINCT x::bigint ORDER BY x::bigint), '{}')
        INTO v_incoming
        FROM jsonb_array_elements_text(p_patch->'team_ids') AS x
        WHERE NULLIF(x, '') IS NOT NULL;
      SELECT COALESCE(array_agg(DISTINCT employee_id ORDER BY employee_id), '{}')
        INTO v_current
        FROM visit_team WHERE visit_id = p_visit_id;
      IF v_incoming IS DISTINCT FROM v_current THEN
        DELETE FROM visit_team WHERE visit_id = p_visit_id;
        INSERT INTO visit_team (visit_id, employee_id)
        SELECT p_visit_id, unnest(v_incoming) ON CONFLICT DO NOTHING;
        UPDATE visits SET
          assigned_driver_id = NULLIF(p_patch->'team_ids'->>0, '')::bigint,
          team_rev = team_rev + 1
        WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  -- Catalog path: services chosen from the service_line_items catalog.
  IF p_patch ? 'service_line_item_ids' THEN
    SELECT array_agg(x::bigint) INTO v_ids FROM jsonb_array_elements_text(p_patch->'service_line_item_ids') AS x;
    IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
      RAISE EXCEPTION 'edit_calendar_visit: at least one service is required';
    END IF;
    DELETE FROM line_items WHERE visit_id = p_visit_id;
    INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
    SELECT p_visit_id, s.title, '',
      COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1),
      COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0),
      COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0)
        * COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1), false
    FROM service_line_items s WHERE s.id = ANY (v_ids);
    v_primary := v_ids[1];
    SELECT service_type INTO v_stype FROM service_line_items WHERE id = v_primary;
    SELECT bool_or(requires_derm) INTO v_derm FROM service_line_items WHERE id = ANY (v_ids);
    UPDATE visits SET service_line_item_id = v_primary, service_type = v_stype,
      derm_required = COALESCE(v_derm, false), line_items_rev = line_items_rev + 1
    WHERE id = p_visit_id;
  END IF;

  -- Arbitrary path: a full line list incl. non-catalog rows (SA agreement lines + fees).
  IF p_patch ? 'line_items' THEN
    IF jsonb_typeof(p_patch->'line_items') <> 'array' OR jsonb_array_length(p_patch->'line_items') = 0 THEN
      RAISE EXCEPTION 'edit_calendar_visit: line_items must be a non-empty array';
    END IF;
    DELETE FROM line_items WHERE visit_id = p_visit_id;
    INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
    SELECT p_visit_id, li->>'name', '',
      COALESCE((li->>'quantity')::numeric, 1),
      COALESCE((li->>'unit_price')::numeric, 0),
      COALESCE((li->>'unit_price')::numeric, 0) * COALESCE((li->>'quantity')::numeric, 1),
      COALESCE((li->>'taxable')::boolean, false)
    FROM jsonb_array_elements(p_patch->'line_items') AS li
    WHERE COALESCE(li->>'name','') <> '';
    SELECT s.id, s.service_type INTO v_primary, v_stype
    FROM jsonb_array_elements(p_patch->'line_items') WITH ORDINALITY AS t(li, ord)
    JOIN service_line_items s ON s.code = split_part(t.li->>'name', ' - ', 1)
    ORDER BY t.ord LIMIT 1;
    SELECT bool_or(public.fn_line_item_requires_derm(li->>'name')) INTO v_derm
    FROM jsonb_array_elements(p_patch->'line_items') AS li;
    UPDATE visits SET
      service_line_item_id = COALESCE(v_primary, service_line_item_id),
      service_type = COALESCE(v_stype, service_type),
      derm_required = COALESCE(v_derm, false),
      line_items_rev = line_items_rev + 1
    WHERE id = p_visit_id;
  END IF;

  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id;
  RETURN v_visit;
END;
$function$;

-- #2 ----------------------------------------------------------------------------
-- fn_push_visit_to_jobber(): include a `changed` array of field-groups so the push
-- edits ONLY what the office changed. INSERT = full initial push. Everything else
-- (suppress GUC, delete fail-safe, vault key) identical to the prior definition.
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
  -- gate #4 adopt + inbound sync writes set this transaction-local GUC so the DB write
  -- does NOT echo back to Jobber (would be a redundant/possibly-wrong push).
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

  -- "On-purpose" diff: which field-groups did the office actually change? The push
  -- edits ONLY these in Jobber and leaves everything else untouched (no crew clobber).
  IF TG_OP = 'UPDATE' THEN
    IF NEW.visit_date IS DISTINCT FROM OLD.visit_date
       OR NEW.start_at IS DISTINCT FROM OLD.start_at
       OR NEW.end_at   IS DISTINCT FROM OLD.end_at THEN
      v_changed := v_changed || to_jsonb('schedule'::text);
    END IF;
    IF NEW.title IS DISTINCT FROM OLD.title OR NEW.notes IS DISTINCT FROM OLD.notes THEN
      v_changed := v_changed || to_jsonb('title'::text);
    END IF;
    IF NEW.team_rev IS DISTINCT FROM OLD.team_rev THEN
      v_changed := v_changed || to_jsonb('crew'::text);
    END IF;
    IF NEW.line_items_rev IS DISTINCT FROM OLD.line_items_rev
       OR NEW.service_line_item_id IS DISTINCT FROM OLD.service_line_item_id THEN
      v_changed := v_changed || to_jsonb('lineitems'::text);
    END IF;
  ELSE
    v_changed := '["schedule","title","crew","lineitems"]'::jsonb;  -- INSERT: full initial push
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
