-- ============================================================================
-- Migration: yannick_readonly Postgres role — 2026-05-08
-- ============================================================================
-- Purpose:
--   Yannick (UnclogMe co-founder) needs read-only access to the Prod DB from
--   his Claude Code instance. This role gives him a dedicated, non-superuser
--   Postgres user that can SELECT against canonical schemas + ops views, but
--   cannot INSERT, UPDATE, DELETE, TRUNCATE, or read secrets (webhook_tokens).
--
-- Adapted from create_viktor_readonly_role.sql (same security shape).
--
-- Security design:
--   - NOSUPERUSER, NOCREATEDB, NOCREATEROLE — least privilege
--   - NOINHERIT — no surprise role-chain elevations
--   - CONNECTION LIMIT 10 — Claude Code might open a few parallel queries
--   - SELECT grants on public + ops only
--   - DEFAULT PRIVILEGES — future tables auto-grant SELECT
--   - Explicit REVOKE on every write privilege + on webhook_tokens
--
-- How to use (give Yannick):
--   Direct PG:
--     postgresql://yannick_readonly:<PW>@db.wbasvhvvismukaqdnouk.supabase.co:5432/postgres
--   Pooler (recommended for MCP / Claude Code transient connections):
--     postgresql://yannick_readonly.wbasvhvvismukaqdnouk:<PW>@aws-1-us-east-1.pooler.supabase.com:6543/postgres
--
-- Password handling:
--   The password is generated at apply time and printed once by the apply
--   script (scripts/probes/apply_yannick_readonly.js). Fred forwards it to
--   Yannick via secure channel. Rotation:
--     ALTER ROLE yannick_readonly WITH PASSWORD '<new>';
--   …and DM Yannick the new one.
-- ============================================================================

BEGIN;

-- Create or update the role (apply script substitutes the literal password)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'yannick_readonly') THEN
    CREATE ROLE yannick_readonly
      WITH LOGIN PASSWORD 'REPLACE_WITH_REAL_PASSWORD_AT_APPLY_TIME'
      NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
      BYPASSRLS
      CONNECTION LIMIT 10;
  END IF;
END$$;

-- BYPASSRLS rationale: most public tables have RLS policies targeting only
-- the `authenticated` and `service_role` roles (set up for the Lovable app +
-- Edge Functions). yannick_readonly is neither of those, so without BYPASSRLS
-- the role's SELECT grants are filtered to 0 rows on every hardened table.
-- BYPASSRLS lets it read freely; writes are still blocked by the explicit
-- REVOKEs below.
ALTER ROLE yannick_readonly WITH BYPASSRLS;

-- Schema usage
GRANT USAGE ON SCHEMA public TO yannick_readonly;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name='ops') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA ops TO yannick_readonly';
  END IF;
END$$;

-- Current SELECT grants
GRANT SELECT ON ALL TABLES    IN SCHEMA public TO yannick_readonly;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO yannick_readonly;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name='ops') THEN
    EXECUTE 'GRANT SELECT ON ALL TABLES    IN SCHEMA ops TO yannick_readonly';
  END IF;
END$$;

-- Future-proof: new tables in these schemas auto-grant SELECT
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES    TO yannick_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO yannick_readonly;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name='ops') THEN
    EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA ops GRANT SELECT ON TABLES TO yannick_readonly';
  END IF;
END$$;

-- Belt-and-suspenders: explicit revokes (defense in depth vs. any future GRANT drift)
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON ALL TABLES IN SCHEMA public FROM yannick_readonly;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name='ops') THEN
    EXECUTE 'REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA ops FROM yannick_readonly';
  END IF;
END$$;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM yannick_readonly;

-- Sensitive tables: no read access even if a blanket grant slipped through
REVOKE ALL ON webhook_tokens FROM yannick_readonly;

COMMIT;
