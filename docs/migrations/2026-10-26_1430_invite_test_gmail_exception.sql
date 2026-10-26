-- ============================================================================
-- 2026-10-26_1430 · Send invite phase 7: let exactly the test mailbox through the sign-up domain rule
-- ============================================================================
-- Plan: Building Apps/HR App/docs/specs/2026-10-26-send-invite-implementation-plan.md, phase 7 step 3 ("The one exception").
-- The phase 7 test invites "ZZ Invite Test" at webunclogme@gmail.com. Supabase runs public.fn_restrict_signup_domains (the
-- before-user-created Auth hook) when the invite creates the sign-in, and hr.fn_invite_refusal calls the same function, so
-- without this one exception the invite is refused as a personal address.
-- TEMPORARY: the revert file (2026-10-26_rollback_invite_test_gmail_exception.sql) puts the body back, fingerprint
-- ad0b912c, in the same sitting. The WORKING-NOW.md line stays until the revert is read back.
-- One anchored edit: the IF gains "AND v_email <> 'webunclogme@gmail.com'". Grants are kept by CREATE OR REPLACE and
-- checked below (postgres, service_role, supabase_auth_admin EXECUTE).
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.fn_restrict_signup_domains(jsonb)'::regprocedure)) <> 'ad0b912c75d4e8f6a5d7ce7c493da6e6' THEN
    RAISE EXCEPTION 'guard: public.fn_restrict_signup_domains(jsonb) is not the ad0b912c body';
  END IF;
END $g$;

CREATE TEMP TABLE p7_acl_before ON COMMIT DROP AS
  SELECT proacl::text a FROM pg_proc WHERE oid = 'public.fn_restrict_signup_domains(jsonb)'::regprocedure;

CREATE OR REPLACE FUNCTION public.fn_restrict_signup_domains(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
DECLARE
  v_email  text := lower(coalesce(event->'user'->>'email', ''));
  v_domain text := substring(v_email from '@([^@]+)$');
BEGIN
  -- Send invite phase 7: the test mailbox only, removed again by the revert file in the same sitting
  IF (v_domain IS NULL OR v_domain NOT IN ('ayache.com', 'unclogme.com')) AND v_email <> 'webunclogme@gmail.com' THEN
    RETURN jsonb_build_object(
      'error', jsonb_build_object(
        'message', 'Sign-up is restricted to ayache.com and unclogme.com accounts.',
        'http_code', 403
      )
    );
  END IF;
  RETURN '{}'::jsonb;  -- allow
END;
$function$;

-- VERIFY
DO $v$
DECLARE f text := 'public.fn_restrict_signup_domains(jsonb)';
  ok  boolean;
BEGIN
  IF (SELECT proacl::text FROM pg_proc WHERE oid = f::regprocedure) IS DISTINCT FROM (SELECT a FROM p7_acl_before) THEN
    RAISE EXCEPTION 'verify: grants changed';
  END IF;
  IF public.fn_restrict_signup_domains('{"user":{"email":"webunclogme@gmail.com"}}') ? 'error' THEN RAISE EXCEPTION 'verify: test mailbox refused'; END IF;
  IF public.fn_restrict_signup_domains('{"user":{"email":"WebUnclogMe@Gmail.com"}}') ? 'error' THEN RAISE EXCEPTION 'verify: test mailbox (case) refused'; END IF;
  IF NOT public.fn_restrict_signup_domains('{"user":{"email":"someone.else@gmail.com"}}') ? 'error' THEN RAISE EXCEPTION 'verify: another gmail passes'; END IF;
  IF NOT public.fn_restrict_signup_domains('{"user":{"email":"webunclogme@gmail.com.evil.com"}}') ? 'error' THEN RAISE EXCEPTION 'verify: a look-alike passes'; END IF;
  IF NOT public.fn_restrict_signup_domains('{"user":{}}') ? 'error' THEN RAISE EXCEPTION 'verify: no email passes'; END IF;
  IF public.fn_restrict_signup_domains('{"user":{"email":"a@unclogme.com"}}') ? 'error' THEN RAISE EXCEPTION 'verify: unclogme.com refused'; END IF;
  IF public.fn_restrict_signup_domains('{"user":{"email":"a@ayache.com"}}') ? 'error' THEN RAISE EXCEPTION 'verify: ayache.com refused'; END IF;
  RAISE NOTICE 'fn_restrict_signup_domains: test mailbox allowed, other gmail and look-alike refused, staff domains allowed, grants unchanged';
END $v$;

COMMIT;
