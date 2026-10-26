-- ============================================================================
-- 2026-10-26_1730 · New hires parts 1 and 3: Add person, a 60-second invite wait, fixing an unaccepted address
-- ============================================================================
-- Fred, 2026-10-26: "in the HR App, we need to be able to create new hires, where we put their data there, and then in
-- the security tab we just let them create their password"; and on the invite follow-ups, "go ahead".
-- Plan: Building Apps/HR App/docs/specs/2026-10-26-new-hires-plan.md (Trello zRTbWvXn).
--
--  1. NEW hr.create_employee(p_person jsonb): admins (it sets an email and a status), HR App Edit. Name (required,
--     unique), email (unique, never one that already signs in), phone, start date, shift, Office or Field (default Field),
--     drives_truck (role 'Technician', which is what the DUMP driver list reads), colour (the Edit details rules), payroll
--     week (default Friday), jobber_user_id (an unlinked live Jobber user: linked in the same step). Created ACTIVE.
--     With an email and no jobber_user_id, the person is linked at once when exactly one unlinked Jobber user has that
--     email (the same rule as hr.sync_jobber_users). Audited by audit_employees; label from the app's header.
--  2. NEW hr.fn_invite_timing(employee): server_now, invite_retry_at (60 s after the last invite request),
--     invites_last_24h, invite_sent_at / invite_expires_at (+ ET labels, 1 hour = Auth mailer_otp_exp 3600) while the
--     invite is unaccepted, invite_expired, email_locked. Merged into get_employee_record's sign_in.
--  3. hr.fn_invite_refusal (spliced): one invite a minute per person (was 15 minutes) and at most 5 in 24 hours.
--  4. hr.update_employee (spliced, email branch): an invite not accepted yet (never confirmed, no password) no longer
--     locks the email; changing it turns that sign-in off (never deleted, recorded in hr.sign_in_changes) and Send invite
--     comes back for the new address. The request window is 60 seconds (was 15 minutes).
--  5. hr.get_employee_record (spliced): sign_in gains the timing; a new 'jobber' block (hr.fn_jobber_person).
-- Every existing body is spliced from the live definition (md5-guarded, one anchor each); grants asserted unchanged.
-- Rollback: 2026-10-26_rollback_hr_add_person_and_invite_wait.sql (the three previous bodies, md5 pinned).
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF left(md5(pg_get_functiondef('hr.fn_invite_refusal(bigint,bigint)'::regprocedure)), 8) <> '89cbaa3c' THEN
    RAISE EXCEPTION 'guard: hr.fn_invite_refusal changed'; END IF;
  IF left(md5(pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure)), 8) <> '14ab32dd' THEN
    RAISE EXCEPTION 'guard: hr.update_employee changed'; END IF;
  IF left(md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)), 8) <> 'c1d2992c' THEN
    RAISE EXCEPTION 'guard: hr.get_employee_record changed'; END IF;
  IF to_regclass('hr.jobber_users') IS NULL THEN RAISE EXCEPTION 'guard: run 2026-10-26_1700 first'; END IF;
END $g$;

CREATE TEMP TABLE nh2_acl_before ON COMMIT DROP AS
  SELECT p.oid::regprocedure::text k, p.proacl::text a FROM pg_proc p
   WHERE p.oid IN ('hr.fn_invite_refusal(bigint,bigint)'::regprocedure, 'hr.update_employee(bigint,jsonb)'::regprocedure,
                   'hr.get_employee_record(bigint)'::regprocedure);

-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION hr.create_employee(p_person jsonb)
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
REVOKE ALL ON FUNCTION hr.create_employee(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION hr.create_employee(jsonb) TO authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------------
CREATE FUNCTION hr.fn_invite_timing(p_employee_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  -- 2026-10-26_1730: the times the HR App shows on the Sign-in row (the app never computes them). The link lasts 1 hour:
  -- Supabase Auth mailer_otp_exp = 3600, shared with reset links (Supabase docs/reference/auth-settings-changes.md).
  with e as (select lower(nullif(btrim(x.email), '')) email from public.employees x where x.id = p_employee_id),
  u as (select su.* from auth.users su, e where e.email is not null and lower(btrim(su.email)) = e.email),
  pend as (select su.invited_at, su.banned_until from u su
            where (select count(*) from u) = 1 and su.email_confirmed_at is null and su.invited_at is not null
              and nullif(su.encrypted_password, '') is null),
  lastreq as (select max(c.created_at) t from hr.sign_in_changes c
               where c.employee_id = p_employee_id and c.action = 'invite' and c.status in ('pending', 'done'))
  select jsonb_build_object(
    'server_now', now(),
    'invite_retry_at', case when (select t from lastreq) > now() - interval '60 seconds' then (select t from lastreq) + interval '60 seconds' end,
    'invites_last_24h', (select count(*) from hr.sign_in_changes c where c.employee_id = p_employee_id and c.action = 'invite'
                            and c.status in ('pending', 'done') and c.created_at > now() - interval '24 hours'),
    'invite_sent_at', (select invited_at from pend),
    'invite_sent_label', to_char((select invited_at from pend) at time zone 'America/New_York', 'FMHH12:MI AM'),
    'invite_expires_at', (select invited_at + interval '1 hour' from pend where banned_until is null or banned_until <= now()),
    'invite_expires_label', to_char((select invited_at + interval '1 hour' from pend where banned_until is null or banned_until <= now())
                                    at time zone 'America/New_York', 'FMHH12:MI AM'),
    'invite_expired', coalesce((select invited_at + interval '1 hour' <= now() from pend where banned_until is null or banned_until <= now()), false),
    -- the email can be changed unless a sign-in at it is more than an unaccepted invite, or an invite request is in flight
    'email_locked', exists (select 1 from u where not (u.email_confirmed_at is null and nullif(u.encrypted_password, '') is null
                                                        and u.invited_at is not null))
                    or coalesce((select t from lastreq) > now() - interval '60 seconds', false))
$function$;
REVOKE ALL ON FUNCTION hr.fn_invite_timing(bigint) FROM PUBLIC, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------------
DO $s$
DECLARE d text; a text; n text;
BEGIN
  -- 3. hr.fn_invite_refusal: 60 seconds, 5 a day
  d := pg_get_functiondef('hr.fn_invite_refusal(bigint,bigint)'::regprocedure);
  a := $a$-- 11. one invite per 15 minutes per person (Supabase has no per-person limit, only 30 emails an hour for everyone)$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: refusal comment'; END IF;
  d := replace(d, a, $n$-- 11. (2026-10-26_1730, Fred: "go ahead") one invite a minute per person, at most 5 in 24 hours (was 15 minutes)$n$);
  a := $a$c.created_at > now() - interval '15 minutes') then$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: refusal window'; END IF;
  d := replace(d, a, $n$c.created_at > now() - interval '60 seconds') then$n$);
  a := $a$return 'An invite went to ' || v_first || ' less than 15 minutes ago. Try again later.';$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: refusal sentence'; END IF;
  d := replace(d, a, $n$return 'An invite went to ' || v_first || ' less than a minute ago. Wait a moment, then send again.';
  end if;
  if (select count(*) from hr.sign_in_changes c where c.employee_id = p_employee_id and c.action = 'invite'
        and c.status in ('pending', 'done') and c.created_at > now() - interval '24 hours') >= 5 then
    return '5 invites went to ' || v_first || ' in the last 24 hours. Check the address with them, then try again tomorrow.';$n$);
  EXECUTE d;

  -- 4. hr.update_employee: an unaccepted invite no longer locks the email; changing it turns that sign-in off
  d := pg_get_functiondef('hr.update_employee(bigint,jsonb)'::regprocedure);
  a := $a$  v_today date := (now() at time zone 'America/New_York')::date;$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: update declare'; END IF;
  d := replace(d, a, a || E'\n  v_u record; v_by text;   -- 2026-10-26_1730 (new hires)');
  a := $a$if exists (select 1 from auth.users u where nullif(btrim(v_row.email), '') is not null and lower(btrim(u.email)) = lower(btrim(v_row.email)))$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: update lock'; END IF;
  d := replace(d, a, $n$-- 2026-10-26_1730 (Fred: "go ahead"): an invite not accepted yet (never confirmed, no password) no longer locks it
    if exists (select 1 from auth.users u where nullif(btrim(v_row.email), '') is not null and lower(btrim(u.email)) = lower(btrim(v_row.email))
                  and not (u.email_confirmed_at is null and nullif(u.encrypted_password, '') is null and u.invited_at is not null))$n$);
  a := $a$and c.created_at > now() - interval '15 minutes') then$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: update window'; END IF;
  d := replace(d, a, $n$and c.created_at > now() - interval '60 seconds') then$n$);
  a := $a$    if v_new.email is not null and exists (select 1 from auth.users u where lower(btrim(u.email)) = lower(btrim(v_new.email))) then$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: update withdraw anchor'; END IF;
  d := replace(d, a, $n$    -- 2026-10-26_1730: the unaccepted invite at the old address is turned off (never deleted) and recorded
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
$n$ || a);
  EXECUTE d;

  -- 5. hr.get_employee_record: the invite times and the Jobber line
  d := pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure);
  a := $a$'sign_in', jsonb_build_object('invited_on', null) || hr.fn_sign_in_summary(p_id)$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: record sign_in'; END IF;
  d := replace(d, a, a || ' || hr.fn_invite_timing(p_id)   /* 2026-10-26_1730 */');
  a := $a$'impact_if_inactive', hr.fn_employee_impact(p_id),$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: record jobber'; END IF;
  d := replace(d, a, $n$'jobber', hr.fn_jobber_person(p_id),   -- 2026-10-26_1730 (new hires): the Jobber line
    $n$ || a);
  EXECUTE d;
END $s$;

-- ---------------------------------------------------------------------------------------------------------------------
-- VERIFY (as Fred, an admin; every probe write is undone)
DO $v$
DECLARE r jsonb; v_id bigint; v_uid uuid := gen_random_uuid(); v_conf uuid := gen_random_uuid(); m text; n int;
BEGIN
  IF EXISTS (SELECT 1 FROM nh2_acl_before b JOIN pg_proc p ON p.oid = b.k::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'verify: the privileges of a spliced function moved'; END IF;
  IF has_function_privilege('anon', 'hr.create_employee(jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'hr.fn_invite_timing(bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'hr.create_employee(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'verify: grants'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com',
                                                             'role', 'authenticated')::text, true);
  BEGIN
    -- create: a driver with an email, Field, drives a truck
    r := hr.create_employee('{"full_name":"ZZ Add Probe","email":"ZZ.Add.Probe@unclogme.com","phone":"(305) 555-0142",
                              "hire_date":"2026-10-26","access_level":"field","drives_truck":true,"payroll_week_start_day":0}'::jsonb);
    v_id := (r->'employee'->>'id')::bigint;
    IF r->'employee'->>'status' <> 'ACTIVE' OR r->'employee'->>'email' <> 'zz.add.probe@unclogme.com'
       OR (SELECT role FROM public.employees WHERE id = v_id) IS DISTINCT FROM 'Technician'
       OR (r->'employee'->>'payroll_week_start_day')::int <> 0 OR (r->>'linked_to_jobber')::boolean THEN
      RAISE EXCEPTION 'verify: create %', r; END IF;
    IF r->'jobber'->>'state' <> 'not_in_jobber' THEN RAISE EXCEPTION 'verify: new person Jobber line %', r->'jobber'; END IF;
    -- refusals
    BEGIN PERFORM hr.create_employee('{"full_name":"zz add probe"}'::jsonb); RAISE EXCEPTION 'verify: duplicate name accepted';
    EXCEPTION WHEN unique_violation THEN NULL; END;
    BEGIN PERFORM hr.create_employee('{"full_name":"ZZ Other","email":"zz.add.probe@unclogme.com"}'::jsonb); RAISE EXCEPTION 'verify: duplicate email accepted';
    EXCEPTION WHEN unique_violation THEN NULL; END;
    BEGIN PERFORM hr.create_employee('{"full_name":"ZZ Other","access_level":"admin"}'::jsonb); RAISE EXCEPTION 'verify: admin level accepted';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    BEGIN PERFORM hr.create_employee('{"full_name":"ZZ Other","status":"INACTIVE"}'::jsonb); RAISE EXCEPTION 'verify: status key accepted';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    BEGIN PERFORM hr.create_employee('{"full_name":"ZZ Other","color_hex":"#F14714"}'::jsonb); RAISE EXCEPTION 'verify: reserved colour accepted';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;
    -- create with a Jobber user: linked in the same step; a second person cannot take that Jobber user
    INSERT INTO hr.jobber_users (jobber_id, full_name, email, status) VALUES ('Z2lkOi8vSm9iYmVyL1VzZXIvOTk5OTk5MTE=', 'ZZ Jobber Probe', 'zz.jobber.probe@example.com', 'ACTIVATED');
    r := hr.create_employee('{"full_name":"ZZ Jobber Probe","jobber_user_id":"Z2lkOi8vSm9iYmVyL1VzZXIvOTk5OTk5MTE="}'::jsonb);
    IF NOT (r->>'linked_to_jobber')::boolean OR r->'jobber'->>'state' <> 'in_step' THEN RAISE EXCEPTION 'verify: jobber create %', r; END IF;
    BEGIN PERFORM hr.create_employee('{"full_name":"ZZ Jobber Probe 2","jobber_user_id":"Z2lkOi8vSm9iYmVyL1VzZXIvOTk5OTk5MTE="}'::jsonb);
      RAISE EXCEPTION 'verify: a taken Jobber user accepted';
    EXCEPTION WHEN unique_violation THEN NULL; END;
    -- create with an email that one unlinked Jobber user has: linked at once
    INSERT INTO hr.jobber_users (jobber_id, full_name, email, status) VALUES ('Z2lkOi8vSm9iYmVyL1VzZXIvOTk5OTk5MTI=', 'ZZ Mail Probe', 'zz.mail.probe@example.com', 'SEND_INVITE');
    r := hr.create_employee('{"full_name":"ZZ Mail Probe","email":"zz.mail.probe@example.com"}'::jsonb);
    IF NOT (r->>'linked_to_jobber')::boolean THEN RAISE EXCEPTION 'verify: email link %', r; END IF;

    -- invite wait: a request 2 minutes old no longer blocks (it did for 15 minutes); one 30 s old does
    UPDATE public.app_config SET value = 'true' WHERE key = 'hr_invites_on';
    INSERT INTO hr.sign_in_changes (employee_id, action, status, created_at) VALUES (v_id, 'invite', 'done', now() - interval '2 minutes');
    m := hr.fn_invite_refusal(v_id, 2);
    IF m IS NOT NULL THEN RAISE EXCEPTION 'verify: a 2-minute-old invite still blocks: %', m; END IF;
    INSERT INTO hr.sign_in_changes (employee_id, action, status, created_at) VALUES (v_id, 'invite', 'pending', now() - interval '30 seconds');
    m := hr.fn_invite_refusal(v_id, 2);
    IF m NOT LIKE 'An invite went to ZZ less than a minute ago.%' THEN RAISE EXCEPTION 'verify: 60 s %', m; END IF;
    r := hr.fn_invite_timing(v_id);
    IF (r->>'invite_retry_at')::timestamptz IS NULL OR NOT (r->'email_locked')::boolean OR (r->>'invites_last_24h')::int <> 2 THEN
      RAISE EXCEPTION 'verify: timing %', r; END IF;
    UPDATE hr.sign_in_changes SET created_at = now() - interval '5 minutes' WHERE employee_id = v_id;
    INSERT INTO hr.sign_in_changes (employee_id, action, status, created_at)
      SELECT v_id, 'invite', 'done', now() - (g || ' hours')::interval FROM generate_series(1, 3) g;
    m := hr.fn_invite_refusal(v_id, 2);
    IF m NOT LIKE '5 invites went to ZZ in the last 24 hours.%' THEN RAISE EXCEPTION 'verify: 5 a day %', m; END IF;

    -- an unaccepted invite: the email can change; the old sign-in is turned off and recorded
    DELETE FROM hr.sign_in_changes WHERE employee_id = v_id;
    INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, invited_at, created_at, updated_at)
      VALUES (v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz.add.probe@unclogme.com', '', now() - interval '10 minutes', now() - interval '10 minutes', now());
    r := hr.fn_invite_timing(v_id);
    IF (r->'email_locked')::boolean OR (r->>'invite_sent_at') IS NULL OR (r->'invite_expired')::boolean THEN RAISE EXCEPTION 'verify: pending timing %', r; END IF;
    r := hr.update_employee(v_id, '{"email":"zz.add.fixed@unclogme.com"}'::jsonb);
    IF r->'employee'->>'email' <> 'zz.add.fixed@unclogme.com' THEN RAISE EXCEPTION 'verify: email change %', r; END IF;
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = v_uid AND banned_until > now() + interval '99 years') THEN RAISE EXCEPTION 'verify: old invite not turned off'; END IF;
    IF NOT EXISTS (SELECT 1 FROM hr.sign_in_changes WHERE employee_id = v_id AND auth_user_id = v_uid AND action = 'turn_off'
                     AND reason = 'Email changed before the invite was accepted' AND requested_by_email = 'fred@ayache.com') THEN
      RAISE EXCEPTION 'verify: the turn-off was not recorded'; END IF;
    -- control: a confirmed sign-in still locks the email
    INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, invited_at, created_at, updated_at)
      VALUES (v_conf, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'zz.add.fixed@unclogme.com', 'x', now(), now(), now(), now());
    BEGIN PERFORM hr.update_employee(v_id, '{"email":"zz.add.third@unclogme.com"}'::jsonb); RAISE EXCEPTION 'verify: a confirmed sign-in did not lock the email';
    EXCEPTION WHEN invalid_parameter_value THEN NULL; END;

    -- the record carries the timing and the Jobber line
    r := hr.get_employee_record(v_id);
    IF NOT (r->'sign_in' ? 'server_now') OR NOT (r->'sign_in' ? 'email_locked') OR r->'jobber'->>'state' IS NULL THEN
      RAISE EXCEPTION 'verify: record keys %', jsonb_build_object('sign_in', r->'sign_in', 'jobber', r->'jobber'); END IF;
    RAISE EXCEPTION 'nh2_undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'nh2_undo' THEN RAISE; END IF;
  END;
  PERFORM set_config('request.jwt.claims', '', true);
  IF EXISTS (SELECT 1 FROM public.employees WHERE full_name LIKE 'ZZ % Probe%' OR full_name = 'ZZ Add Probe')
     OR EXISTS (SELECT 1 FROM auth.users WHERE id IN (v_uid, v_conf)) OR EXISTS (SELECT 1 FROM hr.jobber_users WHERE jobber_id LIKE 'Z2lkOi8vSm9iYmVyL1VzZXIvOTk5OTk5M%') THEN
    RAISE EXCEPTION 'verify: a probe row was left behind'; END IF;
  RAISE NOTICE 'create_employee, invite wait, unaccepted email change and record keys checked';
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
