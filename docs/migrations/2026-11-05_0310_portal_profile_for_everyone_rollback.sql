-- Rollback of 2026-11-05_0310_portal_profile_for_everyone.sql: the previous bodies, verbatim, and the storage gate without the photo arm.
-- The Ops Portal's Profile page then shows a person with no app open only their email, and the camera button fails.
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE FUNCTION hr.get_my_access()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_emp bigint := hr.fn_access_caller();
begin
  if v_emp is null then
    return jsonb_build_object('employee_id', null, 'group', null,
      'apps', (select coalesce(jsonb_agg(jsonb_build_object('app', a.app, 'parent', a.parent, 'mode', a.mode,
                       'level', case when a.parent is null then 'none' else 'no' end) order by a.sort), '[]'::jsonb) from hr.access_apps a));
  end if;
  return jsonb_build_object('employee_id', v_emp,
    'group', (select coalesce(e.access_level, 'field') from public.employees e where e.id = v_emp),
    'apps', (select jsonb_agg(jsonb_build_object('app', f.app, 'name', f.name, 'parent', f.parent, 'mode', f.mode, 'level', f.level) order by f.sort)
               from hr.fn_effective_access(v_emp) f));
end $function$;

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
  raise exception 'You do not have access to any UnclogMe app. Ask Fred or Yannick to change it.'
    using errcode = '42501', detail = 'blocker=no_access app=any in public.fn_request_gate';
end $function$;

ALTER POLICY storage_access_gate ON storage.objects
  USING (CASE
    WHEN ( SELECT hr.fn_storage_open() AS fn_storage_open) THEN true
    WHEN ((bucket_id = 'intake-photos'::text) AND ( SELECT hr.fn_pp_forms_open() AS fn_pp_forms_open)) THEN client.fn_intake_photo_shown(name)
    ELSE false
END)
  WITH CHECK (CASE
    WHEN ( SELECT hr.fn_storage_open() AS fn_storage_open) THEN true
    WHEN ((bucket_id = 'intake-photos'::text) AND ( SELECT hr.fn_pp_forms_open() AS fn_pp_forms_open)) THEN client.fn_intake_photo_shown(name)
    ELSE false
END);
COMMIT;
