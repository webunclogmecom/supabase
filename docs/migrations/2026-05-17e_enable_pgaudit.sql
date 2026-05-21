-- 2026-05-17e_enable_pgaudit.sql
--
-- Audit Trail Layer 1 — pgaudit extension for DDL + role + write tracking.
-- Complements Layer 2 (row-level triggers, migrations 17a-d) by capturing
-- statement-level activity that triggers can't see:
--   * Schema changes (CREATE/ALTER/DROP)
--   * Role/permission grants
--   * Function executions
--   * Bulk statement writes
--
-- Configured at the ROLE level (Supabase explicit recommendation) — system
-- level would flood logs with extension chatter. Output goes to Supabase
-- Logs (Dashboard → Logs → Postgres).
--
-- IMPORTANT: NEVER log 'read' class. Would log every SELECT including all
-- Field Portal customer reads (~thousands/day). Massive log volume, ~zero
-- forensic value.
--
-- Per ADR 010 standing rule, this is the third pillar of our audit trail
-- alongside webhook_events_log (Layer 3 / external-source provenance).

BEGIN;

-- Enable the extension (available on Supabase, uninstalled by default)
CREATE EXTENSION IF NOT EXISTS pgaudit;

-- ---------------------------------------------------------------------------
-- Role-level configuration
-- ---------------------------------------------------------------------------
-- authenticator: the role PostgREST switches to before assuming anon /
-- authenticated. Captures DDL + writes + function calls from PostgREST.
ALTER ROLE authenticator SET pgaudit.log = 'ddl, role, function, write';

-- service_role: bypasses RLS, used by background scripts (cron_jobber,
-- migrations, etc.). Wider coverage — capture misc events too for full audit.
ALTER ROLE service_role SET pgaudit.log = 'ddl, role, function, write, misc';

-- postgres: superuser. Captured for sanity (rare manual interventions).
ALTER ROLE postgres SET pgaudit.log = 'ddl, role';

-- anon: intentionally NOT logged. Customer reads via Field Portal are
-- already covered by Supabase access logs; we don't need pgaudit duplication.

-- ---------------------------------------------------------------------------
-- Settings to reduce noise
-- ---------------------------------------------------------------------------
-- Don't log catalog accesses (every SELECT touches pg_catalog under the hood)
ALTER ROLE authenticator SET pgaudit.log_catalog = off;
ALTER ROLE service_role  SET pgaudit.log_catalog = off;
ALTER ROLE postgres      SET pgaudit.log_catalog = off;

-- Log relation info (table name) for context — small overhead, high value
ALTER ROLE authenticator SET pgaudit.log_relation = on;
ALTER ROLE service_role  SET pgaudit.log_relation = on;
ALTER ROLE postgres      SET pgaudit.log_relation = on;

-- Note: pgaudit.log_parameter is platform-restricted on Supabase
-- (can't be set per-role). Default is 'off' anyway — no secrets logged.

COMMIT;
