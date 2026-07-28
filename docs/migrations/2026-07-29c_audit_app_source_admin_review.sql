-- ============================================================================
-- 2026-07-29c — fix audit app_source attribution for Admin Review (and pin the
--               other custom domains before they drift the same way)
-- ============================================================================
-- ⚠ THIS IS A BROKEN-DETECTOR FIX, and the detector it repairs is the one the
-- root CLAUDE.md §5.5(b) tells the Supabase session to consult BEFORE revoking a
-- grant: "check audit.logs for app_source='<app>'; no policy explains it is not
-- evidence nobody uses it." That check is currently WRONG for Admin Review.
--
-- ── WHAT IS BROKEN ─────────────────────────────────────────────────────────
-- audit.log_change derives app_source from the request Origin. Its CASE still
-- maps only the app's OLD Lovable host:
--     WHEN v_origin LIKE '%grease-buddy-dash%' THEN 'admin-review'
-- Admin Review moved to review.unclogme.app, which matches nothing, so it falls
-- through to the ELSE branch and lands as 'other:review.unclogme.app'.
--
-- Measured on live data:
--     admin-review                anon           108 rows  ended  2026-07-08
--     other:review.unclogme.app   anon            82 rows  ended  2026-07-09
--     other:review.unclogme.app   authenticated  147 rows  through 2026-07-28
--
-- So anyone running the §5.5(b) check today sees app_source='admin-review' go
-- silent on 2026-07-08 and concludes the app is dead — while it is in fact
-- writing 4 tables as authenticated, right now. That is exactly the false
-- all-clear §5.5(b) exists to prevent, reproduced by the rule's own detector.
--
-- ⚠ The X-App-Source header does NOT save it either. Building Apps found the
-- header is set ONLY on the app's second (legacy 'prod mirror') client, while
-- the client that performs the writes that actually land sets no header at all.
-- So the header has never been the attribution source for these tables.
--
-- ── THE FIX ────────────────────────────────────────────────────────────────
-- Add review.unclogme.app, and pin the other three custom domains at the same
-- time so a future header removal cannot silently open a new 'other:' bucket:
--     review.unclogme.app  -> admin-review
--     studio.unclogme.app  -> derm-stamp-studio
--     dump.unclogme.app    -> dump-schedule
--     clients.unclogme.app -> client-app
-- The old grease-buddy-dash mapping is KEPT (that host still 301s to the custom
-- domain, so requests can legitimately arrive from either).
-- ⚠ ORDER MATTERS: every specific host must stay ABOVE the '%lovable.app%'
-- catch-all, or a *.lovable.app app would be labelled 'lovable-preview'. Verified.
--
-- Only ONE other unmapped source exists and it is dead: a stale Lovable preview
-- (8eec2ff9-…lovableproject.com, 16 rows, last seen 2026-07-01). Left alone.
--
-- Everything else in this function is BYTE-IDENTICAL — the definition was pulled
-- with pg_get_functiondef, patched at the anchor line, and re-applied, rather
-- than retyped. SECURITY DEFINER and the pinned search_path are unchanged.
--
-- ── ⚠ HISTORY IS DELIBERATELY NOT REWRITTEN ────────────────────────────────
-- The 232 existing 'other:review.unclogme.app' rows are LEFT AS THEY ARE. They
-- are a truthful record of what the trigger observed, and silently relabelling
-- audit rows is not something to do without Fred's explicit say-so, even when
-- the label is known to be wrong. Until those rows age out, remember that
--     app_source = 'other:review.unclogme.app'  IS  Admin Review  (2026-07-03+)
-- and query app_source IN ('admin-review', 'other:review.unclogme.app') when
-- running the §5.5(b) check over historical data. Backfilling them to
-- 'admin-review' is a one-line UPDATE if Fred prefers that.
--
-- ROLLBACK: re-apply the previous definition (this migration changes only the
-- CASE arms listed above; drop the four new WHEN lines to revert).
--
-- AUDIT (ADR 010): changes the audit trigger's own attribution logic. No
-- business table touched, no existing audit row modified.
-- ============================================================================

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
  IF TG_TABLE_SCHEMA = 'audit' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

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

  v_old_clean := CASE WHEN TG_OP IN ('UPDATE','DELETE')
                      THEN pg_catalog.to_jsonb(OLD) - 'updated_at'
                 END;
  v_new_clean := CASE WHEN TG_OP IN ('INSERT','UPDATE')
                      THEN pg_catalog.to_jsonb(NEW) - 'updated_at'
                 END;

  IF TG_OP = 'UPDATE' AND v_old_clean IS NOT DISTINCT FROM v_new_clean THEN
    RETURN NEW;
  END IF;

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
      WHEN v_origin LIKE '%review.unclogme.app%'  THEN 'admin-review'
      WHEN v_origin LIKE '%studio.unclogme.app%'  THEN 'derm-stamp-studio'
      WHEN v_origin LIKE '%dump.unclogme.app%'    THEN 'dump-schedule'
      WHEN v_origin LIKE '%clients.unclogme.app%' THEN 'client-app'
      WHEN v_origin LIKE '%calendar.unclogme.app%' THEN 'visit-calendar'
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
      'app_source_hint', v_x_app_source,
      'actor_name',      pg_catalog.left(NULLIF(v_headers->>'x-actor-name', ''), 120)
    )
  );

  INSERT INTO audit.logs (
    table_schema, table_name, record_pk, operation,
    old_row, new_row,
    changed_by, db_role, jwt_claims,
    app_source, request_context, txid
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
    CASE WHEN v_request_context = '{}'::jsonb THEN NULL ELSE v_request_context END,
    pg_catalog.txid_current()
  );

  RETURN COALESCE(NEW, OLD);
END;
$function$

