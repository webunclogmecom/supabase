-- 2026-05-27_zones_lock_anon_writes.sql
--
-- Companion to 2026-05-27_zones_reference_table.sql. The Prod project carries
-- a `ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL TO anon, authenticated`
-- setup that auto-grants every write privilege to anon on any new public
-- table. For reference data (zones) we want anon SELECT only. REVOKE
-- everything else and keep SELECT.
--
-- Also enable RLS as defense-in-depth so even if a grant slips through later,
-- no row-level mutation can occur. Policy: anon/authenticated may SELECT all
-- active zones; nothing else.
--
-- Idempotent (Rule 5): REVOKE + GRANT are repeatable; CREATE POLICY uses
-- DO block guard.

BEGIN;

-- 1. Reset grants — keep only SELECT for anon/authenticated.
REVOKE ALL ON public.zones FROM anon, authenticated;
GRANT SELECT ON public.zones TO anon, authenticated;

-- 2. Defense-in-depth: enable RLS + permissive SELECT policy.
ALTER TABLE public.zones ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname='public' AND tablename='zones' AND policyname='zones_anon_select_active'
  ) THEN
    CREATE POLICY zones_anon_select_active ON public.zones
      FOR SELECT
      TO anon, authenticated
      USING (is_active = true);
  END IF;
END $$;

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- 1. Grants should now be SELECT-only for anon + authenticated:
--    SELECT grantee, privilege_type
--    FROM information_schema.role_table_grants
--    WHERE table_schema='public' AND table_name='zones'
--      AND grantee IN ('anon','authenticated')
--    ORDER BY grantee, privilege_type;
--    Expected: 1 row per grantee, privilege_type='SELECT'.
--
-- 2. RLS enabled:
--    SELECT relname, relrowsecurity
--    FROM pg_class WHERE relname='zones';
--    Expected: relrowsecurity = true.
--
-- 3. Policy in place:
--    SELECT policyname, cmd, roles, qual
--    FROM pg_policies WHERE tablename='zones';
