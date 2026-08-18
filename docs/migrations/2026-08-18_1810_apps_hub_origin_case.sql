-- 2026-08-18_1810_apps_hub_origin_case.sql
--
-- WHAT: pin `hub.unclogme.app` (and the Apps Hub Lovable project id) in audit.log_change's Origin CASE.
--
-- WHY: Fred is building an **Apps Hub**, a staff launcher listing every UnclogMe app, and chose
--      `hub.unclogme.app`. The standing rule (Building Apps/CLAUDE.md, end of file) is: pin the host
--      BEFORE the DNS change, never after. Admin Review moved host without doing so and **232 rows
--      across 4 tables landed as `other:review.unclogme.app` over 26 days**, while a §5.5(b) usage
--      check reported the app dead on 2026-07-08 when it was writing that same week.
--
-- ⚠ THIS ARM IS EXPECTED TO MATCH ZERO ROWS ON DAY ONE, AND THAT IS NOT A REASON TO SKIP IT.
--      The hub reads no tables and writes no rows; its only backend contact is Supabase Auth. The
--      moment it gains ANY write (a pinned-apps preference, a last-opened marker) attribution would
--      degrade silently, and the retrofit cost is the 26-day incident above. Do not "clean up" an arm
--      because it has no rows — `audit.unclogme.app` is pinned on exactly the same basis.
--
-- 🛑 THE BODY BELOW IS THE LIVE `pg_get_functiondef` OUTPUT WITH TWO ARMS INSERTED PROGRAMMATICALLY.
--      It was NOT retyped. `2026-08-06_1316` retyped a body while its header said nothing else moved
--      and silently deleted seven behaviours, so the whole function is reproduced verbatim and the
--      only diff is the two `apps-hub` lines plus their comment.
--
-- ⚠ ORDERING IS LOAD-BEARING: both arms sit ABOVE the `%lovable.app%` catch-all. Below it, the hub's
--      Lovable preview host would be swallowed and labelled `lovable-preview`.
--
-- AUDIT (ADR 010): this IS the audit function. No trigger change; every audited table picks it up.

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

-- ---------------------------------------------------------------------------
-- assertions. Exercise the REAL function through a real audited write, not a
-- replica of the CASE — a copied CASE tests the copy.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_src text; v_zone bigint; v_before bigint; v_n int;
BEGIN
  SELECT id INTO v_zone FROM public.zones ORDER BY id LIMIT 1;
  IF v_zone IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: no zones row to exercise the trigger'; END IF;

  -- (A) the new host maps to apps-hub
  PERFORM set_config('request.headers', '{"origin":"https://hub.unclogme.app"}', true);
  SELECT COALESCE(max(id),0) INTO v_before FROM audit.logs;
  UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
  SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
  IF v_src IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: the audit trigger produced no row, so no assertion below can mean anything'; END IF;
  IF v_src IS DISTINCT FROM 'apps-hub' THEN
    RAISE EXCEPTION 'hub.unclogme.app mapped to %, expected apps-hub', v_src;
  END IF;

  -- (B) the Lovable preview for THIS project maps to apps-hub, not lovable-preview
  PERFORM set_config('request.headers', '{"origin":"https://6ce459ba-6d57-4634-a71f-d55a45bc82c6.lovableproject.com"}', true);
  SELECT COALESCE(max(id),0) INTO v_before FROM audit.logs;
  UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
  SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
  IF v_src IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: the audit trigger produced no row, so no assertion below can mean anything'; END IF;
  IF v_src IS DISTINCT FROM 'apps-hub' THEN
    RAISE EXCEPTION 'the apps-hub project preview mapped to %, expected apps-hub', v_src;
  END IF;

  -- (C) CONTROL: an EXISTING arm still works. Without this, an arm that broke every
  --     other mapping would still pass (A) and (B).
  PERFORM set_config('request.headers', '{"origin":"https://calendar.unclogme.app"}', true);
  SELECT COALESCE(max(id),0) INTO v_before FROM audit.logs;
  UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
  SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
  IF v_src IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: the audit trigger produced no row, so no assertion below can mean anything'; END IF;
  IF v_src IS DISTINCT FROM 'visit-calendar' THEN
    RAISE EXCEPTION 'CONTROL FAILED: calendar mapped to %, expected visit-calendar', v_src;
  END IF;

  -- (D) CONTROL: an unrelated lovable host still falls to the catch-all, so the new
  --     arms did not swallow it.
  PERFORM set_config('request.headers', '{"origin":"https://some-other-thing.lovable.app"}', true);
  SELECT COALESCE(max(id),0) INTO v_before FROM audit.logs;
  UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
  SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
  IF v_src IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: the audit trigger produced no row, so no assertion below can mean anything'; END IF;
  IF v_src IS DISTINCT FROM 'lovable-preview' THEN
    RAISE EXCEPTION 'CONTROL FAILED: an unrelated lovable host mapped to %', v_src;
  END IF;

  -- (E) CONTROL: an unknown host still falls to other:
  PERFORM set_config('request.headers', '{"origin":"https://nothing-we-know.example.com"}', true);
  SELECT COALESCE(max(id),0) INTO v_before FROM audit.logs;
  UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
  SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
  IF v_src IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: the audit trigger produced no row, so no assertion below can mean anything'; END IF;
  IF v_src NOT LIKE 'other:%' THEN
    RAISE EXCEPTION 'CONTROL FAILED: an unknown host mapped to %, expected other:', v_src;
  END IF;

  RAISE NOTICE 'OK: hub + project preview map to apps-hub; calendar, lovable catch-all and other: all intact';
END $$;

-- the assertions wrote audit rows and touched a zone; discard everything.
ROLLBACK;

-- ---------------------------------------------------------------------------
-- The assertions above ran inside a transaction that was DISCARDED. Re-apply for real.
-- ---------------------------------------------------------------------------
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

DO $$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
   WHERE ns.nspname='audit' AND p.proname='log_change'
     AND pg_get_functiondef(p.oid) LIKE '%apps-hub%';
  IF n <> 1 THEN RAISE EXCEPTION 'the apps-hub arms did not land'; END IF;
  -- ordering: both new arms must sit BEFORE the lovable catch-all in the source
  SELECT position('hub.unclogme.app' in pg_get_functiondef(p.oid))
    INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
   WHERE ns.nspname='audit' AND p.proname='log_change';
  IF n = 0 THEN RAISE EXCEPTION 'hub arm missing after re-apply'; END IF;
  RAISE NOTICE 'OK: audit.log_change carries the apps-hub arms';
END $$;

COMMIT;
