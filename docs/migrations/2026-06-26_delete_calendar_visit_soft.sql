-- ============================================================================
-- 2026-06-26_delete_calendar_visit_soft.sql
-- ADR 010: writes to already-audited public.visits via existing trigger; no new table.
-- ----------------------------------------------------------------------------
-- Calendar "Delete visit" = a proper SOFT delete + attributed to the deleter.
--
-- The Lovable "Delete visit" button currently does `update({visit_status:'cancelled'})`
-- — the visit lingers (cancelled, not removed) and the Activity tab reads
-- "Status: scheduled -> cancelled", not "deleted by <person>". Fred wants a SOFT
-- delete (recoverable) that shows WHO deleted it.
--
-- This RPC sets `deleted_at = now()` (the canonical soft-delete — every app view
-- reads v_visits_live which filters deleted_at IS NULL, so the visit disappears
-- from the Calendar but the row + its full audit trail persist). Effects:
--   * audit.log_change records the caller — app_source='visit-calendar' + the
--     login email from the JWT -> get_record_history renders "deleted by <person>"
--     (the deleted_at null->set transition makes operation='deleted'). SECURITY
--     DEFINER does NOT change this: the audit reads the REQUEST's jwt/headers.
--   * the deleted_at transition fires trg_push_visit_update -> fn_push_visit_to_jobber:
--     a calendar/cron visit is deleted in Jobber too; a Jobber-born visit is deleted
--     in Jobber only when a human did it in an app (the Origin fail-safe in the push
--     fn) — both handled by the EXISTING trigger, unchanged here.
-- Idempotent: re-deleting an already-deleted visit RAISEs (no double-fire).
-- Never hard-deletes (Rule 6). Apps call ops.delete_calendar_visit.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.delete_calendar_visit(p_visit_id bigint)
RETURNS public.visits
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v public.visits;
BEGIN
  UPDATE public.visits SET deleted_at = now()
   WHERE id = p_visit_id AND deleted_at IS NULL
  RETURNING * INTO v;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delete_calendar_visit: visit % not found or already deleted', p_visit_id;
  END IF;
  RETURN v;
END;
$function$;

REVOKE ALL ON FUNCTION public.delete_calendar_visit(bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.delete_calendar_visit(bigint) TO anon, authenticated, service_role;

-- ops wrapper (apps call via the ops schema, like create/edit_calendar_visit)
CREATE OR REPLACE FUNCTION ops.delete_calendar_visit(p_visit_id bigint)
RETURNS public.visits
LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$ SELECT * FROM public.delete_calendar_visit(p_visit_id) $function$;
REVOKE ALL ON FUNCTION ops.delete_calendar_visit(bigint) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION ops.delete_calendar_visit(bigint) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
