-- 2026-06-27_clobber_class_hardening.sql
-- ============================================================================
-- Close the remaining "overwrite-with-empty/stale" clobber paths found by the 2026-06-27
-- clobber-class sweep (same class as the driver-crew + title/instructions bugs).
--   #1 fn_request_jobber_push: the drift-reconciler HEAL helper omitted `changed`, so the push
--      fell into legacy FULL-push and re-fired visitEditAssignedUsers([]) -> re-clobbered the
--      Jobber driver (228/230 DB-mastered visits have empty visit_team). Default to scheduling-only.
--   #2 visit_last_schedule_edit: only detected visit_date edits, so an hour-only (start_at) office
--      edit whose push failed was misclassified ADOPTABLE -> overwrote the deliberately-set hour with
--      Jobber's stale one. Now detects visit_date OR start_at OR end_at edits.
--   #3 edit_calendar_visit: line_items_rev was bumped on EVERY save carrying line items (no change
--      detection), so a no-op re-save re-fired the 'lineitems' push (delete+recreate on Jobber).
--      Now mirrors the team_rev guard: bump/replace ONLY when the line-item set actually changes.
-- ============================================================================

-- #1 -----------------------------------------------------------------------------------------------
-- Keep the SAME 2-arg signature the drift reconciler calls (rpc('fn_request_jobber_push',{p_visit_id,p_op}))
-- and just send a scoped changed=['schedule'] in the body. (Do NOT add a 3rd param — that creates an
-- overload and the 2-arg call still resolves to the old buggy one.)
DROP FUNCTION IF EXISTS public.fn_request_jobber_push(bigint, text, jsonb);
CREATE OR REPLACE FUNCTION public.fn_request_jobber_push(p_visit_id bigint, p_op text DEFAULT 'upsert'::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_key text;
BEGIN
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'jobber_push_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'jobber_push_service_key vault secret missing; skipping push for visit %', p_visit_id;
    RETURN;
  END IF;
  -- HEAL re-assert is SCHEDULE-ONLY: sending changed=['schedule'] means the push never falls into the
  -- legacy full-push that would re-push (and clobber) crew/instructions with our empty/stale values.
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/jobber-push-visit',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := jsonb_build_object('op', p_op, 'visit_id', p_visit_id, 'changed', '["schedule"]'::jsonb)
  );
END;
$function$;

-- #2 -----------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.visit_last_schedule_edit(p_visit_id bigint)
 RETURNS TABLE(old_date text, new_date text, changed_at timestamp with time zone, app_source text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'audit'
AS $function$
  SELECT l.old_row->>'visit_date', l.new_row->>'visit_date', l.changed_at, l.app_source
  FROM audit.logs l
  WHERE l.table_name = 'visits'
    AND (l.record_pk->>'id') = p_visit_id::text
    AND l.operation = 'UPDATE'
    AND ( (l.new_row->>'visit_date') IS DISTINCT FROM (l.old_row->>'visit_date')
       OR (l.new_row->>'start_at')   IS DISTINCT FROM (l.old_row->>'start_at')
       OR (l.new_row->>'end_at')     IS DISTINCT FROM (l.old_row->>'end_at') )
  ORDER BY l.changed_at DESC
  LIMIT 1;
$function$;

-- #3 -----------------------------------------------------------------------------------------------
-- edit_calendar_visit: line_items_rev bump + line_items replace ONLY when the set actually changes
-- (normalized name|qty|price signature, order-independent). Identical otherwise to the team-guarded
-- 2026-06-27_jobber_push_on_purpose.sql version.
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

  -- Team: replace + bump team_rev ONLY when the set actually changes (on-purpose signal).
  IF p_patch ? 'team_ids' THEN
    DECLARE v_incoming bigint[]; v_current bigint[];
    BEGIN
      SELECT COALESCE(array_agg(DISTINCT x::bigint ORDER BY x::bigint), '{}')
        INTO v_incoming FROM jsonb_array_elements_text(p_patch->'team_ids') AS x WHERE NULLIF(x,'') IS NOT NULL;
      SELECT COALESCE(array_agg(DISTINCT employee_id ORDER BY employee_id), '{}')
        INTO v_current FROM visit_team WHERE visit_id = p_visit_id;
      IF v_incoming IS DISTINCT FROM v_current THEN
        DELETE FROM visit_team WHERE visit_id = p_visit_id;
        INSERT INTO visit_team (visit_id, employee_id) SELECT p_visit_id, unnest(v_incoming) ON CONFLICT DO NOTHING;
        UPDATE visits SET assigned_driver_id = NULLIF(p_patch->'team_ids'->>0, '')::bigint, team_rev = team_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  -- Catalog path: services chosen from the catalog. Replace + bump ONLY on a real change.
  IF p_patch ? 'service_line_item_ids' THEN
    SELECT array_agg(x::bigint) INTO v_ids FROM jsonb_array_elements_text(p_patch->'service_line_item_ids') AS x;
    IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
      RAISE EXCEPTION 'edit_calendar_visit: at least one service is required';
    END IF;
    DECLARE v_inc text[]; v_cur text[];
    BEGIN
      SELECT array_agg(sig ORDER BY sig) INTO v_inc FROM (
        SELECT s.title || '|' || round(COALESCE((p_patch->'line_item_prices'->s.id::text->>'quantity')::numeric, 1), 3)::text
               || '|' || round(COALESCE((p_patch->'line_item_prices'->s.id::text->>'unit_price')::numeric, s.unit_price, 0), 2)::text AS sig
        FROM service_line_items s WHERE s.id = ANY (v_ids)) z;
      SELECT array_agg(sig ORDER BY sig) INTO v_cur FROM (
        SELECT name || '|' || round(quantity,3)::text || '|' || round(unit_price,2)::text AS sig
        FROM line_items WHERE visit_id = p_visit_id) z;
      IF v_inc IS DISTINCT FROM v_cur THEN
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
          derm_required = COALESCE(v_derm, false), line_items_rev = line_items_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  -- Arbitrary path: full line list. Replace + bump ONLY on a real change.
  IF p_patch ? 'line_items' THEN
    IF jsonb_typeof(p_patch->'line_items') <> 'array' OR jsonb_array_length(p_patch->'line_items') = 0 THEN
      RAISE EXCEPTION 'edit_calendar_visit: line_items must be a non-empty array';
    END IF;
    DECLARE v_inc text[]; v_cur text[];
    BEGIN
      SELECT array_agg(sig ORDER BY sig) INTO v_inc FROM (
        SELECT (li->>'name') || '|' || round(COALESCE((li->>'quantity')::numeric,1),3)::text
               || '|' || round(COALESCE((li->>'unit_price')::numeric,0),2)::text AS sig
        FROM jsonb_array_elements(p_patch->'line_items') AS li WHERE COALESCE(li->>'name','') <> '') z;
      SELECT array_agg(sig ORDER BY sig) INTO v_cur FROM (
        SELECT name || '|' || round(quantity,3)::text || '|' || round(unit_price,2)::text AS sig
        FROM line_items WHERE visit_id = p_visit_id) z;
      IF v_inc IS DISTINCT FROM v_cur THEN
        DELETE FROM line_items WHERE visit_id = p_visit_id;
        INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
        SELECT p_visit_id, li->>'name', '',
          COALESCE((li->>'quantity')::numeric, 1),
          COALESCE((li->>'unit_price')::numeric, 0),
          COALESCE((li->>'unit_price')::numeric, 0) * COALESCE((li->>'quantity')::numeric, 1),
          COALESCE((li->>'taxable')::boolean, false)
        FROM jsonb_array_elements(p_patch->'line_items') AS li WHERE COALESCE(li->>'name','') <> '';
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
          line_items_rev = line_items_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id;
  RETURN v_visit;
END;
$function$;
