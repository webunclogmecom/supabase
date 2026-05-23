-- 2026-05-23e_audit_function_nullif_fix.sql
--
-- HOT FIX for the 2026-05-23d audit.log_change function.
--
-- Bug: 2026-05-23d wrote `pg_catalog.nullif(...)` thinking NULLIF was a
-- regular function. It's not — NULLIF is a SQL standard expression
-- compiled to CASE WHEN, like COALESCE and CAST. Postgres rejects
-- `pg_catalog.nullif(text, unknown)` at runtime because the function
-- doesn't exist by that name.
--
-- Impact (2026-05-23 05:50–06:00 ET window between 2026-05-23d apply and
-- this fix): every UPDATE on an audited table that had a real diff
-- failed with `42883: function pg_catalog.nullif(text, unknown) does
-- not exist`. No-op UPDATEs succeeded because the trigger's skip-no-op
-- guard short-circuited before hitting the broken lines. DERM Tracker
-- / Field Portal / Admin Review writes during this window would have
-- received 500 from PostgREST. No data corruption — failed writes
-- rolled back atomically.
--
-- Fix: replace every `pg_catalog.nullif(...)` with plain `NULLIF(...)`.
-- The original 2026-05-17 function used plain NULLIF; only the new
-- lines from 2026-05-23d had the broken form. Everything else in
-- 2026-05-23d (columns, index, derived app_source logic) is correct
-- and stays.
--
-- Idempotent (Rule 5): CREATE OR REPLACE FUNCTION. Re-runnable.

BEGIN;

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
  -- Recursion guard
  IF TG_TABLE_SCHEMA = 'audit' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- PK extraction
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

  -- Old/new diff
  v_old_clean := CASE WHEN TG_OP IN ('UPDATE','DELETE')
                      THEN pg_catalog.to_jsonb(OLD) - 'updated_at'
                 END;
  v_new_clean := CASE WHEN TG_OP IN ('INSERT','UPDATE')
                      THEN pg_catalog.to_jsonb(NEW) - 'updated_at'
                 END;

  IF TG_OP = 'UPDATE' AND v_old_clean IS NOT DISTINCT FROM v_new_clean THEN
    RETURN NEW;
  END IF;

  -- Capture request context defensively (NULLIF as plain SQL expr, not
  -- pg_catalog.nullif which doesn't exist).
  BEGIN
    v_headers := NULLIF(pg_catalog.current_setting('request.headers', true), '')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    v_headers := NULL;
  END;

  v_origin       := COALESCE(v_headers->>'origin', '');
  v_referer      := COALESCE(v_headers->>'referer', '');
  v_method       := NULLIF(pg_catalog.current_setting('request.method', true), '');
  v_path         := NULLIF(pg_catalog.current_setting('request.path', true), '');
  v_x_app_source := NULLIF(v_headers->>'x-app-source', '');

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

  v_request_context := pg_catalog.jsonb_strip_nulls(
    pg_catalog.jsonb_build_object(
      'origin',          NULLIF(v_origin, ''),
      'referer',         NULLIF(v_referer, ''),
      'method',          v_method,
      'path',            v_path,
      'app_source_hint', v_x_app_source
    )
  );

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
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), '')::uuid,
    CURRENT_USER::text,
    NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb,
    v_app_source,
    CASE WHEN v_request_context = '{}'::jsonb THEN NULL ELSE v_request_context END
  );

  RETURN COALESCE(NEW, OLD);
END;
$function$;

COMMIT;
