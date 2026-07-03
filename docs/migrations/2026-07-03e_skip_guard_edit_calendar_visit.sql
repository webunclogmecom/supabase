-- Migration: 2026-07-03e_skip_guard_edit_calendar_visit.sql
-- Author: Claude (Supabase session)
-- Follow-up to 2026-07-03d after the adversarial RE-VERIFY (PASS_WITH_NOTES, 0 must-fix).
-- Closes the two low-severity residual notes:
--   1. (this file) edit_calendar_visit had no skip guard — a skipped visit's schedule/services could
--      be silently edited via the Calendar edit RPC, moving the cadence slot the skip holds. Now
--      RAISEs 'un-skip it first' (parity with ripple_reschedule_visit). Body is the LIVE definition
--      (preserving the 2026-07-03 line_item_descriptions work, commit 941aa30) + the guard only.
--   2. (edge fn, deployed same cycle) webhook-jobber softStatusFlip: an inbound VISIT_DESTROY for a
--      skipped+still-linked visit no longer flips it to 'cancelled' (which lost the skip status/reason
--      and dropped it from both skip watchdogs — usually our own skip-removal echoing back through the
--      poll). It now UNLINKS the entity_source_link and keeps 'skipped' (the skip's intended end-state).
-- Rollback: restore edit_calendar_visit from commit 941aa30 (drop the guard block).
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
  -- A skipped visit is removed from Jobber and holds its cadence slot — editing it would silently move
  -- that slot. Un-skip first (parity with ripple_reschedule_visit's guard). Added 2026-07-03.
  IF v_visit.visit_status = 'skipped' THEN
    RAISE EXCEPTION 'edit_calendar_visit: visit % is skipped — un-skip it first (unskip_visit)', p_visit_id;
  END IF;
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
    DECLARE v_inc text[]; v_cur text[]; v_prev_desc jsonb;
    BEGIN
      -- snapshot existing descriptions (name -> note) BEFORE any delete, to carry forward notes the
      -- patch does not explicitly provide (preserves descriptions on a qty/price-only edit).
      SELECT COALESCE(jsonb_object_agg(name, description), '{}'::jsonb) INTO v_prev_desc
        FROM (SELECT DISTINCT ON (name) name, description FROM line_items
              WHERE visit_id = p_visit_id AND NULLIF(btrim(description),'') IS NOT NULL
              ORDER BY name, id) d;
      SELECT array_agg(sig ORDER BY sig) INTO v_inc FROM (
        SELECT s.title || '|' || round(COALESCE((p_patch->'line_item_prices'->s.id::text->>'quantity')::numeric, 1), 3)::text
               || '|' || round(COALESCE((p_patch->'line_item_prices'->s.id::text->>'unit_price')::numeric, s.unit_price, 0), 2)::text
               || '|' || COALESCE(CASE WHEN (p_patch->'line_item_descriptions') ? s.id::text
                                       THEN NULLIF(btrim(p_patch->'line_item_descriptions'->>s.id::text), '')
                                       ELSE NULLIF(btrim(v_prev_desc->>s.title), '') END, '') AS sig
        FROM service_line_items s WHERE s.id = ANY (v_ids)) z;
      SELECT array_agg(sig ORDER BY sig) INTO v_cur FROM (
        SELECT name || '|' || round(quantity,3)::text || '|' || round(unit_price,2)::text
               || '|' || COALESCE(NULLIF(btrim(description),''),'') AS sig
        FROM line_items WHERE visit_id = p_visit_id) z;
      IF v_inc IS DISTINCT FROM v_cur THEN
        DELETE FROM line_items WHERE visit_id = p_visit_id;
        INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
        SELECT p_visit_id, s.title,
          COALESCE(CASE WHEN (p_patch->'line_item_descriptions') ? s.id::text
                        THEN NULLIF(btrim(p_patch->'line_item_descriptions'->>s.id::text), '')
                        ELSE NULLIF(btrim(v_prev_desc->>s.title), '') END, ''),
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
    DECLARE v_inc text[]; v_cur text[]; v_prev_desc jsonb;
    BEGIN
      SELECT COALESCE(jsonb_object_agg(name, description), '{}'::jsonb) INTO v_prev_desc
        FROM (SELECT DISTINCT ON (name) name, description FROM line_items
              WHERE visit_id = p_visit_id AND NULLIF(btrim(description),'') IS NOT NULL
              ORDER BY name, id) d;
      SELECT array_agg(sig ORDER BY sig) INTO v_inc FROM (
        SELECT (li->>'name') || '|' || round(COALESCE((li->>'quantity')::numeric,1),3)::text
               || '|' || round(COALESCE((li->>'unit_price')::numeric,0),2)::text
               || '|' || COALESCE(CASE WHEN li ? 'description'
                                       THEN NULLIF(btrim(li->>'description'), '')
                                       ELSE NULLIF(btrim(v_prev_desc->>(li->>'name')), '') END, '') AS sig
        FROM jsonb_array_elements(p_patch->'line_items') AS li WHERE COALESCE(li->>'name','') <> '') z;
      SELECT array_agg(sig ORDER BY sig) INTO v_cur FROM (
        SELECT name || '|' || round(quantity,3)::text || '|' || round(unit_price,2)::text
               || '|' || COALESCE(NULLIF(btrim(description),''),'') AS sig
        FROM line_items WHERE visit_id = p_visit_id) z;
      IF v_inc IS DISTINCT FROM v_cur THEN
        DELETE FROM line_items WHERE visit_id = p_visit_id;
        INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
        SELECT p_visit_id, li->>'name',
          COALESCE(CASE WHEN li ? 'description'
                        THEN NULLIF(btrim(li->>'description'), '')
                        ELSE NULLIF(btrim(v_prev_desc->>(li->>'name')), '') END, ''),
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
$function$
;
