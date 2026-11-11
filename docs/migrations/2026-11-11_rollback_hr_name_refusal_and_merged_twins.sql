-- 2026-11-11_rollback_hr_name_refusal_and_merged_twins.sql
-- Undoes 2026-11-11_1600_hr_name_refusal_and_merged_twins.sql: the two bodies as they were before it (verbatim, read live
-- 2026-11-11), and rows 36 / 38 back to their old names. Refuses unless the live bodies are the ones that migration wrote.
begin;
set local lock_timeout = '3s';
do $guard$
begin
  if md5(pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)) <> '44aa1b69b9b96866d75dcfad022bc699'
     or md5(pg_get_functiondef('hr.create_employee(jsonb)'::regprocedure)) <> '7f9e4aba1f0400eecafb63ddd4dde6c6' then
    raise exception 'the live bodies are not the ones 2026-11-11_1600 wrote; read them before rolling back';
  end if;
end $guard$;
update public.employees set full_name = 'Mark noltion' where id = 36 and full_name = 'Mark noltion (samsara duplicate, merged 2026-07-09)';
update public.employees set full_name = 'Anthony Clark' where id = 38 and full_name = 'Anthony Clark (samsara duplicate, merged 2026-07-09)';

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
  v_u record; v_by text;   -- 2026-10-26_1730 (new hires)
begin
  -- 2026-10-19_2230 (review): the access lock first, then the caller check, then the row lock, in every writer
  if p_patch ? 'email' or p_patch ? 'status' then perform pg_advisory_xact_lock(hashtext('hr.access')); end if;
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;
  perform hr.fn_require_app('hr', 'edit');   -- 2026-10-19_2200

  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'Nothing to save.' using errcode = '22023', detail = 'blocker=patch_shape in hr.update_employee';
  end if;
  select array_agg(k order by k) into v_bad from jsonb_object_keys(p_patch) k
   where k not in ('full_name', 'status', 'shift', 'email', 'phone', 'hire_date', 'color_hex');
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

  -- 2026-10-20_0200 (Fred): the person's colour, the one every app shows (Calendar chips, DUMP, the HR avatar)
  if p_patch ? 'color_hex' then
    v_txt := upper(btrim(coalesce(p_patch->>'color_hex', '')));
    if v_txt !~ '^#[0-9A-F]{6}$' then
      raise exception 'Pick a colour from the list. Nothing was saved.' using errcode = '22023', detail = 'blocker=color_format';
    end if;
    if v_txt in ('#F59E0B', '#22D3EE', '#16A34A', '#F14714') then
      raise exception 'That colour already means something in the apps (a dump site, GO or the UnclogMe orange). Pick another. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=color_reserved';
    end if;
    select e.full_name into v_other from public.employees e
     where upper(e.color_hex) = v_txt and e.id <> p_id and e.status = 'ACTIVE' limit 1;
    if v_other is not null then
      raise exception '% already has this colour. Pick another. Nothing was saved.', btrim(v_other)
        using errcode = '23505', detail = 'blocker=color_taken';
    end if;
    v_new.color_hex := v_txt;
  end if;

  if v_new.full_name is distinct from v_row.full_name then v_changed := array_append(v_changed, 'full_name'); end if;
  if v_new.status    is distinct from v_row.status    then v_changed := array_append(v_changed, 'status'); end if;
  if v_new.shift     is distinct from v_row.shift     then v_changed := array_append(v_changed, 'shift'); end if;
  if v_new.email     is distinct from v_row.email     then v_changed := array_append(v_changed, 'email'); end if;
  if v_new.phone     is distinct from v_row.phone     then v_changed := array_append(v_changed, 'phone'); end if;
  if v_new.hire_date is distinct from v_row.hire_date then v_changed := array_append(v_changed, 'hire_date'); end if;
  if v_new.color_hex is distinct from v_row.color_hex then v_changed := array_append(v_changed, 'color_hex'); end if;

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
  -- 2026-10-19_2300 (Fred, default 20): the email of a person with a sign-in is their username; changing it is a separate
  -- task, and no email may be set to one that already signs in (access follows the email).
  if 'email' = any (v_changed) then
    if hr.fn_has_sign_in(v_row.email) then
      raise exception 'This email is also %''s sign-in. Changing it is a separate task. Nothing was saved.', split_part(btrim(v_row.full_name), ' ', 1)
        using errcode = '22023', detail = 'blocker=email_is_sign_in';
    end if;
    -- 2026-10-26 (Send invite): any sign-in at the address (an invite not clicked yet included), or an invite asked for in
    -- the last 15 minutes that Supabase may still be creating, locks the email too. hr.fn_has_sign_in stays confirmed-only
    -- (hr.get_access and hr.get_access_overview read it).
    -- 2026-10-26_1730 (Fred: "go ahead"): an invite not accepted yet (never confirmed, no password) no longer locks it
    if exists (select 1 from auth.users u where nullif(btrim(v_row.email), '') is not null and lower(btrim(u.email)) = lower(btrim(v_row.email))
                  and not (u.email_confirmed_at is null and nullif(u.encrypted_password, '') is null and u.invited_at is not null))
       or exists (select 1 from hr.sign_in_changes c where c.employee_id = p_id and c.action = 'invite' and c.status = 'pending'
                     and c.created_at > now() - interval '60 seconds') then
      raise exception 'An invite was sent to this email. Changing it is a separate task. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=email_has_invite';
    end if;
    -- 2026-10-26_1730: the unaccepted invite at the old address is turned off (never deleted) and recorded
    select x.email into v_by from auth.users x where x.id = auth.uid();
    for v_u in select u.id from auth.users u
                where nullif(btrim(v_row.email), '') is not null and lower(btrim(u.email)) = lower(btrim(v_row.email))
                  and u.email_confirmed_at is null and nullif(u.encrypted_password, '') is null and u.invited_at is not null loop
      update auth.users set banned_until = now() + interval '100 years'
       where id = v_u.id and (banned_until is null or banned_until <= now());
      delete from auth.sessions where user_id = v_u.id;
      insert into hr.sign_in_changes (employee_id, auth_user_id, action, status, reason, requested_by_email, requested_by_employee, finished_at)
      values (p_id, v_u.id, 'turn_off', 'done', 'Email changed before the invite was accepted', v_by, v_caller, now());
    end loop;
    if v_new.email is not null and exists (select 1 from auth.users u where lower(btrim(u.email)) = lower(btrim(v_new.email))) then
      raise exception 'That email already belongs to a sign-in. Nothing was saved.' using errcode = '22023', detail = 'blocker=email_sign_in_taken';
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
         email = v_new.email, phone = v_new.phone, hire_date = v_new.hire_date, color_hex = v_new.color_hex
   where id = p_id
  returning * into v_new;

  return jsonb_build_object('noop', false, 'employee', hr.fn_employee_json(v_new),
    'changed', to_jsonb(v_changed), 'impact', hr.fn_employee_impact(p_id));
end $function$
;

CREATE OR REPLACE FUNCTION hr.create_employee(p_person jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-26_1730 (new hires): the HR App's Add person. Validation copied from hr.update_employee (2026-10-26 body).
declare
  v_caller bigint; v_level text; v_new public.employees; v_bad text[]; v_txt text; v_other text; v_date date;
  v_today date := (now() at time zone 'America/New_York')::date;
  v_name text; v_email text; v_phone text; v_hire date; v_shift text; v_color text; v_access text := 'field';
  v_week int := 5; v_role text; v_jid text; v_ju hr.jobber_users; v_linked boolean := false;
  v_link boolean := false; v_signins int := 0; v_linked_sign_in boolean := false;
begin
  perform pg_advisory_xact_lock(hashtext('hr.access'));
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin']) c;
  perform hr.fn_require_app('hr', 'edit');

  if p_person is null or jsonb_typeof(p_person) <> 'object' then
    raise exception 'Nothing to save.' using errcode = '22023', detail = 'blocker=patch_shape in hr.create_employee';
  end if;
  select array_agg(k order by k) into v_bad from jsonb_object_keys(p_person) k
   where k not in ('full_name', 'email', 'phone', 'hire_date', 'shift', 'access_level', 'drives_truck', 'color_hex',
                   'payroll_week_start_day', 'jobber_user_id', 'link_sign_in');
  if v_bad is not null then
    raise exception 'These fields cannot be set here: %.', array_to_string(v_bad, ', ')
      using errcode = '22023', detail = 'blocker=field_not_editable in hr.create_employee';
  end if;

  -- 2026-10-29_1850 (Fred: "fix Add person"): link_sign_in = true is the admin's confirmation that an existing
  -- sign-in at this email, which no person owns, belongs to this new person
  if p_person ? 'link_sign_in' and jsonb_typeof(p_person->'link_sign_in') not in ('boolean', 'null') then
    raise exception 'Link the sign-in must be yes or no. Nothing was saved.' using errcode = '22023', detail = 'blocker=link_sign_in_value';
  end if;
  v_link := coalesce((p_person->>'link_sign_in')::boolean, false);

  v_name := btrim(coalesce(p_person->>'full_name', ''));
  if v_name = '' then
    raise exception 'The name cannot be empty. Nothing was saved.' using errcode = '22023', detail = 'blocker=name_empty';
  end if;
  if length(v_name) > 80 then
    raise exception 'The name is too long (80 characters at most). Nothing was saved.' using errcode = '22023', detail = 'blocker=name_long';
  end if;
  select e.full_name into v_other from public.employees e where lower(btrim(e.full_name)) = lower(v_name) limit 1;
  if v_other is not null then
    raise exception 'Another person already has the name "%". Nothing was saved.', btrim(v_other)
      using errcode = '23505', detail = 'blocker=name_taken';
  end if;

  v_txt := lower(btrim(coalesce(p_person->>'email', '')));
  if v_txt <> '' then
    if v_txt !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
      raise exception 'That email does not look right. Nothing was saved.' using errcode = '22023', detail = 'blocker=email_format';
    end if;
    select e.full_name into v_other from public.employees e where lower(btrim(e.email)) = v_txt limit 1;
    if v_other is not null then
      raise exception 'That email already belongs to %. Nothing was saved.', btrim(v_other)
        using errcode = '23505', detail = 'blocker=email_taken';
    end if;
    -- 2026-10-29_1850: a sign-in here is one no person owns (the email check above refused one a person owns).
    -- Linked only when the admin confirms it (link_sign_in = true); otherwise the app asks.
    select count(*) into v_signins from auth.users u where lower(btrim(u.email)) = v_txt;
    if v_signins > 1 then
      raise exception 'That email matches more than one sign-in. Ask Fred to sort it out. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=email_sign_in_ambiguous';
    elsif v_signins = 1 and not v_link then
      raise exception 'That email already has a sign-in that no one in the HR App owns. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=email_sign_in_unclaimed';
    end if;
    v_linked_sign_in := v_signins = 1;
    v_email := v_txt;
  end if;

  v_txt := btrim(coalesce(p_person->>'phone', ''));
  if v_txt <> '' then
    if length(v_txt) > 40 then
      raise exception 'The phone number is too long. Nothing was saved.' using errcode = '22023', detail = 'blocker=phone_long';
    end if;
    if v_txt !~ '[0-9]' then
      raise exception 'The phone number has no digits. Nothing was saved.' using errcode = '22023', detail = 'blocker=phone_format';
    end if;
    v_phone := v_txt;
  end if;

  v_txt := btrim(coalesce(p_person->>'hire_date', ''));
  if v_txt <> '' then
    begin
      v_date := v_txt::date;
    exception when others then
      raise exception 'The hire date is not a date. Nothing was saved.' using errcode = '22023', detail = 'blocker=hire_date_format';
    end;
    if v_date < date '1990-01-01' or v_date > v_today + 366 then
      raise exception 'The hire date is out of range. Nothing was saved.' using errcode = '22023', detail = 'blocker=hire_date_range';
    end if;
    v_hire := v_date;
  end if;

  v_txt := lower(btrim(coalesce(p_person->>'shift', '')));
  if v_txt <> '' then
    if v_txt not in ('day', 'night') then
      raise exception 'Shift must be Day, Night or empty. Nothing was saved.' using errcode = '22023', detail = 'blocker=shift_value';
    end if;
    v_shift := v_txt;
  end if;

  v_txt := lower(btrim(coalesce(p_person->>'access_level', '')));
  if v_txt <> '' then
    if v_txt not in ('office', 'field') then
      raise exception 'Pick Office or Field. Nothing was saved.' using errcode = '22023', detail = 'blocker=access_level_value';
    end if;
    v_access := v_txt;
  end if;

  if p_person ? 'payroll_week_start_day' and jsonb_typeof(p_person->'payroll_week_start_day') <> 'null' then
    if jsonb_typeof(p_person->'payroll_week_start_day') <> 'number' or (p_person->>'payroll_week_start_day') !~ '^[0-6]$' then
      raise exception 'Pick the day the payroll week starts. Nothing was saved.' using errcode = '22023', detail = 'blocker=payroll_week_value';
    end if;
    v_week := (p_person->>'payroll_week_start_day')::int;
  end if;

  if p_person ? 'drives_truck' and jsonb_typeof(p_person->'drives_truck') not in ('boolean', 'null') then
    raise exception 'Drives a truck must be yes or no. Nothing was saved.' using errcode = '22023', detail = 'blocker=drives_truck_value';
  end if;
  v_role := case when coalesce((p_person->>'drives_truck')::boolean, false) then 'Technician' end;

  v_txt := upper(btrim(coalesce(p_person->>'color_hex', '')));
  if v_txt <> '' then
    if v_txt !~ '^#[0-9A-F]{6}$' then
      raise exception 'Pick a colour from the list. Nothing was saved.' using errcode = '22023', detail = 'blocker=color_format';
    end if;
    if v_txt in ('#F59E0B', '#22D3EE', '#16A34A', '#F14714') then
      raise exception 'That colour already means something in the apps (a dump site, GO or the UnclogMe orange). Pick another. Nothing was saved.'
        using errcode = '22023', detail = 'blocker=color_reserved';
    end if;
    select e.full_name into v_other from public.employees e where upper(e.color_hex) = v_txt and e.status = 'ACTIVE' limit 1;
    if v_other is not null then
      raise exception '% already has this colour. Pick another. Nothing was saved.', btrim(v_other)
        using errcode = '23505', detail = 'blocker=color_taken';
    end if;
    v_color := v_txt;
  end if;

  v_jid := nullif(btrim(coalesce(p_person->>'jobber_user_id', '')), '');
  if v_jid is not null then
    select * into v_ju from hr.jobber_users j where j.jobber_id = v_jid and j.removed_at is null;
    if not found then
      raise exception 'That Jobber user was not found. Reload the page. Nothing was saved.' using errcode = 'P0002', detail = 'blocker=jobber_user_not_found';
    end if;
    if exists (select 1 from public.entity_source_links l
                where l.entity_type = 'employee' and l.source_system = 'jobber' and l.source_id = v_jid) then
      raise exception 'That Jobber user is already linked to someone in the HR App. Nothing was saved.'
        using errcode = '23505', detail = 'blocker=jobber_user_taken';
    end if;
  elsif v_email is not null then
    -- the same rule as hr.sync_jobber_users: exactly one live, unlinked Jobber user with this email
    select j.jobber_id into v_jid from hr.jobber_users j
     where j.removed_at is null and j.email = v_email
       and not exists (select 1 from public.entity_source_links l
                        where l.entity_type = 'employee' and l.source_system = 'jobber' and l.source_id = j.jobber_id)
       and (select count(*) from hr.jobber_users j2 where j2.removed_at is null and j2.email = v_email) = 1;
    if v_jid is not null then select * into v_ju from hr.jobber_users j where j.jobber_id = v_jid; end if;
  end if;

  insert into public.employees (full_name, status, shift, email, phone, hire_date, access_level, color_hex,
                                payroll_week_start_day, role)
  values (v_name, 'ACTIVE', v_shift, v_email, v_phone, v_hire, v_access, v_color, v_week, v_role)
  returning * into v_new;

  if v_jid is not null then
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence)
    values ('employee', v_new.id, 'jobber', v_jid, coalesce(v_ju.full_name, v_name),
            case when p_person ? 'jobber_user_id' then 'hr_app' else 'email' end, 1);
    v_linked := true;
  end if;

  return jsonb_build_object('employee', hr.fn_employee_json(v_new), 'linked_to_jobber', v_linked,
                            'linked_sign_in', v_linked_sign_in,
                            'jobber', hr.fn_jobber_person(v_new.id));
end $function$
;
commit;
