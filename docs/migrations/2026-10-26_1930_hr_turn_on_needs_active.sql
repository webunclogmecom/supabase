-- ============================================================================
-- 2026-10-26_1930 · HR App: an Inactive person's sign-in comes back only by setting them Active
-- ============================================================================
-- Fred, 2026-10-26: "only when putting them as active they can sign in." Until now "Turn sign-in back on" had no status
-- check, so an admin could lift the turn-off of an Inactive person by hand (seen on test persons 45 and 58; they still
-- reached no app data, every access check needs an Active person). Setting them back to Active already lifts the
-- automatic turn-off (trigger zz_hr_status_sign_in).
--
--  hr.request_sign_in_action (spliced): turn_on for a person who is not ACTIVE is refused, recorded like every refusal:
--  "<first name> is inactive. Set them back to Active first."
-- Rollback: 2026-10-26_rollback_hr_turn_on_needs_active.sql
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF left(md5(pg_get_functiondef('hr.request_sign_in_action(bigint,text)'::regprocedure)), 8) <> 'f8a1b6fc' THEN
    RAISE EXCEPTION 'guard: hr.request_sign_in_action changed'; END IF;
END $g$;

CREATE TEMP TABLE ta_acl_before ON COMMIT DROP AS
  SELECT p.proacl::text a FROM pg_proc p WHERE p.oid = 'hr.request_sign_in_action(bigint,text)'::regprocedure;

-- Probe (always undone): Fred asks to turn on the sign-in of p_emp; returns the reply and the recorded status.
CREATE FUNCTION pg_temp.ta_probe(p_emp bigint) RETURNS jsonb LANGUAGE plpgsql AS $p$
DECLARE r jsonb; v_st text;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b',
                                                               'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    r := hr.request_sign_in_action(p_emp, 'turn_on');
    SELECT status INTO v_st FROM hr.sign_in_changes WHERE employee_id = p_emp AND action = 'turn_on' ORDER BY id DESC LIMIT 1;
    RAISE EXCEPTION 'ta_undo:%', (r || jsonb_build_object('recorded', v_st))::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'ta_undo:%' THEN RAISE; END IF;
    RETURN substr(SQLERRM, 9)::jsonb;
  END;
END $p$;

-- Control on the old body: the Inactive test person's sign-in can be turned back on
DO $c$ DECLARE r jsonb; BEGIN
  r := pg_temp.ta_probe(58);
  IF r->>'recorded' IS DISTINCT FROM 'pending' THEN RAISE EXCEPTION 'control: the old body already refused %', r; END IF;
END $c$;

DO $s$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('hr.request_sign_in_action(bigint,text)'::regprocedure);
  a := $a$    when p_action = 'turn_on' and not v_banned then v_first || '''s sign-in is already on.'$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: turn_on'; END IF;
  d := replace(d, a, a || $n$
    -- 2026-10-26_1930 (Fred: "only when putting them as active they can sign in")
    when p_action = 'turn_on' and v_e.status is distinct from 'ACTIVE' then v_first || ' is inactive. Set them back to Active first.'$n$);
  EXECUTE d;
END $s$;

DO $v$ DECLARE r jsonb; BEGIN
  IF (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'hr.request_sign_in_action(bigint,text)'::regprocedure)
     IS DISTINCT FROM (SELECT a FROM ta_acl_before) THEN RAISE EXCEPTION 'verify: privileges moved'; END IF;
  r := pg_temp.ta_probe(58);   -- Inactive, unaccepted invite turned off
  IF r->>'recorded' IS DISTINCT FROM 'refused' OR r::text NOT LIKE '%ZZ is inactive. Set them back to Active first.%' THEN
    RAISE EXCEPTION 'verify: 58 %', r; END IF;
  r := pg_temp.ta_probe(45);   -- Inactive, confirmed sign-in turned off
  IF r->>'recorded' IS DISTINCT FROM 'refused' OR r::text NOT LIKE '%is inactive. Set them back to Active first.%' THEN
    RAISE EXCEPTION 'verify: 45 %', r; END IF;
  RAISE NOTICE 'turn-on refused for an Inactive person';
END $v$;

COMMIT;
