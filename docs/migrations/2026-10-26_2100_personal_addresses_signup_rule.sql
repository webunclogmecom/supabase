-- ============================================================================
-- 2026-10-26_2100 · Personal addresses, step 4 (last): the sign-up rule lets an Active person's own address in
-- ============================================================================
-- Fred, 2026-10-26: "go ahead with personal addresses" (Trello zRTbWvXn; plan Building Apps/HR App/docs/specs/
-- 2026-10-26-invite-followups-plan.md part A). Steps 1 to 3 are live: the database's staff checks
-- (public.fn_is_staff_email, 2026-10-26_2000), the 17 edge functions (_shared/staff.ts) and all 8 staff app logins
-- (staff = hr.get_my_access returns a person). Only now may a sign-in exist at a personal address: before step 3 a
-- person would have set a password every app then refused.
--
--  1. public.fn_restrict_signup_domains (the before-user-created hook): a sign-in is created for a company address OR
--     the email of exactly one Active employee (public.fn_is_staff_email). Self sign-up is off (D16), so this runs for an
--     invite (generate_link). Its message no longer names the two domains. GRANT EXECUTE on fn_is_staff_email to
--     supabase_auth_admin (the role the hook runs as).
--  2. hr.fn_invite_refusal step 6 (spliced): follows the hook by itself; its sentence no longer says "company addresses
--     only" (it can now fire only if an address stops belonging to one Active person between two checks).
--  3. public.log_access_health (spliced): "a sign-in outside the two company domains" becomes "a sign-in that is not
--     staff" (fn_is_staff_email false) and not turned off, so an Active person's own Gmail is not reported; the
--     reviewed-version fingerprint of the sign-up rule moves to the new body. Issue names (kinds) unchanged.
-- Rollback: 2026-10-26_rollback_personal_addresses_signup_rule.sql
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.fn_restrict_signup_domains(jsonb)'::regprocedure)) <> 'ad0b912c75d4e8f6a5d7ce7c493da6e6' THEN
    RAISE EXCEPTION 'guard: the sign-up rule changed'; END IF;
  IF left(md5(pg_get_functiondef('hr.fn_invite_refusal(bigint,bigint)'::regprocedure)), 8) <> 'dcbd9e60' THEN
    RAISE EXCEPTION 'guard: hr.fn_invite_refusal changed'; END IF;
  IF left(md5(pg_get_functiondef('public.log_access_health()'::regprocedure)), 8) <> '77fbccf4' THEN
    RAISE EXCEPTION 'guard: public.log_access_health changed'; END IF;
  IF to_regprocedure('public.fn_is_staff_email(text)') IS NULL THEN RAISE EXCEPTION 'guard: run 2026-10-26_2000 first'; END IF;
END $g$;

CREATE TEMP TABLE pa_acl_before ON COMMIT DROP AS
  SELECT p.oid::regprocedure::text k, p.proacl::text a FROM pg_proc p
   WHERE p.oid IN ('public.fn_restrict_signup_domains(jsonb)'::regprocedure, 'hr.fn_invite_refusal(bigint,bigint)'::regprocedure,
                   'public.log_access_health()'::regprocedure);

-- control: the old hook refuses an Active person's personal address
DO $c$ BEGIN
  IF NOT (public.fn_restrict_signup_domains('{"user":{"email":"michaelescobar1606@gmail.com"}}'::jsonb) ? 'error') THEN
    RAISE EXCEPTION 'control: the old sign-up rule already lets a personal address in'; END IF;
END $c$;

GRANT EXECUTE ON FUNCTION public.fn_is_staff_email(text) TO supabase_auth_admin;

CREATE OR REPLACE FUNCTION public.fn_restrict_signup_domains(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
  v_email  text := lower(coalesce(event->'user'->>'email', ''));
BEGIN
  -- 2026-10-26_2100 (personal addresses): a sign-in is created for a company address or for the email of exactly one
  -- Active employee: public.fn_is_staff_email, the one staff-email rule. Self sign-up is off (D16), so this runs for an
  -- invite.
  IF NOT coalesce(public.fn_is_staff_email(v_email), false) THEN
    RETURN jsonb_build_object(
      'error', jsonb_build_object(
        'message', 'Sign-up is limited to UnclogMe staff. Ask an admin to send you an invite.',
        'http_code', 403
      )
    );
  END IF;
  RETURN '{}'::jsonb;  -- allow
END;
$function$;

DO $s$
DECLARE d text; a text; v_new text := md5(pg_get_functiondef('public.fn_restrict_signup_domains(jsonb)'::regprocedure));
BEGIN
  -- 2. hr.fn_invite_refusal step 6
  d := pg_get_functiondef('hr.fn_invite_refusal(bigint,bigint)'::regprocedure);
  a := $a$return 'Invites go to company addresses only (@unclogme.com or @ayache.com). ' || v_first || '''s email is a personal address.';$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: refusal step 6'; END IF;
  d := replace(d, a, $n$return v_first || '''s email cannot get a sign-in: it must belong to exactly one active person in the HR App.';   -- 2026-10-26_2100$n$);
  a := $a$-- 6. a company address: the sign-up rule itself decides (Supabase runs it when the invite creates the user), never a copy$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: refusal step 6 comment'; END IF;
  d := replace(d, a, $n$-- 6. the sign-up rule itself decides (Supabase runs it when the invite creates the user), never a copy: a company address or an Active person's own (2026-10-26_2100)$n$);
  EXECUTE d;

  -- 3. public.log_access_health (CRLF body: single-line anchors only)
  d := pg_get_functiondef('public.log_access_health()'::regprocedure);
  a := $a$'reason', format('A sign-in at %s is outside unclogme.com and ayache.com and is not turned off.',$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: health reason 1'; END IF;
  d := replace(d, a, $n$'reason', format('A sign-in at %s is not a company address, belongs to no active person in the HR App, and is not turned off.',$n$);
  a := $a$     and coalesce(substring(lower(u.email) from '@([^@]+)$'), '') not in ('unclogme.com', 'ayache.com');$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: health filter 1'; END IF;
  d := replace(d, a, $n$     and not coalesce(public.fn_is_staff_email(u.email), false);   -- 2026-10-26_2100: an Active person's own address is staff$n$);
  a := 'ad0b912c75d4e8f6a5d7ce7c493da6e6';
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: health fingerprint'; END IF;
  d := replace(d, a, v_new);
  a := $a$'reason', 'The sign-up rule is not the reviewed version, so sign-ups may no longer be limited to unclogme.com and ayache.com.',$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: health reason 2'; END IF;
  d := replace(d, a, $n$'reason', 'The sign-up rule is not the reviewed version, so sign-ups may no longer be limited to UnclogMe staff.',$n$);
  a := $a$(the invite test adds one address for a short time), put back the reviewed body of public.fn_restrict_signup_domains (fingerprint ad0b912c)$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'splice: health what to do'; END IF;
  d := replace(d, a, '(the invite test adds one address for a short time), put back the reviewed body of public.fn_restrict_signup_domains (fingerprint '
                     || left(v_new, 8) || ', Supabase 2026-10-26_2100)');
  EXECUTE d;
END $s$;

DO $v$ DECLARE r text; v_items jsonb; BEGIN
  IF EXISTS (SELECT 1 FROM pa_acl_before b JOIN pg_proc p ON p.oid = b.k::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'verify: privileges moved'; END IF;
  -- the role the hook runs as can run both (postgres cannot SET ROLE to it, so the rights are asserted directly; the staff
  -- rule is SECURITY DEFINER, so EXECUTE is all it needs)
  IF NOT has_function_privilege('supabase_auth_admin', 'public.fn_restrict_signup_domains(jsonb)', 'EXECUTE')
     OR NOT has_function_privilege('supabase_auth_admin', 'public.fn_is_staff_email(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'verify: the hook role cannot run the rule'; END IF;
  -- the rule
  IF public.fn_restrict_signup_domains('{"user":{"email":"michaelescobar1606@gmail.com"}}'::jsonb) <> '{}'::jsonb      -- Active, personal
     OR public.fn_restrict_signup_domains('{"user":{"email":"New.Hire@UnclogMe.com"}}'::jsonb) <> '{}'::jsonb          -- company
     OR NOT (public.fn_restrict_signup_domains('{"user":{"email":"webunclogme@gmail.com"}}'::jsonb) ? 'error')          -- Inactive (45)
     OR NOT (public.fn_restrict_signup_domains('{"user":{"email":"nobody.at.all.zz@gmail.com"}}'::jsonb) ? 'error')     -- nobody
     OR NOT (public.fn_restrict_signup_domains('{"user":{}}'::jsonb) ? 'error') THEN                                     -- no email
    RAISE EXCEPTION 'verify: the sign-up rule'; END IF;
  -- the invite rule follows: an Active person's personal address is invitable (Michael Escobar, 40)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b', 'email', 'fred@ayache.com',
                                                             'role', 'authenticated')::text, true);
  r := hr.fn_invite_refusal(40, 2);
  IF r IS NOT NULL THEN RAISE EXCEPTION 'verify: invite refused for an Active person''s own address: %', r; END IF;
  PERFORM set_config('request.jwt.claims', '', true);
  -- the health check: runs, does not flag its own sign-up rule as changed, and flags nobody new (always undone)
  BEGIN
    PERFORM public.log_access_health();
    SELECT details->'items' INTO v_items FROM public.sync_log WHERE sync_source = 'access-health' ORDER BY id DESC LIMIT 1;
    RAISE EXCEPTION 'pa_undo:%', coalesce(v_items, '[]'::jsonb)::text;
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE 'pa_undo:%' THEN RAISE; END IF;
    v_items := substr(SQLERRM, 9)::jsonb;
  END;
  IF v_items::text LIKE '%signup_rule_changed%' THEN RAISE EXCEPTION 'verify: the health check flags the new sign-up rule %', v_items; END IF;
  IF v_items::text LIKE '%outside_domain_sign_in%' THEN RAISE EXCEPTION 'verify: a sign-in is flagged %', v_items; END IF;
  RAISE NOTICE 'sign-up rule: company addresses and Active people''s own addresses';
END $v$;

COMMIT;
