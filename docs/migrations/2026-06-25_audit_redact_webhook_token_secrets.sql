-- ============================================================================
-- 2026-06-25 — Redact secret values from audit.logs (webhook_tokens leak)
-- ----------------------------------------------------------------------------
-- audit.log_change() snapshots full old_row/new_row as jsonb. For public.
-- webhook_tokens that means the live Jobber OAuth secrets — access_token (740-
-- char JWT), refresh_token, client_secret — were stored in plaintext in
-- audit.logs. Verified 2026-06-25: 974 audit rows, ALL 974 carrying the token.
-- Contained today (audit.logs is RLS-locked to `authenticated` + has NO anon
-- grant, and apps query with the anon key) but it is a hard blocker before any
-- Activity-History surfacing and before switching apps to per-user login
-- (which would give every authenticated user read access to these rows), and it
-- leaks on pg_dump / PITR export / support access.
--
-- Fix (Fred-approved): KEEP the webhook_tokens audit trigger (CLAUDE.md rule:
-- webhook-secret tables must stay audited; the Tier-1 "tokens modified by
-- non-service_role" alert needs the trigger PRESENT) but strip the secret keys
-- from old_row/new_row at capture, data-driven via audit.redacted_columns so
-- future sensitive tables opt in without another function edit. Stripping
-- happens AFTER the no-op-skip check, so a secret-only change is still logged
-- (the security alert keys off table_name/db_role/record_pk, not the values).
-- A companion purge (run after this migration) removes the secrets from the
-- 974 historical rows.
--
-- NOTE on fail-open: this is a column-name denylist. Any newly-added secret
-- column on a denylisted table must be added to audit.redacted_columns. The
-- webhook_tokens secret surface (access_token/refresh_token/client_secret) is
-- seeded below; client_id is an OAuth app id (identifier, not a secret) and is
-- left visible so the alert can still see which app row changed.
-- ============================================================================

-- 1. Denylist config -------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.redacted_columns (
  table_name   text NOT NULL,
  column_name  text NOT NULL,
  reason       text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (table_name, column_name)
);
COMMENT ON TABLE audit.redacted_columns IS
  'Columns stripped from audit.logs old_row/new_row at capture by audit.log_change(). Add a row to redact a new secret/PII column. Keyed by base table_name (not schema-qualified) to match TG_TABLE_NAME.';

INSERT INTO audit.redacted_columns (table_name, column_name, reason) VALUES
  ('webhook_tokens', 'access_token',  'Jobber/OAuth access token (secret)'),
  ('webhook_tokens', 'refresh_token', 'Jobber/OAuth refresh token (secret)'),
  ('webhook_tokens', 'client_secret', 'Jobber/OAuth client secret (secret)')
ON CONFLICT (table_name, column_name) DO NOTHING;

-- 2. Redacting audit trigger function --------------------------------------
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
  v_redact           TEXT[];
  v_col              TEXT;
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

  -- Redaction: strip denylisted secret/PII columns from the stored snapshot.
  -- Done AFTER the no-op check so a secret-only change is still recorded.
  SELECT pg_catalog.array_agg(column_name)
    INTO v_redact
    FROM audit.redacted_columns
   WHERE table_name = TG_TABLE_NAME;
  IF v_redact IS NOT NULL THEN
    FOREACH v_col IN ARRAY v_redact LOOP
      v_old_clean := v_old_clean - v_col;
      v_new_clean := v_new_clean - v_col;
    END LOOP;
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
