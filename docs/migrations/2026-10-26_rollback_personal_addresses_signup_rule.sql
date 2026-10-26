-- ============================================================================
-- ROLLBACK of 2026-10-26_2100_personal_addresses_signup_rule.sql
-- ============================================================================
-- The sign-up rule back to the two company domains (the reviewed body, fingerprint ad0b912c), the invite rule's step 6
-- and the health check by inverse splices (each result must hash to its pre-2100 body), and the hook role's EXECUTE on
-- public.fn_is_staff_email revoked. Sign-ins already created at personal addresses stay; turn them off in the HR App if
-- they should not stay.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $r$
DECLARE d text; a text; v_new text := md5(pg_get_functiondef('public.fn_restrict_signup_domains(jsonb)'::regprocedure));
BEGIN
  -- the health check first: it names the current fingerprint
  d := pg_get_functiondef('public.log_access_health()'::regprocedure);
  a := $a$'reason', format('A sign-in at %s is not a company address, belongs to no active person in the HR App, and is not turned off.',$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: health reason 1'; END IF;
  d := replace(d, a, $n$'reason', format('A sign-in at %s is outside unclogme.com and ayache.com and is not turned off.',$n$);
  a := $a$     and not coalesce(public.fn_is_staff_email(u.email), false);   -- 2026-10-26_2100: an Active person's own address is staff$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: health filter 1'; END IF;
  d := replace(d, a, $n$     and coalesce(substring(lower(u.email) from '@([^@]+)$'), '') not in ('unclogme.com', 'ayache.com');$n$);
  IF (length(d) - length(replace(d, v_new, ''))) / length(v_new) <> 1 THEN RAISE EXCEPTION 'rollback: health fingerprint'; END IF;
  d := replace(d, v_new, 'ad0b912c75d4e8f6a5d7ce7c493da6e6');
  a := $a$'reason', 'The sign-up rule is not the reviewed version, so sign-ups may no longer be limited to UnclogMe staff.',$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: health reason 2'; END IF;
  d := replace(d, a, $n$'reason', 'The sign-up rule is not the reviewed version, so sign-ups may no longer be limited to unclogme.com and ayache.com.',$n$);
  a := '(fingerprint ' || left(v_new, 8) || ', Supabase 2026-10-26_2100)';
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: health what to do'; END IF;
  d := replace(d, a, '(fingerprint ad0b912c)');
  IF left(md5(d), 8) <> '77fbccf4' THEN RAISE EXCEPTION 'rollback: health body does not match the pre-2100 body'; END IF;
  EXECUTE d;

  d := pg_get_functiondef('hr.fn_invite_refusal(bigint,bigint)'::regprocedure);
  a := $a$return v_first || '''s email cannot get a sign-in: it must belong to exactly one active person in the HR App.';   -- 2026-10-26_2100$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: refusal step 6'; END IF;
  d := replace(d, a, $n$return 'Invites go to company addresses only (@unclogme.com or @ayache.com). ' || v_first || '''s email is a personal address.';$n$);
  a := $a$-- 6. the sign-up rule itself decides (Supabase runs it when the invite creates the user), never a copy: a company address or an Active person's own (2026-10-26_2100)$a$;
  IF (length(d) - length(replace(d, a, ''))) / length(a) <> 1 THEN RAISE EXCEPTION 'rollback: refusal comment'; END IF;
  d := replace(d, a, $n$-- 6. a company address: the sign-up rule itself decides (Supabase runs it when the invite creates the user), never a copy$n$);
  IF left(md5(d), 8) <> 'dcbd9e60' THEN RAISE EXCEPTION 'rollback: refusal body does not match the pre-2100 body'; END IF;
  EXECUTE d;
END $r$;

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
    RAISE EXCEPTION 'rollback: the sign-up rule is not the reviewed body'; END IF;
END $v$;

REVOKE EXECUTE ON FUNCTION public.fn_is_staff_email(text) FROM supabase_auth_admin;
COMMIT;
