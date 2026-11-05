-- =============================================================================
-- 2026-11-05_0310_portal_profile_for_everyone.sql
--
-- WHAT: what a small Profile page for EVERYONE needs from the database, on the Ops Portal (/profile):
--   1. hr.get_my_access() also returns 'me': the person's own name, colour and photo path.
--   2. public.fn_request_gate(): a door for exactly POST /rpc/set_employee_photo in schema hr.
--   3. storage_access_gate: an arm for bucket employee-photos, hr.fn_can_set_photo_path(name), the rule the bucket's
--      own INSERT policy already uses.
--
-- WHY: Fred, 2026-11-05: "Build a small Profile page"; on the mockup https://claude.ai/artifact/RMA5YmMRo6xm4Y9R9H7E26 ,
--      layout A, and "Yes, keep the button": everyone can update their own picture.
--      Today a person with no app open (most of the field team) is refused all three by the read gate and the storage
--      gate, so without this the page would show them no name and the camera button would fail.
--
-- WHAT THIS OPENS, and to whom: only people with no app open gain anything. They can read and upload in their OWN
--   folder of employee-photos and set their OWN photo. Staff with an app open stop at the first arm exactly as before.
--   The photo door is not a view path, returns jsonb, and hr.set_employee_photo refuses anyone else's photo
--   (hr.fn_can_set_photo) and any path outside the person's own folder (blocker=photo_path).
--   Not opened: public.employees, any other person's photo, any other function.
--
-- 🛑 THE BODIES ARE THE LIVE pg_get_functiondef OUTPUT WITH ONE ANCHORED EDIT EACH, BY A SCRIPT, md5-GUARDED BELOW.
-- RULE 8, AUDIT: no table changed. public.employees stays audited; a photo change is logged there as before.
-- ATOMIC: one transaction. VERIFY runs its writes in a sub-block rolled back by a sentinel, so they leave nothing.
-- ROLLBACK: 2026-11-05_0310_portal_profile_for_everyone_rollback.sql
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('hr.get_my_access()'::regprocedure)) <> '6c78f425ce35f98049e6bb19554b7350' THEN RAISE EXCEPTION 'hr.get_my_access changed since this was written'; END IF;
  IF md5(pg_get_functiondef('public.fn_request_gate()'::regprocedure)) <> 'a5eb811f6cd88ed77c8e770880ca9d59' THEN RAISE EXCEPTION 'public.fn_request_gate changed since this was written'; END IF;
END $guard$;

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
    -- 2026-11-05_0310: the person's own name, colour and photo, for the Ops Portal's Profile page and sidebar. A person with
    -- no app open cannot read public.employees (fn_request_gate), and this function always passes that gate.
    'me', (select jsonb_build_object('full_name', e.full_name, 'color_hex', e.color_hex, 'photo_path', e.photo_path) from public.employees e where e.id = v_emp),
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
  -- 2026-11-05_0310: the Photo door. A person with no app open may set their own photo from the Ops Portal's Profile page.
  -- This one function, in schema hr, by POST only, and hr.set_employee_photo itself refuses anyone else's photo.
  if v_all_on is not null and v_path = '/rpc/set_employee_photo'
     and coalesce(current_setting('request.method', true), '') = 'POST'
     and coalesce((nullif(current_setting('request.headers', true), '')::jsonb)->>'content-profile', '') = 'hr' then
    return;
  end if;
  raise exception 'You do not have access to any UnclogMe app. Ask Fred or Yannick to change it.'
    using errcode = '42501', detail = 'blocker=no_access app=any in public.fn_request_gate';
end $function$;

ALTER POLICY storage_access_gate ON storage.objects
  USING (CASE
    WHEN ( SELECT hr.fn_storage_open() AS fn_storage_open) THEN true
    WHEN ((bucket_id = 'intake-photos'::text) AND ( SELECT hr.fn_pp_forms_open() AS fn_pp_forms_open)) THEN client.fn_intake_photo_shown(name)
    WHEN (bucket_id = 'employee-photos'::text) THEN hr.fn_can_set_photo_path(name)
    ELSE false
END)
  WITH CHECK (CASE
    WHEN ( SELECT hr.fn_storage_open() AS fn_storage_open) THEN true
    WHEN ((bucket_id = 'intake-photos'::text) AND ( SELECT hr.fn_pp_forms_open() AS fn_pp_forms_open)) THEN client.fn_intake_photo_shown(name)
    WHEN (bucket_id = 'employee-photos'::text) THEN hr.fn_can_set_photo_path(name)
    ELSE false
END);

DO $verify$
DECLARE
  v_fred jsonb; v_stranger jsonb; v_uid uuid; v_emp bigint; v_other bigint; v_seen bigint; v_foreign bigint; v_refused text; v_gate text;
BEGIN
  -- An admin gets 'me', and the old keys are untouched.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_fred := hr.get_my_access();
  RESET ROLE;
  IF v_fred->'me'->>'full_name' IS NULL THEN RAISE EXCEPTION 'verify_fail: no name in me: %', v_fred->'me'; END IF;
  IF NOT (v_fred ? 'employee_id' AND v_fred ? 'group' AND v_fred ? 'apps') THEN RAISE EXCEPTION 'verify_fail: old keys'; END IF;

  -- Someone who is not staff gets no 'me'.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-4000-8000-000000000999', 'email', 'nobody@example.com', 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  v_stranger := hr.get_my_access();
  RESET ROLE;
  IF v_stranger ? 'me' THEN RAISE EXCEPTION 'verify_fail: a stranger got me'; END IF;

  -- A real person with no app open: the case this exists for.
  SELECT u.id, e.id INTO v_uid, v_emp
    FROM public.employees e JOIN auth.users u ON lower(u.email) = lower(e.email)
   WHERE e.status = 'ACTIVE' AND e.access_level = 'field' AND NOT EXISTS (
     SELECT 1 FROM hr.fn_effective_access(e.id) f WHERE f.parent IS NULL AND f.level IN ('view', 'edit'))
   ORDER BY e.id LIMIT 1;
  IF v_uid IS NULL THEN RAISE EXCEPTION 'verify_fail: no field person to test with'; END IF;
  SELECT id INTO v_other FROM public.employees WHERE id <> v_emp ORDER BY id LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', (SELECT email FROM auth.users WHERE id = v_uid), 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('content-profile', 'hr')::text, true);
  PERFORM set_config('request.method', 'POST', true);

  -- The door opens for exactly this path, this method and this schema.
  SET LOCAL ROLE authenticated;
  PERFORM set_config('request.path', '/rpc/set_employee_photo', true);
  PERFORM public.fn_request_gate();
  BEGIN
    PERFORM set_config('request.path', '/rpc/get_pay_summary', true);
    PERFORM public.fn_request_gate();
    RAISE EXCEPTION 'verify_fail: the gate let another function through';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM set_config('request.path', '/rpc/set_employee_photo', true);
    PERFORM set_config('request.headers', json_build_object('content-profile', 'public')::text, true);
    PERFORM public.fn_request_gate();
    RAISE EXCEPTION 'verify_fail: the gate let another schema through';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN
    PERFORM set_config('request.headers', json_build_object('content-profile', 'hr')::text, true);
    PERFORM set_config('request.method', 'GET', true);
    PERFORM public.fn_request_gate();
    RAISE EXCEPTION 'verify_fail: the gate let a GET through';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  PERFORM set_config('request.method', 'POST', true);
  RESET ROLE;

  -- Storage, and the function, for that person. Rolled back by the sentinel.
  BEGIN
    INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('employee-photos', v_emp || '/verify.jpg', '{"mimetype":"image/jpeg"}');
    INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('employee-photos', v_other || '/verify.jpg', '{"mimetype":"image/jpeg"}');
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_seen FROM storage.objects WHERE bucket_id = 'employee-photos' AND name = v_emp || '/verify.jpg';
    SELECT count(*) INTO v_foreign FROM storage.objects WHERE bucket_id = 'employee-photos' AND name NOT LIKE v_emp || '/%';
    IF v_seen <> 1 THEN RAISE EXCEPTION 'verify_fail: cannot see their own photo'; END IF;
    IF v_foreign <> 0 THEN RAISE EXCEPTION 'verify_fail: sees % other photos', v_foreign; END IF;
    PERFORM hr.set_employee_photo(v_emp, v_emp || '/verify.jpg');
    BEGIN
      PERFORM hr.set_employee_photo(v_other, v_other || '/verify.jpg');
      v_refused := 'allowed';
    EXCEPTION WHEN insufficient_privilege THEN v_refused := 'refused'; END;
    IF v_refused <> 'refused' THEN RAISE EXCEPTION 'verify_fail: set someone else''s photo'; END IF;
    BEGIN
      INSERT INTO storage.objects (bucket_id, name, metadata) VALUES ('employee-photos', v_other || '/verify2.jpg', '{"mimetype":"image/jpeg"}');
      v_refused := 'allowed';
    EXCEPTION WHEN insufficient_privilege THEN v_refused := 'refused'; END;
    IF v_refused <> 'refused' THEN RAISE EXCEPTION 'verify_fail: uploaded into someone else''s folder'; END IF;
    RESET ROLE;
    RAISE EXCEPTION 'verify_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify_undo' THEN RAISE; END IF;
  END;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  PERFORM set_config('request.path', '', true);
  PERFORM set_config('request.method', '', true);
END $verify$;

COMMIT;
