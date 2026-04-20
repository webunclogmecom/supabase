-- ============================================================================
-- Migration: drop viktor_readonly role (supersedes create_viktor_readonly_role.sql)
-- ============================================================================
-- Context:
--   The viktor_readonly Postgres login role was created 2026-04-20 as a
--   dedicated read-only credential for Viktor to access the main DB via
--   direct Postgres connection. Shortly after, we discovered Viktor's
--   native Supabase integration (Pipedream-backed) is the more idiomatic
--   path — it enforces read-only at the TOOL LAYER inside Viktor's UI,
--   with each SQL action (Upsert, Update, Insert, Delete, RPC, Proxy
--   Post/Put/Patch/Delete) togglable to 'Off'.
--
--   With all write tools turned Off on the "Main DB - Read Only"
--   integration, Viktor physically cannot issue mutating operations
--   against the main DB — regardless of what credentials are underneath.
--
--   The PG role became unused. Unused credentials rot (passwords shared
--   only via one-time Slack DM; rotation cadence is operational overhead
--   for zero benefit). Dropping.
--
-- If read-only access is needed later for a non-Viktor client (BI tool,
-- analytics dashboard, etc.), recreate using the companion file
-- `create_viktor_readonly_role.sql` as a template (change the role name).
--
-- 3NF check: N/A — role DROP is a Postgres auth concern.
-- ============================================================================

-- Guarded: the REVOKE statements error if the role doesn't exist. Wrap in
-- a DO block that checks for role existence first.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'viktor_readonly') THEN
    REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM viktor_readonly;
    REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM viktor_readonly;
    REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM viktor_readonly;
    REVOKE ALL ON ALL TABLES    IN SCHEMA ops    FROM viktor_readonly;
    REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ops    FROM viktor_readonly;
    REVOKE ALL ON SCHEMA public FROM viktor_readonly;
    REVOKE ALL ON SCHEMA ops    FROM viktor_readonly;

    ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES    FROM viktor_readonly;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM viktor_readonly;
    ALTER DEFAULT PRIVILEGES IN SCHEMA ops    REVOKE ALL ON TABLES    FROM viktor_readonly;

    DROP ROLE viktor_readonly;
  END IF;
END$$;
