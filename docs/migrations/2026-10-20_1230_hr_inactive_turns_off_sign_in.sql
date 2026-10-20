-- 2026-10-20_1230 · HR: setting a person Inactive turns their sign-in off (every staff app)
--
-- Fred, 2026-10-20: "When selecting Inactive, make it so they can't log in on the apps anymore."
-- Before this, Inactive only closed the HR App (hr.fn_access_caller needs an ACTIVE employee); every other staff app
-- checks the sign-in and the staff email domain only, so an Inactive person kept access everywhere else, and the edit
-- dialog told the admin to press "Turn off sign-in" by hand.
-- Now a trigger on public.employees does it whatever path changes the status:
--   ACTIVE -> INACTIVE: each confirmed sign-in with that email gets the same long block the HR App's "Turn off sign-in"
--     sets (auth.users.banned_until, 100 years; never a delete), its sessions are deleted (refresh tokens end; an access
--     token already issued works up to an hour), and hr.sign_in_changes records turn_off "Set to Inactive" (shown in
--     the record's Activity as "Sign-in turned off").
--   INACTIVE -> ACTIVE: the block is lifted ONLY when the latest sign-in change for that person is that automatic
--     turn_off (a sign-in an admin turned off by hand stays off); recorded as turn_on "Set to Active".
-- Measured before apply: 0 inactive people hold a confirmed sign-in, so nothing is back-filled.
-- No Slack/email notice is sent from here (the hr-sign-in edge function sends those for the manual buttons).
-- Rule 8: no new table (hr.sign_in_changes is the record, opted out). The trigger function is not callable by apps.
-- Rollback: DROP TRIGGER zz_hr_status_sign_in ON public.employees; DROP FUNCTION hr.trg_status_sign_in();
BEGIN;

CREATE FUNCTION hr.trg_status_sign_in()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u record; v_by text; v_caller bigint; v_last record;
begin
  if NEW.status is not distinct from OLD.status or nullif(btrim(NEW.email), '') is null then return NEW; end if;
  select x.email into v_by from auth.users x where x.id = auth.uid();
  v_caller := hr.fn_access_caller();

  if OLD.status = 'ACTIVE' and NEW.status = 'INACTIVE' then
    for u in select x.id from auth.users x
              where x.email_confirmed_at is not null and lower(btrim(x.email)) = lower(btrim(NEW.email))
                and (x.banned_until is null or x.banned_until <= now())
    loop
      update auth.users set banned_until = now() + interval '100 years' where id = u.id;
      delete from auth.sessions where user_id = u.id;
      insert into hr.sign_in_changes (employee_id, auth_user_id, action, status, reason, requested_by_email, requested_by_employee, finished_at)
      values (NEW.id, u.id, 'turn_off', 'done', 'Set to Inactive', v_by, v_caller, now());
    end loop;
  elsif OLD.status = 'INACTIVE' and NEW.status = 'ACTIVE' then
    select c.action, c.reason, c.auth_user_id into v_last from hr.sign_in_changes c
     where c.employee_id = NEW.id and c.status = 'done' and c.action in ('turn_off', 'turn_on')
     order by c.created_at desc, c.id desc limit 1;
    if v_last.action = 'turn_off' and v_last.reason = 'Set to Inactive' then
      for u in select x.id from auth.users x
                where x.email_confirmed_at is not null and lower(btrim(x.email)) = lower(btrim(NEW.email))
                  and x.banned_until > now()
      loop
        update auth.users set banned_until = null where id = u.id;
        insert into hr.sign_in_changes (employee_id, auth_user_id, action, status, reason, requested_by_email, requested_by_employee, finished_at)
        values (NEW.id, u.id, 'turn_on', 'done', 'Set to Active', v_by, v_caller, now());
      end loop;
    end if;
  end if;
  return NEW;
end $function$;

REVOKE ALL ON FUNCTION hr.trg_status_sign_in() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER zz_hr_status_sign_in AFTER UPDATE OF status ON public.employees
  FOR EACH ROW EXECUTE FUNCTION hr.trg_status_sign_in();

-- VERIFY on Serena (office, has a sign-in), always rolled back
DO $v$
DECLARE serena uuid := '5c5df96c-1924-410a-a996-e3e58c44e3c2';
  fred text := json_build_object('sub','5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b','email','fred@ayache.com','role','authenticated')::text;
  n_sess int;
BEGIN
  SELECT count(*) INTO n_sess FROM auth.sessions WHERE user_id = serena;
  BEGIN
    PERFORM set_config('request.jwt.claims', fred, true);
    PERFORM hr.update_employee(42, '{"status":"INACTIVE"}');
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = serena AND banned_until > now() + interval '50 years') THEN RAISE EXCEPTION 'V1 not blocked'; END IF;
    IF EXISTS (SELECT 1 FROM auth.sessions WHERE user_id = serena) THEN RAISE EXCEPTION 'V2 sessions left'; END IF;
    IF NOT EXISTS (SELECT 1 FROM hr.sign_in_changes WHERE employee_id = 42 AND action = 'turn_off' AND reason = 'Set to Inactive') THEN RAISE EXCEPTION 'V3 no record'; END IF;
    PERFORM hr.update_employee(42, '{"status":"ACTIVE"}');
    IF EXISTS (SELECT 1 FROM auth.users WHERE id = serena AND banned_until > now()) THEN RAISE EXCEPTION 'V4 not lifted'; END IF;
    -- a manual turn-off survives Inactive -> Active
    UPDATE auth.users SET banned_until = now() + interval '100 years' WHERE id = serena;
    INSERT INTO hr.sign_in_changes (employee_id, auth_user_id, action, status, reason, finished_at) VALUES (42, serena, 'turn_off', 'done', null, now() + interval '1 second');
    PERFORM hr.update_employee(42, '{"status":"INACTIVE"}');
    PERFORM hr.update_employee(42, '{"status":"ACTIVE"}');
    IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = serena AND banned_until > now()) THEN RAISE EXCEPTION 'V5 manual turn-off was lifted'; END IF;
    RAISE EXCEPTION 'rollback_probe';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'rollback_probe' THEN RAISE; END IF; END;
  IF (SELECT count(*) FROM auth.sessions WHERE user_id = serena) <> n_sess
     OR EXISTS (SELECT 1 FROM auth.users WHERE id = serena AND banned_until > now())
     OR (SELECT status FROM public.employees WHERE id = 42) <> 'ACTIVE' THEN RAISE EXCEPTION 'V6 probe not rolled back'; END IF;
  PERFORM set_config('request.jwt.claims', '', true);
END $v$;

COMMIT;
