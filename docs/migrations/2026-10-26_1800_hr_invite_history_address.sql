-- ============================================================================
-- 2026-10-26_1800 · HR App History: an invite line names the address the invite went to
-- ============================================================================
-- Found in the live check of Fred's invite on 2026-10-26 ("I sent the invite, check it", Trello zRTbWvXn): the invite
-- went to fred+invite1@ayache.com, the email was then changed to fred+invite2@ayache.com, and the History read
-- "Invite sent to fred+invite2@ayache.com", because the line printed the person's CURRENT email. An invite row had no
-- sign-in to point at: the person has none when the invite is requested (auth_user_id NULL), and Auth creates it only
-- inside generate_link, after the request row is written.
--
--  1. hr.finish_sign_in_action (spliced): a finished invite (p_ok) records the sign-in it created, the Auth user with
--     the person's email at that moment (milliseconds after generate_link made it). Nothing else is changed; no reader
--     of auth_user_id filters invite rows in a way this changes (hr.trg_status_sign_in reads turn_off / turn_on only).
--  2. hr.get_employee_record (spliced, admin History only): "Invite sent to <that sign-in's email>" (the current email
--     only when no sign-in was recorded, e.g. a failed invite), and the turn-off written when an unaccepted invite's
--     email is changed reads "Invite to <old address> withdrawn: the email changed" instead of "Sign-in turned off".
--  3. Backfill, by rule: a done invite with no sign-in gets the ONE Auth user invited within 10 seconds of the row.
--     Expected: 890 (ZZ Invite Test, webunclogme@gmail.com) and 912 (ZZ Invite Test 2, fred+invite1@ayache.com).
--     hr.sign_in_changes has no audit trigger (it is the record); the two rows are named in the VERIFY.
-- Spliced from the live bodies (md5-guarded, one anchor each); grants asserted unchanged.
-- Rollback: 2026-10-26_rollback_hr_invite_history_address.sql
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF left(md5(pg_get_functiondef('hr.finish_sign_in_action(bigint,boolean,text)'::regprocedure)), 8) <> '08fe10f4' THEN
    RAISE EXCEPTION 'guard: hr.finish_sign_in_action changed'; END IF;
  IF left(md5(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure)), 8) <> '37e741b5' THEN
    RAISE EXCEPTION 'guard: hr.get_employee_record changed'; END IF;
END $g$;

CREATE TEMP TABLE ih_acl_before ON COMMIT DROP AS
  SELECT p.oid::regprocedure::text k, p.proacl::text a FROM pg_proc p
   WHERE p.oid IN ('hr.finish_sign_in_action(bigint,boolean,text)'::regprocedure, 'hr.get_employee_record(bigint)'::regprocedure);

-- The probe used before (control: must NOT record a sign-in) and after the splice (must record it). Fred (employee 2)
-- has a sign-in; a pending invite row for him is finished inside a block that is always undone.
CREATE FUNCTION pg_temp.ih_probe(p_ok boolean, p_action text) RETURNS uuid LANGUAGE plpgsql AS $p$
DECLARE v_id bigint; v_uid uuid;
BEGIN
  BEGIN
    INSERT INTO hr.sign_in_changes (employee_id, action, status, requested_by_email, requested_by_employee)
      VALUES (2, p_action, 'pending', 'fred@ayache.com', 2) RETURNING id INTO v_id;
    PERFORM hr.finish_sign_in_action(v_id, p_ok, 'probe');
    SELECT auth_user_id INTO v_uid FROM hr.sign_in_changes WHERE id = v_id;
    RAISE EXCEPTION 'ih_undo:%', coalesce(v_uid::text, 'null');
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'ih_undo:%' THEN RAISE; END IF;
    RETURN nullif(substr(SQLERRM, 9), 'null')::uuid;
  END;
END $p$;

DO $c$ BEGIN
  IF pg_temp.ih_probe(true, 'invite') IS NOT NULL THEN RAISE EXCEPTION 'control: the old body already records the sign-in'; END IF;
END $c$;

-- ---------------------------------------------------------------------------------------------------------------------
DO $s$
DECLARE d text; a text;
BEGIN
  -- 1. hr.finish_sign_in_action
  d := pg_get_functiondef('hr.finish_sign_in_action(bigint,boolean,text)'::regprocedure);
  a := $a$reason = left(nullif(btrim(p_reason), ''), 300), finished_at = now()$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: finish set'; END IF;
  d := replace(d, a, a || $n$,
         -- 2026-10-26_1800: a finished invite records the sign-in generate_link just created (History names its address)
         auth_user_id = coalesce(c.auth_user_id, case when p_ok and c.action = 'invite' then
           (select u.id from auth.users u join public.employees e on lower(btrim(u.email)) = lower(btrim(e.email))
             where e.id = c.employee_id order by u.created_at desc limit 1) end)$n$);
  EXECUTE d;

  -- 2. hr.get_employee_record, History lines
  d := pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure);
  a := $a$when 'invite' then 'Invite sent to ' || coalesce(lower(btrim(v_e.email)), 'their email')   -- 2026-10-26$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: record invite line'; END IF;
  d := replace(d, a, $n$when 'invite' then 'Invite sent to ' || coalesce((select lower(u.email) from auth.users u where u.id = c.auth_user_id),
                                                                lower(btrim(v_e.email)), 'their email')   -- 2026-10-26_1800: the address it went to$n$);
  a := $a$when 'turn_off' then 'Sign-in turned off'$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: record turn_off line'; END IF;
  d := replace(d, a, $n$when 'turn_off' then case when c.reason = 'Email changed before the invite was accepted'   -- 2026-10-26_1800
                                  then 'Invite to ' || coalesce((select lower(u.email) from auth.users u where u.id = c.auth_user_id), 'the old address')
                                       || ' withdrawn: the email changed'
                                  else 'Sign-in turned off' end$n$);
  EXECUTE d;
END $s$;

-- 3. Backfill by rule
WITH m AS (
  SELECT c.id, (array_agg(u.id))[1] uid, count(*) n
    FROM hr.sign_in_changes c
    JOIN auth.users u ON u.invited_at BETWEEN c.created_at - interval '10 seconds' AND coalesce(c.finished_at, c.created_at) + interval '10 seconds'
   WHERE c.action = 'invite' AND c.status = 'done' AND c.auth_user_id IS NULL
   GROUP BY c.id)
UPDATE hr.sign_in_changes c SET auth_user_id = m.uid FROM m WHERE m.id = c.id AND m.n = 1;

-- ---------------------------------------------------------------------------------------------------------------------
-- VERIFY (as Fred, an admin)
DO $v$
DECLARE r jsonb; h text;
BEGIN
  IF EXISTS (SELECT 1 FROM ih_acl_before b JOIN pg_proc p ON p.oid = b.k::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'verify: the privileges of a spliced function moved'; END IF;
  -- the probe now records the sign-in, and only for a finished invite
  IF pg_temp.ih_probe(true, 'invite') IS DISTINCT FROM '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b'::uuid THEN RAISE EXCEPTION 'verify: invite did not record the sign-in'; END IF;
  IF pg_temp.ih_probe(false, 'invite') IS NOT NULL THEN RAISE EXCEPTION 'verify: a failed invite recorded a sign-in'; END IF;
  IF pg_temp.ih_probe(true, 'reset_email') IS NOT NULL THEN RAISE EXCEPTION 'verify: a reset recorded a sign-in'; END IF;
  -- the backfill: exactly the two rows, to the right sign-ins; no done invite left without one
  IF (SELECT auth_user_id FROM hr.sign_in_changes WHERE id = 890) IS DISTINCT FROM 'b26677d3-1195-4818-9803-2ca80b426f37'::uuid
     OR (SELECT auth_user_id FROM hr.sign_in_changes WHERE id = 912) IS DISTINCT FROM '95977b6d-bc8d-4815-b068-775cc360a119'::uuid
     OR EXISTS (SELECT 1 FROM hr.sign_in_changes WHERE action = 'invite' AND status = 'done' AND auth_user_id IS NULL) THEN
    RAISE EXCEPTION 'verify: backfill'; END IF;
  -- the History (the record's 'activity' list) of ZZ Invite Test 2 (58)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com',
                                                             'role', 'authenticated')::text, true);
  r := hr.get_employee_record(58);
  h := (r->'activity')::text;
  IF h NOT LIKE '%Invite sent to fred+invite1@ayache.com%' OR h NOT LIKE '%Invite to fred+invite1@ayache.com withdrawn: the email changed%'
     OR h LIKE '%Invite sent to fred+invite2%' THEN
    RAISE EXCEPTION 'verify: history lines %', h; END IF;
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'invite sign-in recorded, two rows backfilled, History names the address';
END $v$;

COMMIT;
