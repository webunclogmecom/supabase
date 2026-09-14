-- ============================================================================================
-- 2026-09-14_0615_generated_sheet_finisher.sql
--
-- THE GENERATED-SHEET FINISHER. A DERM address sheet we printed (number 1000+) now measures its
-- own pages from the scan, guided by the layout we printed, and marks itself complete when every
-- gate the human path applies is satisfied, so the blackout follows with no clicks.
--
-- Design: docs/superpowers/specs/2026-09-14-generated-sheet-auto-measure-and-complete-design.md
-- Plan:   docs/superpowers/plans/2026-09-14-generated-sheet-finisher.md (Task 5)
-- Phase 0 (the corpus replay that calibrated the prior and the tolerances below):
--         scripts/probes/generated_finisher/phase0_report.md
--
-- WHY (Fred, 2026-09-14, on 835076): "why if it has been stamped by AI can't it be marked as
-- complete? ... if it's a generated manifest ... it should be auto-stamped and auto marked as
-- complete unless it can be certain of the stamps". Two of his rules could not both hold:
-- "generated sheets are automatic" and "complete means it will be blacked out" (2026-09-03), because
-- nothing MEASURED a generated sheet automatically. This is that step.
--
-- WHAT WRITES, AND THROUGH WHAT. derm.fn_generated_page_measured(folder, page, image_url, lines,
-- meta) is called by the edge function measure-generated-page with the detector's raw lines. It
--   1. checks the image at that position is still the one measured (derm.ticket_page_images),
--   2. takes the page's cards with their PRINTED row (derm.fn_generated_page_cards, migration
--      2026-09-14_0605) and refuses the shapes a machine must not decide,
--   3. runs the pure matcher (derm.fn_match_generated_page) with the calibrated prior,
--   4. inside ONE subtransaction: derm.record_page_rules(source 'template-v1-<date>', the six
--      boundaries as kind boundary, no dividers) then derm.save_page_geometry(bands = consecutive
--      boundaries per card, extent = first..last boundary). Both or neither. Every guard G1..G14
--      runs. The 2026-08-19 rule (an extent opens the gate onto whatever bands exist) is why the two
--      are one call and why nothing is written on any refusal.
--   5. derm.fn_complete_generated_sheet(folder): the resolver's own completion write, keyed on the
--      folder, plus a gate the human path lacks: every client's card count equals its printed row
--      count on the sheet. trg_a0_completion_requires_geometry still gates it on fn_sheet_publishable.
-- Every outcome lands in derm.generated_measure_attempts (the ledger: attempts per image, the plain
-- reason, the technical detail, the raw lines), and derm.fn_sheet_publishable_detail puts the
-- reason in the Studio banner: "Page 2 could not be measured automatically: <reason>. Page 2: ...".
--
-- WHAT NEVER HAPPENS.
--   * No template value is written. Every band edge and both extents are detected lines on THIS scan;
--     the prior only chooses which lines are the boundaries. VERIFY 4d asserts it on a real page.
--   * A person's lines always win (human-v1 outranks template-v1, migration 2026-09-14_0610), and a
--     page that already has a human scan is not in the backlog at all.
--   * A completed sheet, a reopened sheet (reopened_at, the resolver's own pin), a handwritten sheet
--     (no generated-sheet link) are never touched.
--   * A client printed on several rows, a card not on the printed list, a card printed on another
--     page, two stamps on one row, a stamp with no placement: refused, in words, for a person.
--
-- TWO SMALL CHANGES TO EXISTING HELPERS, both "service_role is a machine":
--   derm._actor(text)          returns 'stamp-studio-ai' for a service_role caller with no email
--                              (Fred: everything machine-made carries the one label). A person's
--                              JWT still wins; direct SQL still gets the default.
--   derm._require_stamp_key()  lets a service_role caller through. The finisher writes through
--                              PostgREST as service_role (edge fn -> RPC), and that key already
--                              writes every table directly; the Studio's header key was never a
--                              barrier to it. Bodies copied from pg_get_functiondef, one arm added.
--
-- THE OFF SWITCH. public.app_config 'generated_sheet_auto_complete' = 'true' (missing = true).
-- 'false' stops COMPLETION only, in one statement, without a deploy; measuring continues, so the
-- geometry is banked and a person's Mark completed still works.
--
-- RULE 8: derm.generated_measure_attempts OPTS OUT (machine bookkeeping, regenerable; same as
-- derm.row_ocr_attempts and derm.sheet_number_ocr_attempts). public.app_config is already audited.
-- Grants: service_role only on every new object; authenticated reads nothing new (the banner reason
-- reaches the Studio through fn_sheet_publishable_detail, which is SECURITY DEFINER).
-- ============================================================================================
BEGIN;

CREATE TEMP TABLE _fin_before ON COMMIT DROP AS
  SELECT p.proname, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg, pg_get_functiondef(p.oid) AS def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'derm' AND p.proname IN ('_actor', '_require_stamp_key', 'fn_sheet_publishable_detail');

DO $pre$
BEGIN
  IF (SELECT count(*) FROM _fin_before) <> 3 THEN RAISE EXCEPTION 'PRE 0.1: expected the three helpers'; END IF;
  IF (SELECT def FROM _fin_before WHERE proname = '_actor') NOT LIKE '%nullif(current_setting(''request.jwt.claim.email'', true), ''''),%' THEN
    RAISE EXCEPTION 'PRE 0.2: derm._actor is not the body this file was patched from';
  END IF;
  IF (SELECT def FROM _fin_before WHERE proname = '_require_stamp_key') NOT LIKE '%RETURN;  -- direct SQL (not PostgREST): admin scripts stay allowed%' THEN
    RAISE EXCEPTION 'PRE 0.3: derm._require_stamp_key is not the body this file was patched from';
  END IF;
  IF (SELECT def FROM _fin_before WHERE proname = 'fn_sheet_publishable_detail') NOT LIKE '%''pages_needing_extent'', to_jsonb(a.pages_ext),%' THEN
    RAISE EXCEPTION 'PRE 0.4: derm.fn_sheet_publishable_detail is not the body this file was patched from';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'derm' AND p.proname = 'fn_match_generated_page') THEN
    RAISE EXCEPTION 'PRE 0.5: apply 2026-09-14_0605 first';
  END IF;
  IF NOT derm._is_rule_source('template-v1-2026-09-15') THEN RAISE EXCEPTION 'PRE 0.6: apply 2026-09-14_0610 first'; END IF;
END
$pre$;

-- --------------------------------------------------------------------------------------------
-- PART 1. The calibrated prior and the tolerances. COPIED FROM phase0_calibration.json; the VERIFY
-- checks them against the template they were calibrated from, and the real-page fixture proves
-- they measure a page a person accepted.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_generated_page_prior()
RETURNS numeric[]
LANGUAGE sql IMMUTABLE
AS $function$
  -- The six printed boundaries of the DERM_V4.00 form as our pdf-service prints them, measured as
  -- the mean over the Phase 0 corpus pages the matcher accepted (phase0_calibration.json,
  -- calibrated_prior). A PRIOR: it chooses which detected lines are the boundaries and is never
  -- written. The stamp-midpoint template (derm.fn_generated_template_boundaries) is 0.0 to 0.75pp
  -- from the printed lines; this is what the printed lines actually average to.
  SELECT ARRAY[25.062, 33.431, 40.218, 47.481, 55.380, 63.247]::numeric[];   -- phase0_calibration.json calibrated_prior, 2026-09-14
$function$;

CREATE OR REPLACE FUNCTION derm.fn_generated_match_tolerances()
RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $function$
  -- phase0_calibration.json -> tolerances. search: window around each prior boundary when finding the
  -- page's shift; match: window around prior + shift when taking a boundary; gap: per-slot deviation
  -- from the printed gap; clear: a stamp's distance from both lines of its slot; min_run: shortest
  -- usable line as a fraction of the form width.
  SELECT jsonb_build_object('search', 2.50, 'match', 0.85, 'gap', 0.85, 'clear', 0.50, 'min_run', 0.35);   -- phase0_calibration.json tolerances, 2026-09-14
$function$;

-- --------------------------------------------------------------------------------------------
-- PART 2. The ledger.
-- --------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS derm.generated_measure_attempts (
  dump_folder      text        NOT NULL,
  page             integer     NOT NULL,
  image_url        text,
  source_etag      text,
  attempts         integer     NOT NULL DEFAULT 0,
  first_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_attempt_at  timestamptz NOT NULL DEFAULT now(),
  last_outcome     text,
  last_reason      text,
  last_detail      text,
  lines            jsonb,
  meta             jsonb,
  measured_at      timestamptz,
  CONSTRAINT generated_measure_attempts_pkey PRIMARY KEY (dump_folder, page),
  CONSTRAINT generated_measure_attempts_attempts_chk CHECK (attempts >= 0 AND attempts <= 100),
  CONSTRAINT generated_measure_attempts_outcome_chk
    CHECK (last_outcome IS NULL OR last_outcome IN ('requested', 'measured', 'refused', 'error'))
);
COMMENT ON TABLE derm.generated_measure_attempts IS
  'The generated-sheet finisher''s ledger, one row per (folder, image position). attempts counts '
  'hand-outs (recorded when the cron REQUESTS a measurement, so a worker that dies still consumes '
  'its budget); three per image, re-armed when the image or its etag changes or a card on the page '
  'is edited after the last attempt. last_reason is the plain sentence the Studio banner shows; '
  'last_detail and lines are the forensic record. Unaudited by design (rule 8 opt-out): machine '
  'bookkeeping, regenerable, deleting a row only re-arms a measurement.';
REVOKE ALL ON TABLE derm.generated_measure_attempts FROM PUBLIC;
REVOKE ALL ON TABLE derm.generated_measure_attempts FROM anon;
REVOKE ALL ON TABLE derm.generated_measure_attempts FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE derm.generated_measure_attempts TO service_role;

CREATE OR REPLACE FUNCTION derm._gm_record(
  p_dump_folder text, p_page integer, p_image_url text, p_outcome text,
  p_reason text, p_detail text, p_lines jsonb, p_meta jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_attempts int; v_reason text := p_reason;
BEGIN
  INSERT INTO derm.generated_measure_attempts
    (dump_folder, page, image_url, source_etag, attempts, last_outcome, last_reason, last_detail, lines, meta, measured_at)
  VALUES
    (p_dump_folder, p_page, p_image_url, derm._img_etag(p_image_url), 1, p_outcome, p_reason,
     left(p_detail, 4000), p_lines, p_meta, CASE WHEN p_outcome = 'measured' THEN now() END)
  ON CONFLICT (dump_folder, page) DO UPDATE
     SET image_url = EXCLUDED.image_url, source_etag = EXCLUDED.source_etag,
         last_outcome = EXCLUDED.last_outcome, last_reason = EXCLUDED.last_reason,
         last_detail = EXCLUDED.last_detail, lines = EXCLUDED.lines, meta = EXCLUDED.meta,
         last_attempt_at = now(),
         measured_at = coalesce(EXCLUDED.measured_at, derm.generated_measure_attempts.measured_at)
  RETURNING attempts INTO v_attempts;
  -- the third failed read is the last one the cron will request: say so, in words
  IF p_outcome = 'error' AND v_attempts >= 3 THEN
    v_reason := 'The scan could not be read after three tries. Measure this page with Draw the bands.';
    UPDATE derm.generated_measure_attempts SET last_reason = v_reason
     WHERE dump_folder = p_dump_folder AND page = p_page;
  END IF;
  RETURN jsonb_build_object('outcome', p_outcome, 'reason', v_reason, 'detail', p_detail, 'attempts', v_attempts);
END $function$;
REVOKE ALL ON FUNCTION derm._gm_record(text, integer, text, text, text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm._gm_record(text, integer, text, text, text, text, jsonb, jsonb) TO service_role;

-- --------------------------------------------------------------------------------------------
-- PART 3. "service_role is a machine": one arm in each helper. The two bodies below are spliced in
-- by scripts/probes/generated_finisher/assemble_finisher_migration.py from the LIVE
-- pg_get_functiondef output, each anchor asserted to occur exactly once (the Studio write key in
-- _require_stamp_key is not retyped here on purpose).
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm._actor(p_default text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_email text;
  v_role  text;
BEGIN
  BEGIN
    v_email := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email';
    v_role  := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';
  EXCEPTION WHEN others THEN
    v_email := NULL;
    v_role  := NULL;
  END;
  -- 2026-09-14: a service_role caller with no email is a machine (the generated-sheet finisher
  -- writes bands and extents through save_page_geometry as service_role). Fred, 2026-09-14:
  -- everything machine-made carries the one label. A person's JWT still wins below, and direct
  -- SQL (no JWT at all) still gets p_default.
  IF v_role = 'service_role' AND nullif(v_email, '') IS NULL THEN
    RETURN 'stamp-studio-ai';
  END IF;
  RETURN coalesce(
    nullif(v_email, ''),
    nullif(current_setting('request.jwt.claim.email', true), ''),
    p_default);
END $function$;

CREATE OR REPLACE FUNCTION derm._require_stamp_key()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_headers text; v_key text; v_role text;
BEGIN
  v_headers := current_setting('request.headers', true);
  IF v_headers IS NULL OR v_headers = '' THEN
    RETURN;  -- direct SQL (not PostgREST): admin scripts stay allowed
  END IF;
  -- 2026-09-14: a service_role request (the generated-sheet finisher: edge fn -> PostgREST) is
  -- let through. That key already writes every table directly; the Studio's header key was
  -- never a barrier to it, only to a browser holding the anon or a user key.
  BEGIN
    v_role := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';
  EXCEPTION WHEN others THEN
    v_role := NULL;
  END;
  IF v_role = 'service_role' THEN
    RETURN;
  END IF;
  v_key := v_headers::jsonb->>'x-stamp-key';
  IF v_key IS DISTINCT FROM 'sk_derm_stamp_7f2c91ae4b' THEN
    RAISE EXCEPTION 'unauthorized: stamp-studio write key required';
  END IF;
END $function$;

-- --------------------------------------------------------------------------------------------
-- PART 4. Completion: the pre-checks a machine applies beyond the human path, then the resolver's
-- own write, keyed on the folder.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_generated_completion_blocker(p_dump_folder text)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_ticket text; v_status record; v_cfg text;
BEGIN
  SELECT r.white_manifest_number INTO v_ticket FROM derm.address_row_map r
   WHERE r.dump_folder = p_dump_folder AND r.white_manifest_number IS NOT NULL LIMIT 1;
  IF v_ticket IS NULL OR NOT coalesce(derm.fn_sheet_is_generated(v_ticket), false) THEN
    RETURN 'This sheet was not printed by us, so it is not completed automatically.';
  END IF;
  SELECT * INTO v_status FROM derm.stamp_sheet_status WHERE dump_folder = p_dump_folder;
  IF FOUND AND v_status.completed THEN
    RETURN 'This sheet is already marked complete.';
  END IF;
  IF FOUND AND v_status.reopened_at IS NOT NULL THEN
    RETURN 'This sheet was reopened for a person to look at, so it is not completed automatically.';
  END IF;
  SELECT lower(btrim(value)) INTO v_cfg FROM public.app_config WHERE key = 'generated_sheet_auto_complete';
  IF v_cfg = 'false' THEN
    RETURN 'Automatic completion is switched off.';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map r WHERE r.dump_folder = p_dump_folder AND r.stamp_placed_at IS NULL) THEN
    RETURN 'A card on this sheet has no stamp yet.';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map r
              WHERE r.dump_folder = p_dump_folder AND r.stamp_placed_at IS NOT NULL
                AND (r.stamp_page IS NULL OR r.stamp_page < 1
                     OR r.stamp_page > coalesce(array_length(derm.ticket_page_images(r.white_manifest_number), 1), 0))) THEN
    RETURN 'A stamp on this sheet is on a page that no longer exists.';
  END IF;
  -- one card per printed row, per client, or a neighbour's row could be published as this client's
  IF EXISTS (
    SELECT 1
      FROM (SELECT r.matched_client_id AS client_id, count(*) AS cards
              FROM derm.address_row_map r WHERE r.dump_folder = p_dump_folder GROUP BY 1) c
      LEFT JOIN (SELECT sc.client_id, sum(sc.rows_printed) AS rows_printed
                   FROM derm.address_sheet_manifests l
                   JOIN public.derm_manifests m ON m.id = l.manifest_id AND m.deleted_at IS NULL
                   JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
                   JOIN derm.address_sheet_clients sc ON sc.sheet_id = l.sheet_id AND sc.slot = l.slot
                  WHERE coalesce(m.white_manifest_number, m.yellow_ticket_number) = v_ticket
                  GROUP BY 1) p ON p.client_id = c.client_id
     WHERE p.rows_printed IS NULL) THEN
    RETURN 'A client on this sheet is not on the printed list of this sheet. A person needs to check it.';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM (SELECT r.matched_client_id AS client_id, count(*) AS cards
              FROM derm.address_row_map r WHERE r.dump_folder = p_dump_folder GROUP BY 1) c
      JOIN (SELECT sc.client_id, sum(sc.rows_printed) AS rows_printed
              FROM derm.address_sheet_manifests l
              JOIN public.derm_manifests m ON m.id = l.manifest_id AND m.deleted_at IS NULL
              JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
              JOIN derm.address_sheet_clients sc ON sc.sheet_id = l.sheet_id AND sc.slot = l.slot
             WHERE coalesce(m.white_manifest_number, m.yellow_ticket_number) = v_ticket
             GROUP BY 1) p ON p.client_id = c.client_id
     WHERE p.rows_printed <> c.cards) THEN
    RETURN 'A client on this sheet does not have one card per printed row. Give it one card per permit first.';
  END IF;
  RETURN NULL;
END $function$;
REVOKE ALL ON FUNCTION derm.fn_generated_completion_blocker(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_generated_completion_blocker(text) TO service_role;

CREATE OR REPLACE FUNCTION derm.fn_complete_generated_sheet(p_dump_folder text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_block text; v_pub text; v_done boolean;
BEGIN
  v_block := derm.fn_generated_completion_blocker(p_dump_folder);
  IF v_block = 'This sheet is already marked complete.' THEN
    RETURN jsonb_build_object('completed', true, 'reason', v_block);
  END IF;
  IF v_block IS NOT NULL THEN
    RETURN jsonb_build_object('completed', false, 'reason', v_block);
  END IF;
  -- the same gate trg_a0_completion_requires_geometry applies, checked here first so a refused
  -- attempt writes no status row and no audit row every ten minutes
  v_pub := derm.fn_sheet_publishable(p_dump_folder);
  IF v_pub IS NOT NULL THEN
    RETURN jsonb_build_object('completed', false,
      'reason', coalesce(derm.fn_sheet_publishable_detail(p_dump_folder)->>'message', derm.fn_publishable_hint(v_pub)),
      'blocker', v_pub);
  END IF;
  -- the resolver's own write (fn_resolve_generated_sheet_for_ticket, auto-complete leg), by folder
  INSERT INTO derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  VALUES (p_dump_folder, true, now(), 'stamp-studio-ai', now())
  ON CONFLICT (dump_folder) DO UPDATE
     SET completed    = true,
         completed_at = coalesce(derm.stamp_sheet_status.completed_at, now()),
         completed_by = coalesce(derm.stamp_sheet_status.completed_by, 'stamp-studio-ai'),
         updated_at   = now()
   WHERE NOT derm.stamp_sheet_status.completed
     AND derm.stamp_sheet_status.reopened_at IS NULL;
  SELECT completed INTO v_done FROM derm.stamp_sheet_status WHERE dump_folder = p_dump_folder;
  RETURN jsonb_build_object('completed', coalesce(v_done, false),
    'reason', CASE WHEN coalesce(v_done, false)
                   THEN 'Marked complete. The blacked-out copy follows on the next sweep.'
                   ELSE 'The completion was refused at the last moment; the sheet stays open.' END);
END $function$;
REVOKE ALL ON FUNCTION derm.fn_complete_generated_sheet(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_complete_generated_sheet(text) TO service_role;

-- --------------------------------------------------------------------------------------------
-- PART 5. The backlog: which (folder, image position) the finisher may measure, and which folders
-- it may complete. Derived predicates, no state to drift.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.v_generated_measure_backlog AS
WITH gen AS (
  SELECT r.dump_folder, max(r.white_manifest_number) AS ticket
    FROM derm.address_row_map r
   WHERE r.white_manifest_number IS NOT NULL AND r.dump_folder LIKE 'ticket-%'
   GROUP BY r.dump_folder
), open_folders AS (
  SELECT g.dump_folder, g.ticket
    FROM gen g
    LEFT JOIN derm.stamp_sheet_status s ON s.dump_folder = g.dump_folder
   WHERE coalesce(s.completed, false) = false
     AND s.reopened_at IS NULL
     AND coalesce(derm.fn_sheet_is_generated(g.ticket), false)
), pages AS (
  SELECT o.dump_folder, o.ticket, coalesce(r.stamp_page, r.page) AS page,
         count(*) AS stamped_cards,
         count(*) FILTER (WHERE r.band_y0_pct IS NOT NULL AND r.band_y1_pct IS NOT NULL) AS banded_cards,
         max(r.updated_at) AS cards_updated_at
    FROM open_folders o
    JOIN derm.address_row_map r ON r.dump_folder = o.dump_folder
   WHERE r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL
   GROUP BY 1, 2, 3
), img AS (
  SELECT p.*, (derm.ticket_page_images(p.ticket))[p.page] AS image_url FROM pages p
)
SELECT i.dump_folder, i.ticket, i.page, i.image_url,
       derm._img_etag(i.image_url) AS source_etag,
       i.stamped_cards, i.banded_cards, i.cards_updated_at,
       EXISTS (SELECT 1 FROM derm.page_block_extents e
                WHERE e.dump_folder = i.dump_folder AND e.effective_page = i.page) AS has_extent,
       a.attempts, a.last_outcome, a.last_reason, a.last_attempt_at,
       -- the budget counts against THIS image and THIS card state: a replaced scan, a changed etag
       -- or a card edited after the last attempt re-arms it
       CASE WHEN a.dump_folder IS NULL THEN 0
            WHEN a.image_url IS DISTINCT FROM i.image_url THEN 0
            WHEN a.source_etag IS DISTINCT FROM derm._img_etag(i.image_url) THEN 0
            WHEN i.cards_updated_at > a.last_attempt_at THEN 0
            ELSE a.attempts END AS attempts_on_this_image
  FROM img i
  LEFT JOIN derm.generated_measure_attempts a ON a.dump_folder = i.dump_folder AND a.page = i.page
 WHERE (i.banded_cards < i.stamped_cards
        OR NOT EXISTS (SELECT 1 FROM derm.page_block_extents e
                        WHERE e.dump_folder = i.dump_folder AND e.effective_page = i.page))
   -- a person who has started marking lines on this page owns it
   AND NOT EXISTS (SELECT 1 FROM derm.page_rule_scans sc
                    WHERE sc.dump_folder = i.dump_folder AND sc.effective_page = i.page
                      AND sc.source LIKE 'human-v1-%');
COMMENT ON VIEW derm.v_generated_measure_backlog IS
  'Pages of open generated sheets the finisher may measure: stamped, missing a band or the extent, '
  'no human-marked lines. attempts_on_this_image is the budget consumed against the CURRENT scan '
  'and card state; fn_generated_measure_targets hands out pages below 3.';
REVOKE ALL ON derm.v_generated_measure_backlog FROM PUBLIC;
REVOKE ALL ON derm.v_generated_measure_backlog FROM anon;
REVOKE ALL ON derm.v_generated_measure_backlog FROM authenticated;
GRANT SELECT ON derm.v_generated_measure_backlog TO service_role;

CREATE OR REPLACE FUNCTION derm.fn_generated_measure_targets(p_limit integer DEFAULT 2)
RETURNS TABLE(dump_folder text, ticket text, page integer, image_url text, source_etag text, attempts_on_this_image integer)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
  SELECT b.dump_folder, b.ticket, b.page, b.image_url, b.source_etag, b.attempts_on_this_image
    FROM derm.v_generated_measure_backlog b
   WHERE b.image_url IS NOT NULL AND b.attempts_on_this_image < 3
   ORDER BY b.attempts_on_this_image, b.last_attempt_at NULLS FIRST, b.dump_folder, b.page
   LIMIT greatest(1, least(coalesce(p_limit, 2), 5));
$function$;
REVOKE ALL ON FUNCTION derm.fn_generated_measure_targets(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_generated_measure_targets(integer) TO service_role;

CREATE OR REPLACE VIEW derm.v_generated_complete_backlog AS
WITH gen AS (
  SELECT r.dump_folder, max(r.white_manifest_number) AS ticket
    FROM derm.address_row_map r
   WHERE r.white_manifest_number IS NOT NULL AND r.dump_folder LIKE 'ticket-%'
   GROUP BY r.dump_folder
)
SELECT g.dump_folder, g.ticket, derm.fn_generated_completion_blocker(g.dump_folder) AS blocker
  FROM gen g
  LEFT JOIN derm.stamp_sheet_status s ON s.dump_folder = g.dump_folder
 WHERE coalesce(s.completed, false) = false
   AND s.reopened_at IS NULL
   AND coalesce(derm.fn_sheet_is_generated(g.ticket), false)
   AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                    WHERE r.dump_folder = g.dump_folder AND r.stamp_placed_at IS NULL);
COMMENT ON VIEW derm.v_generated_complete_backlog IS
  'Open generated sheets with every card placed. blocker NULL means fn_complete_generated_sheet '
  'will try (it still checks fn_sheet_publishable); otherwise the plain reason it will not.';
REVOKE ALL ON derm.v_generated_complete_backlog FROM PUBLIC;
REVOKE ALL ON derm.v_generated_complete_backlog FROM anon;
REVOKE ALL ON derm.v_generated_complete_backlog FROM authenticated;
GRANT SELECT ON derm.v_generated_complete_backlog TO service_role;

-- --------------------------------------------------------------------------------------------
-- PART 6. The writer.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_generated_page_measured(
  p_dump_folder text, p_page integer, p_image_url text, p_lines jsonb, p_meta jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'derm', 'public', 'pg_temp'
AS $function$
DECLARE
  v_ticket text; v_live_url text; v_cards jsonb; v_stamps jsonb; v_m jsonb; v_tol jsonb;
  v_bounds numeric[]; v_runs numeric[]; v_rules jsonb; v_bands jsonb;
  v_rec jsonb; v_geo jsonb; v_done jsonb; v_reason text; v_source text;
  v_meta jsonb := coalesce(p_meta, '{}'::jsonb);
BEGIN
  IF p_dump_folder IS NULL OR p_page IS NULL OR p_image_url IS NULL THEN
    RAISE EXCEPTION 'dump_folder, page and image_url are required' USING ERRCODE = '22023';
  END IF;
  v_source := 'template-v1-' || to_char(now() AT TIME ZONE 'America/New_York', 'YYYY-MM-DD');

  -- 0. identity: a generated sheet, and the image at this position is the one that was measured
  SELECT r.white_manifest_number INTO v_ticket FROM derm.address_row_map r
   WHERE r.dump_folder = p_dump_folder AND r.white_manifest_number IS NOT NULL LIMIT 1;
  IF v_ticket IS NULL OR NOT coalesce(derm.fn_sheet_is_generated(v_ticket), false) THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'refused',
      'This sheet was not printed by us, so it cannot be measured automatically. Measure it with Draw the bands.',
      'no generated-sheet link', p_lines, v_meta);
  END IF;
  v_live_url := (derm.ticket_page_images(v_ticket))[p_page];
  IF v_live_url IS DISTINCT FROM p_image_url THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'error',
      'The scan for this page changed while it was being measured. It will be measured again.',
      format('measured %s, live position %s holds %s', p_image_url, p_page, coalesce(v_live_url, '(nothing)')),
      p_lines, v_meta);
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'error',
      'The scan could not be read this time. It will be tried again.',
      coalesce(v_meta->>'error', 'no lines'), p_lines, v_meta);
  END IF;

  -- 1. still in the backlog? (open folder, stamped page, unmeasured, no human-marked lines)
  IF NOT EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog b
                  WHERE b.dump_folder = p_dump_folder AND b.page = p_page) THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'refused',
      'This page no longer needs measuring automatically.',
      'not in v_generated_measure_backlog: completed, reopened, already measured, or a person is measuring it',
      p_lines, v_meta);
  END IF;

  -- 2. the cards, with their printed row (or the plain refusal)
  v_cards := derm.fn_generated_page_cards(p_dump_folder, p_page);
  IF v_cards->>'refusal' IS NOT NULL THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'refused',
      v_cards->>'refusal', v_cards->>'detail', p_lines, v_meta);
  END IF;
  SELECT jsonb_agg(jsonb_build_object('row', c->'row', 'y', c->'y')) INTO v_stamps
    FROM jsonb_array_elements(v_cards->'cards') c;

  -- 3. the match
  v_tol := derm.fn_generated_match_tolerances();
  v_m := derm.fn_match_generated_page(p_lines, v_stamps, derm.fn_generated_page_prior(),
           (v_tol->>'search')::numeric, (v_tol->>'match')::numeric, (v_tol->>'gap')::numeric,
           (v_tol->>'clear')::numeric, (v_tol->>'min_run')::numeric);
  IF NOT coalesce((v_m->>'ok')::boolean, false) THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'refused',
      v_m->>'reason', v_m->>'detail', p_lines, v_meta || jsonb_build_object('match', v_m));
  END IF;
  v_bounds := ARRAY(SELECT e::numeric FROM jsonb_array_elements_text(v_m->'boundaries') e);
  v_runs   := ARRAY(SELECT e::numeric FROM jsonb_array_elements_text(v_m->'runs') e);
  v_rules  := (SELECT jsonb_agg(jsonb_build_object('pct', v_bounds[i], 'run', v_runs[i], 'kind', 'boundary') ORDER BY i)
                 FROM generate_series(1, 6) i);
  v_bands  := (SELECT jsonb_agg(jsonb_build_object('row_id', (c->>'row_id')::bigint,
                                                    'y0', v_bounds[(c->>'row')::int],
                                                    'y1', v_bounds[(c->>'row')::int + 1]))
                 FROM jsonb_array_elements(v_cards->'cards') c);

  -- 4. both writes or neither, through the guarded RPCs, in one subtransaction
  BEGIN
    v_rec := derm.record_page_rules(p_dump_folder, p_page, v_source, p_image_url, v_rules,
               jsonb_build_object(
                 'grade', 'OK',
                 'detail', format('generated-sheet finisher: six printed boundaries matched to the printed layout (shift %spp, residuals %s, %s usable lines)',
                                  v_m->>'shift', v_m->'residuals', v_m->>'usable_lines'),
                 'image_w', v_meta->'image_w', 'image_h', v_meta->'image_h', 'skew', v_meta->'skew'));
    IF NOT coalesce((v_rec->>'wrote')::boolean, false) OR coalesce((v_rec->>'n_boundaries')::int, 0) <> 6 THEN
      RAISE EXCEPTION 'GM_RULES_REFUSED:%', coalesce(v_rec->>'hint', v_rec->>'detail', 'the printed lines were not accepted');
    END IF;
    v_geo := derm.save_page_geometry(p_dump_folder, p_page, v_bands, v_bounds[1], v_bounds[6]);
  EXCEPTION WHEN OTHERS THEN
    -- the subtransaction rolled both writes back. The words go to the person, the rest to the log.
    v_reason := CASE
      WHEN SQLERRM LIKE 'GM_RULES_REFUSED:%' THEN
        'The printed lines found on this scan were not accepted as a row layout. Measure this page with Draw the bands.'
      WHEN SQLERRM LIKE 'page geometry refused:%' THEN
        regexp_replace(regexp_replace(regexp_replace(SQLERRM, '^page geometry refused:\s*', ''),
                                      '\s*\[G[0-9A-Z_]+:[^]]*\]', '', 'g'),
                       '\s*\n\s*', ' ', 'g')
      ELSE 'This page could not be saved automatically. Measure it with Draw the bands.'
    END;
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'refused', v_reason, SQLERRM,
                           p_lines, v_meta || jsonb_build_object('match', v_m));
  END;

  -- 5. complete when every gate passes; a no-op with a reason otherwise
  v_done := derm.fn_complete_generated_sheet(p_dump_folder);
  RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'measured', NULL,
           format('bands %s, extent %s to %s, shift %s, residuals %s, source %s',
                  v_geo->>'saved_bands', v_bounds[1], v_bounds[6], v_m->>'shift', v_m->'residuals', v_source),
           p_lines, v_meta || jsonb_build_object('match', v_m))
         || jsonb_build_object('geometry', v_geo, 'completion', v_done, 'source', v_source);
END $function$;
REVOKE ALL ON FUNCTION derm.fn_generated_page_measured(text, integer, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_generated_page_measured(text, integer, text, jsonb, jsonb) TO service_role;

-- --------------------------------------------------------------------------------------------
-- PART 7. The banner carries the finisher's reason. Body spliced from pg_get_functiondef by the
-- assembly script (a `fin` CTE and one prefix on the page-aware message; nothing else moves).
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_sheet_publishable_detail(p_dump_folder text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  WITH code AS (
    SELECT derm.fn_sheet_publishable(p_dump_folder) AS blocker
  ), stamped AS (
    SELECT DISTINCT COALESCE(r.stamp_page, r.page) AS pg
      FROM derm.address_row_map r
     WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL
  ), need_band AS (
    -- a stamped row still on an ESTIMATED band (no manual/snapped override)
    SELECT DISTINCT COALESCE(r.stamp_page, r.page) AS pg
      FROM derm.address_row_map r
     WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL
       AND (r.band_y0_pct IS NULL OR r.band_y1_pct IS NULL)
  ), need_ext AS (
    SELECT s.pg FROM stamped s
     WHERE NOT EXISTS (SELECT 1 FROM derm.page_block_extents e
                        WHERE e.dump_folder = p_dump_folder AND e.effective_page = s.pg)
  ), fin AS (
    -- 2026-09-14: the generated-sheet finisher's latest reason for a page still needing geometry,
    -- so the banner says WHY the sheet was not measured automatically (plain words, from the
    -- ledger derm.generated_measure_attempts).
    SELECT string_agg('Page ' || a.page || ' could not be measured automatically: ' || a.last_reason,
                      ' ' ORDER BY a.page) AS reasons
      FROM derm.generated_measure_attempts a
     WHERE a.dump_folder = p_dump_folder
       AND a.last_outcome IN ('refused', 'error')
       AND a.last_reason IS NOT NULL
       AND a.page IN (SELECT pg FROM need_band UNION SELECT pg FROM need_ext)
  ), agg AS (
    SELECT (SELECT blocker FROM code) AS blocker,
           (SELECT reasons FROM fin) AS finisher_reasons,
           (SELECT coalesce(array_agg(pg ORDER BY pg), '{}') FROM need_band) AS pages_bands,
           (SELECT coalesce(array_agg(pg ORDER BY pg), '{}') FROM need_ext)  AS pages_ext
  )
  SELECT jsonb_build_object(
    'blocker', a.blocker,
    'pages_needing_bands',  to_jsonb(a.pages_bands),
    'pages_needing_extent', to_jsonb(a.pages_ext),
    'finisher_reasons', a.finisher_reasons,
    'message',
      CASE
        WHEN a.blocker IS NULL THEN NULL
        -- Name the page whenever the fault IS per-page. This is the whole point of the function:
        -- 834742 was blocked only by page 3 while page 1 was already correct, and the bare code
        -- sent the operator back to redo the page that was fine.
        WHEN a.blocker IN ('needs_extent', 'needs_snap_then_extent')
             AND (array_length(a.pages_bands, 1) > 0 OR array_length(a.pages_ext, 1) > 0)
          THEN coalesce(a.finisher_reasons || ' ', '') || 'Page ' ||
               array_to_string(
                 (SELECT array_agg(DISTINCT p ORDER BY p)
                    FROM unnest(a.pages_bands || a.pages_ext) AS u(p)), ', ')
               || ': ' || derm.fn_publishable_hint(a.blocker)
        ELSE derm.fn_publishable_hint(a.blocker)
      END)
  FROM agg a;
$function$;

-- --------------------------------------------------------------------------------------------
-- PART 8. The off switch (missing = on).
-- --------------------------------------------------------------------------------------------
INSERT INTO public.app_config (key, value)
SELECT 'generated_sheet_auto_complete', 'true'
 WHERE NOT EXISTS (SELECT 1 FROM public.app_config WHERE key = 'generated_sheet_auto_complete');

NOTIFY pgrst, 'reload schema';

-- --------------------------------------------------------------------------------------------
-- VERIFY. A real generated page, a person's accepted geometry as the truth, everything in one
-- savepoint that is rolled back. The pad lines are the refusal control.
-- --------------------------------------------------------------------------------------------
DO $verify$
DECLARE
  -- THE FIXTURE: a completed generated folder whose Phase 0 verdict is MATCH, with five single-row
  -- cards on the page. ticket-834742 page 2 (derm/1776/address_2.jpg) unless Phase 0 says otherwise.
  v_fx_folder text := 'ticket-834742';
  v_fx_ticket text := '834742';
  v_fx_page   int  := 2;
  v_fx_suffix text := '/derm/1776/address_2.jpg';
  v_lines jsonb := '[{"pct": 12.852, "run": 0.994, "kind": "boundary"}, {"pct": 22.623, "run": 0.414, "kind": "divider"}, {"pct": 25, "run": 0.992, "kind": "boundary"}, {"pct": 25.352, "run": 0.412, "kind": "divider"}, {"pct": 29.225, "run": 0.412, "kind": "divider"}, {"pct": 33.539, "run": 0.995, "kind": "boundary"}, {"pct": 36.972, "run": 0.415, "kind": "divider"}, {"pct": 40.317, "run": 0.995, "kind": "boundary"}, {"pct": 43.662, "run": 0.417, "kind": "divider"}, {"pct": 47.711, "run": 0.995, "kind": "boundary"}, {"pct": 51.496, "run": 0.415, "kind": "divider"}, {"pct": 55.722, "run": 0.995, "kind": "boundary"}, {"pct": 59.507, "run": 0.414, "kind": "divider"}, {"pct": 63.644, "run": 0.994, "kind": "boundary"}, {"pct": 66.901, "run": 0.835, "kind": "boundary"}, {"pct": 69.366, "run": 0.718, "kind": "divider"}]'::jsonb;    -- phase0_calibration.json -> lines["ticket-834742_p2"].lines
  v_pad   jsonb := '[{"pct":13.118,"run":0.719},{"pct":15.865,"run":0.981},{"pct":26.992,"run":0.359},{"pct":29.396,"run":0.980},{"pct":32.349,"run":0.368},{"pct":35.096,"run":0.981},{"pct":37.981,"run":0.359},{"pct":40.728,"run":0.982},{"pct":43.613,"run":0.366},{"pct":46.36,"run":0.982},{"pct":49.245,"run":0.359},{"pct":51.992,"run":0.983},{"pct":54.876,"run":0.363},{"pct":57.624,"run":0.984},{"pct":60.508,"run":0.361},{"pct":63.324,"run":0.984},{"pct":65.385,"run":0.984},{"pct":67.995,"run":0.983}]';
  v_tech  text := '(_|\[|\]|jsonb|numeric|null|G[0-9]+|template-v1|runlen|human-v1)';
  v_url text; v_j jsonb; v_n int; v_max numeric; v_r record;
  v_fx_bands jsonb; v_fx_top numeric; v_fx_bot numeric; v_msg text;
BEGIN
  -- 0. preconditions and the prior's shape
  IF array_length(derm.fn_generated_page_prior(), 1) <> 6 THEN RAISE EXCEPTION 'PRE: prior'; END IF;
  FOR v_n IN 1 .. 6 LOOP
    IF abs((derm.fn_generated_page_prior())[v_n] - (derm.fn_generated_template_boundaries())[v_n]) > 1.0 THEN
      RAISE EXCEPTION 'PRE: prior boundary % is more than 1pp from the template; the pasted numbers are wrong', v_n;
    END IF;
  END LOOP;
  IF (derm.fn_generated_match_tolerances()->>'match')::numeric NOT BETWEEN 0.5 AND 1.0
     OR (derm.fn_generated_match_tolerances()->>'gap')::numeric NOT BETWEEN 0.5 AND 1.0 THEN
    RAISE EXCEPTION 'PRE: tolerances outside the range Phase 0 allows';
  END IF;
  IF jsonb_typeof(v_lines) <> 'array' OR jsonb_array_length(v_lines) < 6 THEN RAISE EXCEPTION 'PRE: the fixture lines were not spliced in'; END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_fx_folder AND completed) THEN
    RAISE EXCEPTION 'PRE: % is not a completed folder; pick another MATCH page from Phase 0', v_fx_folder;
  END IF;
  v_url := (derm.ticket_page_images(v_fx_ticket))[v_fx_page];
  IF v_url NOT LIKE '%' || v_fx_suffix THEN RAISE EXCEPTION 'PRE: image % is %, not %', v_fx_page, v_url, v_fx_suffix; END IF;
  IF EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder) THEN
    RAISE EXCEPTION 'PRE: % is already in the backlog', v_fx_folder;
  END IF;
  IF (SELECT value FROM public.app_config WHERE key = 'generated_sheet_auto_complete') <> 'true' THEN RAISE EXCEPTION 'PRE: config'; END IF;

  -- =========================== fixture A: the happy path and the refusal control ===========================
  BEGIN
    SELECT jsonb_object_agg(id, jsonb_build_object('y0', band_y0_pct, 'y1', band_y1_pct)) INTO v_fx_bands
      FROM derm.address_row_map WHERE dump_folder = v_fx_folder AND coalesce(stamp_page, page) = v_fx_page;
    SELECT top_pct, bottom_pct INTO v_fx_top, v_fx_bot FROM derm.page_block_extents WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page;
    IF v_fx_top IS NULL OR (SELECT count(*) FROM jsonb_object_keys(v_fx_bands)) < 3 THEN RAISE EXCEPTION 'SETUP: fixture has no accepted geometry'; END IF;
    -- un-complete without leaving the reopen pin (the pin trigger sets reopened_at on the flip)
    UPDATE derm.stamp_sheet_status SET completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_fx_folder;
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL WHERE dump_folder = v_fx_folder;
    -- strip the page's geometry and the person's lines
    UPDATE derm.address_row_map SET band_y0_pct = NULL, band_y1_pct = NULL, band_source = NULL, band_set_at = NULL, band_set_by = NULL
     WHERE dump_folder = v_fx_folder AND coalesce(stamp_page, page) = v_fx_page;
    DELETE FROM derm.page_block_extents WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page;
    DELETE FROM derm.page_row_rules  WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'human-v1-%';
    DELETE FROM derm.page_rule_scans WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'human-v1-%';

    -- 1. the backlog names exactly this page; completion says why it cannot yet
    IF (SELECT count(*) FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder) <> 1
       OR NOT EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder AND page = v_fx_page AND image_url = v_url AND attempts_on_this_image = 0) THEN
      RAISE EXCEPTION 'VERIFY 1 FAILED: backlog';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.fn_generated_measure_targets(5) t WHERE t.dump_folder = v_fx_folder AND t.page = v_fx_page) THEN RAISE EXCEPTION 'VERIFY 1a FAILED: targets'; END IF;
    v_j := derm.fn_complete_generated_sheet(v_fx_folder);
    IF (v_j->>'completed')::boolean OR v_j->>'blocker' IS NULL THEN RAISE EXCEPTION 'VERIFY 1b FAILED: %', v_j; END IF;

    -- 2. the refusal control: pad lines. Nothing is written; the ledger and the banner carry the reason.
    v_j := derm.fn_generated_page_measured(v_fx_folder, v_fx_page, v_url, v_pad, '{"image_w":980,"image_h":728,"skew":0}'::jsonb);
    IF v_j->>'outcome' <> 'refused' OR v_j->>'reason' ~ v_tech THEN RAISE EXCEPTION 'VERIFY 2 FAILED: %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM derm.address_row_map WHERE dump_folder = v_fx_folder AND coalesce(stamp_page, page) = v_fx_page AND band_y0_pct IS NOT NULL)
       OR EXISTS (SELECT 1 FROM derm.page_block_extents WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page)
       OR EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'template-v1-%')
       OR EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_fx_folder AND completed) THEN
      RAISE EXCEPTION 'VERIFY 2a FAILED: a refusal wrote something';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.generated_measure_attempts WHERE dump_folder = v_fx_folder AND page = v_fx_page AND last_outcome = 'refused' AND last_reason !~ v_tech AND lines = v_pad) THEN
      RAISE EXCEPTION 'VERIFY 2b FAILED: ledger';
    END IF;
    v_msg := derm.fn_sheet_publishable_detail(v_fx_folder)->>'message';
    IF v_msg NOT LIKE 'Page ' || v_fx_page || ' could not be measured automatically: %' OR v_msg ~ v_tech THEN
      RAISE EXCEPTION 'VERIFY 2c FAILED: banner reads "%"', v_msg;
    END IF;

    -- 3. a wrong image url is an error, and writes nothing
    v_j := derm.fn_generated_page_measured(v_fx_folder, v_fx_page, 'https://example.invalid/x.jpg', v_lines, '{}'::jsonb);
    IF v_j->>'outcome' <> 'error' THEN RAISE EXCEPTION 'VERIFY 3 FAILED: %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'template-v1-%') THEN RAISE EXCEPTION 'VERIFY 3a FAILED'; END IF;

    -- 4. the real lines: measured, the person's geometry reproduced, completed by the machine
    v_j := derm.fn_generated_page_measured(v_fx_folder, v_fx_page, v_url, v_lines, '{"image_w":1492,"image_h":1156,"skew":0}'::jsonb);
    IF v_j->>'outcome' <> 'measured' THEN RAISE EXCEPTION 'VERIFY 4 FAILED: %', v_j; END IF;
    SELECT max(greatest(abs(r.band_y0_pct - (v_fx_bands->(r.id::text)->>'y0')::numeric),
                        abs(r.band_y1_pct - (v_fx_bands->(r.id::text)->>'y1')::numeric))) INTO v_max
      FROM derm.address_row_map r WHERE r.dump_folder = v_fx_folder AND coalesce(r.stamp_page, r.page) = v_fx_page;
    IF v_max IS NULL OR v_max > 0.35 THEN RAISE EXCEPTION 'VERIFY 4b FAILED: bands sit %pp from the accepted ones', v_max; END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.page_block_extents e WHERE e.dump_folder = v_fx_folder AND e.effective_page = v_fx_page
                     AND abs(e.top_pct - v_fx_top) <= 0.35 AND abs(e.bottom_pct - v_fx_bot) <= 0.35) THEN
      RAISE EXCEPTION 'VERIFY 4c FAILED: extent';
    END IF;
    -- 4d. NO TEMPLATE VALUE: every band edge and both extents are a detected line on this scan
    IF EXISTS (SELECT 1 FROM derm.address_row_map r
                WHERE r.dump_folder = v_fx_folder AND coalesce(r.stamp_page, r.page) = v_fx_page
                  AND (NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) l WHERE (l->>'pct')::numeric = r.band_y0_pct)
                    OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) l WHERE (l->>'pct')::numeric = r.band_y1_pct)))
       OR NOT EXISTS (SELECT 1 FROM derm.page_block_extents e WHERE e.dump_folder = v_fx_folder AND e.effective_page = v_fx_page
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) l WHERE (l->>'pct')::numeric = e.top_pct)
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) l WHERE (l->>'pct')::numeric = e.bottom_pct)) THEN
      RAISE EXCEPTION 'VERIFY 4d FAILED: a written value is not a detected line';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_fx_folder AND completed AND completed_by = 'stamp-studio-ai') THEN
      RAISE EXCEPTION 'VERIFY 4e FAILED: not completed by the machine: %', v_j;
    END IF;
    IF (SELECT count(DISTINCT source) FROM derm.v_page_printed_rules WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page) <> 1
       OR NOT EXISTS (SELECT 1 FROM derm.v_page_printed_rules WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'template-v1-%') THEN
      RAISE EXCEPTION 'VERIFY 4f FAILED: the template scan is not the admitted source';
    END IF;
    IF EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder) THEN RAISE EXCEPTION 'VERIFY 4g FAILED: still in the backlog'; END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.generated_measure_attempts WHERE dump_folder = v_fx_folder AND page = v_fx_page AND last_outcome = 'measured' AND measured_at IS NOT NULL) THEN RAISE EXCEPTION 'VERIFY 4h FAILED: ledger'; END IF;
    IF derm.fn_sheet_publishable(v_fx_folder) IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 4i FAILED: not publishable after the measure'; END IF;
    -- the grader sees the page as any other: no band edge off a printed rule
    IF EXISTS (SELECT 1 FROM derm.v_band_edge_check WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND edge_verdict = 'OFF_RULE') THEN RAISE EXCEPTION 'VERIFY 4j FAILED: off-rule band'; END IF;

    -- 5. a second call is refused as no longer needed and changes nothing
    v_j := derm.fn_generated_page_measured(v_fx_folder, v_fx_page, v_url, v_lines, '{}'::jsonb);
    IF v_j->>'outcome' <> 'refused' OR v_j->>'reason' <> 'This page no longer needs measuring automatically.' THEN RAISE EXCEPTION 'VERIFY 5 FAILED: %', v_j; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- =========================== fixture B: the off switch measures but does not complete ===========================
  BEGIN
    UPDATE derm.stamp_sheet_status SET completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_fx_folder;
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL WHERE dump_folder = v_fx_folder;
    UPDATE derm.address_row_map SET band_y0_pct = NULL, band_y1_pct = NULL, band_source = NULL, band_set_at = NULL, band_set_by = NULL
     WHERE dump_folder = v_fx_folder AND coalesce(stamp_page, page) = v_fx_page;
    DELETE FROM derm.page_block_extents WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page;
    DELETE FROM derm.page_row_rules  WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'human-v1-%';
    DELETE FROM derm.page_rule_scans WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'human-v1-%';
    UPDATE public.app_config SET value = 'false' WHERE key = 'generated_sheet_auto_complete';
    v_j := derm.fn_generated_page_measured(v_fx_folder, v_fx_page, v_url, v_lines, '{}'::jsonb);
    IF v_j->>'outcome' <> 'measured' OR (v_j->'completion'->>'completed')::boolean
       OR v_j->'completion'->>'reason' <> 'Automatic completion is switched off.' THEN
      RAISE EXCEPTION 'VERIFY 6 FAILED: %', v_j;
    END IF;
    IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_fx_folder AND completed) THEN RAISE EXCEPTION 'VERIFY 6a FAILED: completed with the switch off'; END IF;
    -- geometry was still banked, so a person's Mark completed would work
    IF derm.fn_sheet_publishable(v_fx_folder) IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 6b FAILED: geometry not banked'; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- =========================== fixture C: the reopen pin and the under-carded client ===========================
  BEGIN
    UPDATE derm.stamp_sheet_status SET completed = false WHERE dump_folder = v_fx_folder;   -- pin sets reopened_at
    v_j := derm.fn_complete_generated_sheet(v_fx_folder);
    IF (v_j->>'completed')::boolean OR v_j->>'reason' NOT LIKE 'This sheet was reopened%' THEN RAISE EXCEPTION 'VERIFY 7 FAILED: %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder) THEN RAISE EXCEPTION 'VERIFY 7a FAILED: a reopened folder is in the measure backlog'; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;
  BEGIN
    -- ticket-833395: 242-WYN printed on 3 rows, 1 card (the known un-split folder)
    UPDATE derm.stamp_sheet_status SET completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = 'ticket-833395';
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL WHERE dump_folder = 'ticket-833395';
    v_j := derm.fn_complete_generated_sheet('ticket-833395');
    IF (v_j->>'completed')::boolean OR v_j->>'reason' NOT LIKE 'A client on this sheet%' OR v_j->>'reason' ~ v_tech THEN RAISE EXCEPTION 'VERIFY 8 FAILED: %', v_j; END IF;
    IF (SELECT blocker FROM derm.v_generated_complete_backlog WHERE dump_folder = 'ticket-833395') IS NULL THEN RAISE EXCEPTION 'VERIFY 8a FAILED: complete backlog shows no blocker'; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- =========================== fixture D: the budget and its re-arming ===========================
  BEGIN
    UPDATE derm.stamp_sheet_status SET completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_fx_folder;
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL WHERE dump_folder = v_fx_folder;
    DELETE FROM derm.page_block_extents WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page;
    DELETE FROM derm.page_rule_scans WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'human-v1-%';
    INSERT INTO derm.generated_measure_attempts (dump_folder, page, image_url, source_etag, attempts, last_outcome, last_attempt_at)
    VALUES (v_fx_folder, v_fx_page, v_url, derm._img_etag(v_url), 3, 'refused', now());
    IF EXISTS (SELECT 1 FROM derm.fn_generated_measure_targets(5) t WHERE t.dump_folder = v_fx_folder) THEN RAISE EXCEPTION 'VERIFY 9 FAILED: a page at 3 attempts was handed out'; END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder AND attempts_on_this_image = 3) THEN RAISE EXCEPTION 'VERIFY 9a FAILED: the backlog hides a budgeted page'; END IF;
    UPDATE derm.generated_measure_attempts SET source_etag = 'replaced' WHERE dump_folder = v_fx_folder AND page = v_fx_page;
    IF NOT EXISTS (SELECT 1 FROM derm.fn_generated_measure_targets(5) t WHERE t.dump_folder = v_fx_folder) THEN RAISE EXCEPTION 'VERIFY 9b FAILED: a replaced scan did not re-arm'; END IF;
    UPDATE derm.generated_measure_attempts SET source_etag = derm._img_etag(v_url), last_attempt_at = '2020-01-01' WHERE dump_folder = v_fx_folder AND page = v_fx_page;
    IF NOT EXISTS (SELECT 1 FROM derm.fn_generated_measure_targets(5) t WHERE t.dump_folder = v_fx_folder) THEN RAISE EXCEPTION 'VERIFY 9c FAILED: a card edited after the last attempt did not re-arm'; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- =========================== fixture E: "service_role is a machine" ===========================
  BEGIN
    PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
    PERFORM set_config('request.headers', '{"x-nothing":"1"}', true);
    IF derm._actor('stamp-studio') <> 'stamp-studio-ai' THEN RAISE EXCEPTION 'VERIFY 10 FAILED: service_role actor is %', derm._actor('stamp-studio'); END IF;
    PERFORM derm._require_stamp_key();   -- must not raise
    PERFORM set_config('request.jwt.claims', '{"role":"authenticated","email":"person@ayache.com"}', true);
    IF derm._actor('stamp-studio') <> 'person@ayache.com' THEN RAISE EXCEPTION 'VERIFY 10a FAILED: a person''s email did not win'; END IF;
    BEGIN
      PERFORM derm._require_stamp_key();
      RAISE EXCEPTION 'VERIFY 10b FAILED: an authenticated caller without the key was let through';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE 'VERIFY%' THEN RAISE; END IF;
    END;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.headers', '', true);
    IF derm._actor('stamp-studio') <> 'stamp-studio' THEN RAISE EXCEPTION 'VERIFY 10c FAILED: direct SQL default'; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);

  -- =========================== after the rollbacks ===========================
  IF NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_fx_folder AND completed)
     OR NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-833395' AND completed)
     OR EXISTS (SELECT 1 FROM derm.generated_measure_attempts)
     OR EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE source LIKE 'template-v1-%')
     OR (SELECT value FROM public.app_config WHERE key = 'generated_sheet_auto_complete') <> 'true' THEN
    RAISE EXCEPTION 'CLEANUP FAILED: a fixture survived its rollback';
  END IF;
  -- grants, SECDEF and search_path of the three patched helpers unchanged
  FOR v_r IN SELECT p.proname, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'derm' AND p.proname IN ('_actor', '_require_stamp_key', 'fn_sheet_publishable_detail')
  LOOP
    IF v_r.acl IS DISTINCT FROM (SELECT acl FROM _fin_before b WHERE b.proname = v_r.proname)
       OR v_r.prosecdef IS DISTINCT FROM (SELECT prosecdef FROM _fin_before b WHERE b.proname = v_r.proname)
       OR v_r.cfg IS DISTINCT FROM (SELECT cfg FROM _fin_before b WHERE b.proname = v_r.proname) THEN
      RAISE EXCEPTION 'VERIFY 11 FAILED: % acl/secdef/search_path moved', v_r.proname;
    END IF;
  END LOOP;
  IF has_function_privilege('authenticated', 'derm.fn_generated_page_measured(text, integer, text, jsonb, jsonb)', 'EXECUTE')
     OR has_table_privilege('authenticated', 'derm.generated_measure_attempts', 'SELECT')
     OR has_table_privilege('authenticated', 'derm.v_generated_measure_backlog', 'SELECT')
     OR NOT has_function_privilege('service_role', 'derm.fn_generated_page_measured(text, integer, text, jsonb, jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 12 FAILED: grants';
  END IF;
  -- the live backlog today: nothing to measure unless a generated sheet is open right now
  SELECT count(*) INTO v_n FROM derm.v_generated_measure_backlog;
  RAISE NOTICE 'ALL VERIFY PASSED: a real page measured from its own lines within 0.35pp of the accepted geometry and completed by the machine; a pad refused with nothing written; the off switch, the reopen pin, the under-carded gate, the budget and its re-arming, and the service_role arms all proven; live measure backlog % page(s).', v_n;
END
$verify$;

COMMIT;
