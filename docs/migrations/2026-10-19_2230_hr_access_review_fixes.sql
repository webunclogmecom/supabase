-- 2026-10-19_2230_hr_access_review_fixes
-- The adversarial review of 2130 / 2145 (13 findings confirmed, 0 refuted; several were the same defect seen by two lenses):
--   1. set_access, set_group_access and update_employee (when email or status is in the patch) take the hr.access lock
--      FIRST, then check who is calling, then lock the row: two admins acting at once can no longer leave no admin, and the
--      two writers no longer take the same two locks in opposite orders (deadlock).
--   2. update_employee refuses an email or status change on an active admin that would leave no active admin who can sign in.
--   3. set_group_access refuses a lowered HR App default that would leave someone's own HR App setting above it (the rule
--      set_access already enforces), and refuses a missing group or level in words instead of saving nothing or a raw 23502.
--   4. Access changes in a person's Activity are shown to admins only, like the access screens.
--   5. An admin's stored own settings are neither shown (set by / set at) nor counted as custom.
-- Bodies copied from the live definitions (md5 guarded). Rollback: 2026-10-19_rollback_hr_access_review_fixes.sql.
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $guard$
BEGIN
  IF md5(pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)) <> '299bda553af1954ccec52f1a237f2ecf' OR md5(pg_get_functiondef('hr.set_access(bigint,text,jsonb,text)'::regprocedure)) <> 'dcdecfcd75ec4919e146f6f8f7b2e0c3' OR md5(pg_get_functiondef('hr.set_group_access(jsonb,text)'::regprocedure)) <> '4cc191a51ba3e8c6e9618e73c8fee9f9' OR md5(pg_get_functiondef('hr.get_access(bigint)'::regprocedure)) <> 'd41c6dc334adadffac28fafeb4de0c08' OR md5(pg_get_functiondef('hr.get_access_overview()'::regprocedure)) <> '018d46662381ea7dbb5c07c3ac559696' OR md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)) <> 'c1c1bdbcce0b3a1c6662e05d00dbef97' THEN
    RAISE EXCEPTION 'a function changed since this migration was written; rebuild it from the live bodies';
  END IF;
END $guard$;
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
  -- 2026-10-19_2230 (review): the access lock first, then the caller check, then the row lock, in every writer
  if p_patch ? 'email' or p_patch ? 'status' then perform pg_advisory_xact_lock(hashtext('hr.access')); end if;
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;
  perform hr.fn_require_app('hr', 'edit');   -- 2026-10-19_2200

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
    if v_row.access_level = 'admin' and v_row.status = 'ACTIVE' and hr.fn_active_admins(p_id) < 1 then
      raise exception 'There must always be one active admin who can sign in. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=last_admin';
    end if;
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

CREATE OR REPLACE FUNCTION hr.get_access(p_employee_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
                       'own_set_by', case when f.own is not null then hr.fn_person_label(o.set_by_email) end,
                       'own_set_at', case when f.own is not null then o.set_at end) order by f.sort)
               from hr.fn_effective_access(v_e.id) f left join hr.access_overrides o on o.employee_id = v_e.id and o.app = f.app),
    'active_admins_other_than_this_person', hr.fn_active_admins(v_e.id),
    'version', hr.fn_access_version(v_e.id));
end $function$;

CREATE OR REPLACE FUNCTION hr.get_access_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_caller bigint := hr.fn_require_access_admin();
begin
  return jsonb_build_object(
    'apps', (select jsonb_agg(jsonb_build_object('app', a.app, 'name', a.name, 'parent', a.parent, 'needs', a.needs, 'mode', a.mode, 'on_since', a.on_since) order by a.sort) from hr.access_apps a),
    'defaults', (select jsonb_agg(jsonb_build_object('group', d.grp, 'app', d.app, 'level', d.level) order by d.grp, a.sort)
                   from hr.access_group_defaults d join hr.access_apps a on a.app = d.app),
    'people', (select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.full_name, 'group', coalesce(e.access_level, 'field'),
                       'has_sign_in', hr.fn_has_sign_in(e.email), 'is_self', e.id = v_caller,
                       'custom', case when e.access_level = 'admin' then 0 else (select count(*) from hr.access_overrides o where o.employee_id = e.id) end,
                       'own', case when e.access_level = 'admin' then '{}'::jsonb else (select coalesce(jsonb_object_agg(o.app, o.level), '{}'::jsonb) from hr.access_overrides o where o.employee_id = e.id) end) order by e.full_name)
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

CREATE OR REPLACE FUNCTION hr.get_employee_record(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_level text; v_e public.employees; v_pay boolean; v_seebonus boolean; v_can_edit boolean;
  v_today date := (now() at time zone 'America/New_York')::date;
  v_rates jsonb; v_history jsonb; v_weeks jsonb; v_activity jsonb; v_company jsonb; v_bonus jsonb;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;
  select * into v_e from public.employees where id = p_id;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_id;
  end if;
  -- 2026-10-19_2200: the HR App checks the person's access settings (hr.access_*); pay rates follow "Pay rates and bonus
  -- settings", bonuses "See bonus amounts", editing the HR App level. While a row is not checked, the old group rule stands.
  perform hr.fn_require_app('hr', 'view');
  v_pay := case when hr.fn_app_mode('hr_pay') = 'on' then hr.fn_app_level('hr_pay') = 'yes' else v_level = 'admin' end;
  v_seebonus := case when hr.fn_app_mode('hr_bonus') = 'on' then hr.fn_app_level('hr_bonus') = 'yes' else true end;
  v_can_edit := case when hr.fn_app_mode('hr') = 'on' then hr.fn_app_level('hr') = 'edit' else true end;

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
   where (p.kind in ('per_visit_bonus', 'per_shift_bonus') and v_seebonus) or v_pay
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
   where l.table_schema = 'hr' and l.table_name = 'access_overrides' and v_level = 'admin'   -- 2026-10-19_2230: admins only
     and coalesce(l.new_row, l.old_row)->>'employee_id' = p_id::text
     and (l.operation <> 'UPDATE' or (l.old_row->>'level') is distinct from (l.new_row->>'level'))
  ) s2;

  if not v_seebonus then
    v_history := '[]'::jsonb; v_weeks := '[]'::jsonb; v_bonus := null; v_company := null;
  end if;

  return jsonb_build_object(
    'employee', hr.fn_employee_json(v_e),
    'viewer', jsonb_build_object('level', v_level, 'can_edit', v_can_edit, 'can_see_pay', v_pay, 'can_see_bonus', v_seebonus, 'is_self', v_e.id = v_caller,
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

DO $verify$
DECLARE
  c_fred text := json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated')::text;
  c_yan text := json_build_object('sub','71e294b9-9898-4c21-a48d-d970e32d829c','email','yannick@ayache.com','role','authenticated')::text;
  c_aaron text := json_build_object('sub','77d4c343-1e21-44eb-98ce-c221028d028a','email','aaron@unclogme.com','role','authenticated')::text;
  j jsonb; v_ok boolean; v_det text; v_ver text; v_pos_lock int; v_pos_admin int;
BEGIN
  -- 1. the lock comes before the caller check in the three writers
  SELECT position('pg_advisory_xact_lock' IN pg_get_functiondef('hr.set_access(bigint,text,jsonb,text)'::regprocedure)),
         position('fn_require_access_admin()' IN pg_get_functiondef('hr.set_access(bigint,text,jsonb,text)'::regprocedure)) INTO v_pos_lock, v_pos_admin;
  IF v_pos_lock = 0 OR v_pos_lock > v_pos_admin THEN RAISE EXCEPTION 'VERIFY 1a: set_access checks the caller before the lock'; END IF;
  SELECT position('pg_advisory_xact_lock' IN pg_get_functiondef('hr.set_group_access(jsonb,text)'::regprocedure)),
         position('fn_require_access_admin()' IN pg_get_functiondef('hr.set_group_access(jsonb,text)'::regprocedure)) INTO v_pos_lock, v_pos_admin;
  IF v_pos_lock = 0 OR v_pos_lock > v_pos_admin THEN RAISE EXCEPTION 'VERIFY 1b: set_group_access checks the caller before the lock'; END IF;
  SELECT position('pg_advisory_xact_lock' IN pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)),
         position('for update' IN pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)) INTO v_pos_lock, v_pos_admin;
  IF v_pos_lock = 0 OR v_pos_lock > v_pos_admin
     OR position('fn_require_level' IN pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)) < v_pos_lock THEN
    RAISE EXCEPTION 'VERIFY 1c: update_employee does not lock first';
  END IF;

  -- 2. the sign-in-aware admin rule (it can only fire in a race between two admins; the count it relies on is tested here)
  v_ok := false;
  BEGIN
    UPDATE public.employees SET access_level = 'office' WHERE id = 2;
    v_ok := hr.fn_active_admins(27) = 0 AND hr.fn_active_admins(2) = 1;
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 2: the admin count is wrong'; END IF;
  IF position('blocker=last_admin' IN pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)) = 0
     OR position('fn_active_admins(p_id)' IN pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'VERIFY 2b: update_employee has no sign-in-aware admin rule';
  END IF;
  IF (SELECT access_level FROM public.employees WHERE id = 2) <> 'admin' THEN
    RAISE EXCEPTION 'VERIFY 2c: not undone';
  END IF;

  -- 3. a lowered HR App default cannot leave an own setting above it; NULL group or level refused in words
  PERFORM set_config('request.jwt.claims', c_fred, true);
  v_ok := false;
  BEGIN
    PERFORM hr.set_access(26, NULL, '{"hr":"edit"}', hr.fn_access_version(26));
    v_ver := hr.fn_defaults_version();
    BEGIN
      PERFORM hr.set_group_access('[{"group":"office","app":"hr","level":"view"}]', v_ver);
    EXCEPTION WHEN invalid_parameter_value THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_ok := v_det = 'blocker=hr_above_group';
    END;
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 3a: a lowered HR App default left an own setting above it'; END IF;
  v_ver := hr.fn_defaults_version();
  BEGIN PERFORM hr.set_group_access('[{"app":"hr","level":"view"}]', v_ver); v_ok := false;
  EXCEPTION WHEN invalid_parameter_value THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_ok := v_det = 'blocker=group_value'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 3b: a missing group was not refused'; END IF;
  BEGIN PERFORM hr.set_group_access('[{"group":"office","app":"hr"}]', v_ver); v_ok := false;
  EXCEPTION WHEN invalid_parameter_value THEN GET STACKED DIAGNOSTICS v_det = PG_EXCEPTION_DETAIL; v_ok := v_det = 'blocker=level_value'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 3c: a missing level was not refused in words'; END IF;

  -- 4. access changes in Activity: admins see them, office does not (a change made and undone here; the 2145 seed rows
  -- were written before the audit triggers existed, so they have no log rows)
  v_ok := false;
  BEGIN
    PERFORM set_config('request.jwt.claims', c_fred, true);
    PERFORM hr.set_access(26, NULL, '{"visit_calendar":"view"}', hr.fn_access_version(26));
    j := hr.get_employee_record(26);
    v_ok := EXISTS (SELECT 1 FROM jsonb_array_elements(j->'activity') a WHERE a->>'operation' = 'ACCESS');
    PERFORM set_config('request.jwt.claims', c_aaron, true);
    j := hr.get_employee_record(26);
    v_ok := v_ok AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(j->'activity') a WHERE a->>'operation' = 'ACCESS');
    RAISE EXCEPTION 'undo' USING errcode = 'P0001';
  EXCEPTION WHEN raise_exception THEN NULL;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'VERIFY 4: access changes are not admin-only in Activity'; END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'VERIFY 2230 passed';
END $verify$;

COMMIT;
