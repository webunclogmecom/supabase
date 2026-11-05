-- =============================================================================
-- 2026-11-04_2141_audit_origin_ops_portal.sql
--
-- WHAT: pin the Ops Portal's hosts in audit.log_change's Origin CASE, label 'ops-portal':
--       ops.unclogme.app (reserved for it, not yet in DNS) and 9f6cf384 (its Lovable project id, which covers
--       its preview hosts).
--
-- WHY: Fred, 2026-11-04, Trello #161: "I want a monolith. I want everything merged." The standing rule is to pin
--      a host BEFORE its DNS change. Plan: Building Apps/Ops Portal/docs/specs/2026-11-04-phase-0-1-ground-and-shell.md
--
-- ⚠ EXPECTED TO MATCH ZERO ROWS ON DAY ONE. The shell writes nothing, and each app that moves in keeps sending its
--   own X-App-Source header, which outranks the Origin.
--
-- 🛑 THE BODY IS THE LIVE pg_get_functiondef OUTPUT (md5 c93f59bc7978be06d78747c9fd929da0) WITH ONE BLOCK INSERTED BY A SCRIPT, never
--   retyped. VERIFY V1 proves it: removing the inserted block gives back the old md5.
--
-- ⚠ ORDERING IS LOAD-BEARING: the arms sit directly ABOVE the %lovable.app% catch-all. Below it, the project's
--   Lovable hosts would be labelled lovable-preview.
--
-- RULE 8, AUDIT: this IS the audit function. No trigger changes; every audited table picks it up.
-- ATOMIC: no COMMIT. The probes run in a sub-block that is rolled back by a sentinel, so they leave no audit rows
-- and no zone edit behind; any failed assertion aborts the whole migration.
-- ROLLBACK: the same statement with the inserted block removed.
-- =============================================================================

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
      -- HR App (2026-10-18): hr.unclogme.app, its Lovable project id and its default host, pinned before its
      -- first write (until now the app wrote nothing). Above the %lovable.app% catch-all.
      WHEN v_origin LIKE '%hr.unclogme.app%'      THEN 'hr-app'
      WHEN v_origin LIKE '%816f8580%'             THEN 'hr-app'
      WHEN v_origin LIKE '%blank-canvas-creator-8666%' THEN 'hr-app'
      -- Ops Portal (2026-11-04, Trello #161). One app for every staff tool, moving in one app at a time. Pinned
      -- BEFORE the DNS change: Admin Review moved host without an arm and 232 rows landed as
      -- other:review.unclogme.app over 26 days. Only the shell uses this label; each moved app sends its own
      -- X-App-Source header. It writes nothing today, so these arms match zero rows on day one. The project
      -- id keeps its previews out of the %lovable.app% catch-all.
      WHEN v_origin LIKE '%ops.unclogme.app%'     THEN 'ops-portal'
      WHEN v_origin LIKE '%9f6cf384%'             THEN 'ops-portal'
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

DO $verify$
DECLARE
  v_def    text := pg_get_functiondef('audit.log_change'::regproc);
  v_ins    text := $ins$      -- Ops Portal (2026-11-04, Trello #161). One app for every staff tool, moving in one app at a time. Pinned
      -- BEFORE the DNS change: Admin Review moved host without an arm and 232 rows landed as
      -- other:review.unclogme.app over 26 days. Only the shell uses this label; each moved app sends its own
      -- X-App-Source header. It writes nothing today, so these arms match zero rows on day one. The project
      -- id keeps its previews out of the %lovable.app% catch-all.
      WHEN v_origin LIKE '%ops.unclogme.app%'     THEN 'ops-portal'
      WHEN v_origin LIKE '%9f6cf384%'             THEN 'ops-portal'
$ins$;
  v_zone   bigint;
  v_before bigint;
  v_src    text;
BEGIN
  -- V1 nothing else moved: take the inserted block out and the old body comes back byte for byte
  IF md5(replace(v_def, v_ins, '')) IS DISTINCT FROM 'c93f59bc7978be06d78747c9fd929da0' THEN
    RAISE EXCEPTION 'VERIFY V1: the body differs from the live one by more than the inserted block'; END IF;
  -- V2 ordering: the new arms sit above the lovable catch-all
  IF position($t$LIKE '%9f6cf384%'$t$ in v_def) = 0
     OR position($t$LIKE '%9f6cf384%'$t$ in v_def) > position($t$LIKE '%lovable.app%'$t$ in v_def) THEN
    RAISE EXCEPTION 'VERIFY V2: the ops-portal arms are missing or below the %%lovable.app%% catch-all'; END IF;

  SELECT id INTO v_zone FROM public.zones ORDER BY id LIMIT 1;
  IF v_zone IS NULL THEN RAISE EXCEPTION 'VERIFY: no zone to probe with'; END IF;

  -- V3 exercise the REAL function through a real audited write (a copied CASE tests the copy),
  -- inside a sub-block that the sentinel rolls back.
  BEGIN

    PERFORM set_config('request.headers', '{"origin":"https://ops.unclogme.app"}', true);
    SELECT coalesce(max(id), 0) INTO v_before FROM audit.logs;
    UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
    SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
    IF v_src IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: no audit row for %, so nothing below can mean anything', 'https://ops.unclogme.app'; END IF;
    IF v_src IS DISTINCT FROM 'ops-portal' THEN
      RAISE EXCEPTION 'V3a the custom domain: % mapped to %, expected ops-portal', 'https://ops.unclogme.app', v_src; END IF;

    PERFORM set_config('request.headers', '{"origin":"https://id-preview--9f6cf384-0f0d-4982-936b-9e39408362b8.lovable.app"}', true);
    SELECT coalesce(max(id), 0) INTO v_before FROM audit.logs;
    UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
    SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
    IF v_src IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: no audit row for %, so nothing below can mean anything', 'https://id-preview--9f6cf384-0f0d-4982-936b-9e39408362b8.lovable.app'; END IF;
    IF v_src IS DISTINCT FROM 'ops-portal' THEN
      RAISE EXCEPTION 'V3b the preview host: % mapped to %, expected ops-portal', 'https://id-preview--9f6cf384-0f0d-4982-936b-9e39408362b8.lovable.app', v_src; END IF;

    PERFORM set_config('request.headers', '{"origin":"https://9f6cf384-0f0d-4982-936b-9e39408362b8.lovableproject.com"}', true);
    SELECT coalesce(max(id), 0) INTO v_before FROM audit.logs;
    UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
    SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
    IF v_src IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: no audit row for %, so nothing below can mean anything', 'https://9f6cf384-0f0d-4982-936b-9e39408362b8.lovableproject.com'; END IF;
    IF v_src IS DISTINCT FROM 'ops-portal' THEN
      RAISE EXCEPTION 'V3c the project-id host: % mapped to %, expected ops-portal', 'https://9f6cf384-0f0d-4982-936b-9e39408362b8.lovableproject.com', v_src; END IF;

    PERFORM set_config('request.headers', '{"origin":"https://calendar.unclogme.app"}', true);
    SELECT coalesce(max(id), 0) INTO v_before FROM audit.logs;
    UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
    SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
    IF v_src IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: no audit row for %, so nothing below can mean anything', 'https://calendar.unclogme.app'; END IF;
    IF v_src IS DISTINCT FROM 'visit-calendar' THEN
      RAISE EXCEPTION 'V3d CONTROL an existing arm: % mapped to %, expected visit-calendar', 'https://calendar.unclogme.app', v_src; END IF;

    PERFORM set_config('request.headers', '{"origin":"https://hr.unclogme.app"}', true);
    SELECT coalesce(max(id), 0) INTO v_before FROM audit.logs;
    UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
    SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
    IF v_src IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: no audit row for %, so nothing below can mean anything', 'https://hr.unclogme.app'; END IF;
    IF v_src IS DISTINCT FROM 'hr-app' THEN
      RAISE EXCEPTION 'V3e CONTROL the arm just above: % mapped to %, expected hr-app', 'https://hr.unclogme.app', v_src; END IF;

    PERFORM set_config('request.headers', '{"origin":"https://some-other-thing.lovable.app"}', true);
    SELECT coalesce(max(id), 0) INTO v_before FROM audit.logs;
    UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
    SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
    IF v_src IS NULL THEN RAISE EXCEPTION 'CONTROL FAILED: no audit row for %, so nothing below can mean anything', 'https://some-other-thing.lovable.app'; END IF;
    IF v_src IS DISTINCT FROM 'lovable-preview' THEN
      RAISE EXCEPTION 'V3f CONTROL the catch-all still catches: % mapped to %, expected lovable-preview', 'https://some-other-thing.lovable.app', v_src; END IF;

    PERFORM set_config('request.headers', '{"origin":"https://nothing-we-know.example.com"}', true);
    SELECT coalesce(max(id), 0) INTO v_before FROM audit.logs;
    UPDATE public.zones SET label = label || 'probe' WHERE id = v_zone;
    SELECT app_source INTO v_src FROM audit.logs WHERE id > v_before AND table_name = 'zones' ORDER BY id DESC LIMIT 1;
    IF v_src NOT LIKE 'other:%' THEN
      RAISE EXCEPTION 'V3g CONTROL an unknown host mapped to %, expected other:%%', v_src; END IF;
    RAISE EXCEPTION 'probe sentinel' USING ERRCODE = 'PPOK1';
  EXCEPTION WHEN SQLSTATE 'PPOK1' THEN
    NULL;   -- the probe writes are gone; only the function change remains
  END;

  RAISE NOTICE 'OK: ops.unclogme.app, the preview and the project id map to ops-portal; calendar, hr, the catch-all and other: intact';
END
$verify$;
