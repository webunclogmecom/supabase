-- ============================================================================
-- 2026-10-26_1830 · HR App: the 60-second invite wait shows the countdown instead of hiding Send invite
-- ============================================================================
-- Found in Fred's second live invite on 2026-10-26 ("I sent the invite again, check it", Trello zRTbWvXn, item "Resend
-- wait"): for the minute after a send the Security tab showed no button and the sentence "An invite went to ZZ less
-- than a minute ago. Wait a moment, then send again." The HR App draws Send invite only when sign_in.can_invite is
-- true, and can_invite was false because the 60-second wait is a refusal of hr.fn_invite_refusal (step 11). So the
-- "Send again in 0:SS" countdown the app already has (from sign_in.invite_retry_at) could never show.
--
--  hr.get_employee_record (spliced): when the ONLY reason is the wait sentence, can_invite stays true and no
--  invite_reason is given; the app then shows the button disabled with the countdown and reloads at zero. Every other
--  reason (steps 1-10 come first, the 24-hour cap after) still hides the button. hr.fn_invite_refusal is unchanged, so
--  hr-sign-in still refuses a click inside the minute. If the wait sentence is ever reworded in fn_invite_refusal
--  without this line, the match simply fails and the page goes back to showing the sentence (safe).
-- Rollback: 2026-10-26_rollback_hr_invite_wait_keeps_the_button.sql
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF left(md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)), 8) <> '59e89cef' THEN
    RAISE EXCEPTION 'guard: hr.get_employee_record changed'; END IF;
END $g$;

CREATE TEMP TABLE iw_acl_before ON COMMIT DROP AS
  SELECT p.proacl::text a FROM pg_proc p WHERE p.oid = 'hr.get_employee_record(bigint)'::regprocedure;

-- Probe (always undone): a done invite row created now for p_emp, then the record's sign_in as Fred.
CREATE FUNCTION pg_temp.iw_probe(p_emp bigint) RETURNS jsonb LANGUAGE plpgsql AS $p$
DECLARE r jsonb;
BEGIN
  BEGIN
    INSERT INTO hr.sign_in_changes (employee_id, action, status, requested_by_email, requested_by_employee, finished_at)
      VALUES (p_emp, 'invite', 'done', 'fred@ayache.com', 2, now());
    PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b',
                                                               'email', 'fred@ayache.com', 'role', 'authenticated')::text, true);
    r := hr.get_employee_record(p_emp)->'sign_in';
    PERFORM set_config('request.jwt.claims', '', true);
    RAISE EXCEPTION 'iw_undo:%', jsonb_build_object('can_invite', r->'can_invite', 'invite_reason', r->'invite_reason',
                                                    'retry', r->'invite_retry_at')::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'iw_undo:%' THEN RAISE; END IF;
    RETURN substr(SQLERRM, 9)::jsonb;
  END;
END $p$;

-- Control on the old body: person 58 inside the wait has no button
DO $c$ DECLARE r jsonb; BEGIN
  r := pg_temp.iw_probe(58);
  IF coalesce((r->>'can_invite')::boolean, true) OR r->>'retry' IS NULL OR coalesce(r->>'invite_reason', '') NOT LIKE '%less than a minute ago%' THEN
    RAISE EXCEPTION 'control: the old body did not hide the button inside the wait %', r; END IF;
END $c$;

DO $s$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure);
  a := $a$if v_level = 'admin' then v_invite := hr.fn_invite_refusal(p_id, v_caller); end if;$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: record invite'; END IF;
  d := replace(d, a, a || $n$
  -- 2026-10-26_1830: the 60-second wait alone keeps Send invite (the app counts down from invite_retry_at; hr-sign-in
  -- still refuses a click inside the minute). The sentence is hr.fn_invite_refusal step 11, word for word.
  if v_invite = 'An invite went to ' || split_part(btrim(v_e.full_name), ' ', 1)
                || ' less than a minute ago. Wait a moment, then send again.' then
    v_invite := null;
  end if;$n$);
  EXECUTE d;
END $s$;

DO $v$ DECLARE r jsonb; BEGIN
  IF (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'hr.get_employee_record(bigint)'::regprocedure)
     IS DISTINCT FROM (SELECT a FROM iw_acl_before) THEN RAISE EXCEPTION 'verify: privileges moved'; END IF;
  -- inside the wait: the button stays, with the countdown time and no sentence
  r := pg_temp.iw_probe(58);
  IF NOT coalesce((r->>'can_invite')::boolean, false) OR r->>'retry' IS NULL OR r->>'invite_reason' IS NOT NULL THEN
    RAISE EXCEPTION 'verify: wait %', r; END IF;
  -- a real reason still wins inside the wait: 45 (ZZ Invite Test) is Inactive (its reason line is hidden because it
  -- has a sign-in; can_invite is what hides the button)
  r := pg_temp.iw_probe(45);
  IF coalesce((r->>'can_invite')::boolean, true) THEN
    RAISE EXCEPTION 'verify: a real reason was hidden %', r; END IF;
  -- the server still refuses inside the wait (fn_invite_refusal untouched)
  IF left(md5(pg_get_functiondef('hr.fn_invite_refusal(bigint,bigint)'::regprocedure)), 8) <> 'dcbd9e60' THEN
    RAISE EXCEPTION 'verify: fn_invite_refusal moved'; END IF;
  RAISE NOTICE 'the wait keeps the button; real reasons still hide it';
END $v$;

COMMIT;
