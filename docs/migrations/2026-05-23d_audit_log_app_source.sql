-- 2026-05-23d_audit_log_app_source.sql
--
-- ADR-016: add app_source + request_context to audit.logs.
--
-- All four apps run on anon JWTs with no `sub` claim, so the current
-- audit.log_change trigger always writes changed_by=NULL and
-- jwt_claims=NULL. That left a forensic gap surfaced 2026-05-23: the
-- only way to attribute the 5/21 18:23 bulk DERM-not-required flip
-- (115 visits in one statement) to "Yannick clicked the DERM Tracker
-- bulk button" was timestamp clustering — inference, not evidence.
--
-- This migration adds two columns:
--   * app_source TEXT — normalized friendly name (one of:
--     'derm-tracker', 'field-portal', 'admin-review',
--     'visit-calendar', 'lovable-preview', 'sql',
--     'other:<host>', or whatever X-App-Source was explicitly set to)
--   * request_context JSONB — curated subset of request metadata
--     (origin, referer, method, path, app_source_hint). Excludes
--     Authorization / Cookie / full User-Agent to avoid token/PII
--     leakage inside the audit table.
--
-- Trigger logic order of precedence for app_source:
--   1. X-App-Source request header if set (explicit beats derived)
--   2. Origin header → subdomain mapping
--   3. 'sql' when no Origin (direct SQL / service_role scripts)
--
-- Defensive: every current_setting + cast wrapped in EXCEPTION block.
-- The trigger is SECURITY DEFINER and fires on every write — a parse
-- error here would brick the canonical DB. Better to log null than
-- to fail the write.
--
-- jwt_claims and changed_by are preserved unchanged. They'll start
-- populating automatically when Phase 2 user-level auth ships, with no
-- further migration.
--
-- Audit (Rule 8): VIEW/trigger update + columns on audit.logs. The
-- audit table itself is intentionally not audited (recursion guard
-- in log_change). Per ADR-010, tampering on audit.* is monitored via
-- Layer 1 pgaudit.
--
-- Idempotent (Rule 5): ADD COLUMN IF NOT EXISTS + CREATE INDEX IF NOT
-- EXISTS + CREATE OR REPLACE FUNCTION. Re-runnable.
--
-- Partitioned-table notes: audit.logs is partitioned monthly via
-- pg_partman. Postgres 11+ automatically propagates ALTER TABLE
-- ADD COLUMN and CREATE INDEX on the partitioned parent to all
-- existing and future child partitions, so no per-partition action.

BEGIN;

-- ============================================================
-- 1. SCHEMA — add columns to partitioned parent
-- ============================================================
ALTER TABLE audit.logs
  ADD COLUMN IF NOT EXISTS app_source TEXT,
  ADD COLUMN IF NOT EXISTS request_context JSONB;

COMMENT ON COLUMN audit.logs.app_source IS
  'Normalized app identifier (per ADR-016). Derived in audit.log_change from X-App-Source header (explicit) or Origin header (derived), else ''sql'' for direct SQL, else ''other:<host>'' for unmapped origins.';

COMMENT ON COLUMN audit.logs.request_context IS
  'Curated subset of PostgREST request metadata (origin, referer, method, path, app_source_hint). Does NOT include Authorization / Cookie / User-Agent — those are PII/token-leak risks inside this table. NULL for direct SQL.';

-- ============================================================
-- 2. INDEX — app_source for forensic queries
-- ============================================================
-- Propagates to all monthly partitions via Postgres native partition
-- inheritance.
CREATE INDEX IF NOT EXISTS idx_audit_logs_app_source
  ON audit.logs (app_source);

-- ============================================================
-- 3. TRIGGER FUNCTION — extend with app_source + request_context
-- ============================================================
-- All pg_catalog references kept (SECURITY DEFINER + SET search_path='').
-- The new request-context capture is wrapped in EXCEPTION to keep the
-- trigger robust against malformed headers / missing PostgREST context.

CREATE OR REPLACE FUNCTION audit.log_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_pk_cols          TEXT[];
  v_pk               JSONB;
  v_old_clean        JSONB;
  v_new_clean        JSONB;
  v_headers          JSONB;
  v_origin           TEXT;
  v_referer          TEXT;
  v_method           TEXT;
  v_path             TEXT;
  v_x_app_source     TEXT;
  v_app_source       TEXT;
  v_request_context  JSONB;
BEGIN
  -- Recursion guard — don't audit the audit table itself.
  IF TG_TABLE_SCHEMA = 'audit' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- ---------------------------------------------------------
  -- 1. Primary key extraction (unchanged from prior version)
  -- ---------------------------------------------------------
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

  -- ---------------------------------------------------------
  -- 2. Old/new diff with updated_at stripped (unchanged)
  -- ---------------------------------------------------------
  v_old_clean := CASE WHEN TG_OP IN ('UPDATE','DELETE')
                      THEN pg_catalog.to_jsonb(OLD) - 'updated_at'
                 END;
  v_new_clean := CASE WHEN TG_OP IN ('INSERT','UPDATE')
                      THEN pg_catalog.to_jsonb(NEW) - 'updated_at'
                 END;

  -- Skip no-op UPDATEs (same value)
  IF TG_OP = 'UPDATE' AND v_old_clean IS NOT DISTINCT FROM v_new_clean THEN
    RETURN NEW;
  END IF;

  -- ---------------------------------------------------------
  -- 3. NEW: capture request context defensively
  -- ---------------------------------------------------------
  -- Wrap the header parse in EXCEPTION — a malformed JSON in
  -- request.headers must NOT brick the underlying write.
  BEGIN
    v_headers := pg_catalog.nullif(pg_catalog.current_setting('request.headers', true), '')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    v_headers := NULL;
  END;

  v_origin       := COALESCE(v_headers->>'origin', '');
  v_referer      := COALESCE(v_headers->>'referer', '');
  v_method       := pg_catalog.nullif(pg_catalog.current_setting('request.method', true), '');
  v_path         := pg_catalog.nullif(pg_catalog.current_setting('request.path', true), '');
  v_x_app_source := pg_catalog.nullif(v_headers->>'x-app-source', '');

  -- Derive app_source: explicit X-App-Source > Origin mapping > 'sql'
  v_app_source := COALESCE(
    v_x_app_source,
    CASE
      WHEN v_origin = '' THEN 'sql'
      WHEN v_origin LIKE '%derm.unclogme.app%'    THEN 'derm-tracker'
      WHEN v_origin LIKE '%fp.unclogme.app%'      THEN 'field-portal'
      WHEN v_origin LIKE '%grease-buddy-dash%'    THEN 'admin-review'
      WHEN v_origin LIKE '%6533c3ee%'             THEN 'visit-calendar'
      WHEN v_origin LIKE '%lovable.app%'          THEN 'lovable-preview'
      ELSE 'other:' || COALESCE(pg_catalog.substring(v_origin, 'https?://([^/]+)'), v_origin)
    END
  );

  -- Build curated request_context. Strip nulls to keep the jsonb tight.
  -- Excludes Authorization / Cookie / User-Agent on purpose.
  v_request_context := pg_catalog.jsonb_strip_nulls(
    pg_catalog.jsonb_build_object(
      'origin',          pg_catalog.nullif(v_origin, ''),
      'referer',         pg_catalog.nullif(v_referer, ''),
      'method',          v_method,
      'path',            v_path,
      'app_source_hint', v_x_app_source
    )
  );

  -- ---------------------------------------------------------
  -- 4. Insert the audit row
  -- ---------------------------------------------------------
  INSERT INTO audit.logs (
    table_schema, table_name, record_pk, operation,
    old_row, new_row,
    changed_by, db_role, jwt_claims,
    app_source, request_context
  ) VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    v_pk,
    TG_OP,
    v_old_clean,
    v_new_clean,
    pg_catalog.nullif(pg_catalog.current_setting('request.jwt.claim.sub', true), '')::uuid,
    CURRENT_USER::text,
    pg_catalog.nullif(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb,
    v_app_source,
    CASE WHEN v_request_context = '{}'::jsonb THEN NULL ELSE v_request_context END
  );

  RETURN COALESCE(NEW, OLD);
END;
$function$;

COMMIT;

-- ============================================================
-- VERIFICATION (run after apply)
-- ============================================================
-- 1. Direct SQL write should land as app_source='sql':
--    UPDATE visits SET derm_required = derm_required WHERE id = <X>;
--    -- (no-op skipped by trigger; pick a column that actually changes)
--
-- 2. REST write from DERM Tracker (live URL) should land as
--    app_source='derm-tracker'. Test by toggling a flag in the UI
--    and then querying:
--      SELECT app_source, request_context FROM audit.logs
--      WHERE table_name='visits' AND changed_at > NOW() - INTERVAL '5 minutes'
--      ORDER BY changed_at DESC LIMIT 5;
--
-- 3. Curl-with-header test for explicit X-App-Source override:
--    curl -X PATCH "$URL/rest/v1/visits?id=eq.<X>" \
--         -H "apikey: $ANON" \
--         -H "Authorization: Bearer $ANON" \
--         -H "Content-Type: application/json" \
--         -H "Prefer: return=representation" \
--         -H "X-App-Source: test-suite" \
--         -d '{"derm_required": false}'
--    -- Should land as app_source='test-suite'.
--
-- 4. Confirm old rows untouched (app_source IS NULL for everything
--    written before this migration applied):
--      SELECT COUNT(*) FILTER (WHERE app_source IS NULL) AS pre_migration,
--             COUNT(*) FILTER (WHERE app_source IS NOT NULL) AS post_migration
--      FROM audit.logs;
