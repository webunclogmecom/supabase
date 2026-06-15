-- ============================================================================
-- 2026-06-15 — Before-User-Created auth hook: restrict sign-up to office domains
-- ============================================================================
-- Phase-1 of the app auth gate (docs/specs/2026-06-15-app-auth-gate-design.md §4.1).
-- Fail-CLOSED Postgres-function hook (runs in the signup transaction; cannot
-- fail-open like an HTTP/Edge hook). Restricts ALL account creation (Google OAuth
-- AND email/password) to {ayache.com, unclogme.com}. Domain is matched on the part
-- after the LAST '@' (robust against multi-@ / subdomain spoof like x@ayache.com.evil.com).
-- NOTE (verified vs Supabase docs 2026-06-15): the hook payload exposes user.email +
-- app_metadata.provider but NOT email_verified or Google's hd claim — so this is
-- domain string matching; the spec's negative acceptance test (off-domain Google
-- rejected) is what proves it. Enabled via Management API /config/auth, URI
-- pg-functions://postgres/public/fn_restrict_signup_domains.
-- Audit (ADR 010): N/A — pure function, no business table touched.
-- Reversible: disable via hook_before_user_created_enabled=false; drop function.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_restrict_signup_domains(event jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = ''
AS $$
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
$$;

-- The hook is invoked by the auth admin role only.
GRANT EXECUTE ON FUNCTION public.fn_restrict_signup_domains(jsonb) TO supabase_auth_admin;
REVOKE EXECUTE ON FUNCTION public.fn_restrict_signup_domains(jsonb) FROM anon, authenticated, public;
