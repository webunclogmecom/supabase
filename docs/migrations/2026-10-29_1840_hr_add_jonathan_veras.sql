-- 2026-10-29_1840_hr_add_jonathan_veras.sql
--
-- Fred, 2026-10-29: "let's create an account for Jonathan too, i can't see him in the HR Apps, his email is
-- jon.v@ayache.com". His picks the same minute: Office (everything); reuse his existing sign-in; fix Add person.
--
-- 🛑 ONE-OFF, WRITTEN DOWN (root CLAUDE.md section 7: a hand repair says so in its header).
-- Why by hand: hr.create_employee refuses an email that already has a sign-in (blocker=email_sign_in_taken), and
-- Jonathan's sign-in (Google, created 2026-07-24, last used 2026-10-13) came before his person record. It was blocked on
-- 2026-10-21 by Fred's decision D14 (access switch-on plan, step G0c) because no person stood behind it; the plan said a
-- block can be lifted. The next migration (2026-10-29_1850) teaches hr.create_employee to link such a sign-in when an
-- admin confirms it, so the next person in this state needs no hand step.
--
-- What it does, in one transaction:
--   1. premises: no employee has this email or name; exactly one sign-in has this email, confirmed and blocked;
--   2. adds the person: Jonathan Veras, ACTIVE, Office (the group defaults decide his apps), payroll week Friday;
--   3. lifts the block on his sign-in the way hr.trg_status_sign_in does (banned_until = null) and records it in
--      hr.sign_in_changes as a turn_on requested by Fred (the person who asked);
--   4. VERIFY: as his own sign-in, hr.get_my_access() answers with his new person id.
-- Rule 8: public.employees is audited (audit_employees); the write carries x-change-reason. hr.sign_in_changes is its
-- own record (opted out of audit by design).
-- Undo: set him Inactive in the HR App; trigger zz_hr_status_sign_in blocks the sign-in again and records it.

begin;
set local lock_timeout = '3s';

do $$
declare
  v_uid uuid := '8bdb9ba7-e917-466d-bdb1-c525dbf90194';
  v_n int; v_id bigint; v_acc jsonb;
begin
  select count(*) into v_n from public.employees
   where lower(btrim(email)) = 'jon.v@ayache.com' or lower(btrim(full_name)) = 'jonathan veras';
  if v_n <> 0 then raise exception 'premise: an employee already has this email or name (%)', v_n; end if;
  select count(*) into v_n from auth.users where lower(btrim(email)) = 'jon.v@ayache.com';
  if v_n <> 1 then raise exception 'premise: expected exactly one sign-in, found %', v_n; end if;
  perform 1 from auth.users where id = v_uid and email_confirmed_at is not null and banned_until > now();
  if not found then raise exception 'premise: sign-in % is not the confirmed, blocked one', v_uid; end if;

  perform set_config('request.headers', json_build_object('x-change-reason',
    'Fred, 2026-10-29: add Jonathan Veras (contractor, GDO bot) as Office and link his existing sign-in. One-off: '
    || 'Add person could not take an email that already has a sign-in (migration 2026-10-29_1840).')::text, true);

  insert into public.employees (full_name, status, email, access_level, payroll_week_start_day)
  values ('Jonathan Veras', 'ACTIVE', 'jon.v@ayache.com', 'office', 5)
  returning id into v_id;

  update auth.users set banned_until = null where id = v_uid;
  insert into hr.sign_in_changes (employee_id, auth_user_id, action, status, reason, requested_by_email,
                                  requested_by_employee, finished_at)
  values (v_id, v_uid, 'turn_on', 'done',
          'Fred in chat 2026-10-29: create an account for Jonathan (one-off, migration 2026-10-29_1840)',
          'fred@ayache.com', 2, now());

  -- VERIFY: the apps' gate, asked as his own sign-in, finds exactly this person
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', 'jon.v@ayache.com',
    'role', 'authenticated', 'aud', 'authenticated')::text, true);
  v_acc := hr.get_my_access();
  if (v_acc->>'employee_id')::bigint is distinct from v_id then
    raise exception 'verify: get_my_access employee_id % (want %)', v_acc->>'employee_id', v_id;
  end if;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.headers', '', true);

  perform 1 from auth.users where id = v_uid and banned_until is null;
  if not found then raise exception 'verify: sign-in still blocked'; end if;
end $$;

commit;
