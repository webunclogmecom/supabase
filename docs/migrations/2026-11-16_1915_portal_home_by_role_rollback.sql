-- =============================================================================
-- 2026-11-16_1915_portal_home_by_role_rollback.sql
--
-- Undoes 2026-11-16_1915_portal_home_by_role.sql: puts back the previous bodies of ops.portal_waiting() and
-- public.fn_request_gate() (verbatim, md5 below) and drops ops.portal_home() and ops.portal_my_work().
-- Guarded: it refuses unless both live bodies are exactly the ones that migration wrote.
-- After it, the portal's Home shows a read error until the portal goes back to its previous build.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure)) <> '14253eb27f0899428a86e4f72b8d6d02' THEN RAISE EXCEPTION 'guard: ops.portal_waiting() is not the 2026-11-16 body'; END IF;
  IF md5(pg_get_functiondef('public.fn_request_gate()'::regprocedure)) <> '579b255909b5a6c323bd424e0f377861' THEN RAISE EXCEPTION 'guard: public.fn_request_gate() is not the 2026-11-16 body'; END IF;
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
$function$
;

CREATE OR REPLACE FUNCTION public.fn_request_gate()
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
-- 2026-10-21_0145: PostgREST pre-request gate (pgrst.db_pre_request). Access phase 6.
-- SECURITY INVOKER on purpose: current_user must be the request role (anon / authenticated / service_role);
-- inside a SECURITY DEFINER body current_user is the owner and the gate would pass everyone (caught by VERIFY).
declare v_path text; v_all_on boolean;
begin
  perform set_config('response.headers', '[{"x-access-gate": "pass"}]', true);
  if current_user is distinct from 'authenticated' then return; end if;
  v_path := coalesce(current_setting('request.path', true), '');
  if v_path in ('/rpc/get_my_access') then return; end if;
  v_all_on := coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>'x-access-rehearsal', '') in ('all-on', 'refuse-me');
  if (nullif(current_setting('request.headers', true), '')::jsonb)->>'x-access-rehearsal' = 'refuse-me' then v_all_on := null; end if;  -- 2026-10-21_0215 live negative probe
  if v_all_on is not null and hr.fn_any_app_open(v_all_on) then return; end if;
  -- 2026-10-27_2130 (Trello AIwCYcmn): the Forms door. A "See submitted forms" person with no top-level View reaches
  -- exactly two client functions that return jsonb, never a view path (embedding would bring properties rows).
  -- The schema header is the one PostgREST uses for the method (GET/HEAD Accept-Profile, else Content-Profile), with no
  -- fallback, so a same-named function in another exposed schema can never be reached through this door.
  -- 2026-11-04_1930: and get_intake_link, which itself refuses any form not assigned to the caller.
  if v_all_on is not null and v_path in ('/rpc/get_intake', '/rpc/list_intake_forms', '/rpc/get_intake_link')
     and coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>
           case when coalesce(current_setting('request.method', true), '') in ('GET', 'HEAD') then 'accept-profile' else 'content-profile' end, '') = 'client'
     and hr.fn_pp_forms_open() then
    return;
  end if;
  -- 2026-11-05_0310: the Photo door. A person with no app open may set their own photo from the Ops Portal's Profile page.
  -- This one function, in schema hr, by POST only, and hr.set_employee_photo itself refuses anyone else's photo.
  if v_all_on is not null and v_path = '/rpc/set_employee_photo'
     and coalesce(current_setting('request.method', true), '') = 'POST'
     and coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>'content-profile', '') = 'hr' then
    return;
  end if;
  raise exception 'You do not have access to any UnclogMe app. Ask Fred or Yannick to change it.'
    using errcode = '42501', detail = 'blocker=no_access app=any in public.fn_request_gate';
end $function$
;

DROP FUNCTION ops.portal_home();
DROP FUNCTION ops.portal_my_work();

NOTIFY pgrst, 'reload schema';

DO $verify$
BEGIN
  IF md5(pg_get_functiondef('ops.portal_waiting()'::regprocedure)) <> '658ee63214dbbf326a1874122d750a99' THEN RAISE EXCEPTION 'verify_fail: portal_waiting'; END IF;
  IF md5(pg_get_functiondef('public.fn_request_gate()'::regprocedure)) <> 'a54d74e1398124e3f62b2419fd54b084' THEN RAISE EXCEPTION 'verify_fail: fn_request_gate'; END IF;
  IF to_regprocedure('ops.portal_home()') IS NOT NULL OR to_regprocedure('ops.portal_my_work()') IS NOT NULL THEN RAISE EXCEPTION 'verify_fail: new functions still there'; END IF;
END $verify$;

COMMIT;
