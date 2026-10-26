-- ============================================================================
-- ROLLBACK of 2026-10-26_1930_hr_turn_on_needs_active.sql
-- ============================================================================
-- Removes the two spliced lines; the result must hash to the pre-1930 body (f8a1b6fc).
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $r$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('hr.request_sign_in_action(bigint,text)'::regprocedure);
  a := $a$
    -- 2026-10-26_1930 (Fred: "only when putting them as active they can sign in")
    when p_action = 'turn_on' and v_e.status is distinct from 'ACTIVE' then v_first || ' is inactive. Set them back to Active first.'$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: anchor'; END IF;
  d := replace(d, a, '');
  IF left(md5(d), 8) <> 'f8a1b6fc' THEN RAISE EXCEPTION 'rollback: body does not match the pre-1930 body'; END IF;
  EXECUTE d;
END $r$;

COMMIT;
