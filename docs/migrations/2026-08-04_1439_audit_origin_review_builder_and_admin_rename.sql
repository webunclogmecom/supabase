-- audit.log_change: pin reviews.unclogme.app (NEW app) and Admin Review's replacement hosts
--
-- Fred 2026-08-04: a new Lovable app by Yannick, "Review Builder", now has reviews.unclogme.app. Because
-- that reads almost identically to the Admin Review app's review.unclogme.app, Admin Review is moving to
-- a different subdomain (audit.* or admin.*, see below).
--
-- 🛑 WHY THIS MIGRATION EXISTS, AND WHY IT MUST LAND BEFORE THE DNS CHANGE.
-- app_source is derived from the request Origin by a hard-coded CASE in this function. The LAST time an
-- app changed domain, the CASE was not updated: Admin Review moved to review.unclogme.app while the CASE
-- still matched only %grease-buddy-dash%, so from 2026-07-03 to 2026-07-29 every write landed as
-- 'other:review.unclogme.app'. A "is this app still used" check reported the app DEAD since 2026-07-08
-- while it was writing four tables that same week. Those 232 rows are still in audit.logs, deliberately
-- not relabelled. Changing the domain first and the CASE second reproduces that exactly.
--
-- WHAT WAS MEASURED FIRST, not assumed:
--   'https://reviews.unclogme.app' LIKE '%review.unclogme.app%'  -> FALSE   (no accidental collision)
--   'https://review.unclogme.app'  LIKE '%review.unclogme.app%'  -> TRUE    (positive control)
--   'https://admin.unclogme.app'   LIKE '%review.unclogme.app%'  -> FALSE   } the rename would have
--   'https://audit.unclogme.app'   LIKE '%review.unclogme.app%'  -> FALSE   } silently broken attribution
--
-- WHAT THIS ADDS (three branches, all ABOVE the %lovable.app% catch-all, verified by index comparison):
--   %reviews.unclogme.app% -> 'review-builder'   NEW APP. Listed FIRST so a future loosening of the
--                                                review.* pattern cannot swallow it.
--   %admin.unclogme.app%   -> 'admin-review'     } BOTH candidate replacement hosts are pinned now, so
--   %audit.unclogme.app%   -> 'admin-review'     } Fred's choice of name does not depend on a DB change,
--                                                  and either can be cut over with zero attribution loss.
-- Nothing is removed. %review.unclogme.app% and %grease-buddy-dash% both stay mapped so a rollback of the
-- DNS change is also safe, and so the historical rows keep their meaning.
--
-- ⚠ ONE THING THIS MIGRATION CANNOT DO: the Origin CASE is only half the story. app_source is
-- COALESCE(X-App-Source header, origin CASE), and that header is set PER SUPABASE CLIENT. Admin Review is
-- the app that proved this: it sets the header on only its secondary client, while the client that does
-- the writes sets none. So the Origin mapping is the load-bearing half. Do not "simplify" it away.
--
-- ADR 010: function only, no table or column -> no audit-trigger decision.
-- REVERSIBLE: drop the three added WHEN branches.
--
-- VERIFIED LIVE AFTER APPLYING:
--   reviews.unclogme.app -> review-builder   |  review.unclogme.app -> admin-review
--   admin.unclogme.app   -> admin-review     |  audit.unclogme.app  -> admin-review
--   dump.unclogme.app    -> dump-schedule    |  nope.example.com    -> other:nope.example.com (control)

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
      -- Review Builder (Yannick, 2026-08-04). NEW APP on reviews.unclogme.app. Listed FIRST so that a
      -- future loosening of the review.* pattern below cannot swallow it. Verified today that
      -- 'https://reviews.unclogme.app' LIKE '%review.unclogme.app%' is FALSE, so the two do not collide
      -- as written, but the ordering makes that independent of the pattern staying exactly as it is.
      WHEN v_origin LIKE '%reviews.unclogme.app%' THEN 'review-builder'
      -- Admin Review is moving OFF review.unclogme.app because it reads almost identically to the new
      -- app's domain. Both candidate replacements are pinned NOW, before DNS changes, so the cutover
      -- cannot reproduce the 2026-07-03..07-29 failure where 232 rows landed as
      -- other:review.unclogme.app and a usage check reported the app dead while it was writing daily.
      -- All three Admin Review hosts stay mapped: whichever is chosen, and the old one for rollback.
      WHEN v_origin LIKE '%admin.unclogme.app%'   THEN 'admin-review'
      WHEN v_origin LIKE '%audit.unclogme.app%'   THEN 'admin-review'
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
