-- =============================================================================
-- 2026-11-09_1230_portal_waiting_site_files_rollback.sql
--
-- WHAT: puts ops.portal_waiting() back to its body before 2026-11-09_1230 (md5 8f13dad101592beec9cf75d656d7c915): no site_files key.
-- The Ops Portal's bell then simply shows no Picture Planner row. Guarded on the 2026-11-09_1230 body's md5.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure)) <> '658ee63214dbbf326a1874122d750a99' THEN
    RAISE EXCEPTION 'guard: ops.portal_waiting() is not the 2026-11-09_1230 body (md5 %). Read it again before changing it.',
      md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure));
  END IF;
END $guard$;

CREATE OR REPLACE FUNCTION ops.portal_waiting()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_access jsonb := hr.get_my_access();
  v_closed text[];
  v_out jsonb := '{}'::jsonb;
  v_admin jsonb;
BEGIN
  IF v_access IS NULL OR v_access->>'employee_id' IS NULL THEN
    RETURN v_out;
  END IF;

  SELECT coalesce(array_agg(a->>'app'), '{}'::text[]) INTO v_closed
    FROM jsonb_array_elements(coalesce(v_access->'apps', '[]'::jsonb)) a
   WHERE a->>'mode' = 'on' AND coalesce(a->>'level', 'none') NOT IN ('view', 'edit');

  IF NOT 'visit_calendar' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object(
      'call_first', (SELECT count(*) FROM ops.visit_requests r
                      WHERE r.deleted_at IS NULL AND r.status = 'open' AND r.call_required),
      'time_on_site', jsonb_array_length(coalesce(
        public.fn_time_on_site_gaps(((now() AT TIME ZONE 'America/New_York')::date - 1))->'visits', '[]'::jsonb)));
  END IF;

  IF NOT 'admin_review' = ANY (v_closed) THEN
    v_admin := public.fn_admin_review_pending();
    v_out := v_out || jsonb_build_object(
      'photos_unsorted', coalesce((v_admin->'photos'->>'count')::int, 0),
      'city_emails', jsonb_array_length(coalesce(v_admin->'city', '[]'::jsonb)));
  END IF;

  IF NOT 'stamp_studio' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('stamp_sheets', jsonb_array_length(coalesce(derm.fn_stamp_open_sheets(), '[]'::jsonb)));
  END IF;

  IF NOT 'derm_tracker' = ANY (v_closed) THEN
    v_out := v_out || jsonb_build_object('unopened_emails', jsonb_array_length(coalesce(public.fn_unopened_emails(now())->'emails', '[]'::jsonb)));
  END IF;

  RETURN v_out;
END;
$function$;

NOTIFY pgrst, 'reload schema';

DO $verify$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure)) <> '8f13dad101592beec9cf75d656d7c915' THEN RAISE EXCEPTION 'verify_fail: not the old body'; END IF;
END $verify$;
COMMIT;
