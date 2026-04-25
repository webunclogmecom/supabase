-- ============================================================================
-- enable_rls_security_fix.sql — close 7 public-schema tables to anon access
-- ============================================================================
-- Triggered by Supabase security alert 2026-04-19:
--   * rls_disabled_in_public  — 7 tables had RLS off, exposing them via anon key
--   * sensitive_columns_exposed — webhook_tokens.{access_token,refresh_token,client_secret}
--
-- Strategy: enable RLS with NO policies. service_role bypasses RLS by design,
-- so all our scripts and Edge Functions keep working. anon (and authenticated)
-- get denied. This is the right move because none of these tables should ever
-- be queried by end-user / public client applications — they're operational.
--
-- This migration is idempotent: ALTER TABLE ... ENABLE ROW LEVEL SECURITY is a
-- no-op when already enabled.
-- ============================================================================

ALTER TABLE public.webhook_tokens               ENABLE ROW LEVEL SECURITY;  -- CRITICAL: contains Jobber tokens
ALTER TABLE public.webhook_events_log           ENABLE ROW LEVEL SECURITY;  -- raw webhook payloads
ALTER TABLE public.notes                        ENABLE ROW LEVEL SECURITY;  -- visit/job notes
ALTER TABLE public.photos                       ENABLE ROW LEVEL SECURITY;  -- signed Storage refs
ALTER TABLE public.photo_links                  ENABLE ROW LEVEL SECURITY;  -- polymorphic junction
ALTER TABLE public.jobber_oversized_attachments ENABLE ROW LEVEL SECURITY;  -- migration tracking
ALTER TABLE public.vehicle_telemetry_readings   ENABLE ROW LEVEL SECURITY;  -- Samsara telemetry

-- Verification: list any remaining tables in public.* without RLS
DO $$
DECLARE
  bad_tables text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
  INTO bad_tables
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r'
    AND c.relrowsecurity = false;

  IF bad_tables IS NOT NULL THEN
    RAISE WARNING 'public tables still without RLS: %', bad_tables;
  ELSE
    RAISE NOTICE 'All public tables have RLS enabled.';
  END IF;
END $$;
