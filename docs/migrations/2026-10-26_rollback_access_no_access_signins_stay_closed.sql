-- 2026-10-26_rollback_access_no_access_signins_stay_closed.sql
--
-- Puts the six functions of 2026-10-26_1030_access_no_access_signins_stay_closed.sql back to their bodies from before it (copied from the live catalog on
-- 2026-10-26 by pg_get_functiondef, md5 pinned): the "an app is not on" pass for every signed-in caller again, no
-- D17 refusal, no view_derm_doc action, no three health lines.
-- 🛑 ORDER: redeploy the previous get-derm-doc FIRST (its body from before this change, read back), then run this file.
-- The new get-derm-doc asks hr.check_app_action('view_derm_doc'); without that action every DERM Tracker Address sheet
-- and FOG preview would answer 503.
-- 🛑 Before running it once invites exist: ban the sign-ins with no access first (docs/runbooks/access-undo.md, G3),
-- because this file reopens watch mode to every signed-in caller.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_any_app_open(boolean)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'e0c88f2a5fe785470ce8b82f0a9b0cad' THEN RAISE EXCEPTION 'guard: hr.fn_any_app_open is not the 2026-10-26_1030 body'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_storage_open()'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '002e023f0f01bdee7e0e9cdc5a308c21' THEN RAISE EXCEPTION 'guard: hr.fn_storage_open is not the 2026-10-26_1030 body'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.check_app_action(text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '3d191ed22af8efdd777330bd115887e5' THEN RAISE EXCEPTION 'guard: hr.check_app_action is not the 2026-10-26_1030 body'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.set_access(bigint,text,jsonb,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '874aef9d7abf8ee0bf946af622340d8a' THEN RAISE EXCEPTION 'guard: hr.set_access is not the 2026-10-26_1030 body'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.set_group_access(jsonb,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'f78eee3b906d6cdd390a2cc20395f1ae' THEN RAISE EXCEPTION 'guard: hr.set_group_access is not the 2026-10-26_1030 body'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('public.log_access_health()'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'e5fe04eb8468fb10436aa921e00e49dc' THEN RAISE EXCEPTION 'guard: public.log_access_health is not the 2026-10-26_1030 body'; END IF;
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
  if not p_all_on and exists (select 1 from hr.access_apps a where a.parent is null and a.mode <> 'on') then
    return true;
  end if;
  v_emp := hr.fn_access_caller();
  if v_emp is null then return false; end if;
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
      or exists (select 1 from hr.access_apps a where a.parent is null and a.mode <> 'on')
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
  n := jsonb_array_length(v_items);
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('access-health', clock_timestamp(), clock_timestamp(), n, case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items, 'all_on_by', v_by));
  return n;
end $function$;

DO $v$ BEGIN
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_any_app_open(boolean)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'd7e8ee44b897b62d80aaea31bbd99148' THEN RAISE EXCEPTION 'VERIFY: hr.fn_any_app_open not back to its body before 2026-10-26_1030'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_storage_open()'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'd8816445e456b7220410a6af34b8a590' THEN RAISE EXCEPTION 'VERIFY: hr.fn_storage_open not back to its body before 2026-10-26_1030'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.check_app_action(text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '33138880523049f7e4fb1ad9d3b28546' THEN RAISE EXCEPTION 'VERIFY: hr.check_app_action not back to its body before 2026-10-26_1030'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.set_access(bigint,text,jsonb,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '933231e7739ef6d5830cf53f8a100454' THEN RAISE EXCEPTION 'VERIFY: hr.set_access not back to its body before 2026-10-26_1030'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.set_group_access(jsonb,text)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '8a52f9cb9f12d2d39429b5958fbe6666' THEN RAISE EXCEPTION 'VERIFY: hr.set_group_access not back to its body before 2026-10-26_1030'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('public.log_access_health()'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '1e8cd7d31cc8085e2a70479069ca23ce' THEN RAISE EXCEPTION 'VERIFY: public.log_access_health not back to its body before 2026-10-26_1030'; END IF;
  IF EXISTS (SELECT 1 FROM p1_acl_before b JOIN pg_proc p ON p.oid = b.k::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'VERIFY: privileges of a restored function moved'; END IF;
  RAISE NOTICE 'rollback VERIFY passed';
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
