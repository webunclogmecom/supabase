-- 2026-10-29_rollback_hr_create_employee_link_sign_in.sql: puts back hr.create_employee as it was before
-- 2026-10-29_1850 (live body md5 2835b9036b1578e8d591fed095504bf1, verbatim). Run only if the link rule must go.
begin;
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
begin
  perform pg_advisory_xact_lock(hashtext('hr.access'));
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin']) c;
  perform hr.fn_require_app('hr', 'edit');

  if p_person is null or jsonb_typeof(p_person) <> 'object' then
    raise exception 'Nothing to save.' using errcode = '22023', detail = 'blocker=patch_shape in hr.create_employee';
  end if;
  select array_agg(k order by k) into v_bad from jsonb_object_keys(p_person) k
   where k not in ('full_name', 'email', 'phone', 'hire_date', 'shift', 'access_level', 'drives_truck', 'color_hex',
                   'payroll_week_start_day', 'jobber_user_id');
  if v_bad is not null then
    raise exception 'These fields cannot be set here: %.', array_to_string(v_bad, ', ')
      using errcode = '22023', detail = 'blocker=field_not_editable in hr.create_employee';
  end if;

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
    if exists (select 1 from auth.users u where lower(btrim(u.email)) = v_txt) then
      raise exception 'That email already belongs to a sign-in. Nothing was saved.' using errcode = '22023', detail = 'blocker=email_sign_in_taken';
    end if;
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
                            'jobber', hr.fn_jobber_person(v_new.id));
end $function$;
commit;
