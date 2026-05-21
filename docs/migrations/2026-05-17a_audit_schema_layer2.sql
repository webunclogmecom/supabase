-- 2026-05-17a_audit_schema_layer2.sql
--
-- Audit Trail — Layer 2 (row-level business-data triggers)
-- Per ADR 010, this is the row-level event store. Captures who/when/what for
-- business-data changes on a narrow set of audited tables. Companion to
-- Layer 1 (pgaudit, in 2026-05-17e) and Layer 3 (webhook_events_log,
-- already exists).
--
-- Design:
--   * Schema: audit (segregated from public.* canonical + per-app schemas)
--   * Single partitioned table: audit.logs, partitioned monthly via pg_partman
--   * 24-month retention (SOC2 floor is 1y; HIPAA is 6y; DERM ~3y. Go 24mo.)
--   * Single reusable trigger function: audit.log_change()
--   * SECURITY DEFINER + SET search_path = '' (Supabase-mandated safety)
--   * No anon access; authenticated read-only; service_role bypass
--   * Append-only — no UPDATE/DELETE policies on audit.logs
--
-- Triggers themselves attach in subsequent migrations (b, c, d).

BEGIN;

-- ---------------------------------------------------------------------------
-- Extensions (pg_cron lives in 'extensions' schema on Supabase by default;
-- pg_partman needs its own schema which must exist before extension creation)
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS partman;
CREATE EXTENSION IF NOT EXISTS pg_partman WITH SCHEMA partman;
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS audit;
GRANT USAGE ON SCHEMA audit TO authenticated, service_role;
-- Intentionally NO grant to anon. The audit log isn't a customer surface.

-- ---------------------------------------------------------------------------
-- Partitioned table
-- ---------------------------------------------------------------------------
CREATE TABLE audit.logs (
  id            BIGINT GENERATED ALWAYS AS IDENTITY,
  table_schema  TEXT NOT NULL,
  table_name    TEXT NOT NULL,
  record_pk     JSONB NOT NULL,
  operation     TEXT NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
  old_row       JSONB,
  new_row       JSONB,
  changed_by    UUID,
  db_role       TEXT NOT NULL,
  jwt_claims    JSONB,
  changed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (id, changed_at)
) PARTITION BY RANGE (changed_at);

-- pg_partman manages monthly partitions, 3 months pre-created, 24mo retention.
-- create_parent itself creates the current-month partition + N premake months,
-- so no manual CREATE PARTITION needed.
SELECT partman.create_parent(
  p_parent_table => 'audit.logs',
  p_control      => 'changed_at',
  p_interval     => '1 month',
  p_premake      => 3
);

UPDATE partman.part_config
   SET retention             = '24 months',
       retention_keep_table  = false,
       retention_keep_index  = false,
       infinite_time_partitions = true
 WHERE parent_table = 'audit.logs';

-- ---------------------------------------------------------------------------
-- Indexes (each partition inherits)
-- ---------------------------------------------------------------------------
CREATE INDEX audit_logs_table_changed_idx
  ON audit.logs (table_name, changed_at DESC);
CREATE INDEX audit_logs_changed_at_idx
  ON audit.logs (changed_at DESC);
CREATE INDEX audit_logs_record_id_idx
  ON audit.logs ((record_pk->>'id'))
  WHERE record_pk ? 'id';
CREATE INDEX audit_logs_changed_by_idx
  ON audit.logs (changed_by, changed_at DESC)
  WHERE changed_by IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Trigger function
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION audit.log_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $func$
DECLARE
  v_pk_cols   TEXT[];
  v_pk        JSONB;
  v_old_clean JSONB;
  v_new_clean JSONB;
BEGIN
  -- Recursion guard: don't audit the audit schema
  IF TG_TABLE_SCHEMA = 'audit' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- Build PK JSON from primary-key columns (handles composite keys).
  -- ANY is a SQL keyword (operator), not a function — don't schema-qualify it.
  SELECT pg_catalog.array_agg(a.attname::TEXT)
    INTO v_pk_cols
    FROM pg_catalog.pg_index i
    JOIN pg_catalog.pg_attribute a
      ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
   WHERE i.indrelid = TG_RELID AND i.indisprimary;

  IF v_pk_cols IS NULL THEN
    v_pk := '{}'::jsonb;
  ELSE
    SELECT pg_catalog.jsonb_object_agg(col, pg_catalog.to_jsonb(COALESCE(NEW, OLD))->col)
      INTO v_pk
      FROM pg_catalog.unnest(v_pk_cols) AS col;
  END IF;

  -- Strip auto-managed updated_at column from comparison + storage
  v_old_clean := CASE WHEN TG_OP IN ('UPDATE','DELETE')
                      THEN pg_catalog.to_jsonb(OLD) - 'updated_at'
                 END;
  v_new_clean := CASE WHEN TG_OP IN ('INSERT','UPDATE')
                      THEN pg_catalog.to_jsonb(NEW) - 'updated_at'
                 END;

  -- Skip no-op UPDATEs (only updated_at changed) to reduce Jobber-sync noise
  IF TG_OP = 'UPDATE' AND v_old_clean IS NOT DISTINCT FROM v_new_clean THEN
    RETURN NEW;
  END IF;

  INSERT INTO audit.logs (
    table_schema, table_name, record_pk, operation,
    old_row, new_row, changed_by, db_role, jwt_claims
  ) VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    v_pk,
    TG_OP,
    v_old_clean,
    v_new_clean,
    pg_catalog.nullif(pg_catalog.current_setting('request.jwt.claim.sub', true), '')::uuid,
    pg_catalog.current_user::text,
    pg_catalog.nullif(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb
  );

  RETURN COALESCE(NEW, OLD);
END;
$func$;

-- Owner = postgres so SECURITY DEFINER runs with full privileges
ALTER FUNCTION audit.log_change() OWNER TO postgres;

-- Lock down direct execution — only triggers should invoke
REVOKE ALL ON FUNCTION audit.log_change() FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- RLS — append-only, authenticated-read, no anon
-- ---------------------------------------------------------------------------
ALTER TABLE audit.logs ENABLE ROW LEVEL SECURITY;

-- authenticated users (Phase 2 auth) can read
CREATE POLICY "authenticated_read_all"
  ON audit.logs
  FOR SELECT
  TO authenticated
  USING (true);

-- service_role bypasses RLS automatically (Supabase default behavior)
-- anon: no policy = no access
-- NO UPDATE policy. NO DELETE policy. audit.logs is append-only.
-- Retention happens via pg_partman partition drops (run as superuser via cron).

-- ---------------------------------------------------------------------------
-- Grants on the table itself
-- ---------------------------------------------------------------------------
GRANT SELECT ON audit.logs TO authenticated;
GRANT ALL    ON audit.logs TO service_role;  -- needed for retention cron
-- intentionally no grants to anon

-- Ensure trigger function can INSERT (SECURITY DEFINER bypasses RLS)
GRANT INSERT ON audit.logs TO postgres;

-- ---------------------------------------------------------------------------
-- pg_partman maintenance: schedule via pg_cron (runs every 6h, idempotent)
-- ---------------------------------------------------------------------------
SELECT cron.schedule(
  'audit-partman-maintenance',
  '0 */6 * * *',
  $$SELECT partman.run_maintenance(p_analyze := false)$$
);

COMMIT;

-- ---------------------------------------------------------------------------
-- Smoke-test the function (no real table affected — just confirms it parses)
-- ---------------------------------------------------------------------------
-- SELECT 'audit.log_change function created' AS status WHERE EXISTS (
--   SELECT 1 FROM pg_proc WHERE proname = 'log_change'
--     AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'audit')
-- );
