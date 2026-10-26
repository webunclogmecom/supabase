-- 2026-10-26_rollback_invite_test_gmail_exception.sql
--
-- Puts public.fn_restrict_signup_domains back to the body from before 2026-10-26_1430_invite_test_gmail_exception.sql
-- (copied from the live catalog on 2026-10-26, fingerprint ad0b912c75d4e8f6a5d7ce7c493da6e6), so the test mailbox is
-- refused again. Phase 7 clean-up, step 2. Read back the md5 after running it.

BEGIN;
SET LOCAL lock_timeout = '3s';

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
  IF v_domain IS NULL OR v_domain NOT IN ('ayache.com', 'unclogme.com') THEN
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

DO $v$ BEGIN
  IF md5(pg_get_functiondef('public.fn_restrict_signup_domains(jsonb)'::regprocedure)) <> 'ad0b912c75d4e8f6a5d7ce7c493da6e6' THEN
    RAISE EXCEPTION 'verify: body is not back to ad0b912c';
  END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_restrict_signup_domains(jsonb)'::regprocedure) IS DISTINCT FROM (SELECT a FROM p7_acl_before) THEN
    RAISE EXCEPTION 'verify: grants changed';
  END IF;
  IF NOT public.fn_restrict_signup_domains('{"user":{"email":"webunclogme@gmail.com"}}') ? 'error' THEN RAISE EXCEPTION 'verify: test mailbox still passes'; END IF;
  IF public.fn_restrict_signup_domains('{"user":{"email":"a@unclogme.com"}}') ? 'error' THEN RAISE EXCEPTION 'verify: unclogme.com refused'; END IF;
  RAISE NOTICE 'fn_restrict_signup_domains back to ad0b912c; test mailbox refused again';
END $v$;

COMMIT;
