-- ============================================================================
-- ROLLBACK of 2026-10-26_1830_hr_invite_wait_keeps_the_button.sql
-- ============================================================================
-- Removes the spliced lines from hr.get_employee_record; the result must hash to the pre-1830 body (59e89cef).
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $r$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure);
  a := $a$
  -- 2026-10-26_1830: the 60-second wait alone keeps Send invite (the app counts down from invite_retry_at; hr-sign-in
  -- still refuses a click inside the minute). The sentence is hr.fn_invite_refusal step 11, word for word.
  if v_invite = 'An invite went to ' || split_part(btrim(v_e.full_name), ' ', 1)
                || ' less than a minute ago. Wait a moment, then send again.' then
    v_invite := null;
  end if;$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: anchor'; END IF;
  d := replace(d, a, '');
  IF left(md5(d), 8) <> '59e89cef' THEN RAISE EXCEPTION 'rollback: body does not match the pre-1830 body'; END IF;
  EXECUTE d;
END $r$;

COMMIT;
