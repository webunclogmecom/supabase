-- 2026-05-26_hr_sandbox_recovery.sql
--
-- Recovery patch for the HR sandbox (klgtrdwrasrlxbmfyvdh) after the
-- rollback migration left two issues exposed:
--
--   1. service_role had no SELECT/INSERT/UPDATE/DELETE on public.* tables.
--      Symptom: HTTP 403 / PostgreSQL 42501 "permission denied for table X"
--      on every canonical table except photo_classifications. Likely a
--      side-effect of how the FP sandbox was originally cloned (table
--      privileges weren't restored to service_role).
--
--   2. Schema cache may still be stale after the DROP SCHEMA hr CASCADE.
--      NOTIFY pgrst, 'reload schema' forces PostgREST to re-introspect.
--
-- WHAT THIS DOES (Rule 5: idempotent — re-run safely)
--   - GRANT ALL on every table/sequence/function in public to service_role
--     (Supabase's intended default).
--   - GRANT SELECT to authenticated + anon on every table in public
--     (matches FP-clone pattern of "authenticated read, anon read for
--     non-PII"; deliberate per project_sandbox_anon_accepted_risk.md +
--     feedback_ship_first_harden_later.md — sandbox is not Prod).
--   - Re-apply ALTER DEFAULT PRIVILEGES so future tables inherit the grants.
--   - NOTIFY pgrst to reload schema cache.
--
-- WHAT THIS DOES NOT TOUCH
--   - hr schema (still absent — Yannick's AI builds it)
--   - app_admin_users (does not exist; HR's AI creates it)
--   - RLS policies (pre-existing FP-clone policies kept)
--   - data rows (no INSERT/UPDATE/DELETE of business data)
--
-- HOW TO APPLY
--   1. Open https://supabase.com/dashboard/project/klgtrdwrasrlxbmfyvdh/sql/new
--   2. Paste this entire file.
--   3. Run.
--   4. Re-probe: curl …/rest/v1/employees?select=id&limit=1 -H apikey:<key>
--      Expected: 200 with JSON array.

BEGIN;

-- ============================================================
-- 1. Schema USAGE
-- ============================================================
GRANT USAGE ON SCHEMA public TO service_role, authenticated, anon;

-- ============================================================
-- 2. Table privileges
-- ============================================================
-- service_role: full access (Supabase intended default)
GRANT ALL    ON ALL TABLES    IN SCHEMA public TO service_role;
GRANT ALL    ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT ALL    ON ALL FUNCTIONS IN SCHEMA public TO service_role;

-- authenticated: read all canonical tables (RLS still applies for writes)
GRANT SELECT ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- anon: read all canonical tables (matches FP-clone ship-first pattern)
GRANT SELECT ON ALL TABLES IN SCHEMA public TO anon;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon;

-- ============================================================
-- 3. Default privileges for any NEW table added later (e.g., by
--    Yannick's AI via the hr schema migration; doesn't auto-affect
--    public since DEFAULT PRIVILEGES is per-creator role, but harmless)
-- ============================================================
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL    ON TABLES    TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL    ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES    TO authenticated, anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO authenticated, anon;

COMMIT;

-- ============================================================
-- 4. Force PostgREST to reload schema cache
-- ============================================================
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- VERIFY (run after the migration finishes)
-- ============================================================
-- SELECT grantee, privilege_type
-- FROM information_schema.role_table_grants
-- WHERE table_schema = 'public' AND table_name = 'employees'
-- ORDER BY grantee, privilege_type;
--
-- Expected: service_role has DELETE/INSERT/REFERENCES/SELECT/TRIGGER/TRUNCATE/UPDATE
--           authenticated has SELECT
--           anon has SELECT
