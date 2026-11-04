-- 2026-11-04_1930_pp_forms_open_my_form
-- Fred, 2026-11-04, asked "Should a collector get an Open form button on their own waiting form?": "sure".
-- Today the form's link reaches a Field person only inside the Jobber task; a lost task means calling the office.
-- WHAT CHANGES:
--   client.get_intake_link  a Forms-only caller (hr.fn_pp_forms_only) gets the link of a form ASSIGNED to them
--                           (client.fn_intake_assigned_to_me, the one rule of 2026-11-04_1500); any other form raises 42501
--                           'This form is not assigned to you.' Everyone else still needs Picture Planner Edit, unchanged.
--   public.fn_request_gate  one more path in the Forms door: /rpc/get_intake_link, same schema header rule.
-- NOT CHANGED: the refusals for cancelled, submitted, expired and removed forms; the reveal row (a Field person's tap is logged
-- like anyone's, in public.property_intake_link_reveals); list_intake_forms, get_intake, the storage gate.
-- Audit (rule 8): no new table and no audited write; the reveal table is the trail, as before.
-- Checks: scripts/checks/hr_app/probe_pp_forms.sql. Control: on the 2026-11-04_1500 bodies its Open form cases FAIL.
-- Rollback: 2026-11-04_rollback_pp_forms_open_my_form.sql. App: Picture Planner prompt 2026-11-04-open-form-and-share-icon.md.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path TO '';

DO $guard$
BEGIN
  IF md5(pg_get_functiondef('client.get_intake_link(bigint)'::regprocedure)) <> '0281ae89d4546602a287ba495af952d3' THEN RAISE EXCEPTION 'guard: get_intake_link changed'; END IF;
  IF md5(pg_get_functiondef('public.fn_request_gate()'::regprocedure)) <> 'f97fe611f1b12b95f04091280ae7bfe1' THEN RAISE EXCEPTION 'guard: fn_request_gate changed'; END IF;
END $guard$;

CREATE OR REPLACE FUNCTION client.get_intake_link(p_intake_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid   uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_i     record;
  v_deleted boolean;
  v_url   text;
begin
  if v_uid is null then
    raise exception 'Please sign in again.'
      using errcode = '28000', detail = 'blocker=not_signed_in in client.get_intake_link';
  end if;
  if not public.fn_is_staff_email(v_email) then
    raise exception 'This page is for UnclogMe staff only.'
      using errcode = '42501', detail = 'blocker=not_staff in client.get_intake_link';
  end if;
  -- 2026-11-04_1930 (Fred): a Forms-only caller gets the link of a form assigned to them, so a lost Jobber task does not mean a call
  -- to the office. Every other form stays refused. Everyone else still needs Edit (2026-10-20_1600 access phase 3).
  if hr.fn_pp_forms_only() then
    if not client.fn_intake_assigned_to_me(p_intake_id) then
      raise exception 'This form is not assigned to you.'
        using errcode = '42501', detail = 'blocker=not_assigned in client.get_intake_link';
    end if;
  else
    perform hr.fn_check_app('picture_planner', 'edit', 'show a collector link');
  end if;
  if p_intake_id is null then
    raise exception 'No form was chosen. Go back to the forms and try again.'
      using errcode = '22023', detail = 'blocker=no_intake in client.get_intake_link';
  end if;

  -- Everything but the token first: every refusal is decided before the token is read.
  select i.id, i.property_id, i.expires_at, i.submitted_at, i.cancelled_at
    into v_i
    from public.property_intakes i
   where i.id = p_intake_id;
  if not found then
    raise exception 'This form does not exist.'
      using errcode = 'P0002', detail = 'blocker=not_found in client.get_intake_link';
  end if;
  if v_i.cancelled_at is not null then
    raise exception 'This form was cancelled, so its link no longer opens.'
      using errcode = '22023', detail = 'blocker=cancelled in client.get_intake_link';
  end if;
  if v_i.submitted_at is not null then
    raise exception 'This form was already submitted, so its link cannot take answers any more. To collect again, schedule a new intake from the property in the Client App.'
      using errcode = '22023', detail = 'blocker=submitted in client.get_intake_link';
  end if;
  if v_i.expires_at <= now() then
    raise exception 'This link has expired. Schedule a new intake from the property in the Client App to get a new link.'
      using errcode = '22023', detail = 'blocker=expired in client.get_intake_link';
  end if;
  select (p.deleted_at is not null) into v_deleted from public.properties p where p.id = v_i.property_id;
  if coalesce(v_deleted, true) then
    raise exception 'This property was removed, so its form should not be filled any more.'
      using errcode = '22023', detail = 'blocker=property_removed in client.get_intake_link';
  end if;

  -- The link, built in ONE place, public.fn_intake_link_url (2026-09-25_1705). It returns NULL for a
  -- token that does not look like one (the collector endpoint accepts ^[A-Za-z0-9_-]{8,64}$); the token
  -- itself never appears in a message.
  select public.fn_intake_link_url(i.token)
    into v_url
    from public.property_intakes i
   where i.id = v_i.id;
  if v_url is null then
    raise exception 'This form''s link cannot be shown. Ask for help.'
      using errcode = '22023', detail = 'blocker=bad_token in client.get_intake_link';
  end if;

  insert into public.property_intake_link_reveals (intake_id, revealed_by, revealed_email)
  values (v_i.id, v_uid, v_email);

  return jsonb_build_object('ok', true, 'intake_id', v_i.id, 'url', v_url, 'expires_at', v_i.expires_at);
end
$function$;

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

DO $verify$
BEGIN
  IF pg_get_functiondef('client.get_intake_link(bigint)'::regprocedure) NOT LIKE '%blocker=not_assigned%' THEN RAISE EXCEPTION 'verify: link body'; END IF;
  IF pg_get_functiondef('client.get_intake_link(bigint)'::regprocedure) NOT LIKE '%fn_check_app(''picture_planner'', ''edit''%' THEN RAISE EXCEPTION 'verify: Edit check gone'; END IF;
  IF pg_get_functiondef('public.fn_request_gate()'::regprocedure) NOT LIKE '%/rpc/get_intake_link%' THEN RAISE EXCEPTION 'verify: gate body'; END IF;
  IF has_function_privilege('anon', 'client.get_intake_link(bigint)', 'EXECUTE') THEN RAISE EXCEPTION 'verify: anon can run get_intake_link'; END IF;
END $verify$;

COMMIT;
