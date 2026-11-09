-- =============================================================================
-- 2026-11-09_1230_portal_waiting_site_files.sql
--
-- WHAT: ops.portal_waiting() gains one key, site_files: Site file versions waiting for approval, for the people who can
--       approve them. The Ops Portal's bell shows it ("Picture Planner").
--
-- WHY: Fred, 2026-11-09, on the Picture Planner move plan, question "Should the portal's bell count Site file versions
--      waiting for approval?": "Yes, for approvers only". Plan and his answers:
--      Building Apps/Ops Portal/docs/specs/2026-11-09-picture-planner-move-plan.md (decision 9).
--
-- HOW: copied from the LIVE body (md5 8f13dad101592beec9cf75d656d7c915, guarded below), one anchored edit before the last RETURN: a new
--   arm, nothing else moved. Who: Picture Planner open to the person (the function's own v_closed rule) AND auth.uid()
--   in public.fn_page_approver_ids(), the one approver rule (HR switch "Approve site files"). The v_closed rule alone
--   could not say it: pp_approve's level is yes/no, so it always lands in v_closed. What: the versions the
--   #apps-notifications post announces (fn_slack_event_claim, version_waiting), still decidable: neither approved nor
--   rejected, property not removed, above the property's live version, test clients left out by fn_is_non_customer.
--   Measured before: 2 (354-TBS v1 and v2, waiting since 2026-10-21).
--
-- ACCESS: unchanged. SECURITY DEFINER, EXECUTE authenticated + service_role (CREATE OR REPLACE keeps the grants; the
--   VERIFY reads them back). It still returns counts only.
-- RULE 8, AUDIT: no table written, so no audit trigger applies.
-- REHEARSED: rolled back first with the old body as the control (it has no site_files key, so the VERIFY fails on it).
-- ATOMIC: one transaction. The guard and the VERIFY raise on any failure and roll the whole thing back.
-- ROLLBACK: 2026-11-09_1230_portal_waiting_site_files_rollback.sql
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure)) <> '8f13dad101592beec9cf75d656d7c915' THEN
    RAISE EXCEPTION 'guard: ops.portal_waiting() is not the live 2026-11-05_0135 body (md5 %). Read it again before changing it.',
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

  -- 2026-11-09_1230: Site file versions waiting for approval, only for someone who can approve them (Picture Planner open,
  -- and "Approve site files" by the one approver rule, public.fn_page_approver_ids()). The same versions the
  -- #apps-notifications post announces (public.fn_slack_event_claim, version_waiting): neither approved nor rejected, on a
  -- real client (test clients left out the same way), on a property not removed, and above the property's live version,
  -- because a version below the live one can no longer be decided (Picture Planner rules 20 and 27).
  IF NOT 'picture_planner' = ANY (v_closed) AND auth.uid() = ANY (public.fn_page_approver_ids()) THEN
    v_out := v_out || jsonb_build_object('site_files', (
      SELECT count(*)
        FROM public.property_pages pg
        JOIN public.properties p ON p.id = pg.property_id
       WHERE pg.approved_at IS NULL AND pg.rejected_at IS NULL AND p.deleted_at IS NULL
         AND pg.version > coalesce((SELECT max(l.version) FROM public.property_pages l
                                     WHERE l.property_id = pg.property_id AND l.approved_at IS NOT NULL), 0)
         AND NOT coalesce(public.fn_is_non_customer(p.client_id, array['test', 'fixture']), false)));
  END IF;

  RETURN v_out;
END;
$function$;

NOTIFY pgrst, 'reload schema';

DO $verify$
DECLARE
  v_fred jsonb; v_diego jsonb; v_field jsonb; v_uid uuid; v_keys text[]; v_direct bigint;
BEGIN
  IF has_function_privilege('anon', 'ops.portal_waiting()', 'execute') THEN RAISE EXCEPTION 'verify_fail: anon can execute'; END IF;
  IF NOT has_function_privilege('authenticated', 'ops.portal_waiting()', 'execute') THEN RAISE EXCEPTION 'verify_fail: authenticated cannot execute'; END IF;

  -- The count, worked out a second way: versions above each property's live version, real clients, property not removed.
  SELECT count(*) INTO v_direct
    FROM public.property_pages pg
    JOIN public.properties p ON p.id = pg.property_id
    LEFT JOIN (SELECT property_id, max(version) AS live FROM public.property_pages WHERE approved_at IS NOT NULL GROUP BY 1) lv
      ON lv.property_id = pg.property_id
   WHERE pg.approved_at IS NULL AND pg.rejected_at IS NULL AND p.deleted_at IS NULL AND pg.version > coalesce(lv.live, 0)
     AND p.client_id NOT IN (SELECT c.id FROM public.clients c WHERE public.fn_is_non_customer(c.id, array['test', 'fixture']));

  -- An admin (an approver) sees every key, site_files included, and the number matches.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_fred := ops.portal_waiting();
  RESET ROLE;
  SELECT array_agg(k ORDER BY k) INTO v_keys FROM jsonb_object_keys(v_fred) k;
  IF v_keys IS DISTINCT FROM ARRAY['call_first','city_emails','photos_unsorted','site_files','stamp_sheets','time_on_site','unopened_emails'] THEN RAISE EXCEPTION 'verify_fail: admin keys %', v_keys; END IF;
  IF (v_fred->>'site_files')::bigint IS DISTINCT FROM v_direct THEN RAISE EXCEPTION 'verify_fail: site_files % vs %', v_fred->>'site_files', v_direct; END IF;

  -- Diego (office, approves by his own setting) sees it too.
  SELECT u.id INTO v_uid FROM public.employees e JOIN auth.users u ON lower(u.email) = lower(e.email) WHERE e.id = 28;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_diego := ops.portal_waiting();
  RESET ROLE;
  IF NOT v_diego ? 'site_files' THEN RAISE EXCEPTION 'verify_fail: an approver sees no site_files: %', v_diego; END IF;

  -- A Field person (Picture Planner closed, no approval) does not.
  SELECT u.id INTO v_uid FROM public.employees e JOIN auth.users u ON lower(u.email) = lower(e.email) WHERE e.id = 59;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_field := ops.portal_waiting();
  RESET ROLE;
  IF v_field ? 'site_files' THEN RAISE EXCEPTION 'verify_fail: a Field person sees site_files: %', v_field; END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'verify ok: admin %, direct %, field keys %', v_fred, v_direct, (SELECT count(*) FROM jsonb_object_keys(v_field));
END $verify$;

COMMIT;
