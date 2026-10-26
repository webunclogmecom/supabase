-- 2026-10-26_1030_access_no_access_signins_stay_closed.sql
--
-- Send invite, phase 1 (Trello HhuFXLlt; plan Building Apps/HR App/docs/specs/2026-10-26-send-invite-implementation-plan.md,
-- approved by Fred 2026-10-26). Fred: "why is that we're still missing the invite link for new drivers?" Inviting a
-- person who has no access means a sign-in that is NOT staff can exist for the first time. Until now every sign-in was
-- staff (admin or office with Edit everywhere), and three database doors relied on that. This migration closes them
-- before any invite can be sent (invites stay impossible: hr-sign-in still refuses the action).
--
-- 1. hr.fn_any_app_open (the read gate behind public.fn_request_gate), hr.fn_storage_open (the Storage gate) and
--    hr.check_app_action (the edge functions' access check): the "an app is not on, let it through" shortcut now
--    applies only to a caller with View or Edit in at least one top-level app (hr.fn_effective_access). A sign-in with
--    no access anywhere, or with no employee row, stays refused whatever the app modes. Before, putting ONE app back
--    to watch (the documented undo, docs/runbooks/access-undo.md section 1) opened every table, Storage and every edge
--    action to every signed-in account. Staff are unchanged: Fred, Diego and Aaron pass exactly as before.
--    hr.check_app_action also gains the read action 'view_derm_doc' (DERM Tracker View), which get-derm-doc now asks
--    for kinds address and fog when the caller is a person (no existing action fitted a read of those sheets).
-- 2. D17 (decided 10-21, enforced nowhere until now): hr.set_access refuses View or Edit in any top-level app for a
--    person whose group is Field, and hr.set_group_access refuses it for the Field defaults, with the sentence
--    "Field people cannot get View or Edit yet (D17): reads are not limited per app." set_access checks the SAVED
--    result (group defaults + own settings, through hr.fn_effective_access), so moving someone into Field over an old
--    own setting is refused too. Decision on the Yes/No sub-settings (hr.access_apps rows whose parent is not null):
--    allowed, because each needs its app's View (needs) and hr.fn_effective_access reads it as No while the app is at
--    None, so it grants nothing. Not covered on purpose: moving a person from Field to Office or Admin is a group
--    decision by an admin, not a Field person getting View.
-- 3. public.log_access_health (daily health email) gains three lines, in the function's existing item format:
--    outside_domain_sign_in (an auth user not turned off whose address is outside unclogme.com / ayache.com),
--    signup_rule_changed (md5(pg_get_functiondef(public.fn_restrict_signup_domains)) is not ad0b912c...), and
--    field_with_view (an ACTIVE Field employee with a confirmed sign-in not turned off and View/Edit in some app).
--    All three return 0 rows today (asserted below). Expected to fire during the phase 7 test window (the test person
--    at a Gmail address and the one-address sign-up exception) until its clean-up.
--
-- Sweep of the edge functions that read a bearer token (Supabase/docs/audits/2026-10-26_signed_in_is_not_staff_sweep.md):
-- get-derm-doc was the only one returning data to ANY signed-in account without checkAppAction; it is changed in the
-- same cycle (deploy AFTER this migration, see below). Every other one is service-key-only, signed (webhooks, keys),
-- or calls checkAppAction, which now refuses a no-access caller in every mode.
--
-- Known residual, behind the read gate and not changed here: hr.fn_check_app, hr.fn_require_app and hr.fn_app_open
-- still let any caller through while their app is not on. They are reached only through PostgREST, so the gate refuses
-- a no-access caller first. Turning the gate off (G3) therefore needs the no-access sign-ins banned first (runbook).
--
-- Order: this migration first, then deploy get-derm-doc (it asks for 'view_derm_doc', which only exists after this).
-- Bodies spliced from the live definitions (pg_get_functiondef, 2026-10-26 09:50 ET) with anchored edits, md5 guards
-- below; privileges asserted unchanged; no new function (nothing to revoke). VERIFY runs every case with a temporary
-- ACTIVE Field employee and a temporary confirmed sign-in at a fresh @unclogme.com address, all undone inside the
-- transaction. The same cases are the standing probe scripts/checks/hr_app/probe_no_access_signin.sql, which on the
-- bodies before this migration FAILS the watch / off / D17 / view_derm_doc / new health line cases (old-body control).
-- Rollback: 2026-10-26_rollback_access_no_access_signins_stay_closed.sql (read its header for the order).

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_any_app_open(boolean)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'd7e8ee44b897b62d80aaea31bbd99148' THEN RAISE EXCEPTION 'guard: hr.fn_any_app_open changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_storage_open()'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'd8816445e456b7220410a6af34b8a590' THEN RAISE EXCEPTION 'guard: hr.fn_storage_open changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.check_app_action(text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '33138880523049f7e4fb1ad9d3b28546' THEN RAISE EXCEPTION 'guard: hr.check_app_action changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.set_access(bigint,text,jsonb,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '933231e7739ef6d5830cf53f8a100454' THEN RAISE EXCEPTION 'guard: hr.set_access changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.set_group_access(jsonb,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '8a52f9cb9f12d2d39429b5958fbe6666' THEN RAISE EXCEPTION 'guard: hr.set_group_access changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('public.log_access_health()'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '1e8cd7d31cc8085e2a70479069ca23ce' THEN RAISE EXCEPTION 'guard: public.log_access_health changed'; END IF;
  IF md5(pg_get_functiondef('public.fn_restrict_signup_domains(jsonb)'::regprocedure)) <> 'ad0b912c75d4e8f6a5d7ce7c493da6e6' THEN
    RAISE EXCEPTION 'guard: public.fn_restrict_signup_domains is not the reviewed version (the new health line would fire at once)'; END IF;
END $g$;

CREATE TEMP TABLE p1_acl_before ON COMMIT DROP AS SELECT p.oid::regprocedure::text k, p.proacl::text a FROM pg_proc p
 WHERE p.oid IN ('hr.fn_any_app_open(boolean)'::regprocedure, 'hr.fn_storage_open()'::regprocedure, 'hr.check_app_action(text)'::regprocedure, 'hr.set_access(bigint,text,jsonb,text)'::regprocedure, 'hr.set_group_access(jsonb,text)'::regprocedure, 'public.log_access_health()'::regprocedure);

CREATE OR REPLACE FUNCTION hr.fn_any_app_open(p_all_on boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-21_0145: true when the caller may read the shared lists (View in at least one checked app).
declare v_claims text := nullif(current_setting('request.jwt.claims', true), ''); v_emp bigint;
begin
  if v_claims is null or (v_claims::jsonb)->>'role' = 'service_role' then return true; end if;
  v_emp := hr.fn_access_caller();
  if v_emp is null then return false; end if;
  -- 2026-10-26_1030 (Send invite phase 1): an app that is not on lets the caller through only when they have View or Edit in
  -- some top-level app; a sign-in with no access anywhere (an invited driver) stays refused whatever the modes.
  if not p_all_on and exists (select 1 from hr.access_apps a where a.parent is null and a.mode <> 'on')
     and exists (select 1 from hr.fn_effective_access(v_emp) f where f.parent is null and f.level in ('view', 'edit')) then
    return true;
  end if;
  return exists (select 1 from hr.fn_effective_access(v_emp) f
                  where f.parent is null and (p_all_on or f.mode = 'on') and f.level in ('view', 'edit'));
end $function$;

CREATE OR REPLACE FUNCTION hr.fn_storage_open()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- 2026-10-21_1915 (G0b): true unless every top-level app is on and the signed-in caller has View/Edit in none of them
  select auth.uid() is null
      -- 2026-10-26_1030 (Send invite phase 1): "an app is not on" opens Storage only for a caller with View or Edit in some app
      or (exists (select 1 from hr.access_apps a where a.parent is null and a.mode <> 'on')
          and exists (select 1 from hr.fn_effective_access(hr.fn_access_caller()) f
                       where f.parent is null and f.level in ('view', 'edit')))
      or exists (select 1 from hr.fn_effective_access(hr.fn_access_caller()) f
                  where f.parent is null and f.mode = 'on' and f.level in ('view', 'edit'))
$function$;

CREATE OR REPLACE FUNCTION hr.check_app_action(p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_apps text[]; v_level text;
begin
  -- 2026-10-21_0900: each action names the app(s) whose level allows it; several apps = allowed in ANY of them
  select a.apps, a.lvl into v_apps, v_level
    from (values ('send_visit_photos_email',      array['admin_review'], 'edit'),
                 ('rotate_photo',                 array['admin_review'], 'edit'),
                 ('visit_client_note_photos',     array['admin_review'], 'view'),
                 ('send_derm_email',              array['derm_tracker'], 'edit'),
                 ('preview_derm_email',           array['derm_tracker'], 'view'),   -- 2026-10-21_0700 (D2)
                 ('generate_derm_address_pdf',    array['derm_tracker'], 'edit'),
                 ('generate_derm_address_preview',array['derm_tracker'], 'edit'),   -- 2026-10-21_0700: it assigns a printed sheet number (D6)
                 ('record_manual_gdo_report',     array['derm_tracker'], 'edit'),
                 ('derm_visit_report',            array['derm_tracker'], 'view'),
                 ('view_derm_doc',                array['derm_tracker'], 'view'),   -- 2026-10-26_1030: get-derm-doc address / fog sheets
                 ('create_client',                array['client_app','visit_calendar'], 'edit'),
                 ('save_calendar_task',           array['client_app','visit_calendar'], 'edit'),
                 ('save_client_job',              array['client_app'], 'edit'),
                 ('create_service_call_job',      array['client_app','visit_calendar'], 'edit'),   -- 2026-10-21_0640 (D6)
                 ('save_client_property',         array['client_app'], 'edit'),
                 ('save_client_contact',          array['client_app'], 'edit'),
                 ('refresh_client_contacts',      array['client_app'], 'view'),   -- 2026-10-21_0915: runs on every client page open
                 ('archive_client',               array['client_app'], 'edit'),
                 ('unarchive_client',             array['client_app'], 'edit'),
                 ('save_client_fields',           array['client_app'], 'edit'),
                 ('parse_gdo_permit',             array['client_app'], 'edit'),
                 ('save_day_marker',              array['visit_calendar'], 'edit'),
                 ('adopt_visit_from_jobber',      array['visit_calendar'], 'edit'),
                 ('push_visit_to_jobber',         array['visit_calendar'], 'edit'),
                 ('save_calendar_visit',          array['visit_calendar'], 'edit'),
                 ('calculate_driving_time',       array['visit_calendar'], 'view')) a(action, apps, lvl)
   where a.action = p_action;
  if v_apps is null then
    raise exception 'Unknown action.' using errcode = '22023', detail = 'blocker=unknown_action in hr.check_app_action';
  end if;
  -- 2026-10-26_1030 (Send invite phase 1): an app that is not on lets the action through (off) or logs it (watch) only for a
  -- caller with View or Edit in some top-level app. hr.fn_app_level gives no claims / service_role edit, so they pass.
  if exists (select 1 from hr.access_apps a where a.app = any (v_apps) and a.mode <> 'on')
     and not exists (select 1 from hr.access_apps a where a.parent is null and hr.fn_access_rank(hr.fn_app_level(a.app)) >= 1) then
    raise exception 'You do not have access to do this. Ask Fred or Yannick to change it.'
      using errcode = '42501', detail = 'blocker=no_access app=any needs=' || v_level || ' in hr.check_app_action';
  end if;
  perform hr.fn_check_any_app(v_apps, v_level, replace(p_action, '_', ' '));
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION hr.set_access(p_employee_id bigint, p_group text, p_levels jsonb, p_expected_version text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_e public.employees; v_grp text; v_new_grp text; k text; v_val text; v_app hr.access_apps; v_def text;
  v_email text;
begin
  perform pg_advisory_xact_lock(hashtext('hr.access'));   -- 2026-10-19_2230: lock first, then who is calling
  v_caller := hr.fn_require_access_admin();
  select * into v_e from public.employees where id = p_employee_id for update;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_employee_id;
  end if;
  if v_e.id = v_caller then
    raise exception 'You cannot change your own access. Ask another admin.' using errcode = '42501', detail = 'blocker=own_row';
  end if;
  if v_e.status <> 'ACTIVE' then
    raise exception 'This person is inactive, so they have no access anywhere. Nothing was saved.' using errcode = '22023', detail = 'blocker=inactive';
  end if;
  if p_expected_version is distinct from hr.fn_access_version(v_e.id) then
    raise exception 'Someone else changed this person''s access while you were editing. Nothing was saved.'
      using errcode = '40001', detail = 'blocker=stale_version';
  end if;
  v_grp := coalesce(v_e.access_level, 'field');
  v_new_grp := coalesce(nullif(btrim(p_group), ''), v_grp);
  if v_new_grp not in ('admin', 'office', 'field') then
    raise exception 'The group must be Admin, Office or Field. Nothing was saved.' using errcode = '22023', detail = 'blocker=group_value';
  end if;
  if v_grp = 'admin' and v_new_grp <> 'admin' and hr.fn_active_admins(v_e.id) < 1 then
    raise exception 'At least one active admin must remain. Nothing was saved.' using errcode = '22023', detail = 'blocker=last_admin';
  end if;
  if p_levels is not null and jsonb_typeof(p_levels) <> 'object' then
    raise exception 'Nothing to save.' using errcode = '22023', detail = 'blocker=levels_shape';
  end if;

  if v_new_grp is distinct from v_grp then
    update public.employees set access_level = v_new_grp where id = v_e.id;
  end if;

  select u.email into v_email from auth.users u where u.id = auth.uid();
  for k in select jsonb_object_keys(coalesce(p_levels, '{}'::jsonb)) loop
    select * into v_app from hr.access_apps a where a.app = k;
    if not found then
      raise exception 'Unknown app "%". Nothing was saved.', k using errcode = '22023', detail = 'blocker=unknown_app';
    end if;
    v_val := p_levels->>k;
    if v_val is null then
      delete from hr.access_overrides o where o.employee_id = v_e.id and o.app = k;
      continue;
    end if;
    if v_new_grp = 'admin' then
      raise exception 'Admins have everything in every app, so they have no own settings. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=admin_override';
    end if;
    if (v_app.parent is null and v_val not in ('none', 'view', 'edit')) or (v_app.parent is not null and v_val not in ('no', 'yes')) then
      raise exception 'That is not a level for %. Nothing was saved.', v_app.name using errcode = '22023', detail = 'blocker=level_value app=' || k;
    end if;
    if k = 'hr' then
      select d.level into v_def from hr.access_group_defaults d where d.grp = v_new_grp and d.app = 'hr';
      if hr.fn_access_rank(v_val) > hr.fn_access_rank(v_def) then
        raise exception 'To give more in the HR App, change the group. Nothing was saved.' using errcode = '22023', detail = 'blocker=hr_above_group';
      end if;
    end if;
    insert into hr.access_overrides (employee_id, app, level, set_by_email, set_at)
    values (v_e.id, k, v_val, v_email, now())
    on conflict (employee_id, app) do update set level = excluded.level, set_by_email = excluded.set_by_email, set_at = excluded.set_at
      where hr.access_overrides.level is distinct from excluded.level;
  end loop;

  -- An HR App own setting may not sit above a lowered group either
  if exists (select 1 from hr.access_overrides o join hr.access_group_defaults d on d.grp = v_new_grp and d.app = 'hr'
              where o.employee_id = v_e.id and o.app = 'hr' and v_new_grp <> 'admin' and hr.fn_access_rank(o.level) > hr.fn_access_rank(d.level)) then
    raise exception 'This person''s own HR App setting is above the new group. Reset it first. Nothing was saved.'
      using errcode = '22023', detail = 'blocker=hr_above_group';
  end if;

  -- 2026-10-26_1030 (Send invite phase 1) (D17): a Field person gets no View or Edit in any top-level app while reads are not
  -- limited per app (the read gate is all or nothing). Checked on the SAVED result (group defaults + own settings), so
  -- a move to Field over an old own setting is refused too. Yes/No sub-settings stay allowed: each needs its app's
  -- View (hr.access_apps.needs) and hr.fn_effective_access reads it as No under an app at None.
  if v_new_grp = 'field'
     and exists (select 1 from hr.fn_effective_access(v_e.id) f where f.parent is null and f.level in ('view', 'edit')) then
    raise exception 'Field people cannot get View or Edit yet (D17): reads are not limited per app.'
      using errcode = '22023', detail = 'blocker=d17_field_view';
  end if;

  return hr.get_access(v_e.id);
end $function$;

CREATE OR REPLACE FUNCTION hr.set_group_access(p_changes jsonb, p_expected_version text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller bigint; c jsonb; v_app hr.access_apps; v_grp text; v_val text; v_names text;
begin
  perform pg_advisory_xact_lock(hashtext('hr.access'));   -- 2026-10-19_2230: lock first, then who is calling
  v_caller := hr.fn_require_access_admin();
  if p_expected_version is distinct from hr.fn_defaults_version() then
    raise exception 'Someone else changed the group defaults while you were editing. Nothing was saved.'
      using errcode = '40001', detail = 'blocker=stale_version';
  end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'array' or jsonb_array_length(p_changes) = 0 then
    raise exception 'Nothing to save.' using errcode = '22023', detail = 'blocker=changes_shape';
  end if;
  for c in select * from jsonb_array_elements(p_changes) loop
    v_grp := c->>'group'; v_val := c->>'level';
    if v_grp is null or v_grp not in ('office', 'field') then
      raise exception 'Only the Office and Field defaults can be changed; admins have everything. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=group_value';
    end if;
    select * into v_app from hr.access_apps a where a.app = c->>'app';
    if not found then
      raise exception 'Unknown app "%". Nothing was saved.', c->>'app' using errcode = '22023', detail = 'blocker=unknown_app';
    end if;
    if v_val is null or (v_app.parent is null and v_val not in ('none', 'view', 'edit')) or (v_app.parent is not null and v_val not in ('no', 'yes')) then
      raise exception 'That is not a level for %. Nothing was saved.', v_app.name using errcode = '22023', detail = 'blocker=level_value';
    end if;
    -- 2026-10-26_1030 (Send invite phase 1) (D17): no View or Edit in a top-level app for the Field defaults
    if v_grp = 'field' and v_app.parent is null and v_val in ('view', 'edit') then
      raise exception 'Field people cannot get View or Edit yet (D17): reads are not limited per app.'
        using errcode = '22023', detail = 'blocker=d17_field_view app=' || v_app.app;
    end if;
    -- 2026-10-21_0630 (D9): never take an app that is on away from the whole office in one save
    if v_grp = 'office' and v_app.parent is null and v_app.mode = 'on' and v_val = 'none'
       and coalesce(c->>'allow_none', '') <> 'true'
       and exists (select 1 from hr.access_group_defaults d where d.grp = 'office' and d.app = v_app.app and d.level <> 'none') then
      raise exception 'That would take % away from every office person at once. Change people one by one instead. Nothing was saved.', v_app.name
        using errcode = '22023', detail = 'blocker=office_app_to_none app=' || v_app.app;
    end if;
    update hr.access_group_defaults d set level = v_val where d.grp = v_grp and d.app = v_app.app and d.level is distinct from v_val;
  end loop;
  -- 2026-10-19_2230 (review): the same rule as hr.set_access, whichever writer moved the default
  select string_agg(e.full_name, ', ' order by e.full_name) into v_names
    from hr.access_overrides o
    join public.employees e on e.id = o.employee_id and e.status = 'ACTIVE' and coalesce(e.access_level, 'field') <> 'admin'
    join hr.access_group_defaults d on d.grp = coalesce(e.access_level, 'field') and d.app = 'hr'
   where o.app = 'hr' and hr.fn_access_rank(o.level) > hr.fn_access_rank(d.level);
  if v_names is not null then
    raise exception 'These people have their own HR App setting above the new default: %. Reset it first. Nothing was saved.', v_names
      using errcode = '22023', detail = 'blocker=hr_above_group';
  end if;
  return hr.get_access_overview();
end $function$;

CREATE OR REPLACE FUNCTION public.log_access_health()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-21 (D11): the read gate setting and apps left out of 'on' after the planned date
declare v_items jsonb := '[]'::jsonb; v_by timestamptz; n int;
begin
  if not exists (select 1 from pg_db_role_setting s join pg_roles r on r.oid = s.setrole
                  where r.rolname = 'authenticator' and array_to_string(s.setconfig, ' ') like '%pgrst.db_pre_request=public.fn_request_gate%') then
    v_items := v_items || jsonb_build_object('kind', 'access:gate_setting_missing', 'issue', 'gate_setting_missing',
      'reason', 'The read gate is switched off, so a sign-in with no access to any app can read the shared lists.',
      'what_to_do', 'If nobody turned it off on purpose, turn it back on: alter role authenticator set pgrst.db_pre_request to ''public.fn_request_gate''; notify pgrst, ''reload config''; (docs/runbooks/access-undo.md section 3).');
  end if;
  begin v_by := nullif(btrim((select value from public.app_config where key = 'access_all_on_by')), '')::timestamptz;
  exception when others then v_by := null; end;
  if v_by is not null and now() > v_by then
    select v_items || coalesce(jsonb_agg(jsonb_build_object('kind', 'access:app_not_on:' || a.app, 'issue', 'app_not_on', 'app', a.app,
             'reason', format('%s is still in %s, so its access is not enforced.', a.name, a.mode),
             'what_to_do', 'Finish its switch-on (plan HR App/docs/specs/2026-10-21-access-switch-on-and-invite-plan.md), or move app_config access_all_on_by if the date changed.')
             order by a.app), '[]'::jsonb)
      into v_items from hr.access_apps a where a.parent is null and a.mode <> 'on';
  end if;
  -- 2026-10-26_1030 (Send invite phase 1): three lines that reach a person on their own now that a sign-in can exist that is not
  -- staff. 1. a sign-in outside the two company domains that is not turned off
  select v_items || coalesce(jsonb_agg(jsonb_build_object('kind', 'access:outside_domain_sign_in:' || u.id, 'issue', 'outside_domain_sign_in',
           'user_id', u.id, 'domain', substring(lower(u.email) from '@([^@]+)$'),
           'reason', format('A sign-in at %s is outside unclogme.com and ayache.com and is not turned off.',
                            coalesce('@' || substring(lower(u.email) from '@([^@]+)$'), 'an address with no domain')),
           'what_to_do', 'If nobody created it on purpose, turn it off: set the person Inactive in the HR App, or ban the user in the Supabase dashboard (Authentication, Users). docs/runbooks/access-undo.md.')
           order by u.created_at), '[]'::jsonb)
    into v_items from auth.users u
   where u.deleted_at is null and (u.banned_until is null or u.banned_until <= now())
     and coalesce(substring(lower(u.email) from '@([^@]+)$'), '') not in ('unclogme.com', 'ayache.com');
  -- 2. the sign-up rule is not the reviewed version (it is what keeps sign-ups to the two company domains)
  if md5(coalesce(pg_get_functiondef(to_regprocedure('public.fn_restrict_signup_domains(jsonb)')), '')) <> 'ad0b912c75d4e8f6a5d7ce7c493da6e6' then
    v_items := v_items || jsonb_build_object('kind', 'access:signup_rule_changed', 'issue', 'signup_rule_changed',
      'reason', 'The sign-up rule is not the reviewed version, so sign-ups may no longer be limited to unclogme.com and ayache.com.',
      'what_to_do', 'If nobody changed it on purpose (the invite test adds one address for a short time), put back the reviewed body of public.fn_restrict_signup_domains (fingerprint ad0b912c) and check its grants.');
  end if;
  -- 3. an active Field person with a confirmed sign-in that is not turned off and View or Edit in an app (D17)
  select v_items || coalesce(jsonb_agg(jsonb_build_object('kind', 'access:field_with_view:e' || e.id, 'issue', 'field_with_view', 'employee_id', e.id,
           'reason', format('%s is in the Field group, can sign in and has View or Edit in an app. Reads are not limited per app yet (D17), so they can read every shared list.', e.full_name),
           'what_to_do', 'Set their apps back to None in the HR App (Access), or turn off their sign-in.')
           order by e.id), '[]'::jsonb)
    into v_items from public.employees e
   where e.status = 'ACTIVE' and coalesce(e.access_level, 'field') = 'field'
     and exists (select 1 from auth.users u
                  where lower(btrim(u.email)) = lower(btrim(e.email)) and u.deleted_at is null and u.email_confirmed_at is not null
                    and (u.banned_until is null or u.banned_until <= now()))
     and exists (select 1 from hr.fn_effective_access(e.id) f where f.parent is null and f.level in ('view', 'edit'));
  n := jsonb_array_length(v_items);
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('access-health', clock_timestamp(), clock_timestamp(), n, case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items, 'all_on_by', v_by));
  return n;
end $function$;

DO $p1$
DECLARE
  c_fred  text := json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com', 'role', 'authenticated')::text;
  c_diego text := json_build_object('sub', 'cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8', 'email', 'contact@unclogme.com', 'role', 'authenticated')::text;
  v_tag text := substr(md5(random()::text || clock_timestamp()::text), 1, 10);
  v_emp bigint := 990001;   -- explicit id (OVERRIDING SYSTEM VALUE) so the probe takes no value from the employees sequence
  v_uid uuid := gen_random_uuid(); v_stranger uuid := gen_random_uuid(); v_gmail uuid := gen_random_uuid();
  c_tmp text; c_str text;
  r jsonb := '[]'; v_state text; v_msg text; v_det text; v_note text; v_b boolean; v_j jsonb; v_ver text; v_n bigint; v_items jsonb;
BEGIN
  c_tmp := json_build_object('sub', v_uid, 'email', 'p1-probe-' || v_tag || '@unclogme.com', 'role', 'authenticated')::text;
  c_str := json_build_object('sub', v_stranger, 'email', 'p1-stranger-' || v_tag || '@unclogme.com', 'role', 'authenticated')::text;
  BEGIN   -- every write in this block (the temporary people included) is undone by the raise at its end

  -- case 1: health today: none of the three new lines
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM public.log_access_health();
      SELECT s.details->'items' INTO v_items FROM public.sync_log s WHERE s.sync_source = 'access-health' ORDER BY s.id DESC LIMIT 1;
      v_note := 'new lines: ' || coalesce((SELECT jsonb_agg(x->>'kind') FROM jsonb_array_elements(v_items) x
                 WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view'))::text, '[]');
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'health today: none of the three new lines', 'expect', '0 lines', 'ok', coalesce(v_state is null and (SELECT count(*) FROM jsonb_array_elements(v_items) x WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view')) = 0, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

  -- the temporary people (undone at the end of the outer block)
  INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES ('00000000-0000-0000-0000-000000000000', v_uid, 'authenticated', 'authenticated', 'p1-probe-' || v_tag || '@unclogme.com', '',
          now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false),
         ('00000000-0000-0000-0000-000000000000', v_stranger, 'authenticated', 'authenticated', 'p1-stranger-' || v_tag || '@unclogme.com', '',
          now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false);
  INSERT INTO public.employees (id, full_name, status, email, access_level, notes) OVERRIDING SYSTEM VALUE
  VALUES (v_emp, 'ZZ P1 Probe ' || v_tag, 'ACTIVE', 'p1-probe-' || v_tag || '@unclogme.com', 'field', 'Temporary row of a rolled-back probe');

  -- case 2: instrument: the temp sign-in is the temp Field person, with no View/Edit anywhere
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      v_note := 'caller ' || coalesce(hr.fn_access_caller()::text, 'null') || ', apps with view/edit '
                || (SELECT count(*) FROM hr.fn_effective_access(v_emp) f WHERE f.parent IS NULL AND f.level IN ('view', 'edit'));
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'instrument: the temp sign-in is the temp Field person, with no View/Edit anywhere', 'expect', 'caller = temp employee, 0 apps', 'ok', coalesce(v_state is null and v_note = 'caller ' || v_emp || ', apps with view/edit 0', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 3: gate: temp Field person, every app on
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: temp Field person, every app on', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 4: gate: Fred, every app on
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: Fred, every app on', 'expect', 'passes', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 5: gate: temp Field person, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: temp Field person, stamp_studio in watch', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 6: gate: a confirmed sign-in with no employee row, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_str, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: a confirmed sign-in with no employee row, stamp_studio in watch', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 7: gate: Fred, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: Fred, stamp_studio in watch', 'expect', 'passes', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 8: gate: Diego, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_diego, true);
      SET LOCAL ROLE authenticated;
      PERFORM public.fn_request_gate();
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'gate: Diego, stamp_studio in watch', 'expect', 'passes', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 9: storage: temp Field person, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_b := hr.fn_storage_open(); v_note := 'returned ' || coalesce(v_b::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'storage: temp Field person, stamp_studio in watch', 'expect', 'fn_storage_open() = false', 'ok', coalesce(v_state is null and v_b = false, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 10: storage: temp Field person, every app on
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_b := hr.fn_storage_open(); v_note := 'returned ' || coalesce(v_b::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'storage: temp Field person, every app on', 'expect', 'fn_storage_open() = false', 'ok', coalesce(v_state is null and v_b = false, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 11: storage: Fred, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_b := hr.fn_storage_open(); v_note := 'returned ' || coalesce(v_b::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'storage: Fred, stamp_studio in watch', 'expect', 'fn_storage_open() = true', 'ok', coalesce(v_state is null and v_b = true, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 12: storage: Diego, stamp_studio in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'stamp_studio';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_diego, true);
      SET LOCAL ROLE authenticated;
      v_b := hr.fn_storage_open(); v_note := 'returned ' || coalesce(v_b::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'storage: Diego, stamp_studio in watch', 'expect', 'fn_storage_open() = true', 'ok', coalesce(v_state is null and v_b = true, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 13: check_app_action(preview_derm_email): temp Field person, derm_tracker in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'derm_tracker';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): temp Field person, derm_tracker in watch', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 14: check_app_action(preview_derm_email): temp Field person, derm_tracker off
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'off' WHERE app = 'derm_tracker';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): temp Field person, derm_tracker off', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 15: check_app_action(preview_derm_email): temp Field person, every app on
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): temp Field person, every app on', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 16: check_app_action(preview_derm_email): Fred, derm_tracker in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'derm_tracker';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): Fred, derm_tracker in watch', 'expect', 'ok', 'ok', coalesce(v_state is null and (v_j->>'ok')::boolean, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 17: check_app_action(preview_derm_email): Diego, derm_tracker in watch
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'watch' WHERE app = 'derm_tracker';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_diego, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): Diego, derm_tracker in watch', 'expect', 'ok', 'ok', coalesce(v_state is null and (v_j->>'ok')::boolean, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 18: check_app_action(preview_derm_email): Fred, derm_tracker off
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    UPDATE hr.access_apps SET mode = 'off' WHERE app = 'derm_tracker';
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('preview_derm_email'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(preview_derm_email): Fred, derm_tracker off', 'expect', 'ok', 'ok', coalesce(v_state is null and (v_j->>'ok')::boolean, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 19: check_app_action(view_derm_doc): Fred, every app on (new action)
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('view_derm_doc'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(view_derm_doc): Fred, every app on (new action)', 'expect', 'ok', 'ok', coalesce(v_state is null and (v_j->>'ok')::boolean, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 20: check_app_action(view_derm_doc): Diego, every app on (new action)
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_diego, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('view_derm_doc'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(view_derm_doc): Diego, every app on (new action)', 'expect', 'ok', 'ok', coalesce(v_state is null and (v_j->>'ok')::boolean, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 21: check_app_action(view_derm_doc): temp Field person, every app on (new action)
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN

    BEGIN
      PERFORM set_config('request.jwt.claims', c_tmp, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.check_app_action('view_derm_doc'); v_note := 'returned ' || coalesce(v_j::text, 'null');
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'check_app_action(view_derm_doc): temp Field person, every app on (new action)', 'expect', 'refused 42501', 'ok', coalesce(v_state = '42501', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 22: set_access: Fred gives the temp Field person View in client_app
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_access_version(v_emp);
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(v_emp, null, '{"client_app":"view"}'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_access: Fred gives the temp Field person View in client_app', 'expect', 'refused with the D17 sentence', 'ok', coalesce(v_state = '22023' and v_msg = 'Field people cannot get View or Edit yet (D17): reads are not limited per app.', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 23: set_access: Fred gives the temp Field person Edit in admin_review
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_access_version(v_emp);
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(v_emp, null, '{"admin_review":"edit"}'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_access: Fred gives the temp Field person Edit in admin_review', 'expect', 'refused with the D17 sentence', 'ok', coalesce(v_state = '22023' and v_msg = 'Field people cannot get View or Edit yet (D17): reads are not limited per app.', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 24: set_access: Fred sets the temp Field person to None in client_app
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_access_version(v_emp);
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(v_emp, null, '{"client_app":"none"}'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_access: Fred sets the temp Field person to None in client_app', 'expect', 'saved', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 25: set_access: Fred sets a Yes/No sub-setting for the temp Field person
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_access_version(v_emp);
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(v_emp, null, '{"hr_bonus":"yes"}'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_access: Fred sets a Yes/No sub-setting for the temp Field person', 'expect', 'saved', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 26: set_group_access: Field group default View in client_app
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_defaults_version();
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_group_access('[{"group":"field","app":"client_app","level":"view"}]'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_group_access: Field group default View in client_app', 'expect', 'refused with the D17 sentence', 'ok', coalesce(v_state = '22023' and v_msg = 'Field people cannot get View or Edit yet (D17): reads are not limited per app.', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 27: set_group_access: Office group default View in client_app
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_defaults_version();
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_group_access('[{"group":"office","app":"client_app","level":"view"}]'::jsonb, v_ver); v_note := 'saved';
      RESET ROLE;
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_group_access: Office group default View in client_app', 'expect', 'saved', 'ok', coalesce(v_state is null, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 28: set_access: Fred gives Aaron (office) View in client_app, then takes it back
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    v_ver := hr.fn_access_version(26);
    BEGIN
      PERFORM set_config('request.jwt.claims', c_fred, true);
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(26, null, '{"client_app":"view"}'::jsonb, v_ver);
      RESET ROLE;
      v_ver := hr.fn_access_version(26);
      v_n := (SELECT count(*) FROM hr.access_overrides o WHERE o.employee_id = 26 AND o.app = 'client_app' AND o.level = 'view');
      SET LOCAL ROLE authenticated;
      v_j := hr.set_access(26, null, '{"client_app":null}'::jsonb, v_ver);
      RESET ROLE;
      v_note := 'override after save ' || v_n || ', after undo ' || (SELECT count(*) FROM hr.access_overrides o WHERE o.employee_id = 26);
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'set_access: Fred gives Aaron (office) View in client_app, then takes it back', 'expect', 'saved twice, 0 own settings left', 'ok', coalesce(v_state is null and v_note = 'override after save 1, after undo 0', false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 29: health: an unbanned sign-in at a gmail address is listed
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
    VALUES ('00000000-0000-0000-0000-000000000000', v_gmail, 'authenticated', 'authenticated', 'p1-probe-' || v_tag || '@gmail.com', '',
            now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false);
    BEGIN
      PERFORM public.log_access_health();
      SELECT s.details->'items' INTO v_items FROM public.sync_log s WHERE s.sync_source = 'access-health' ORDER BY s.id DESC LIMIT 1;
      v_note := 'new lines: ' || coalesce((SELECT jsonb_agg(x->>'kind') FROM jsonb_array_elements(v_items) x
                 WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view'))::text, '[]');
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'health: an unbanned sign-in at a gmail address is listed', 'expect', 'line outside_domain_sign_in for it', 'ok', coalesce(v_state is null and EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) x WHERE x->>'issue' = 'outside_domain_sign_in' AND x->>'user_id' = v_gmail::text), false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 30: health: the same gmail sign-in turned off is not listed
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at,
                            raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous, banned_until)
    VALUES ('00000000-0000-0000-0000-000000000000', v_gmail, 'authenticated', 'authenticated', 'p1-probe-' || v_tag || '@gmail.com', '',
            now(), now(), now(), '{"provider":"email","providers":["email"]}', '{}', false, false, now() + interval '100 years');
    BEGIN
      PERFORM public.log_access_health();
      SELECT s.details->'items' INTO v_items FROM public.sync_log s WHERE s.sync_source = 'access-health' ORDER BY s.id DESC LIMIT 1;
      v_note := 'new lines: ' || coalesce((SELECT jsonb_agg(x->>'kind') FROM jsonb_array_elements(v_items) x
                 WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view'))::text, '[]');
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'health: the same gmail sign-in turned off is not listed', 'expect', 'no line', 'ok', coalesce(v_state is null and (SELECT count(*) FROM jsonb_array_elements(v_items) x WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view')) = 0, false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));
  -- case 31: health: a Field person with a sign-in and View in an app is listed
  v_state := null; v_msg := null; v_det := null; v_b := null; v_j := null; v_note := null;
  BEGIN
    INSERT INTO hr.access_overrides (employee_id, app, level, set_by_email) VALUES (v_emp, 'client_app', 'view', 'p1-probe');
    BEGIN
      PERFORM public.log_access_health();
      SELECT s.details->'items' INTO v_items FROM public.sync_log s WHERE s.sync_source = 'access-health' ORDER BY s.id DESC LIMIT 1;
      v_note := 'new lines: ' || coalesce((SELECT jsonb_agg(x->>'kind') FROM jsonb_array_elements(v_items) x
                 WHERE x->>'issue' IN ('outside_domain_sign_in', 'signup_rule_changed', 'field_with_view'))::text, '[]');
    EXCEPTION WHEN others THEN
      GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT, v_det = PG_EXCEPTION_DETAIL;
    END;
    RESET ROLE;
    RAISE EXCEPTION 'p1_case_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_case_undo' THEN RAISE; END IF;
  END;
  r := r || jsonb_build_object('t', 'health: a Field person with a sign-in and View in an app is listed', 'expect', 'line field_with_view for the temp person', 'ok', coalesce(v_state is null and EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) x WHERE x->>'issue' = 'field_with_view' AND (x->>'employee_id')::bigint = v_emp), false),
             'got', coalesce(v_state || ' ' || v_msg || coalesce(' [' || v_det || ']', ''), coalesce(v_note, 'no error')));

    RAISE EXCEPTION 'p1_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'p1_undo' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('p1.results', r::text, true);
END $p1$;

DO $v$
DECLARE r jsonb := current_setting('p1.results')::jsonb; v_bad text;
BEGIN
  SELECT string_agg(x->>'t', '; ') INTO v_bad FROM jsonb_array_elements(r) x WHERE NOT (x->>'ok')::boolean;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'VERIFY failed: % PROBE_RESULT %', v_bad, r; END IF;
  IF jsonb_array_length(r) < 30 THEN RAISE EXCEPTION 'VERIFY ran only % cases', jsonb_array_length(r); END IF;
  IF EXISTS (SELECT 1 FROM p1_acl_before b JOIN pg_proc p ON p.oid = b.k::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'VERIFY: privileges of a replaced function moved'; END IF;
  IF EXISTS (SELECT 1 FROM public.employees WHERE id = 990001) OR EXISTS (SELECT 1 FROM auth.users WHERE email LIKE 'p1-probe-%' OR email LIKE 'p1-stranger-%') THEN
    RAISE EXCEPTION 'VERIFY: a temporary row was left behind'; END IF;
  RAISE NOTICE 'VERIFY passed (% cases)', jsonb_array_length(r);
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
