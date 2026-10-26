-- ============================================================================
-- ROLLBACK of 2026-10-26_1900_hr_withdrawn_invite_reads_turned_off.sql
-- ============================================================================
-- Removes the two spliced lines; each result must hash to its pre-1900 body (787df79c, 1beab93f).
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $r$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('hr.fn_sign_in_summary(bigint)'::regprocedure);
  a := $a$'state', case when u.banned_until is not null and u.banned_until > now() then 'turned_off'   -- 2026-10-26_1900: turned off wins
                          when u.email_confirmed_at is null then 'unconfirmed'$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: summary'; END IF;
  d := replace(d, a, $n$'state', case when u.email_confirmed_at is null then 'unconfirmed'$n$);
  IF left(md5(d), 8) <> '787df79c' THEN RAISE EXCEPTION 'rollback: summary body does not match the pre-1900 body'; END IF;
  EXECUTE d;

  d := pg_get_functiondef('hr.fn_invite_timing(bigint)'::regprocedure);
  a := $a$
              and (su.banned_until is null or su.banned_until <= now())   -- 2026-10-26_1900: a turned-off invite is not pending$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: timing'; END IF;
  d := replace(d, a, '');
  IF left(md5(d), 8) <> '1beab93f' THEN RAISE EXCEPTION 'rollback: timing body does not match the pre-1900 body'; END IF;
  EXECUTE d;
END $r$;

COMMIT;
