-- 2026-10-19_2145_hr_access_settings
-- Fred, 2026-10-19: "a tab in the user for like privileges, like what they can see, access and edit, like in each app ...
-- a gear icon which opens a modal/dialog with the privileges that person can have ... a tab called Access where we have
-- like the access by default of the groups Field, Office and Admin, and also to be able there to customize the
-- privileges per person". Then "go ahead with all recommended". Plan: Building Apps/HR App/docs/specs/
-- 2026-10-19-access-privileges-plan.md (phase 1a: the settings are stored, every app is off).
--   1. hr.access_apps (7 apps + 3 Yes/No switches, mode off|watch|on, all OFF here), hr.access_group_defaults (Office and
--      Field; Admin is fixed at everything), hr.access_overrides (a person's own setting). Starting values = today:
--      Office edits every app, sees bonus amounts, no pay rates; Field nothing; Diego and Serena keep Approve site files
--      (carried from app_config.page_approvers; Fred and Yannick are admins). Rule 8: all three audited.
--   2. hr.fn_app_level(app) / hr.fn_require_app(app, level): the caller is auth.uid() -> a confirmed sign-in -> one
--      active employee (never the token's email claim); timed jobs and direct SQL (no claims) and the server key get
--      everything; anyone else is looked up. fn_require_app passes while an app is off. Nothing calls it yet (phase 1d).
--   3. hr.get_my_access, hr.get_access (admins), hr.get_access_overview (admins), hr.set_access (admins, never their own,
--      stale-version refusal, an HR App own setting never above the group, the last active admin protected, one lock),
--      hr.set_group_access (admins; own settings never touched).
--   4. Decision 10: only an admin changes a person's email or status (hr.update_employee + viewer.can_change_email_status);
--      update_employee takes the same lock before its admin count. hr.get_employee_record's Activity lists own-setting
--      changes ("Visit Calendar: Group default -> View").
-- Bodies of the two edited functions copied from the live definitions (md5 guarded).
-- Rollback: 2026-10-19_rollback_hr_access_settings.sql.
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $guard$
BEGIN
  IF md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)) <> 'f1b101a4c85e3bd1a7300cbc3294a165' OR md5(pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)) <> 'b818c230f34a2884d76e12e64bf7a8d0' THEN
    RAISE EXCEPTION 'a function changed since this migration was written; rebuild it from the live bodies';
  END IF;
END $guard$;
-- ===== 1. The apps and switches access is set for. mode decides whether an app checks it: 'off' (not checked yet),
-- 'watch' (phase 2: refusals noted, nothing refused) or 'on'. Modes change only by migration.
CREATE TABLE hr.access_apps (
  app       text PRIMARY KEY CHECK (app ~ '^[a-z_]+$'),
  name      text NOT NULL,
  sort      smallint NOT NULL,
  parent    text REFERENCES hr.access_apps(app),
  needs     text CHECK (needs IN ('view', 'edit')),
  mode      text NOT NULL DEFAULT 'off' CHECK (mode IN ('off', 'watch', 'on')),
  on_since  timestamptz,
  CONSTRAINT access_apps_switch_shape_chk CHECK ((parent IS NULL) = (needs IS NULL))
);
COMMENT ON TABLE hr.access_apps IS 'The apps (and Yes/No switches under them) a person''s access is set for. mode: off = not checked yet, watch = refusals noted only, on = checked by the database. Changed only by migration. 2026-10-19_2145.';
INSERT INTO hr.access_apps (app, name, sort, parent, needs) VALUES
  ('hr', 'HR App', 10, NULL, NULL),
  ('hr_pay', 'Pay rates and bonus settings', 11, 'hr', 'view'),
  ('hr_bonus', 'See bonus amounts', 12, 'hr', 'view'),
  ('admin_review', 'Admin Review', 20, NULL, NULL),
  ('client_app', 'Client App', 30, NULL, NULL),
  ('visit_calendar', 'Visit Calendar', 40, NULL, NULL),
  ('derm_tracker', 'DERM Tracker', 50, NULL, NULL),
  ('stamp_studio', 'Stamp Studio', 60, NULL, NULL),
  ('picture_planner', 'Picture Planner', 70, NULL, NULL),
  ('pp_approve', 'Approve site files', 71, 'picture_planner', 'edit');

-- ===== 2. What each group can do (Admin is fixed at everything and is not stored). Starting values = today.
CREATE TABLE hr.access_group_defaults (
  grp    text NOT NULL CHECK (grp IN ('office', 'field')),
  app    text NOT NULL REFERENCES hr.access_apps(app),
  level  text NOT NULL CHECK (level IN ('none', 'view', 'edit', 'no', 'yes')),
  PRIMARY KEY (grp, app)
);
COMMENT ON TABLE hr.access_group_defaults IS 'Each group''s level in each app (none / view / edit) and each switch (no / yes). Admin is fixed at everything. Written only by hr.set_group_access. 2026-10-19_2145.';
INSERT INTO hr.access_group_defaults (grp, app, level)
SELECT g.grp, a.app,
       CASE WHEN g.grp = 'field' THEN CASE WHEN a.parent IS NULL THEN 'none' ELSE 'no' END
            WHEN a.app = 'hr_pay' THEN 'no'
            WHEN a.app = 'hr_bonus' THEN 'yes'
            WHEN a.app = 'pp_approve' THEN 'no'
            ELSE 'edit' END
  FROM (VALUES ('office'), ('field')) g(grp) CROSS JOIN hr.access_apps a;

-- ===== 3. A person's own settings. A row stays until Reset deletes it, even when it equals the default.
CREATE TABLE hr.access_overrides (
  employee_id  bigint NOT NULL REFERENCES public.employees(id),
  app          text NOT NULL REFERENCES hr.access_apps(app),
  level        text NOT NULL CHECK (level IN ('none', 'view', 'edit', 'no', 'yes')),
  set_by_email text,
  set_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (employee_id, app)
);
COMMENT ON TABLE hr.access_overrides IS 'A person''s own level on one app or switch, replacing their group''s default. Written only by hr.set_access (admins, never their own). 2026-10-19_2145.';
-- Today's page approver list, carried over: Diego and Serena approve site files (Fred and Yannick are admins)
INSERT INTO hr.access_overrides (employee_id, app, level, set_by_email)
SELECT e.id, 'pp_approve', 'yes', 'carried over from app_config.page_approvers'
  FROM public.employees e
 WHERE e.id IN (28, 42) AND e.status = 'ACTIVE' AND e.access_level = 'office';

-- Rule 8: all three are human-edited settings, so they are audited.
CREATE TRIGGER audit_access_apps AFTER INSERT OR UPDATE OR DELETE ON hr.access_apps FOR EACH ROW EXECUTE FUNCTION audit.log_change();
CREATE TRIGGER audit_access_group_defaults AFTER INSERT OR UPDATE OR DELETE ON hr.access_group_defaults FOR EACH ROW EXECUTE FUNCTION audit.log_change();
CREATE TRIGGER audit_access_overrides AFTER INSERT OR UPDATE OR DELETE ON hr.access_overrides FOR EACH ROW EXECUTE FUNCTION audit.log_change();
REVOKE ALL ON hr.access_apps, hr.access_group_defaults, hr.access_overrides FROM PUBLIC, anon, authenticated, service_role;

-- ===== 4. Helpers (owner only)
CREATE FUNCTION hr.fn_access_rank(p_level text) RETURNS integer LANGUAGE sql IMMUTABLE SET search_path TO '' AS $function$
  select case p_level when 'edit' then 2 when 'view' then 1 when 'yes' then 1 else 0 end
$function$;

CREATE FUNCTION hr.fn_access_label(p_level text) RETURNS text LANGUAGE sql IMMUTABLE SET search_path TO '' AS $function$
  select case p_level when 'none' then 'No access' when 'view' then 'View' when 'edit' then 'Edit'
                      when 'yes' then 'Yes' when 'no' then 'No' end
$function$;

-- Each app and switch for one person: their group's default, their own setting, and what counts.
-- Inactive: nothing. Admin: everything. A switch counts only when its app is at the level it needs;
-- Pay rates and bonus settings Yes turns on See bonus amounts.
CREATE FUNCTION hr.fn_effective_access(p_employee_id bigint)
 RETURNS TABLE(app text, name text, sort smallint, parent text, needs text, mode text, grp text, group_default text, own text, level text)
 LANGUAGE sql STABLE SET search_path TO '' AS $function$
  with e as (select x.id, x.status, coalesce(x.access_level, 'field') as grp from public.employees x where x.id = p_employee_id),
  raw as (
    select a.app, a.name, a.sort, a.parent, a.needs, a.mode, e.grp,
           case when e.grp = 'admin' then case when a.parent is null then 'edit' else 'yes' end
                else coalesce(d.level, case when a.parent is null then 'none' else 'no' end) end as group_default,
           case when e.grp = 'admin' then null else o.level end as own,
           case when e.status <> 'ACTIVE' then case when a.parent is null then 'none' else 'no' end
                when e.grp = 'admin' then case when a.parent is null then 'edit' else 'yes' end
                else coalesce(o.level, d.level, case when a.parent is null then 'none' else 'no' end) end as lvl
      from hr.access_apps a cross join e
      left join hr.access_overrides o on o.employee_id = e.id and o.app = a.app
      left join hr.access_group_defaults d on d.grp = e.grp and d.app = a.app)
  select r.app, r.name, r.sort, r.parent, r.needs, r.mode, r.grp, r.group_default, r.own,
         case when r.parent is null then r.lvl
              when hr.fn_access_rank(p.lvl) < hr.fn_access_rank(r.needs) then 'no'
              when r.app = 'hr_bonus' and (select x.lvl from raw x where x.app = 'hr_pay') = 'yes' then 'yes'
              else r.lvl end
    from raw r left join raw p on p.app = r.parent
$function$;

-- The caller as one active employee: auth.uid() -> a CONFIRMED sign-in -> exactly one active employee with that
-- email. Never the token's email claim. NULL when there is no such person.
CREATE FUNCTION hr.fn_access_caller() RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
  select case when count(*) = 1 then min(e.id) end
    from auth.users u
    join public.employees e on e.status = 'ACTIVE' and lower(btrim(e.email)) = lower(btrim(u.email))
   where u.id = auth.uid() and u.email_confirmed_at is not null
$function$;

-- The caller's level in one app or switch. Timed jobs and direct SQL (no request claims at all) and the server's
-- own key (role service_role) get everything; anyone else is looked up; no person = nothing.
CREATE FUNCTION hr.fn_app_level(p_app text) RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
declare v_claims text := nullif(current_setting('request.jwt.claims', true), ''); v_emp bigint; v_lvl text; v_switch boolean;
begin
  select a.parent is not null into v_switch from hr.access_apps a where a.app = p_app;
  if v_switch is null then
    raise exception 'Unknown app "%".', p_app using errcode = '22023', detail = 'blocker=unknown_app in hr.fn_app_level';
  end if;
  if v_claims is null or (v_claims::jsonb)->>'role' = 'service_role' then
    return case when v_switch then 'yes' else 'edit' end;
  end if;
  v_emp := hr.fn_access_caller();
  if v_emp is null then return case when v_switch then 'no' else 'none' end; end if;
  select f.level into v_lvl from hr.fn_effective_access(v_emp) f where f.app = p_app;
  return coalesce(v_lvl, case when v_switch then 'no' else 'none' end);
end $function$;

-- The check other functions call: passes while the app is not checked yet (mode off or watch), refuses in plain words
-- when it is on and the caller's level is below what the action needs.
CREATE FUNCTION hr.fn_require_app(p_app text, p_level text) RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
declare v_mode text; v_name text; v_lvl text;
begin
  select a.mode, coalesce(p.name, a.name) into v_mode, v_name from hr.access_apps a left join hr.access_apps p on p.app = a.parent where a.app = p_app;
  if v_mode is null then
    raise exception 'Unknown app "%".', p_app using errcode = '22023', detail = 'blocker=unknown_app in hr.fn_require_app';
  end if;
  if v_mode <> 'on' then return; end if;
  v_lvl := hr.fn_app_level(p_app);
  if hr.fn_access_rank(v_lvl) < hr.fn_access_rank(p_level) then
    raise exception 'You do not have access to do this in %. Ask Fred or Yannick to change it.', v_name
      using errcode = '42501', detail = 'blocker=no_access app=' || p_app || ' needs=' || p_level || ' has=' || coalesce(v_lvl, 'none');
  end if;
end $function$;

-- The admin who may change access, by Appendix A's rule.
CREATE FUNCTION hr.fn_require_access_admin() RETURNS bigint LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
declare v_emp bigint := hr.fn_access_caller();
begin
  if v_emp is null then
    raise exception 'Your sign-in is not linked to one active person in the HR App, so it cannot let you do this.'
      using errcode = '42501', detail = 'blocker=no_employee_row in hr access';
  end if;
  if not exists (select 1 from public.employees e where e.id = v_emp and e.access_level = 'admin') then
    raise exception 'Only an admin can change access.' using errcode = '42501', detail = 'blocker=level in hr access';
  end if;
  return v_emp;
end $function$;

-- A person has a sign-in = a confirmed sign-in with their email.
CREATE FUNCTION hr.fn_has_sign_in(p_email text) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
  select exists (select 1 from auth.users u where u.email_confirmed_at is not null and nullif(btrim(p_email), '') is not null
                   and lower(btrim(u.email)) = lower(btrim(p_email)))
$function$;

CREATE FUNCTION hr.fn_access_version(p_employee_id bigint) RETURNS text LANGUAGE sql STABLE SET search_path TO '' AS $function$
  select md5(coalesce((select coalesce(e.access_level, 'field') from public.employees e where e.id = p_employee_id), '') || '|' ||
             coalesce((select string_agg(o.app || '=' || o.level, ',' order by o.app) from hr.access_overrides o where o.employee_id = p_employee_id), ''))
$function$;

CREATE FUNCTION hr.fn_defaults_version() RETURNS text LANGUAGE sql STABLE SET search_path TO '' AS $function$
  select md5(coalesce(string_agg(d.grp || '.' || d.app || '=' || d.level, ',' order by d.grp, d.app), '')) from hr.access_group_defaults d
$function$;

-- Active admins who can really sign in (one confirmed sign-in with their email)
CREATE FUNCTION hr.fn_active_admins(p_except bigint) RETURNS integer LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
  select count(*)::int from public.employees e
   where e.access_level = 'admin' and e.status = 'ACTIVE' and e.id is distinct from p_except
     and (select count(*) from auth.users u where u.email_confirmed_at is not null and lower(btrim(u.email)) = lower(btrim(e.email))) = 1
$function$;

-- ===== 5. What the apps call
-- The caller's own access (any signed-in staff): drives each app's no-access screen and greyed buttons.
CREATE FUNCTION hr.get_my_access() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
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

-- One person's access for the dialog (admins only).
CREATE FUNCTION hr.get_access(p_employee_id bigint) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
declare v_caller bigint := hr.fn_require_access_admin(); v_e public.employees;
begin
  select * into v_e from public.employees where id = p_employee_id;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_employee_id;
  end if;
  return jsonb_build_object(
    'person', jsonb_build_object('id', v_e.id, 'name', v_e.full_name, 'status', v_e.status, 'group', coalesce(v_e.access_level, 'field'),
                                 'has_sign_in', hr.fn_has_sign_in(v_e.email)),
    'viewer', jsonb_build_object('employee_id', v_caller, 'is_self', v_e.id = v_caller, 'can_edit', v_e.id <> v_caller and v_e.status = 'ACTIVE'),
    'apps', (select jsonb_agg(jsonb_build_object('app', f.app, 'name', f.name, 'parent', f.parent, 'needs', f.needs, 'mode', f.mode,
                       'group_default', f.group_default, 'own', f.own, 'level', f.level,
                       'own_set_by', hr.fn_person_label(o.set_by_email), 'own_set_at', o.set_at) order by f.sort)
               from hr.fn_effective_access(v_e.id) f left join hr.access_overrides o on o.employee_id = v_e.id and o.app = f.app),
    'active_admins_other_than_this_person', hr.fn_active_admins(v_e.id),
    'version', hr.fn_access_version(v_e.id));
end $function$;

-- The Access tab (admins only): apps, the group defaults, the people, the last default change.
CREATE FUNCTION hr.get_access_overview() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO '' AS $function$
declare v_caller bigint := hr.fn_require_access_admin();
begin
  return jsonb_build_object(
    'apps', (select jsonb_agg(jsonb_build_object('app', a.app, 'name', a.name, 'parent', a.parent, 'needs', a.needs, 'mode', a.mode, 'on_since', a.on_since) order by a.sort) from hr.access_apps a),
    'defaults', (select jsonb_agg(jsonb_build_object('group', d.grp, 'app', d.app, 'level', d.level) order by d.grp, a.sort)
                   from hr.access_group_defaults d join hr.access_apps a on a.app = d.app),
    'people', (select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.full_name, 'group', coalesce(e.access_level, 'field'),
                       'has_sign_in', hr.fn_has_sign_in(e.email), 'is_self', e.id = v_caller,
                       'custom', (select count(*) from hr.access_overrides o where o.employee_id = e.id)) order by e.full_name)
                 from public.employees e where e.status = 'ACTIVE'),
    'last_change', (select jsonb_build_object('at', l.changed_at, 'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'), 'Changed outside the apps'),
                            'group', l.new_row->>'grp', 'app', (select a.name from hr.access_apps a where a.app = l.new_row->>'app'),
                            'old', hr.fn_access_label(l.old_row->>'level'), 'new', hr.fn_access_label(l.new_row->>'level'))
                      from audit.logs l
                     where l.table_schema = 'hr' and l.table_name = 'access_group_defaults' and l.operation = 'UPDATE'
                       and (l.old_row->>'level') is distinct from (l.new_row->>'level')
                     order by l.id desc limit 1),
    'version', hr.fn_defaults_version());
end $function$;

-- Change one person's group and own settings (admins only, never their own). p_levels: {app: level | null}; null =
-- back to the group default (Reset). An HR App own setting may lower the person's group level, never raise it.
CREATE FUNCTION hr.set_access(p_employee_id bigint, p_group text, p_levels jsonb, p_expected_version text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
declare
  v_caller bigint; v_e public.employees; v_grp text; v_new_grp text; k text; v_val text; v_app hr.access_apps; v_def text;
  v_email text;
begin
  v_caller := hr.fn_require_access_admin();
  perform pg_advisory_xact_lock(hashtext('hr.access'));
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

-- Change group defaults (admins only). p_changes: [{group, app, level}]. Own settings are never touched.
CREATE FUNCTION hr.set_group_access(p_changes jsonb, p_expected_version text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
declare v_caller bigint; c jsonb; v_app hr.access_apps; v_grp text; v_val text;
begin
  v_caller := hr.fn_require_access_admin();
  perform pg_advisory_xact_lock(hashtext('hr.access'));
  if p_expected_version is distinct from hr.fn_defaults_version() then
    raise exception 'Someone else changed the group defaults while you were editing. Nothing was saved.'
      using errcode = '40001', detail = 'blocker=stale_version';
  end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'array' or jsonb_array_length(p_changes) = 0 then
    raise exception 'Nothing to save.' using errcode = '22023', detail = 'blocker=changes_shape';
  end if;
  for c in select * from jsonb_array_elements(p_changes) loop
    v_grp := c->>'group'; v_val := c->>'level';
    if v_grp not in ('office', 'field') then
      raise exception 'Only the Office and Field defaults can be changed; admins have everything. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=group_value';
    end if;
    select * into v_app from hr.access_apps a where a.app = c->>'app';
    if not found then
      raise exception 'Unknown app "%". Nothing was saved.', c->>'app' using errcode = '22023', detail = 'blocker=unknown_app';
    end if;
    if (v_app.parent is null and v_val not in ('none', 'view', 'edit')) or (v_app.parent is not null and v_val not in ('no', 'yes')) then
      raise exception 'That is not a level for %. Nothing was saved.', v_app.name using errcode = '22023', detail = 'blocker=level_value';
    end if;
    update hr.access_group_defaults d set level = v_val where d.grp = v_grp and d.app = v_app.app and d.level is distinct from v_val;
  end loop;
  return hr.get_access_overview();
end $function$;

REVOKE ALL ON FUNCTION hr.fn_access_rank(text), hr.fn_access_label(text), hr.fn_effective_access(bigint), hr.fn_access_caller(),
  hr.fn_require_access_admin(), hr.fn_has_sign_in(text), hr.fn_access_version(bigint), hr.fn_defaults_version(), hr.fn_active_admins(bigint)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION hr.fn_app_level(text), hr.fn_require_app(text, text), hr.get_my_access(), hr.get_access(bigint),
  hr.get_access_overview(), hr.set_access(bigint, text, jsonb, text), hr.set_group_access(jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.fn_app_level(text), hr.fn_require_app(text, text), hr.get_my_access(), hr.get_access(bigint),
  hr.get_access_overview(), hr.set_access(bigint, text, jsonb, text), hr.set_group_access(jsonb, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION hr.get_employee_record(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_level text; v_e public.employees; v_pay boolean;
  v_today date := (now() at time zone 'America/New_York')::date;
  v_rates jsonb; v_history jsonb; v_weeks jsonb; v_activity jsonb; v_company jsonb; v_bonus jsonb;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;
  select * into v_e from public.employees where id = p_id;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_id;
  end if;
  v_pay := v_level = 'admin';

  v_company := jsonb_build_object(
    'per_visit_bonus', (select r.amount from hr.fn_rate_on(p_id, 'per_visit_bonus', v_today) r),
    'per_shift_bonus', (select r.amount from hr.fn_rate_on(p_id, 'per_shift_bonus', v_today) r));

  -- 2026-10-19_1200: this person's own bonus amounts (admin and office), with the next scheduled change
  select jsonb_object_agg(k.kind, jsonb_build_object(
           'amount', r.amount,
           'since', p.effective_from,
           'next', (select jsonb_build_object('amount', n.amount, 'effective_from', n.effective_from)
                      from hr.pay_rates n where n.employee_id = p_id and n.kind = k.kind and n.effective_from > v_today
                     order by n.effective_from, n.id desc limit 1)))
    into v_bonus
    from unnest(array['per_visit_bonus', 'per_shift_bonus']) k(kind)
    cross join lateral hr.fn_rate_on(p_id, k.kind, v_today) r
    left join hr.pay_rates p on p.id = r.rate_id;

  if v_pay then
    select coalesce(jsonb_agg(x order by x->>'kind'), '[]'::jsonb) into v_rates from (
      select jsonb_build_object('kind', k.kind, 'amount', r.amount, 'effective_from', p.effective_from,
                                'reason', p.reason, 'set_by', hr.fn_person_label(p.created_by_email)) x
        from unnest(array['hourly', 'salary_weekly', 'salary_yearly']) k(kind)
        cross join lateral hr.fn_rate_on(p_id, k.kind, v_today) r
        left join hr.pay_rates p on p.id = r.rate_id
       where r.amount is not null) s;
  end if;

  -- One history list, newest first: rate changes (admin only) and bonuses (admin and office)
  select coalesce(jsonb_agg(h order by (h->>'date') desc, (h->>'sort_at') desc, (h->>'id')::bigint desc), '[]'::jsonb) into v_history from (
    -- 2026-10-19_1815 (Fred): pay rate changes are shown in Activity, never in this history table
    select jsonb_build_object(
      'id', g.id, 'type', case when g.rule = 'reversal' then 'reversal' else g.kind end,
      'date', g.work_date, 'sort_at', g.created_at,
      'title', case when g.rule = 'reversal' then 'Bonus taken back'
                    when g.kind = 'visit_bonus' then 'Visit bonus' else 'Shift bonus' end,
      'amount', g.amount, 'unit', null,
      'detail', concat_ws(' · ',
                  case when g.kind = 'visit_bonus' then concat_ws(' ', c.client_code, c.name) else 'Shift forms of ' || to_char(g.work_date, 'Mon FMDD') end,
                  case when g.crew_size > 1 then 'shared visit, ' || g.crew_size || ' on the crew' end,
                  g.note),
      'by', coalesce(hr.fn_person_label(g.decided_by_email), case when g.rule = 'reversal' then 'System' end),
      'decided_at', g.decided_at,
      'source', 'Admin Review',
      'link', case when g.kind = 'visit_bonus' then '/review/' || g.visit_id
                   else '/review-shift/shift-' || g.employee_id || '-' || to_char(g.work_date, 'YYYY-MM-DD') end,
      'reversed', exists (select 1 from hr.bonus_events r where r.reverses_id = g.id),
      -- 2026-10-19_0215: structured fields (additive; the keys above are unchanged)
      'bonus_kind', g.kind, 'rule', g.rule, 'visit_id', g.visit_id,
      'client_code', c.client_code, 'client_name', c.name,
      'crew_size', g.crew_size,
      'shared_with', (select jsonb_agg(e2.full_name order by e2.full_name)
                        from hr.bonus_events b2 join public.employees e2 on e2.id = b2.employee_id
                       where g.visit_id is not null and b2.visit_id = g.visit_id and b2.employee_id <> g.employee_id
                         and b2.kind = 'visit_bonus' and b2.reverses_id is null
                         and not exists (select 1 from hr.bonus_events r2 where r2.reverses_id = b2.id)),
      'note', g.note,
      'decided_on', (g.decided_at at time zone 'America/New_York')::date, 'decided_time', to_char(g.decided_at at time zone 'America/New_York', 'HH24:MI'),
      'recorded_on', (g.created_at at time zone 'America/New_York')::date,
      'week_start', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6,
      'reverses_id', g.reverses_id,
      'reversed_on', (select (r.created_at at time zone 'America/New_York')::date from hr.bonus_events r where r.reverses_id = g.id order by r.id limit 1),
      'after_week_ended', case when g.rule = 'reversal'
                               then (g.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6
                               else (select (r.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6
                                       from hr.bonus_events r where r.reverses_id = g.id order by r.id limit 1) end,
      'counts_in_total', true,
      'admin_review_url', hr.fn_admin_review_url(g.kind, g.visit_id, g.employee_id, g.work_date),
      -- 2026-10-19_1900 (Fred): every row says its status
      'status', case when g.rule = 'reversal' then 'taken_back' else 'approved' end) h
      from hr.bonus_events g
      left join public.visits v on v.id = g.visit_id
      left join public.clients c on c.id = v.client_id
     where g.employee_id = p_id
    -- 2026-10-19_1900 (Fred): the bonuses not recorded in HR, so the table shows every bonus with its status.
    -- Pending: what Admin Review still has to decide (the same scope as hr.fn_pending_bonus), priced at the person's
    -- rate on the work date. Rejected: a decision of "not eligible", $0, with Admin Review's reason. Neither counts in
    -- a total. Ids are negative (visits: -visit_id; shifts: -(1000000 + days since 2020-01-01)) so a row key never
    -- equals a recorded bonus id.
    union all
    select jsonb_build_object(
      'id', -v.id, 'type', 'visit_bonus', 'date', v.visit_date, 'sort_at', v.completed_at,
      'title', 'Visit bonus', 'amount', case when coalesce(v.bonus_status, 'pending') = 'pending' then coalesce(r.amount, 0) else 0 end,
      'detail', concat_ws(' ', c.client_code, c.name),
      'by', case when v.bonus_status = 'denied' then coalesce(hr.fn_person_label(rj.email), 'Admin Review') end,
      'decided_at', case when v.bonus_status = 'denied' then vr.bonus_decided_at end,
      'link', '/review/' || v.id,
      'bonus_kind', 'visit_bonus', 'rule', case when v.bonus_status = 'denied' then 'denied' else 'pending' end,
      'visit_id', v.id, 'client_code', c.client_code, 'client_name', c.name,
      'crew_size', (select count(*) from public.visit_team t2 where t2.visit_id = v.id),
      'shared_with', (select jsonb_agg(e2.full_name order by e2.full_name) from public.visit_team t2
                        join public.employees e2 on e2.id = t2.employee_id where t2.visit_id = v.id and t2.employee_id <> p_id),
      'note', case when v.bonus_status = 'denied' then vr.bonus_denial_note end,
      'decided_on', case when v.bonus_status = 'denied' then (vr.bonus_decided_at at time zone 'America/New_York')::date end,
      'decided_time', case when v.bonus_status = 'denied' then to_char(vr.bonus_decided_at at time zone 'America/New_York', 'HH24:MI') end,
      'week_start', hr.fn_payroll_week_start(v.visit_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(v.visit_date, v_e.payroll_week_start_day) + 6,
      'admin_review_url', hr.fn_admin_review_url('visit_bonus', v.id, p_id, v.visit_date),
      'status', case when v.bonus_status = 'denied' then 'rejected' else 'pending' end)
      || jsonb_build_object(
      'unit', null, 'source', 'Admin Review', 'reversed', false, 'reverses_id', null, 'reversed_on', null,
      'after_week_ended', false, 'counts_in_total', false, 'recorded_on', null) h
      from public.visits_with_review v
      join public.visit_team t on t.visit_id = v.id and t.employee_id = p_id
      left join public.visit_reviews vr on vr.visit_id = v.id
      left join public.clients c on c.id = v.client_id
      left join lateral hr.fn_rate_on(p_id, 'per_visit_bonus', v.visit_date) r on true
      left join lateral (select lower(btrim(nullif(a.jwt_claims->>'email', ''))) as email from audit.logs a
                          where a.table_name = 'visit_reviews' and a.record_pk = jsonb_build_object('visit_id', v.id)
                            and a.new_row->>'bonus_status' = 'denied'
                            and (a.old_row is null or a.old_row->>'bonus_status' is distinct from 'denied')
                          order by a.id desc limit 1) rj on v.bonus_status = 'denied'
     where v.visit_status = 'completed' and not public.fn_is_non_customer(v.client_id)
       and ((coalesce(v.bonus_status, 'pending') = 'pending' and v.in_review_scope and v.visit_date <= v_today)
            or v.bonus_status = 'denied')
    union all
    select jsonb_build_object(
      'id', -(1000000 + (x.shift_date - date '2020-01-01')), 'type', 'shift_bonus', 'date', x.shift_date, 'sort_at', x.shift_date::timestamptz,
      'title', 'Shift bonus', 'amount', case when x.status = 'pending' then coalesce(r.amount, 0) else 0 end,
      'detail', 'Shift forms of ' || to_char(x.shift_date, 'Mon FMDD'),
      'by', case when x.status = 'rejected' then coalesce(hr.fn_person_label(rj.email), 'Admin Review') end,
      'decided_at', x.decided_at, 'link', '/review-shift/shift-' || p_id || '-' || to_char(x.shift_date, 'YYYY-MM-DD'),
      'bonus_kind', 'shift_bonus', 'rule', case when x.status = 'rejected' then 'denied' else 'pending' end,
      'visit_id', null, 'client_code', null, 'client_name', null, 'crew_size', null, 'shared_with', null,
      'note', x.note,
      'decided_on', (x.decided_at at time zone 'America/New_York')::date,
      'decided_time', to_char(x.decided_at at time zone 'America/New_York', 'HH24:MI'),
      'week_start', hr.fn_payroll_week_start(x.shift_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(x.shift_date, v_e.payroll_week_start_day) + 6,
      'admin_review_url', hr.fn_admin_review_url('shift_bonus', null, p_id, x.shift_date),
      'status', x.status)
      || jsonb_build_object(
      'unit', null, 'source', 'Admin Review', 'reversed', false, 'reverses_id', null, 'reversed_on', null,
      'after_week_ended', false, 'counts_in_total', false, 'recorded_on', null) h
      from (
        -- pending: the shifts of the last 28 days with both forms and no issue, not decided (as hr.fn_pending_bonus)
        select s.shift_date, 'pending'::text as status, null::timestamptz as decided_at, null::text as note
          from (select i.shift_date from public.inspections i
                 where i.employee_id = p_id and i.shift_date >= v_today - 28 and i.shift_date <= v_today
                 group by i.shift_date
                having bool_or(i.inspection_type = 'PRE') and bool_or(i.inspection_type = 'POST')
                   and not bool_or(coalesce(i.has_issue, false))) s
         where not exists (select 1 from public.shift_reviews sr where sr.employee_id = p_id and sr.shift_date = s.shift_date
                             and coalesce(sr.bonus_status, 'pending') <> 'pending')
        union all
        select sr.shift_date, 'rejected', sr.bonus_decided_at, sr.bonus_denial_note
          from public.shift_reviews sr where sr.employee_id = p_id and sr.bonus_status = 'denied'
      ) x
      left join lateral hr.fn_rate_on(p_id, 'per_shift_bonus', x.shift_date) r on true
      left join lateral (select lower(btrim(nullif(a.jwt_claims->>'email', ''))) as email from audit.logs a
                          where a.table_name = 'shift_reviews'
                            and a.record_pk = jsonb_build_object('employee_id', p_id, 'shift_date', to_char(x.shift_date, 'YYYY-MM-DD'))
                            and a.new_row->>'bonus_status' = 'denied'
                            and (a.old_row is null or a.old_row->>'bonus_status' is distinct from 'denied')
                          order by a.id desc limit 1) rj on x.status = 'rejected'
  ) s;

  select coalesce(jsonb_agg(w order by w->>'week_start' desc), '[]'::jsonb) into v_weeks from (
    select jsonb_build_object('week_start', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day),
                              'week_end', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6,
                              'total', sum(g.amount),
                              'visit_bonuses', count(*) filter (where g.kind = 'visit_bonus' and g.rule <> 'reversal'),
                              'shift_bonuses', count(*) filter (where g.kind = 'shift_bonus' and g.rule <> 'reversal')) w
      from hr.bonus_events g where g.employee_id = p_id
     group by hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day)) s;

  select coalesce(jsonb_agg(a order by (a->>'at') desc, (a->>'id')::bigint desc), '[]'::jsonb) into v_activity from (
    select a from (
    select jsonb_build_object(
      'id', l.id, 'at', l.changed_at, 'operation', l.operation,
      'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'),
                     case when l.app_source is null then 'Not recorded'
                          when l.app_source = 'sql' then 'Changed outside the apps'
                          when l.app_source = 'employee-dedup-merge' then 'Duplicate clean-up'
                          when l.app_source = 'hr-app' then 'HR App'
                          when l.app_source = 'admin-review' then 'Admin Review'
                          when l.app_source = 'visit-calendar' then 'Visit Calendar'
                          when l.app_source = 'client-app' then 'Client App'
                          when l.app_source = 'derm-tracker' then 'DERM Tracker'
                          when l.app_source = 'jobber' then 'Jobber sync'
                          else 'Another app' end),
      'app', case l.app_source when 'hr-app' then 'HR App' else null end,
      'changes', (select coalesce(jsonb_agg(jsonb_build_object('field', f.label,
                      -- 2026-10-19_2130: the payroll week is stored as a day number; Activity shows "Thu to Wed"
                      'old', case when f.col = 'payroll_week_start_day' then hr.fn_week_label((l.old_row->>f.col)::smallint) else l.old_row->>f.col end,
                      'new', case when f.col = 'payroll_week_start_day' then hr.fn_week_label((l.new_row->>f.col)::smallint) else l.new_row->>f.col end)
                                             order by f.ord), '[]'::jsonb)
                    from (values (1, 'full_name', 'Name'), (2, 'status', 'Status'), (3, 'shift', 'Shift'), (4, 'email', 'Email'),
                                 (5, 'phone', 'Phone'), (6, 'hire_date', 'Start date'), (7, 'access_level', 'Access'),
                                 (8, 'color_hex', 'Color'), (9, 'payroll_week_start_day', 'Payroll week')) f(ord, col, label)
                   where l.operation = 'INSERT' and l.new_row->>f.col is not null
                      or l.operation = 'UPDATE' and (l.old_row->>f.col) is distinct from (l.new_row->>f.col))) a
      from audit.logs l
     where l.table_name = 'employees' and l.record_pk->>'id' = p_id::text
     order by l.id desc limit 100) s
   where jsonb_array_length(a->'changes') > 0 or a->>'operation' <> 'UPDATE'
  -- 2026-10-19_1815 (Fred): pay rate changes are part of the person's Activity. Bonus amounts for admin and office,
  -- hourly and salary for admin only. The id is negative so it can never equal an audit row id.
  union all
  select jsonb_build_object(
      'id', -p.id, 'at', p.created_at, 'operation', 'RATE',
      'by', coalesce(hr.fn_person_label(p.created_by_email), 'Changed outside the apps'),
      'app', 'HR App',
      'changes', jsonb_build_array(
        jsonb_build_object('field', case p.kind when 'hourly' then 'Hourly rate' when 'salary_weekly' then 'Weekly salary'
                                                when 'salary_yearly' then 'Yearly salary' when 'per_visit_bonus' then 'Visit bonus'
                                                else 'Shift bonus' end,
                           'old', case when p.prev_amount is null then null else to_char(p.prev_amount, 'FM$999,999,990.00') end,
                           'new', coalesce(to_char(p.amount, 'FM$999,999,990.00'), 'Stopped')
                                  || ' from ' || to_char(p.effective_from, 'Mon FMDD, YYYY')),
        jsonb_build_object('field', 'Reason', 'old', null, 'new', p.reason))) a
    from (select p0.*, lag(p0.amount) over (partition by p0.kind order by p0.effective_from, p0.id) as prev_amount
            from hr.pay_rates p0 where p0.employee_id = p_id) p
   where p.kind in ('per_visit_bonus', 'per_shift_bonus') or v_pay
  -- 2026-10-19_2145: a change to this person's own access settings ("Visit Calendar: Group default -> View")
  union all
  select jsonb_build_object(
      'id', l.id, 'at', l.changed_at, 'operation', 'ACCESS',
      'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'), 'Changed outside the apps'),
      'app', 'HR App',
      'changes', jsonb_build_array(jsonb_build_object(
        'field', coalesce(ap.name, coalesce(l.new_row, l.old_row)->>'app'),
        'old', case when l.operation = 'INSERT' then 'Group default' else hr.fn_access_label(l.old_row->>'level') end,
        'new', case when l.operation = 'DELETE' then 'Group default' else hr.fn_access_label(l.new_row->>'level') end))) a
    from audit.logs l
    left join hr.access_apps ap on ap.app = coalesce(l.new_row, l.old_row)->>'app'
   where l.table_schema = 'hr' and l.table_name = 'access_overrides'
     and coalesce(l.new_row, l.old_row)->>'employee_id' = p_id::text
     and (l.operation <> 'UPDATE' or (l.old_row->>'level') is distinct from (l.new_row->>'level'))
  ) s2;

  return jsonb_build_object(
    'employee', hr.fn_employee_json(v_e),
    'viewer', jsonb_build_object('level', v_level, 'can_edit', true, 'can_see_pay', v_pay, 'is_self', v_e.id = v_caller,
                                 -- 2026-10-19_2145 (decision 10): access follows the email, so only an admin changes email or status
                                 'can_change_email_status', v_e.id <> v_caller and v_level = 'admin',
                                 -- 2026-10-19_2130: only an admin changes a person's payroll week (hr.set_payroll_week)
                                 'can_set_payroll_week', v_pay),
    'impact_if_inactive', hr.fn_employee_impact(p_id),
    'company_bonus', v_company,
    'bonus_amounts', v_bonus,
    'rates', v_rates,
    'history', v_history,
    'bonus_weeks', v_weeks,
    'activity', v_activity);
end $function$;

CREATE OR REPLACE FUNCTION hr.update_employee(p_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_level text;
  v_row public.employees; v_new public.employees;
  v_bad text[]; v_changed text[] := '{}'; v_txt text; v_other text; v_date date;
  v_today date := (now() at time zone 'America/New_York')::date;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'Nothing to save.' using errcode = '22023', detail = 'blocker=patch_shape in hr.update_employee';
  end if;
  select array_agg(k order by k) into v_bad from jsonb_object_keys(p_patch) k
   where k not in ('full_name', 'status', 'shift', 'email', 'phone', 'hire_date');
  if v_bad is not null then
    raise exception 'These fields cannot be changed here: %.', array_to_string(v_bad, ', ')
      using errcode = '22023', detail = 'blocker=field_not_editable in hr.update_employee';
  end if;

  select * into v_row from public.employees where id = p_id for update;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_id;
  end if;
  v_new := v_row;

  if p_patch ? 'full_name' then
    v_txt := btrim(coalesce(p_patch->>'full_name', ''));
    if v_txt = '' then
      raise exception 'The name cannot be empty. Nothing was saved.' using errcode = '22023', detail = 'blocker=name_empty';
    end if;
    if length(v_txt) > 80 then
      raise exception 'The name is too long (80 characters at most). Nothing was saved.' using errcode = '22023', detail = 'blocker=name_long';
    end if;
    select e.full_name into v_other from public.employees e
     where lower(btrim(e.full_name)) = lower(v_txt) and e.id <> p_id limit 1;
    if v_other is not null then
      raise exception 'Another person already has the name "%". Nothing was saved.', btrim(v_other)
        using errcode = '23505', detail = 'blocker=name_taken';
    end if;
    v_new.full_name := v_txt;
  end if;

  if p_patch ? 'status' then
    v_txt := upper(btrim(coalesce(p_patch->>'status', '')));
    if v_txt not in ('ACTIVE', 'INACTIVE') then
      raise exception 'Status must be Active or Inactive. Nothing was saved.' using errcode = '22023', detail = 'blocker=status_value';
    end if;
    v_new.status := v_txt;
  end if;

  if p_patch ? 'shift' then
    v_txt := lower(btrim(coalesce(p_patch->>'shift', '')));
    if v_txt = '' then v_new.shift := null;
    elsif v_txt in ('day', 'night') then v_new.shift := v_txt;
    else
      raise exception 'Shift must be Day, Night or empty. Nothing was saved.' using errcode = '22023', detail = 'blocker=shift_value';
    end if;
  end if;

  if p_patch ? 'email' then
    v_txt := lower(btrim(coalesce(p_patch->>'email', '')));
    if v_txt = '' then v_new.email := null;
    else
      if v_txt !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
        raise exception 'That email does not look right. Nothing was saved.' using errcode = '22023', detail = 'blocker=email_format';
      end if;
      select e.full_name into v_other from public.employees e
       where lower(btrim(e.email)) = v_txt and e.id <> p_id limit 1;
      if v_other is not null then
        raise exception 'That email already belongs to %. Nothing was saved.', btrim(v_other)
          using errcode = '23505', detail = 'blocker=email_taken';
      end if;
      v_new.email := v_txt;
    end if;
  end if;

  if p_patch ? 'phone' then
    v_txt := btrim(coalesce(p_patch->>'phone', ''));
    if v_txt = '' then v_new.phone := null;
    else
      if length(v_txt) > 40 then
        raise exception 'The phone number is too long. Nothing was saved.' using errcode = '22023', detail = 'blocker=phone_long';
      end if;
      if v_txt !~ '[0-9]' then
        raise exception 'The phone number has no digits. Nothing was saved.' using errcode = '22023', detail = 'blocker=phone_format';
      end if;
      v_new.phone := v_txt;
    end if;
  end if;

  if p_patch ? 'hire_date' then
    v_txt := btrim(coalesce(p_patch->>'hire_date', ''));
    if v_txt = '' then v_new.hire_date := null;
    else
      begin
        v_date := v_txt::date;
      exception when others then
        raise exception 'The hire date is not a date. Nothing was saved.' using errcode = '22023', detail = 'blocker=hire_date_format';
      end;
      if v_date < date '1990-01-01' or v_date > v_today + 366 then
        raise exception 'The hire date is out of range. Nothing was saved.' using errcode = '22023', detail = 'blocker=hire_date_range';
      end if;
      v_new.hire_date := v_date;
    end if;
  end if;

  if v_new.full_name is distinct from v_row.full_name then v_changed := array_append(v_changed, 'full_name'); end if;
  if v_new.status    is distinct from v_row.status    then v_changed := array_append(v_changed, 'status'); end if;
  if v_new.shift     is distinct from v_row.shift     then v_changed := array_append(v_changed, 'shift'); end if;
  if v_new.email     is distinct from v_row.email     then v_changed := array_append(v_changed, 'email'); end if;
  if v_new.phone     is distinct from v_row.phone     then v_changed := array_append(v_changed, 'phone'); end if;
  if v_new.hire_date is distinct from v_row.hire_date then v_changed := array_append(v_changed, 'hire_date'); end if;

  if cardinality(v_changed) = 0 then
    return jsonb_build_object('noop', true, 'employee', hr.fn_employee_json(v_row), 'changed', '[]'::jsonb);
  end if;

  -- Rights. Email and status decide who the HR App lets in, so they are guarded.
  if 'email' = any (v_changed) or 'status' = any (v_changed) then
    if p_id = v_caller then
      raise exception 'You cannot change your own email or status. Ask an admin to do it.'
        using errcode = '42501', detail = 'blocker=own_row';
    end if;
    -- 2026-10-19_2145 (Fred, decision 10): access follows the email, so only an admin changes anyone's email or status
    if v_level <> 'admin' then
      raise exception 'Only an admin can change a person''s email or status.'
        using errcode = '42501', detail = 'blocker=rights_row';
    end if;
    perform pg_advisory_xact_lock(hashtext('hr.access'));   -- the same lock as hr.set_access, before the admin count
  end if;
  if v_new.status = 'ACTIVE' and v_row.status is distinct from 'ACTIVE'
     and not exists (select 1 from public.entity_source_links l
                      where l.entity_type = 'employee' and l.source_system = 'jobber' and l.entity_id = p_id) then
    raise exception 'This person is not linked to their Jobber user, so they cannot be made Active. Nothing was saved.'
      using errcode = '22023', detail = 'blocker=no_jobber_link';
  end if;
  if v_row.access_level = 'admin' and v_row.status = 'ACTIVE' and v_new.status = 'INACTIVE'
     and not exists (select 1 from public.employees e where e.access_level = 'admin' and e.status = 'ACTIVE' and e.id <> p_id) then
    raise exception 'There must always be one active admin. Nothing was saved.' using errcode = '22023', detail = 'blocker=last_admin';
  end if;

  update public.employees
     set full_name = v_new.full_name, status = v_new.status, shift = v_new.shift,
         email = v_new.email, phone = v_new.phone, hire_date = v_new.hire_date
   where id = p_id
  returning * into v_new;

  return jsonb_build_object('noop', false, 'employee', hr.fn_employee_json(v_new),
    'changed', to_jsonb(v_changed), 'impact', hr.fn_employee_impact(p_id));
end $function$;

-- VERIFY (inside the transaction; any failure rolls the whole migration back)
DO $verify$
DECLARE
  u_fred text := '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b'; u_yan text := '71e294b9-9898-4c21-a48d-d970e32d829c';
  u_aaron text := '77d4c343-1e21-44eb-98ce-c221028d028a'; u_diego text := 'cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8';
  j jsonb; v text; v_n int; v_ok boolean; v_det text; v_ver text;
  c_fred text; c_aaron text; c_diego text; c_anon text := '{"role":"anon"}'; c_svc text := '{"role":"service_role"}';
BEGIN
  c_fred := json_build_object('sub', u_fred, 'email', 'fred@ayache.com', 'role', 'authenticated')::text;
  c_aaron := json_build_object('sub', u_aaron, 'email', 'aaron@unclogme.com', 'role', 'authenticated')::text;
  c_diego := json_build_object('sub', u_diego, 'email', 'contact@unclogme.com', 'role', 'authenticated')::text;

  -- 1. the stored settings
  IF (SELECT count(*) FROM hr.access_apps) <> 10 OR (SELECT count(*) FROM hr.access_group_defaults) <> 20
     OR (SELECT count(*) FROM hr.access_overrides) <> 2 OR (SELECT count(*) FROM hr.access_apps WHERE mode <> 'off') <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1a: the seed is not as intended';
  END IF;
  SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'hr' AND c.relname IN ('access_apps', 'access_group_defaults', 'access_overrides')
     AND (has_table_privilege('anon', c.oid, 'SELECT') OR has_table_privilege('authenticated', c.oid, 'SELECT')
          OR has_table_privilege('authenticated', c.oid, 'INSERT') OR has_table_privilege('authenticated', c.oid, 'UPDATE')
          OR has_table_privilege('authenticated', c.oid, 'DELETE') OR has_table_privilege('service_role', c.oid, 'SELECT'));
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1b: % access tables are reachable by an app role', v_n; END IF;
  IF (SELECT count(*) FROM pg_trigger WHERE tgname IN ('audit_access_apps', 'audit_access_group_defaults', 'audit_access_overrides')) <> 3 THEN
    RAISE EXCEPTION 'VERIFY 1c: an audit trigger is missing';
  END IF;

  -- 2. everyone's access equals today
  SELECT count(*) INTO v_n FROM public.employees e CROSS JOIN LATERAL hr.fn_effective_access(e.id) f
   WHERE f.level IS DISTINCT FROM CASE
           WHEN e.status <> 'ACTIVE' THEN CASE WHEN f.parent IS NULL THEN 'none' ELSE 'no' END
           WHEN e.access_level = 'admin' THEN CASE WHEN f.parent IS NULL THEN 'edit' ELSE 'yes' END
           WHEN e.access_level = 'office' THEN CASE f.app WHEN 'hr_pay' THEN 'no' WHEN 'hr_bonus' THEN 'yes'
                                                   WHEN 'pp_approve' THEN CASE WHEN e.id IN (28, 42) THEN 'yes' ELSE 'no' END
                                                   ELSE 'edit' END
           ELSE CASE WHEN f.parent IS NULL THEN 'none' ELSE 'no' END END;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 2a: % app levels differ from today', v_n; END IF;
  -- the approvers by the new rule are exactly today's list
  IF (SELECT array_agg(u.id ORDER BY u.id) FROM auth.users u JOIN public.employees e ON e.status = 'ACTIVE' AND lower(btrim(e.email)) = lower(btrim(u.email))
       CROSS JOIN LATERAL hr.fn_effective_access(e.id) f WHERE f.app = 'pp_approve' AND f.level = 'yes' AND u.email_confirmed_at IS NOT NULL)
     IS DISTINCT FROM (SELECT array_agg(x ORDER BY x) FROM unnest(public.fn_page_approver_ids()) x) THEN
    RAISE EXCEPTION 'VERIFY 2b: the Approve site files switch does not match today''s approver list';
  END IF;

  -- 3. the caller lookup
  PERFORM set_config('request.jwt.claims', c_fred, true);
  IF hr.fn_app_level('hr') <> 'edit' OR hr.fn_app_level('hr_pay') <> 'yes' THEN RAISE EXCEPTION 'VERIFY 3a: Fred is not everything'; END IF;
  PERFORM set_config('request.jwt.claims', c_aaron, true);
  IF hr.fn_app_level('hr') <> 'edit' OR hr.fn_app_level('hr_pay') <> 'no' OR hr.fn_app_level('hr_bonus') <> 'yes' OR hr.fn_app_level('pp_approve') <> 'no' THEN
    RAISE EXCEPTION 'VERIFY 3b: Aaron is not Office';
  END IF;
  j := hr.get_my_access();
  IF j->>'group' <> 'office' OR jsonb_array_length(j->'apps') <> 10 THEN RAISE EXCEPTION 'VERIFY 3c: get_my_access for Aaron'; END IF;
  PERFORM set_config('request.jwt.claims', c_diego, true);
  IF hr.fn_app_level('pp_approve') <> 'yes' THEN RAISE EXCEPTION 'VERIFY 3d: Diego lost Approve site files'; END IF;
  PERFORM set_config('request.jwt.claims', c_anon, true);
  IF hr.fn_app_level('hr') <> 'none' OR hr.fn_app_level('hr_bonus') <> 'no' THEN RAISE EXCEPTION 'VERIFY 3e: no sign-in is not nothing'; END IF;
  PERFORM set_config('request.jwt.claims', c_svc, true);
  IF hr.fn_app_level('hr') <> 'edit' THEN RAISE EXCEPTION 'VERIFY 3f: the server key is not everything'; END IF;
  PERFORM set_config('request.jwt.claims', '', true);
  IF hr.fn_app_level('hr') <> 'edit' THEN RAISE EXCEPTION 'VERIFY 3g: timed jobs are not everything'; END IF;

  -- 4. the check passes while an app is off, refuses when on (then undone)
  PERFORM set_config('request.jwt.claims', c_aaron, true);
  PERFORM hr.fn_require_app('hr_pay', 'yes');   -- off: passes
  v_ok := false;
  BEGIN
    UPDATE hr.access_apps SET mode = 'on' WHERE app = 'hr_pay';
    BEGIN
      PERFORM hr.fn_require_app('hr_pay', 'yes');
    EXCEPTION WHEN insufficient_privilege THEN
      GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_ok := v_det LIKE 'blocker=no_access app=hr_pay%';
    END;
    PERFORM set_config('request.jwt.claims', c_fred, true);
    PERFORM hr.fn_require_app('hr_pay', 'yes');   -- Fred passes
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok OR (SELECT mode FROM hr.access_apps WHERE app = 'hr_pay') <> 'off' THEN RAISE EXCEPTION 'VERIFY 4: the on check did not refuse Aaron, or was not undone'; END IF;

  -- 5. reading one person: admins only; own page cannot be edited
  PERFORM set_config('request.jwt.claims', c_fred, true);
  j := hr.get_access(40);
  IF jsonb_array_length(j->'apps') <> 10 OR NOT (j->'viewer'->>'can_edit')::boolean OR (j->'person'->>'has_sign_in')::boolean THEN
    RAISE EXCEPTION 'VERIFY 5a: get_access for Michael';
  END IF;
  j := hr.get_access(2);
  IF NOT (j->'viewer'->>'is_self')::boolean OR (j->'viewer'->>'can_edit')::boolean THEN RAISE EXCEPTION 'VERIFY 5b: own page editable'; END IF;
  j := hr.get_access_overview();
  IF jsonb_array_length(j->'people') <> 9 OR jsonb_array_length(j->'defaults') <> 20 THEN RAISE EXCEPTION 'VERIFY 5c: overview'; END IF;
  PERFORM set_config('request.jwt.claims', c_aaron, true);
  BEGIN PERFORM hr.get_access(40); v_ok := false; EXCEPTION WHEN insufficient_privilege THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 5d: office read someone''s access'; END IF;

  -- 6. set_access (each change undone)
  PERFORM set_config('request.jwt.claims', c_fred, true);
  BEGIN PERFORM hr.set_access(2, 'office', '{}', hr.fn_access_version(2)); v_ok := false;
  EXCEPTION WHEN insufficient_privilege THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_ok := v_det = 'blocker=own_row'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 6a: an admin changed their own access'; END IF;
  BEGIN PERFORM hr.set_access(26, NULL, '{"visit_calendar":"view"}', 'stale'); v_ok := false;
  EXCEPTION WHEN serialization_failure THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 6b: a stale save went through'; END IF;
  BEGIN PERFORM hr.set_access(40, NULL, '{"hr":"view"}', hr.fn_access_version(40)); v_ok := false;
  EXCEPTION WHEN invalid_parameter_value THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_ok := v_det = 'blocker=hr_above_group'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 6c: a field person got more HR App than the group'; END IF;
  BEGIN PERFORM hr.set_access(26, NULL, '{"visit_calendar":"yes"}', hr.fn_access_version(26)); v_ok := false;
  EXCEPTION WHEN invalid_parameter_value THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 6d: a wrong level was accepted'; END IF;
  BEGIN PERFORM hr.set_access(27, NULL, '{"client_app":"view"}', hr.fn_access_version(27)); v_ok := false;
  EXCEPTION WHEN invalid_parameter_value THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 6e: an admin got an own setting'; END IF;
  v_ok := false;
  BEGIN
    j := hr.set_access(26, NULL, '{"visit_calendar":"view","pp_approve":"yes"}', hr.fn_access_version(26));
    v_ok := (SELECT f.level FROM hr.fn_effective_access(26) f WHERE f.app = 'visit_calendar') = 'view'
        AND (SELECT f.level FROM hr.fn_effective_access(26) f WHERE f.app = 'pp_approve') = 'yes'
        AND EXISTS (SELECT 1 FROM audit.logs l WHERE l.table_schema = 'hr' AND l.table_name = 'access_overrides' AND l.new_row->>'employee_id' = '26');
    j := hr.get_employee_record(26);
    v_ok := v_ok AND EXISTS (SELECT 1 FROM jsonb_array_elements(j->'activity') a, jsonb_array_elements(a->'changes') c
                              WHERE a->>'operation' = 'ACCESS' AND c->>'field' = 'Visit Calendar' AND c->>'old' = 'Group default' AND c->>'new' = 'View');
    j := hr.set_access(26, NULL, '{"visit_calendar":null}', hr.fn_access_version(26));
    v_ok := v_ok AND NOT EXISTS (SELECT 1 FROM hr.access_overrides o WHERE o.employee_id = 26 AND o.app = 'visit_calendar')
        AND (SELECT f.level FROM hr.fn_effective_access(26) f WHERE f.app = 'visit_calendar') = 'edit';
    j := hr.set_access(27, 'office', '{}', hr.fn_access_version(27));   -- Fred moves Yannick to Office
    v_ok := v_ok AND (SELECT access_level FROM public.employees WHERE id = 27) = 'office' AND hr.fn_active_admins(NULL) = 1;
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok OR (SELECT access_level FROM public.employees WHERE id = 27) <> 'admin' OR (SELECT count(*) FROM hr.access_overrides) <> 2 THEN
    RAISE EXCEPTION 'VERIFY 6f: a valid change, its Activity line, the reset or the group move failed, or was not undone';
  END IF;

  -- 7. set_group_access (undone); own settings untouched
  j := hr.get_access_overview(); v_ver := j->>'version';
  BEGIN PERFORM hr.set_group_access('[{"group":"admin","app":"hr","level":"view"}]', v_ver); v_ok := false;
  EXCEPTION WHEN invalid_parameter_value THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 7a: an Admin default was changed'; END IF;
  BEGIN PERFORM hr.set_group_access('[{"group":"office","app":"hr","level":"view"}]', 'stale'); v_ok := false;
  EXCEPTION WHEN serialization_failure THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 7b: a stale default save went through'; END IF;
  v_ok := false;
  BEGIN
    j := hr.set_group_access('[{"group":"office","app":"pp_approve","level":"yes"},{"group":"field","app":"client_app","level":"view"}]', v_ver);
    v_ok := (SELECT f.level FROM hr.fn_effective_access(26) f WHERE f.app = 'pp_approve') = 'yes'
        AND (SELECT f.level FROM hr.fn_effective_access(40) f WHERE f.app = 'client_app') = 'view'
        AND (SELECT count(*) FROM hr.access_overrides) = 2
        AND j->'last_change'->>'new' IS NOT NULL;
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok OR hr.fn_defaults_version() <> v_ver THEN RAISE EXCEPTION 'VERIFY 7c: a default change failed, or was not undone'; END IF;

  -- 8. decision 10: only an admin changes email or status
  PERFORM set_config('request.jwt.claims', c_aaron, true);
  BEGIN PERFORM hr.update_employee(40, '{"phone":"305 555 0100","email":"michael.test@example.com"}'); v_ok := false;
  EXCEPTION WHEN insufficient_privilege THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_ok := v_det = 'blocker=rights_row'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 8a: office changed a field person''s email'; END IF;
  j := hr.get_employee_record(40);
  IF (j->'viewer'->>'can_change_email_status')::boolean THEN RAISE EXCEPTION 'VERIFY 8b: office is still offered email and status'; END IF;
  PERFORM set_config('request.jwt.claims', c_fred, true);
  j := hr.get_employee_record(40);
  IF NOT (j->'viewer'->>'can_change_email_status')::boolean THEN RAISE EXCEPTION 'VERIFY 8c: admin lost email and status'; END IF;

  -- 9. who can call what
  IF has_function_privilege('anon', 'hr.set_access(bigint,text,jsonb,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'hr.get_my_access()', 'EXECUTE')
     OR has_function_privilege('anon', 'hr.fn_require_app(text,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'hr.set_access(bigint,text,jsonb,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'hr.get_access_overview()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'hr.fn_effective_access(bigint)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'hr.fn_access_caller()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'hr.fn_active_admins(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 9: a function grant is wrong';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'VERIFY 2145 passed';
END $verify$;

COMMIT;
