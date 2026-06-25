-- ============================================================================
-- 2026-06-25 — edit_calendar_visit RPC (editable visit drawer)
-- ----------------------------------------------------------------------------
-- The visit-detail drawer could only edit date/truck/driver. Instructions, time
-- and line items were not editable: `line_items` has no anon/authenticated write
-- grant (SELECT only), so editing services/prices needs a SECURITY DEFINER RPC.
--
-- edit_calendar_visit(p_visit_id, p_patch jsonb) applies a PATCH — only the keys
-- present in p_patch are changed:
--   notes, start_at, end_at, visit_date, title, vehicle_id, driver_id,
--   service_line_item_ids (array) [+ line_item_prices {id:{unit_price,quantity}}].
-- When service_line_item_ids is present it REPLACES the visit's line items
-- (price = COALESCE(form, catalog default, 0)), re-derives service_type /
-- primary service_line_item_id / derm_required, and bumps visits.line_items_rev.
--
-- Jobber sync: line_items is a separate table the visits push trigger can't see,
-- so line_items_rev gives the trigger something to fire on. We also add `notes`
-- to the trigger WHEN so instruction edits push. The edit then flows through the
-- existing fn_push_visit_to_jobber -> jobber-push-visit (which on update
-- re-syncs schedule + driver + line items). Only Calendar/cron-mastered visits
-- push (jobber-born visits stay Jobber-mastered) — same source gate as before.
-- ============================================================================

ALTER TABLE public.visits ADD COLUMN IF NOT EXISTS line_items_rev integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.visits.line_items_rev IS
  'Bumped by edit_calendar_visit whenever the visit''s line items change, so trg_push_visit_update fires (line_items is a separate table the visits trigger cannot observe).';

CREATE OR REPLACE FUNCTION public.edit_calendar_visit(p_visit_id bigint, p_patch jsonb)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_visit   visits;
  v_ids     bigint[];
  v_primary bigint;
  v_stype   text;
  v_derm    boolean;
BEGIN
  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'edit_calendar_visit: visit % not found or deleted', p_visit_id;
  END IF;
  IF p_patch IS NULL OR p_patch = '{}'::jsonb THEN
    RETURN v_visit;
  END IF;

  -- Scalar fields: only keys present in the patch are changed.
  UPDATE visits SET
    notes              = CASE WHEN p_patch ? 'notes'      THEN NULLIF(p_patch->>'notes','')        ELSE notes END,
    start_at           = CASE WHEN p_patch ? 'start_at'   THEN (p_patch->>'start_at')::timestamptz ELSE start_at END,
    end_at             = CASE WHEN p_patch ? 'end_at'     THEN (p_patch->>'end_at')::timestamptz   ELSE end_at END,
    visit_date         = CASE WHEN p_patch ? 'visit_date' THEN (p_patch->>'visit_date')::date      ELSE visit_date END,
    title              = CASE WHEN p_patch ? 'title'      THEN NULLIF(p_patch->>'title','')        ELSE title END,
    vehicle_id         = CASE WHEN p_patch ? 'vehicle_id' THEN (p_patch->>'vehicle_id')::bigint    ELSE vehicle_id END,
    assigned_driver_id = CASE WHEN p_patch ? 'driver_id'  THEN (p_patch->>'driver_id')::bigint     ELSE assigned_driver_id END
  WHERE id = p_visit_id;

  -- Line items: replace when service_line_item_ids provided.
  IF p_patch ? 'service_line_item_ids' THEN
    SELECT array_agg(x::bigint) INTO v_ids
    FROM jsonb_array_elements_text(p_patch->'service_line_item_ids') AS x;
    IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
      RAISE EXCEPTION 'edit_calendar_visit: at least one service is required';
    END IF;

    DELETE FROM line_items WHERE visit_id = p_visit_id;
    INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
    SELECT
      p_visit_id, s.title, '',
      COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1),
      COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0),
      COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0)
        * COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1),
      false
    FROM service_line_items s WHERE s.id = ANY (v_ids);

    v_primary := v_ids[1];
    SELECT service_type INTO v_stype FROM service_line_items WHERE id = v_primary;
    SELECT bool_or(requires_derm) INTO v_derm FROM service_line_items WHERE id = ANY (v_ids);
    UPDATE visits SET
      service_line_item_id = v_primary,
      service_type         = v_stype,
      derm_required        = COALESCE(v_derm, false),
      line_items_rev       = line_items_rev + 1
    WHERE id = p_visit_id;
  END IF;

  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id;
  RETURN v_visit;
END;
$function$;

CREATE OR REPLACE FUNCTION ops.edit_calendar_visit(p_visit_id bigint, p_patch jsonb)
 RETURNS visits
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT public.edit_calendar_visit(p_visit_id, p_patch);
$function$;

GRANT EXECUTE ON FUNCTION public.edit_calendar_visit(bigint, jsonb) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION ops.edit_calendar_visit(bigint, jsonb)    TO anon, authenticated, service_role;

-- Push trigger: also fire on `notes` and `line_items_rev` changes so instruction
-- and line-item edits propagate to Jobber (Calendar/cron-mastered visits only).
DROP TRIGGER IF EXISTS trg_push_visit_update ON public.visits;
CREATE TRIGGER trg_push_visit_update
AFTER UPDATE ON public.visits
FOR EACH ROW
WHEN (
  (
    (NEW.source = ANY (ARRAY['visit-calendar'::text, 'supabase_cron'::text]))
    AND (
         (OLD.visit_date            IS DISTINCT FROM NEW.visit_date)
      OR (OLD.start_at              IS DISTINCT FROM NEW.start_at)
      OR (OLD.end_at                IS DISTINCT FROM NEW.end_at)
      OR (OLD.title                 IS DISTINCT FROM NEW.title)
      OR (OLD.notes                 IS DISTINCT FROM NEW.notes)
      OR (OLD.job_id                IS DISTINCT FROM NEW.job_id)
      OR (OLD.service_line_item_id  IS DISTINCT FROM NEW.service_line_item_id)
      OR (OLD.line_items_rev        IS DISTINCT FROM NEW.line_items_rev)
      OR (OLD.deleted_at            IS DISTINCT FROM NEW.deleted_at)
      OR (OLD.visit_status          IS DISTINCT FROM NEW.visit_status)
    )
  )
  OR ((OLD.deleted_at   IS DISTINCT FROM NEW.deleted_at)   AND (NEW.deleted_at IS NOT NULL))
  OR ((OLD.visit_status IS DISTINCT FROM NEW.visit_status) AND (NEW.visit_status = 'cancelled'))
)
EXECUTE FUNCTION fn_push_visit_to_jobber();
