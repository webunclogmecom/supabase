-- 2026-07-20d — Stamp Studio: generated (#1000+) sheets now FLOW THROUGH the Studio
--
-- CONTEXT (Fred, answering the 20c design questions, 2026-07-20): "we can also update the
-- generated sheets too, just put the generated sheets, do the auto-place for them, mark them as
-- completed, but we can also later on, modify them manually like in case there is an error,
-- misplaced visit/client or wrong client added." + list treatment: "Show them, like if it was
-- done by us, but put like a special tag like 'AI'."
--
-- This REVERSES 20c's hard block (20c raised in set_stamp_position + auto_place_page for
-- generated sheets). New model:
--   * Generated sheets are AUTO-STAMPED at card-insert time from the pdf-service's exact
--     template geometry (deterministic, no vision needed), placed_by='stamp-studio-ai'.
--   * Their sheet is auto-marked COMPLETED (completed_by='stamp-studio-ai').
--   * Manual correction stays fully allowed (set/clear/auto-place all work on them now).
--   * The app shows them like normal sheets with an "AI" badge (no more default-hide).
--   * fn_blackout_targets STILL EXCLUDES generated sheets (unchanged from 20c): their
--     customer copy is the born-redacted per-client FOG PDF; stamps here are bookkeeping +
--     correction surface, NOT redaction inputs.
--
-- GEOMETRY SOURCE (authoritative): Building Apps/unclogme-pdf-service/pdf_service/generators/
-- derm_address.py — page 792x612 landscape letter, Section B = 5 rows/page (chunks of 5 →
-- extra pages), GDO/name value baselines y=[453.0,400.1,357.5,311.5,261.6]pt from BOTTOM
-- = [25.98,34.62,41.58,49.10,57.25]% from TOP (the Studio's stamp_y_pct axis); code-chip
-- cell spans x=24..80pt, center 54pt = 6.82% of width. Pitch is intentionally non-uniform
-- (per-row arrays in the generator). ⚠ If templates/derm_address.pdf or those baseline
-- arrays change in pdf-service, update derm.fn_generated_row_geometry to match.
--
-- Audit rule (ADR 010): no new tables; derm.address_row_map already carries audit_address_row_map
-- (AFTER ROW) — the new BEFORE INSERT trigger mutates NEW before audit logs the final row. Opt-in
-- unchanged.

BEGIN;

-- A. Deterministic geometry for a generated sheet's i-th card (1-based, link/creation order):
--    printed page = ceil(i/5); slot on page = ((i-1) mod 5)+1; y from the generator's
--    Section B GDO/name baselines (% from top); x = chip-cell center (% of width).
CREATE OR REPLACE FUNCTION derm.fn_generated_row_geometry(p_row_index integer)
RETURNS TABLE(o_page integer, o_x_pct numeric, o_y_pct numeric)
LANGUAGE sql IMMUTABLE AS $$
  SELECT ((p_row_index - 1) / 5) + 1,
         6.82::numeric,
         (ARRAY[25.98, 34.62, 41.58, 49.10, 57.25]::numeric[])[((p_row_index - 1) % 5) + 1]
$$;

-- B. set_stamp_position: DROP the generated-sheet refusal (manual correction is now allowed).
--    NULL/page/range hardening from 20c kept.
CREATE OR REPLACE FUNCTION derm.set_stamp_position(p_row_id bigint, p_page integer, p_x_pct numeric, p_y_pct numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_row_id IS NULL OR p_page IS NULL OR p_x_pct IS NULL OR p_y_pct IS NULL THEN
    RAISE EXCEPTION 'stamp arguments must not be null (row=%, page=%, x=%, y=%)', p_row_id, p_page, p_x_pct, p_y_pct;
  END IF;
  IF p_page < 1 THEN RAISE EXCEPTION 'stamp page must be >= 1 (got %)', p_page; END IF;
  IF p_x_pct < 0 OR p_x_pct > 100 OR p_y_pct < 0 OR p_y_pct > 100 THEN
    RAISE EXCEPTION 'stamp percent out of range (x=%, y=%)', p_x_pct, p_y_pct;
  END IF;
  UPDATE derm.address_row_map
     SET stamp_x_pct = round(p_x_pct, 3),
         stamp_y_pct = round(p_y_pct, 3),
         stamp_page  = p_page,
         stamp_placed_at = now(),
         stamp_placed_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
   WHERE id = p_row_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'address_row_map id % not found', p_row_id; END IF;
END $function$;

-- C. auto_place_page: DROP the generated refusal — it now works on generated sheets too
--    (the view's guess cascade serves the template geometry for them, see D).
CREATE OR REPLACE FUNCTION derm.auto_place_page(p_dump_folder text, p_page integer)
 RETURNS TABLE(placed integer, skipped integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_sheet text; v_placed integer := 0; v_skipped integer := 0;
BEGIN
  PERFORM derm._require_stamp_key();
  IF p_dump_folder IS NULL OR p_page IS NULL OR p_page < 1 THEN
    RAISE EXCEPTION 'auto-place: bad arguments (folder=%, page=%)', p_dump_folder, p_page;
  END IF;
  SELECT min(white_manifest_number) INTO v_sheet FROM derm.address_row_map WHERE dump_folder = p_dump_folder;
  IF v_sheet IS NULL THEN RAISE EXCEPTION 'auto-place: unknown sheet %', p_dump_folder; END IF;
  SELECT count(*) FILTER (WHERE g.guess_y_pct IS NULL) INTO v_skipped
    FROM derm.v_stamp_rows g
   WHERE g.dump_folder = p_dump_folder AND g.page = p_page AND NOT g.placed;
  UPDATE derm.address_row_map a
     SET stamp_x_pct = round(g.guess_x_pct, 3),
         stamp_y_pct = round(g.guess_y_pct, 3),
         stamp_page  = p_page,
         stamp_placed_at = now(),
         stamp_placed_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
    FROM derm.v_stamp_rows g
   WHERE g.id = a.id AND g.dump_folder = p_dump_folder AND g.page = p_page
     AND NOT g.placed AND g.guess_y_pct IS NOT NULL;
  GET DIAGNOSTICS v_placed = ROW_COUNT;
  RETURN QUERY SELECT v_placed, v_skipped;
END $function$;

-- D. v_stamp_rows: generated branch in the guess cascade (after manual bands, before extents)
--    + guess_x per class + guess_confidence gains the 'generated' value (deterministic — the
--    app's low-confidence review banner does NOT fire for it).
CREATE OR REPLACE VIEW derm.v_stamp_rows AS
 SELECT r.id,
    r.dump_folder,
    r.white_manifest_number,
    r.page,
    r.row_index,
    r.image_url,
    r.facility_name_read,
    r.address_read,
    COALESCE(c.client_code, r.manual_code) AS client_code,
    COALESCE(c.name, r.manual_code) AS client_name,
    ( SELECT min(m.service_date) AS min
           FROM derm_manifests m
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = r.white_manifest_number AND m.deleted_at IS NULL) AS service_date,
    r.assignment_status,
    r.confidence,
    r.stamp_x_pct,
    r.stamp_y_pct,
    r.stamp_page,
    CASE WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN 6.82 ELSE 8.0 END AS guess_x_pct,
    round(
        CASE
            WHEN r.band_y0_pct IS NOT NULL AND r.band_y1_pct IS NOT NULL THEN (r.band_y0_pct + r.band_y1_pct) / 2::numeric
            WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN (ARRAY[25.98, 34.62, 41.58, 49.10, 57.25]::numeric[])[((r.row_index - 1) % 5) + 1]
            WHEN ext.top_pct IS NOT NULL THEN LEAST(ext.top_pct + (r.row_index::numeric - 0.5) * LEAST((ext.bottom_pct - ext.top_pct) / NULLIF(r.mx, 0)::numeric, 6.0), ext.bottom_pct)
            ELSE LEAST(28::numeric + (r.row_index::numeric - 0.5) * 5.2, 62::numeric)
        END, 3) AS guess_y_pct,
    r.stamp_placed_at IS NOT NULL AS placed,
    r.source = 'stamp-studio'::text AS is_manual,
    r.matched_client_id,
    r.matched_manifest_id,
    r.band_y0_pct,
    r.band_y1_pct,
    r.band_source,
    r.reviewed_at IS NOT NULL AS reviewed,
    r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM manifest_visits mv
          WHERE mv.manifest_id = r.matched_manifest_id)) AS visit_linked,
    ( SELECT count(*) AS count
           FROM manifest_visits mv
          WHERE mv.manifest_id = r.matched_manifest_id) AS linked_visit_count,
        CASE
            WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN 'generated'::text
            WHEN r.source = ANY (ARRAY['derm-link'::text, 'linked-backfill'::text]) THEN 'low'::text
            ELSE 'ok'::text
        END AS guess_confidence,
    derm.fn_sheet_is_generated(r.white_manifest_number) AS is_generated
   FROM ( SELECT a.id,
            a.dump_folder,
            a.white_manifest_number,
            a.page,
            a.row_index,
            a.image_url,
            a.facility_name_read,
            a.address_read,
            a.matched_client_id,
            a.assignment_status,
            a.confidence,
            a.agent_agreement,
            a.flags,
            a.source,
            a.reviewed_by,
            a.reviewed_at,
            a.created_at,
            a.updated_at,
            a.stamp_x_pct,
            a.stamp_y_pct,
            a.stamp_page,
            a.stamp_placed_at,
            a.stamp_placed_by,
            a.manual_code,
            a.matched_manifest_id,
            a.band_y0_pct,
            a.band_y1_pct,
            a.band_source,
            a.band_set_at,
            a.band_set_by,
            max(a.row_index) OVER (PARTITION BY a.dump_folder, a.page) AS mx
           FROM derm.address_row_map a) r
     LEFT JOIN clients c ON c.id = r.matched_client_id
     LEFT JOIN derm.page_block_extents ext ON ext.dump_folder = r.dump_folder AND ext.effective_page = COALESCE(r.stamp_page, r.page)
  WHERE r.white_manifest_number IS NOT NULL AND (r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL OR r.manual_code IS NOT NULL) AND (r.stamp_placed_at IS NOT NULL OR r.manual_code IS NOT NULL OR r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM derm_manifests m
          WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)));

-- E. AUTO-STAMP AT BIRTH: BEFORE INSERT trigger — a card landing on a generated sheet is
--    stamped immediately from the template geometry, and its page is corrected to the printed
--    page (cards for rows 6+ belong to page 2, etc.). placed_by='stamp-studio-ai' is the
--    provenance marker the app renders as the "AI" tag.
CREATE OR REPLACE FUNCTION derm.trg_autoplace_generated()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE geo record;
BEGIN
  IF NEW.white_manifest_number IS NOT NULL
     AND NEW.stamp_placed_at IS NULL
     AND derm.fn_sheet_is_generated(NEW.white_manifest_number) THEN
    SELECT * INTO geo FROM derm.fn_generated_row_geometry(NEW.row_index);
    NEW.page            := geo.o_page;
    NEW.stamp_page      := geo.o_page;
    NEW.stamp_x_pct     := round(geo.o_x_pct, 3);
    NEW.stamp_y_pct     := round(geo.o_y_pct, 3);
    NEW.stamp_placed_at := now();
    NEW.stamp_placed_by := 'stamp-studio-ai';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_ab_autoplace_generated ON derm.address_row_map;
CREATE TRIGGER trg_ab_autoplace_generated
  BEFORE INSERT ON derm.address_row_map
  FOR EACH ROW EXECUTE FUNCTION derm.trg_autoplace_generated();

-- F. AUTO-COMPLETE: the sheet is marked completed the moment its first AI-stamped card lands
--    (idempotent upsert; later cards keep it completed; office can un-complete manually).
CREATE OR REPLACE FUNCTION derm.trg_generated_sheet_complete()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  VALUES (NEW.dump_folder, true, now(), 'stamp-studio-ai', now())
  ON CONFLICT (dump_folder) DO UPDATE
    SET completed = true,
        completed_at = COALESCE(derm.stamp_sheet_status.completed_at, now()),
        completed_by = COALESCE(derm.stamp_sheet_status.completed_by, 'stamp-studio-ai'),
        updated_at = now()
    WHERE NOT derm.stamp_sheet_status.completed;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_zy_generated_sheet_complete ON derm.address_row_map;
CREATE TRIGGER trg_zy_generated_sheet_complete
  AFTER INSERT ON derm.address_row_map
  FOR EACH ROW
  WHEN (NEW.stamp_placed_by = 'stamp-studio-ai')
  EXECUTE FUNCTION derm.trg_generated_sheet_complete();

COMMIT;

-- fn_blackout_targets: UNCHANGED — still excludes generated sheets (their FP copy is the
-- born-redacted per-client FOG PDF; these stamps are bookkeeping, not redaction inputs).

-- ============================================================================
-- POST-DEPLOY VALIDATION + SMOKE (2026-07-20, Prod, all synthetics torn down to exact baseline):
--   * fn_generated_row_geometry: rows 1/5/6/7 -> (p1,25.98) (p1,57.25) (p2,25.98) (p2,34.62). OK.
--   * SMOKE D (synthetic generated #1002 + 7 cards inserted page=1): ALL auto-stamped at birth
--     by trg_ab_autoplace_generated (x=6.820, exact template y, placed_by='stamp-studio-ai'),
--     pages CORRECTED to printed pages (rows 6-7 -> page 2); sheet auto-completed by
--     'stamp-studio-ai'; manual set_stamp_position WORKS (12.5/44.0 persisted, placed_by flips);
--     clear + auto_place_page re-placed at template y with guess_confidence='generated';
--     county-style '999888' insert NOT touched (no auto-stamp, no auto-complete);
--     fn_blackout_targets still 0 (exclusion held); teardown left manifests/rows/seq/status
--     counts EXACTLY at baseline (553/555/1025/104), no ghost view rows.
--   * EXTENT/BAND-BRANCH regression (Fred: "let's do tests"): on measured sheet backfill-829201
--     p1, cleared 2 placed rows -> auto_place_page placed both at the view guesses, deltas vs the
--     ORIGINAL hand placements 0.09 and 0.51 pts (band-midpoint branch); restored byte-identical.
--   * App published (bundle index-BrxnQIQ7): 'Show generated' toggle GONE, 'stamping does not
--     apply' GONE, violet AI chip (tooltip 'Generated sheet, auto-stamped') in list + stamp view,
--     auto_place_page + per-page label + low-confidence banner intact.
-- ============================================================================
