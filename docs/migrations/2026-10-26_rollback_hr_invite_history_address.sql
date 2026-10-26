-- ============================================================================
-- ROLLBACK of 2026-10-26_1800_hr_invite_history_address.sql
-- ============================================================================
-- Puts back the two bodies (inverse splices, each anchor asserted once; the result must hash to the pre-1800 md5) and
-- clears the sign-in on the two backfilled rows. Invites finished after 1800 keep their sign-in: harmless, nothing
-- reads it once the History line is back.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $r$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('hr.finish_sign_in_action(bigint,boolean,text)'::regprocedure);
  a := $a$,
         -- 2026-10-26_1800: a finished invite records the sign-in generate_link just created (History names its address)
         auth_user_id = coalesce(c.auth_user_id, case when p_ok and c.action = 'invite' then
           (select u.id from auth.users u join public.employees e on lower(btrim(u.email)) = lower(btrim(e.email))
             where e.id = c.employee_id order by u.created_at desc limit 1) end)$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: finish set'; END IF;
  d := replace(d, a, '');
  IF left(md5(d), 8) <> '08fe10f4' THEN RAISE EXCEPTION 'rollback: finish body does not match the pre-1800 body'; END IF;
  EXECUTE d;

  d := pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure);
  a := $a$when 'invite' then 'Invite sent to ' || coalesce((select lower(u.email) from auth.users u where u.id = c.auth_user_id),
                                                                lower(btrim(v_e.email)), 'their email')   -- 2026-10-26_1800: the address it went to$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: record invite line'; END IF;
  d := replace(d, a, $n$when 'invite' then 'Invite sent to ' || coalesce(lower(btrim(v_e.email)), 'their email')   -- 2026-10-26$n$);
  a := $a$when 'turn_off' then case when c.reason = 'Email changed before the invite was accepted'   -- 2026-10-26_1800
                                  then 'Invite to ' || coalesce((select lower(u.email) from auth.users u where u.id = c.auth_user_id), 'the old address')
                                       || ' withdrawn: the email changed'
                                  else 'Sign-in turned off' end$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: record turn_off line'; END IF;
  d := replace(d, a, $n$when 'turn_off' then 'Sign-in turned off'$n$);
  IF left(md5(d), 8) <> '37e741b5' THEN RAISE EXCEPTION 'rollback: record body does not match the pre-1800 body'; END IF;
  EXECUTE d;
END $r$;

UPDATE hr.sign_in_changes SET auth_user_id = NULL WHERE id IN (890, 912) AND action = 'invite';

COMMIT;
