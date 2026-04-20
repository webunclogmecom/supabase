-- ============================================================================
-- Migration: viktor_readonly Postgres role
-- ============================================================================
-- Purpose:
--   Give Viktor (AI coworker in Slack) a dedicated, read-only Postgres user
--   for the main DB. Viktor uses this to read fresh operational data (clients,
--   visits, invoices, DERM manifests, photos, notes). Write access is blocked
--   at the role level — not just by convention.
--
--   Yan's Sales App writes to a SEPARATE Supabase project. Viktor gets full
--   write access there via the service_role key of that project, not this role.
--
-- Security design:
--   - NOSUPERUSER, NOCREATEDB, NOCREATEROLE — least privilege
--   - NOINHERIT — role privileges don't inherit into other roles
--   - CONNECTION LIMIT 10 — caps concurrent queries
--   - SELECT grants on public + ops schemas only
--   - DEFAULT PRIVILEGES — future tables in public/ops auto-grant SELECT
--   - Explicit REVOKE on INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER
--   - Explicit REVOKE on webhook_tokens (holds OAuth credentials — never read)
--
-- How to use:
--   - Direct PG:  postgresql://viktor_readonly:<PW>@db.wbasvhvvismukaqdnouk.supabase.co:5432/postgres
--   - Pooler:     postgresql://viktor_readonly.wbasvhvvismukaqdnouk:<PW>@aws-1-us-east-1.pooler.supabase.com:6543/postgres
--
-- Password handling:
--   The password lives ONLY in Viktor's credential store (handed to Viktor
--   via Slack DM). If compromised, rotate via:
--     ALTER ROLE viktor_readonly WITH PASSWORD '<new>';
--   …and DM Viktor the new one.
--
-- 3NF check (role creation):
--   N/A — role creation is a Postgres auth concern, not schema-shaped data.
--
-- Rotation reminder:
--   Rotate password every 90 days. Record rotation in docs/runbook.md §8.
-- ============================================================================

BEGIN;

-- Create (or update password of) the role
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'viktor_readonly') THEN
    -- REAL PASSWORD IS NOT IN THIS FILE. Applied via a separate one-shot
    -- command using a password generated at setup time, documented in Fred's
    -- credential store. This file is the idempotent re-apply template.
    CREATE ROLE viktor_readonly
      WITH LOGIN PASSWORD 'REPLACE_WITH_REAL_PASSWORD_AT_APPLY_TIME'
      NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
      CONNECTION LIMIT 10;
  END IF;
END$$;

-- Schema usage
GRANT USAGE ON SCHEMA public TO viktor_readonly;
GRANT USAGE ON SCHEMA ops    TO viktor_readonly;

-- Current SELECT grants
GRANT SELECT ON ALL TABLES    IN SCHEMA public TO viktor_readonly;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO viktor_readonly;
GRANT SELECT ON ALL TABLES    IN SCHEMA ops    TO viktor_readonly;

-- Future-proof: new tables created in these schemas auto-grant SELECT to viktor
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES    TO viktor_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO viktor_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA ops    GRANT SELECT ON TABLES    TO viktor_readonly;

-- Belt-and-suspenders: explicit revokes (defense in depth vs. any future GRANT drift)
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON ALL TABLES IN SCHEMA public FROM viktor_readonly;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON ALL TABLES IN SCHEMA ops    FROM viktor_readonly;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM viktor_readonly;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA ops    FROM viktor_readonly;

-- Sensitive tables: revoke access even if a blanket grant slipped through
REVOKE ALL ON webhook_tokens FROM viktor_readonly;
-- (If any new *_tokens or *_secrets table is added, add its REVOKE here.)

COMMIT;

-- ============================================================================
-- Verification (run ad-hoc, not as part of the migration):
-- ============================================================================
-- SELECT rolname, rolcanlogin, rolsuper, rolcreaterole, rolcreatedb, rolconnlimit
-- FROM pg_roles WHERE rolname = 'viktor_readonly';
--
-- SELECT table_schema, table_name, privilege_type
-- FROM information_schema.role_table_grants
-- WHERE grantee = 'viktor_readonly'
-- ORDER BY table_schema, table_name, privilege_type;
--
-- SELECT COUNT(*) AS must_be_zero
-- FROM information_schema.role_table_grants
-- WHERE grantee = 'viktor_readonly'
--   AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE');
