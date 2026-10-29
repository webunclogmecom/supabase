-- 2026-10-29_1850_hr_create_employee_link_sign_in.sql
--
-- Fred, 2026-10-29, adding Jonathan Veras: "Reuse it, and fix Add person". Add person (hr.create_employee) refused any
-- email that already had a sign-in (blocker=email_sign_in_taken), so a real person whose sign-in came first (Jonathan:
-- Google since 2026-07-24, no person record) could only be added by hand (2026-10-29_1840).
--
-- The rule now:
--   - a sign-in that a PERSON owns is refused as before (the email check: "That email already belongs to <name>");
--   - a sign-in no person owns is refused with blocker=email_sign_in_unclaimed and the sentence "That email already has
--     a sign-in that no one in the HR App owns." The HR App then asks the admin to confirm and calls again with
--     link_sign_in = true, which creates the person on that email; the reply says linked_sign_in = true;
--   - two sign-ins at one email: blocker=email_sign_in_ambiguous (a person sorts it out);
--   - the sign-in itself is not changed: if it is turned off, the admin turns it on in the Security tab
--     (hr.request_sign_in_action turn_on, which already accepts a confirmed or invited sign-in of an Active person).
-- Why linking is safe: the person check is the admin's (Add person is admin only), the email is the same, and the sign-in
-- belongs to whoever holds that mailbox or Google account, which is the same trust an invite to that email gives.
-- The old blocker code email_sign_in_taken is no longer raised by this function (hr.update_employee keeps its own).
--
-- Copied from the LIVE body (md5 2835b9036b1578e8d591fed095504bf1, guarded below), five anchored edits, nothing else
-- moved. Grants unchanged (CREATE OR REPLACE keeps them; VERIFY reads them). Rule 8: no table change.
-- VERIFY (rolled back): as Fred, an unclaimed sign-in without the flag is refused unclaimed; with the flag the person is
-- created with linked_sign_in true; a non-boolean flag is refused; an email with no sign-in is unchanged; an email a
-- person owns is still refused; the OLD body, run as a temporary copy, refuses the flag (the control).
-- Rollback: docs/migrations/2026-10-29_rollback_hr_create_employee_link_sign_in.sql (the old body, verbatim).

begin;
set local lock_timeout = '3s';

do $guard$
begin
  if md5(pg_get_functiondef('hr.create_employee(jsonb)'::regprocedure)) <> '2835b9036b1578e8d591fed095504bf1' then
    raise exception 'hr.create_employee changed since it was read; rebuild this migration from the live body';
  end if;
end $guard$;

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
end $function$;

-- the old body under a temporary name, for the control below (dropped before commit)
CREATE OR REPLACE FUNCTION hr.zz_probe_create_employee_old(p_person jsonb)
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

do $verify$
declare
  v_fred uuid := '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b';
  v_r jsonb; v_det text; v_ok boolean; v_free text;
begin
  -- a sign-in no person owns, the only one at its address (measured 2026-10-29: 3 such, all turned off)
  select lower(btrim(u.email)) into v_free from auth.users u
   where not exists (select 1 from public.employees e where lower(btrim(e.email)) = lower(btrim(u.email)))
     and (select count(*) from auth.users u2 where lower(btrim(u2.email)) = lower(btrim(u.email))) = 1
   order by u.created_at limit 1;
  if v_free is null then raise exception 'verify premise: no unclaimed sign-in to test with'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_fred, 'email', 'fred@ayache.com',
    'role', 'authenticated', 'aud', 'authenticated')::text, true);

  -- 1. unclaimed sign-in, no flag -> refused unclaimed
  v_ok := false;
  begin
    perform hr.create_employee(jsonb_build_object('full_name', 'ZZ Probe One', 'email', v_free));
  exception when invalid_parameter_value then
    get stacked diagnostics v_det = pg_exception_detail; v_ok := v_det = 'blocker=email_sign_in_unclaimed';
  end;
  if not v_ok then raise exception 'verify 1: expected email_sign_in_unclaimed, got %', v_det; end if;

  -- 2. unclaimed sign-in, flag true -> created, linked_sign_in true (rolled back by the caught exception)
  begin
    v_r := hr.create_employee(jsonb_build_object('full_name', 'ZZ Probe Two', 'email', v_free, 'link_sign_in', true));
    if (v_r->>'linked_sign_in')::boolean is not true then raise exception 'verify 2: linked_sign_in %', v_r->>'linked_sign_in'; end if;
    if (v_r->'employee'->>'email') is distinct from v_free then raise exception 'verify 2: email %', v_r->'employee'->>'email'; end if;
    raise exception 'probe_rollback';
  exception when raise_exception then
    if sqlerrm <> 'probe_rollback' then raise; end if;
  end;

  -- 3. a non-boolean flag -> refused
  v_ok := false;
  begin
    perform hr.create_employee(jsonb_build_object('full_name', 'ZZ Probe Three', 'email', v_free, 'link_sign_in', 'yes'));
  exception when invalid_parameter_value then
    get stacked diagnostics v_det = pg_exception_detail; v_ok := v_det = 'blocker=link_sign_in_value';
  end;
  if not v_ok then raise exception 'verify 3: expected link_sign_in_value, got %', v_det; end if;

  -- 4. an email with no sign-in -> created as before, linked_sign_in false
  begin
    v_r := hr.create_employee(jsonb_build_object('full_name', 'ZZ Probe Four', 'email', 'zz.probe.four@example.com'));
    if (v_r->>'linked_sign_in')::boolean is not false then raise exception 'verify 4: linked_sign_in %', v_r->>'linked_sign_in'; end if;
    raise exception 'probe_rollback';
  exception when raise_exception then
    if sqlerrm <> 'probe_rollback' then raise; end if;
  end;

  -- 5. an email a person owns -> still refused, even with the flag
  v_ok := false;
  begin
    perform hr.create_employee(jsonb_build_object('full_name', 'ZZ Probe Five', 'email', 'jon.v@ayache.com', 'link_sign_in', true));
  exception when unique_violation then
    get stacked diagnostics v_det = pg_exception_detail; v_ok := v_det = 'blocker=email_taken';
  end;
  if not v_ok then raise exception 'verify 5: expected email_taken, got %', v_det; end if;

  -- 6. control: the OLD body refuses case 2's input
  v_ok := false;
  begin
    perform hr.zz_probe_create_employee_old(jsonb_build_object('full_name', 'ZZ Probe Six', 'email', v_free, 'link_sign_in', true));
  exception when invalid_parameter_value then
    get stacked diagnostics v_det = pg_exception_detail; v_ok := v_det like 'blocker=field_not_editable%';
  end;
  if not v_ok then raise exception 'verify 6 (control): the old body did not refuse, detail %', v_det; end if;

  perform set_config('request.jwt.claims', '', true);
  if exists (select 1 from public.employees where full_name like 'ZZ Probe %') then raise exception 'verify: a probe row survived'; end if;
end $verify$;

drop function hr.zz_probe_create_employee_old(jsonb);

do $grants$
begin
  if has_function_privilege('anon', 'hr.create_employee(jsonb)', 'execute') then raise exception 'grants: anon can execute'; end if;
  if not has_function_privilege('authenticated', 'hr.create_employee(jsonb)', 'execute') then raise exception 'grants: authenticated lost execute'; end if;
end $grants$;

commit;
