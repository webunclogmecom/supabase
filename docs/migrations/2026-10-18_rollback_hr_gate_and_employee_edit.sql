-- ROLLBACK of 2026-10-18_0320_hr_gate_and_employee_edit.sql: drops the hr functions and the two unique
-- indexes, and restores audit.log_change exactly as it was (md5 d2e48e25e2d29dd0453e6d0e78f7acf6). Employee edits already made stay
-- (they are ordinary audited updates; undo them from audit.logs.old_row if needed).
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION IF EXISTS hr.update_employee(bigint, jsonb);
DROP FUNCTION IF EXISTS hr.fn_employee_impact(bigint);
DROP FUNCTION IF EXISTS hr.fn_employee_json(public.employees);
DROP FUNCTION IF EXISTS hr.fn_require_level(text[]);
DROP FUNCTION IF EXISTS hr.fn_caller_level();
DROP INDEX IF EXISTS public.employees_email_lower_uniq;
DROP INDEX IF EXISTS public.employees_full_name_ci_uniq;
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
      -- Apps Hub (2026-08-18). The staff launcher at hub.unclogme.app. Pinned BEFORE the DNS change,
      -- which is the rule this file exists to enforce: Admin Review moved host without a CASE arm and
      -- 232 rows landed as other:review.unclogme.app over 26 days while a usage check called it dead.
      -- ⚠ The hub writes NOTHING today (no tables, no RPCs; its only backend contact is Supabase Auth),
      -- so this arm is expected to match ZERO rows on day one. That is not a reason to omit it: the
      -- moment the hub gains any write (a pinned-apps preference, a last-opened marker) attribution
      -- would degrade silently, and the retrofit is the 26-day incident above.
      -- The project-id arm mirrors the %6533c3ee% precedent below so the Lovable preview is labelled
      -- apps-hub rather than being swallowed by the %lovable.app% catch-all.
      WHEN v_origin LIKE '%hub.unclogme.app%'     THEN 'apps-hub'
      WHEN v_origin LIKE '%6ce459ba%'             THEN 'apps-hub'
      -- Picture Planner (2026-09-24). Staff page builder plus, later, the public intake form, moving to
      -- planner.unclogme.app. Pinned BEFORE the DNS change (plan B.3, Building Apps/docs/
      -- 2026-09-23_intake-forms-viewer-plan.md): Admin Review moved host without an arm and 232 rows
      -- landed as other:review.unclogme.app over 26 days. It writes nothing today, so these arms match
      -- zero rows on day one; that is not a reason to omit them. The published Lovable host and the
      -- project id keep its previews out of the %lovable.app% catch-all, as %6533c3ee% does.
      WHEN v_origin LIKE '%planner.unclogme.app%' THEN 'picture-planner'
      WHEN v_origin LIKE '%unclogme-pics-organizer%' THEN 'picture-planner'
      WHEN v_origin LIKE '%d9464151%'             THEN 'picture-planner'
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
      'actor_name',      pg_catalog.left(NULLIF(v_headers->>'x-actor-name', ''), 120),
      'change_reason',   pg_catalog.left(NULLIF(v_headers->>'x-change-reason', ''), 500)
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
$function$;
DO $v$ BEGIN
  IF md5(pg_get_functiondef('audit.log_change()'::regprocedure)) <> 'd2e48e25e2d29dd0453e6d0e78f7acf6' THEN
    RAISE EXCEPTION 'ROLLBACK VERIFY: audit.log_change not restored byte for byte';
  END IF;
END $v$;
COMMIT;
