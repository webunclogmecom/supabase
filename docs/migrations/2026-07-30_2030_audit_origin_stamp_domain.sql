-- 2026-07-30_2030  audit.log_change: recognise stamp.unclogme.app (Stamp Studio's new domain)
--
-- Found by @Building Apps during the auto-stamp browser pass: studio.unclogme.app now REDIRECTS to
-- stamp.unclogme.app, and the Origin CASE had no pattern for the new host. Measured before the fix:
--   origin https://stamp.unclogme.app  -> 16 rows, first seen 2026-07-30 21:37 UTC
--   origin https://studio.unclogme.app -> 71 rows, last  seen 2026-07-28 18:08 UTC
--
-- ⚠ WHY THIS WAS URGENT DESPITE NOTHING LOOKING BROKEN. Attribution was surviving ONLY because the
-- Studio's single client sends an explicit X-App-Source header, which ADR 016 makes an override that
-- wins over Origin. The header is per-CLIENT: the day anyone adds a second Supabase client or drops
-- the header, Studio writes start landing as 'other:stamp.unclogme.app' and a check for
-- app_source='derm-stamp-studio' returns a FALSE ALL-CLEAR. That is not hypothetical - it is exactly
-- what cost Admin Review 232 mislabelled rows over 26 days (CLAUDE.md 5.5(b)). Origin mapping is the
-- durable source; the header is the override. Keep the CASE correct even for apps that "have a header".
--
-- BOTH patterns are kept: studio.* still matches 71 historical rows and a redirect can be undone.
-- Placed immediately after the studio.* arm and well before the %lovable.app% catch-all (asserted by
-- the generator: studio index < stamp index < lovable index).
--
-- Produced by editing the LIVE pg_get_functiondef with the anchor asserted to match exactly once;
-- every other byte is unchanged from what was running.
--
-- PROBED before applying, in one rolled-back transaction, through the REAL trigger on a real audited
-- table, each iteration asserting a FRESH audit row was created:
--   https://stamp.unclogme.app  -> derm-stamp-studio   (the fix)
--   https://studio.unclogme.app -> derm-stamp-studio   (regression: old host still maps)
--   https://review.unclogme.app -> admin-review        (POSITIVE CONTROL, unrelated arm intact)
--   https://nope.example.com    -> other:nope.example.com (NEGATIVE CONTROL, catch-all intact)
-- ⚠ The first version of that probe returned 'sql' for ALL FOUR, including the positive control -
-- because log_change SKIPS an UPDATE whose only change is updated_at, so no row was written and the
-- probe re-read the same stale row four times. The control is what exposed it. Any future probe of
-- this function must change a REAL column and assert the audit id advanced.
--
-- RULE 8 (ADR 010): no table or column change. This IS the audit trigger; behaviour change is
-- additive (one new CASE arm), no existing arm altered, no historical row relabelled.

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
      -- stamp.unclogme.app: the Studio's CURRENT custom domain (studio.* redirects here as of
      -- 2026-07-30). Both patterns are kept: the old one still matches 71 historical rows, and a
      -- redirect can be undone. Attribution was surviving ONLY on the per-client X-App-Source
      -- header, which is the Admin Review failure shape (232 rows lost to other:review.unclogme.app).
      WHEN v_origin LIKE '%stamp.unclogme.app%'   THEN 'derm-stamp-studio'
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
;

COMMIT;
