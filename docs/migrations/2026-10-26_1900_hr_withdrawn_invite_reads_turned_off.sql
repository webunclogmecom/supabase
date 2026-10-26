-- ============================================================================
-- 2026-10-26_1900 · HR App: a withdrawn invite reads as turned off, not as a live invite
-- ============================================================================
-- Found closing Fred's third live invite on 2026-10-26 (Trello zRTbWvXn): test person 58 was set Inactive, which turns
-- the unaccepted invite's sign-in off (banned). The Security tab then showed the chip "Invite sent" and "Invite sent
-- 5:00 PM. The link works until ." (an empty time). Two causes, both from the Send invite work of the same day:
--  1. hr.fn_sign_in_summary tested "never confirmed" BEFORE "turned off", so a turned-off unaccepted invite read as
--     state 'unconfirmed'. Its "Turn sign-in back on" button therefore never showed, although hr.fn_invite_refusal
--     step 10 tells the admin "...invite was withdrawn. Turn the sign-in back on first." Now turned off wins.
--  2. hr.fn_invite_timing counted a turned-off invite as pending: invite_sent_at set while invite_expires_at (which
--     already left banned sign-ins out) was empty. A turned-off invite is no longer pending.
-- Reach measured before: one person (58, a test row). Spliced from the live bodies (md5-guarded, one anchor each).
-- Rollback: 2026-10-26_rollback_hr_withdrawn_invite_reads_turned_off.sql
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF left(md5(pg_get_functiondef('hr.fn_sign_in_summary(bigint)'::regprocedure)), 8) <> '787df79c' THEN
    RAISE EXCEPTION 'guard: hr.fn_sign_in_summary changed'; END IF;
  IF left(md5(pg_get_functiondef('hr.fn_invite_timing(bigint)'::regprocedure)), 8) <> '1beab93f' THEN
    RAISE EXCEPTION 'guard: hr.fn_invite_timing changed'; END IF;
END $g$;

CREATE TEMP TABLE wi_acl_before ON COMMIT DROP AS
  SELECT p.oid::regprocedure::text k, p.proacl::text a FROM pg_proc p
   WHERE p.oid IN ('hr.fn_sign_in_summary(bigint)'::regprocedure, 'hr.fn_invite_timing(bigint)'::regprocedure);

-- Probe: person 58 as it is (its unaccepted invite turned off), and with the turn-off lifted (always undone).
CREATE FUNCTION pg_temp.wi_probe(p_lift boolean) RETURNS jsonb LANGUAGE plpgsql AS $p$
DECLARE r jsonb;
BEGIN
  BEGIN
    IF p_lift THEN UPDATE auth.users SET banned_until = NULL WHERE lower(email) = 'fred+invite2@ayache.com'; END IF;
    r := jsonb_build_object('state', hr.fn_sign_in_summary(58)->>'state', 'sent', hr.fn_invite_timing(58)->>'invite_sent_at',
                            'until', hr.fn_invite_timing(58)->>'invite_expires_at');
    RAISE EXCEPTION 'wi_undo:%', r::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'wi_undo:%' THEN RAISE; END IF;
    RETURN substr(SQLERRM, 9)::jsonb;
  END;
END $p$;

DO $c$ DECLARE r jsonb; BEGIN
  r := pg_temp.wi_probe(false);
  IF r->>'state' <> 'unconfirmed' OR r->>'sent' IS NULL OR r->>'until' IS NOT NULL THEN
    RAISE EXCEPTION 'control: the old bodies did not show the defect %', r; END IF;
END $c$;

DO $s$
DECLARE d text; a text;
BEGIN
  d := pg_get_functiondef('hr.fn_sign_in_summary(bigint)'::regprocedure);
  a := $a$'state', case when u.email_confirmed_at is null then 'unconfirmed'$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: summary state'; END IF;
  d := replace(d, a, $n$'state', case when u.banned_until is not null and u.banned_until > now() then 'turned_off'   -- 2026-10-26_1900: turned off wins
                          when u.email_confirmed_at is null then 'unconfirmed'$n$);
  EXECUTE d;

  d := pg_get_functiondef('hr.fn_invite_timing(bigint)'::regprocedure);
  a := $a$where (select count(*) from u) = 1 and su.email_confirmed_at is null and su.invited_at is not null$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: timing pend'; END IF;
  d := replace(d, a, a || $n$
              and (su.banned_until is null or su.banned_until <= now())   -- 2026-10-26_1900: a turned-off invite is not pending$n$);
  EXECUTE d;
END $s$;

DO $v$ DECLARE r jsonb; BEGIN
  IF EXISTS (SELECT 1 FROM wi_acl_before b JOIN pg_proc p ON p.oid = b.k::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'verify: privileges moved'; END IF;
  -- turned off: reads turned_off, no pending invite
  r := pg_temp.wi_probe(false);
  IF r->>'state' <> 'turned_off' OR r->>'sent' IS NOT NULL OR r->>'until' IS NOT NULL THEN RAISE EXCEPTION 'verify: withdrawn %', r; END IF;
  -- the same invite not turned off: unchanged (unconfirmed, sent and until both set)
  r := pg_temp.wi_probe(true);
  IF r->>'state' <> 'unconfirmed' OR r->>'sent' IS NULL OR r->>'until' IS NULL THEN RAISE EXCEPTION 'verify: pending %', r; END IF;
  -- a confirmed, turned-off sign-in still reads turned_off (45), a confirmed active one active (Fred, 2)
  IF hr.fn_sign_in_summary(45)->>'state' <> 'turned_off' OR hr.fn_sign_in_summary(2)->>'state' <> 'active' THEN
    RAISE EXCEPTION 'verify: confirmed sign-ins moved'; END IF;
  RAISE NOTICE 'a withdrawn invite reads turned off; a pending one is unchanged';
END $v$;

COMMIT;
