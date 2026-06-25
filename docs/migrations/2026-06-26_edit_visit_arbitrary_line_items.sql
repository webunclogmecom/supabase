-- 2026-06-26_edit_visit_arbitrary_line_items.sql
-- Extend edit_calendar_visit to accept a FULL arbitrary line-item list, for editing
-- Service-Agreement visits whose lines include non-catalog rows (ACH/credit-card fees,
-- one-off items) that have no service_line_items id. Coexists with the existing catalog
-- path (service_line_item_ids); the form sends one or the other.
--
-- p_patch->'line_items' = [{name, unit_price, quantity, taxable?}]
--   - DELETE+INSERT the visit's visit-scoped line_items directly from the array
--   - re-derive service_line_item_id/service_type from the first line whose code prefix
--     ("NN - ...") matches service_line_items.code; DERM via fn_line_item_requires_derm(name)
--   - bump line_items_rev so trg_push_visit_update fires (-> jobber-push-visit)
-- 3NF: line_items stores name/price/qty directly (no catalog FK col), so arbitrary lines
-- fit the existing table; price/qty are point-in-time instance facts (same as SC + invoices).

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

  -- Team: replace visit_team, set the derived primary, bump team_rev to fire the push.
  IF p_patch ? 'team_ids' THEN
    DELETE FROM visit_team WHERE visit_id = p_visit_id;
    INSERT INTO visit_team (visit_id, employee_id)
    SELECT p_visit_id, x::bigint FROM jsonb_array_elements_text(p_patch->'team_ids') AS x ON CONFLICT DO NOTHING;
    UPDATE visits SET
      assigned_driver_id = NULLIF(p_patch->'team_ids'->>0, '')::bigint,
      team_rev = team_rev + 1
    WHERE id = p_visit_id;
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
    -- derive primary + service_type from the first catalog-matching line (by code prefix), in array order
    SELECT s.id, s.service_type INTO v_primary, v_stype
    FROM jsonb_array_elements(p_patch->'line_items') WITH ORDINALITY AS t(li, ord)
    JOIN service_line_items s ON s.code = split_part(t.li->>'name', ' - ', 1)
    ORDER BY t.ord LIMIT 1;
    -- DERM from every line name (catalog + non-catalog), via the canonical name->DERM fn
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

NOTIFY pgrst, 'reload schema';
