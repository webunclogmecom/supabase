-- ============================================================================================
-- 2026-09-13_1300_auto_place_page_generated_resolves_own_page.sql
--
-- derm.auto_place_page: on a GENERATED sheet, place each card on the image its PRINTED PAGE maps
-- to, never on the tab the operator happens to be looking at.
--
-- WHY (Fred, 2026-09-13, after "why is 835076 AI-stamped on page 1 only?"): "yes build it".
--
-- ============================================================================================
-- THE DEFECT, IN TWO LINES.
--
--   derm.v_stamp_rows.guess_y_pct  = fn_generated_row_geometry(fn_generated_sheet_slot(m)).o_y_pct
--                                    ^ takes o_y_pct, DISCARDS o_page
--   derm.auto_place_page           ... SET stamp_page = p_page ...
--                                    ^ writes the TAB as the target image
--
-- So a generated-sheet card printed on page 2 whose stamp_page is still NULL sits in the page-1
-- roster (COALESCE(stamp_page, page) = 1, since page is the OCR page and reads 1 for every card
-- of a single-sheet filing), and Auto-place on the page-1 tab stamps it on image 1 at page 2's row
-- geometry. Measured on ticket-835076 in a rolled-back probe, and re-measured as PART 1 of this
-- file with the pre-fix body kept as the control:
--
--     auto_place_page('ticket-835076', 1)  ->  placed 5: 049-PV, 083-SHUL, 082-TFC, 033-LG, 142-57
--         ALL on image 1 at y 29.800 / 37.720 / 44.480 / 51.810 / 60.040, which are EXACTLY the
--         stamps of 149-RUS, 014-JOY, 032-LG, 035-LG, 040-MV. Ten stamps on a five-row scan.
--
-- The state that arms it is ordinary: a generated sheet whose page-N sheet-number read lands after
-- the filing's insert-time placement. The margin was 0.75 s on 835076 and 9 minutes on 834742.
-- The insert trigger (derm.trg_autoplace_generated) handles that correctly, by refusing; the
-- button did not, because it never resolved the card's page at all.
--
-- ============================================================================================
-- THE FIX. One new branch, the handwritten half BYTE-IDENTICAL.
--
-- When derm.fn_sheet_is_generated(sheet), the function now evaluates, per unplaced card, exactly
-- the chain the insert trigger evaluates:
--     fn_generated_sheet_slot(manifest) -> fn_generated_row_geometry(slot).{o_page, o_x, o_y}
--       -> fn_sheet_image_position(folder, o_page)      NULL = image unknown = SKIP
--       -> fn_row_read_confirms(folder, image, row, code) FALSE = paper disagrees = SKIP
-- and writes stamp_page = that image position. p_page is deliberately NOT a filter on this
-- branch: the cards belong where the paper says, and it is the tab-based roster that put page-2
-- cards under the page-1 button in the first place. The return still reports (placed, skipped)
-- for the FOLDER, so the operator sees what happened.
--
-- ⚠ A client holding MORE THAN ONE card on the folder is skipped by this branch.
-- fn_generated_sheet_slot resolves the client's FIRST printed row, so placing both of a
-- two-permit client's cards here would stack the second permit on the first one's row, the trap
-- CLAUDE.md documents for the insert trigger ("letting it run stacks the second and third permits
-- on top of the first one's row"). Those cards are placed by derm.assign_card_to_slot or by
-- dragging. Today (2026-09-13) the old body would ALSO have stacked them (guess_y_pct is the
-- same first-row value for both), so this is a narrowing from wrong to refused, not a regression.
--
-- Handwritten sheets have no printed order, so the tab is the only information there; that
-- branch is the previous body, unchanged, and VERIFY 6 proves old and new produce identical
-- output on a handwritten fixture.
--
-- 🛑 KNOWN AND DELIBERATELY UNTOUCHED: stamp_placed_by still reads the SINGULAR
-- request.jwt.claim.email, which PostgREST never sets, so it always records 'stamp-studio'
-- (the defect CLAUDE.md documents for audit.logs.changed_by and fixed for three other writers in
-- derm._actor). The expression is copied verbatim into the new branch so both branches label the
-- same way; changing it is a separate, one-line, behaviour-changing edit and is out of scope here.
--
-- BODY PROVENANCE: pg_get_functiondef of the live function, the new branch inserted at one
-- anchor (asserted to match exactly once), the remainder asserted byte-identical at assembly
-- time. Never retyped. CREATE OR REPLACE keeps the ACL; VERIFY 7 reads proacl before and after
-- rather than trusting that.
--
-- RULE 8: no schema change. address_row_map is audit-triggered, so every placement the new
-- branch makes is captured like any other.
-- ============================================================================================

BEGIN;

CREATE TEMP TABLE _apf_before ON COMMIT DROP AS
  SELECT p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg, pg_get_functiondef(p.oid) AS def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'derm' AND p.proname = 'auto_place_page';

CREATE TEMP TABLE _cards_before ON COMMIT DROP AS
  SELECT id, dump_folder, page, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, stamp_placed_by,
         stamp_image_url, image_url, gdo_id, band_y0_pct, band_y1_pct, matched_client_id
    FROM derm.address_row_map;

-- ============================================================================================
-- PART 0. PRECONDITIONS.
-- ============================================================================================
DO $pre$
DECLARE v_n int;
BEGIN
  -- The fixture folder is fully placed, five per image, by the AI, exactly as 2026-09-13_1200 left it.
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-835076'
     AND stamp_placed_at IS NOT NULL AND stamp_placed_by = 'stamp-studio-ai';
  IF v_n <> 10 THEN RAISE EXCEPTION 'PRE 0.1: ticket-835076 holds % AI-placed cards, expected 10', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-835076' AND stamp_page = 2;
  IF v_n <> 5 THEN RAISE EXCEPTION 'PRE 0.2: % cards on image 2, expected 5', v_n; END IF;
  IF NOT derm.fn_sheet_is_generated('835076') THEN RAISE EXCEPTION 'PRE 0.3: 835076 is not a generated sheet'; END IF;
  IF derm.fn_sheet_image_position('ticket-835076', 2) IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'PRE 0.4: image position of page 2 is not 2';
  END IF;

  -- The handwritten control folder exists and is placed.
  SELECT count(*) INTO v_n FROM derm.v_stamp_rows
   WHERE dump_folder = 'window3-sheet5' AND NOT is_generated AND placed AND guess_y_pct IS NOT NULL
     AND COALESCE(stamp_page, page) = 1;
  IF v_n < 2 THEN RAISE EXCEPTION 'PRE 0.5: window3-sheet5 has only % usable page-1 cards', v_n; END IF;

  -- The exact live body this file was written against.
  IF (SELECT count(*) FROM _apf_before) <> 1 THEN RAISE EXCEPTION 'PRE 0.6: auto_place_page not found'; END IF;
  IF (SELECT def FROM _apf_before) NOT LIKE '%stamp_page  = p_page,%' THEN
    RAISE EXCEPTION 'PRE 0.7: the live body no longer writes stamp_page = p_page; re-derive this file';
  END IF;
  IF (SELECT def FROM _apf_before) LIKE '%fn_sheet_is_generated(v_sheet)%' THEN
    RAISE EXCEPTION 'PRE 0.7: the live body already carries a generated branch';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'derm' AND p.proname = '_auto_place_page_pre_20260913') THEN
    RAISE EXCEPTION 'PRE 0.8: the control function already exists; a previous run did not clean up';
  END IF;
  RAISE NOTICE 'PRE OK';
END
$pre$;

-- ============================================================================================
-- PART 1. THE OLD BODY, KEPT UNDER A TEMP NAME AS THE CONTROL. Dropped in VERIFY 8.
-- ============================================================================================
CREATE FUNCTION derm._auto_place_page_pre_20260913(p_dump_folder text, p_page integer)
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
  -- 🛑 2026-09-03: the roster keys on the EFFECTIVE page, COALESCE(stamp_page, page), not on
  -- raw `page`. On a folder scanned as one sheet, derm._materialize_card writes page = 1 for every
  -- card, so `page` is a constant and cannot say which scan a card belongs on: 23 of 138 folders
  -- (193 cards) are in that state. Rostering on it offered a page-2 card from the PAGE-1 tab and
  -- re-filed it against page 1's scan. Paired with clear_stamp_position keeping stamp_page, this
  -- reads the operator's page intent instead.
  SELECT count(*) FILTER (WHERE g.guess_y_pct IS NULL) INTO v_skipped
    FROM derm.v_stamp_rows g
   WHERE g.dump_folder = p_dump_folder AND COALESCE(g.stamp_page, g.page) = p_page AND NOT g.placed;
  UPDATE derm.address_row_map a
     SET stamp_x_pct = round(g.guess_x_pct, 3),
         stamp_y_pct = round(g.guess_y_pct, 3),
         stamp_page  = p_page,
         stamp_placed_at = now(),
         stamp_placed_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
    FROM derm.v_stamp_rows g
   WHERE g.id = a.id AND g.dump_folder = p_dump_folder AND COALESCE(g.stamp_page, g.page) = p_page
     AND NOT g.placed AND g.guess_y_pct IS NOT NULL;
  GET DIAGNOSTICS v_placed = ROW_COUNT;
  RETURN QUERY SELECT v_placed, v_skipped;
END $function$;

DO $ctl$
DECLARE v_n int; v_old text; v_live text;
BEGIN
  -- It must be the live body, name apart, or the control proves nothing.
  SELECT replace(pg_get_functiondef(p.oid), 'derm._auto_place_page_pre_20260913(', 'derm.auto_place_page(')
    INTO v_old FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'derm' AND p.proname = '_auto_place_page_pre_20260913';
  SELECT def INTO v_live FROM _apf_before;
  IF v_old IS DISTINCT FROM v_live THEN
    RAISE EXCEPTION 'CONTROL SETUP FAILED: the preserved body differs from the live body';
  END IF;

  -- The defect, reproduced with the OLD body on the fixture, then rolled back.
  BEGIN
    UPDATE derm.address_row_map
       SET stamp_page = NULL, stamp_x_pct = NULL, stamp_y_pct = NULL, stamp_placed_at = NULL,
           stamp_placed_by = NULL, stamp_image_url = NULL
     WHERE dump_folder = 'ticket-835076' AND stamp_page = 2;
    PERFORM derm._auto_place_page_pre_20260913('ticket-835076', 1);
    SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-835076' AND stamp_page = 1;
    IF v_n <> 10 THEN
      RAISE EXCEPTION 'CONTROL FAILED: the old body put % stamps on image 1, expected 10 (five stacked)', v_n;
    END IF;
    SELECT count(*) INTO v_n
      FROM derm.address_row_map a JOIN derm.address_row_map b
        ON b.dump_folder = a.dump_folder AND b.stamp_page = a.stamp_page AND b.id < a.id
       AND abs(a.stamp_y_pct - b.stamp_y_pct) < 0.001
     WHERE a.dump_folder = 'ticket-835076';
    IF v_n <> 5 THEN
      RAISE EXCEPTION 'CONTROL FAILED: expected 5 exactly-stacked stamp pairs, found %', v_n;
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CONTROL';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CONTROL' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'CONTROL OK: the old body stacks the five page-2 clients onto image 1.';
END
$ctl$;

-- ============================================================================================
-- PART 2. THE CHANGE.
-- ============================================================================================
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
  -- 🛑 2026-09-13: a GENERATED sheet knows its own layout, so the TAB is not the target image.
  -- Until this branch existed, every generated-sheet card was stamped at stamp_page = p_page:
  -- derm.v_stamp_rows.guess_y_pct takes o_y_pct from derm.fn_generated_row_geometry and DISCARDS
  -- o_page, and the UPDATE below wrote the tab. Measured on ticket-835076 (rolled back): pressing
  -- Auto-place on the page-1 tab placed the five page-2 clients on image 1 at exactly the five
  -- page-1 clients' y values. Ten stamps on a scan that prints five.
  -- This branch is derm.trg_autoplace_generated's own resolution chain, evaluated per card:
  --   slot -> geometry -> fn_sheet_image_position(o_page) -> fn_row_read_confirms
  -- and it places the card on THAT image, whatever tab the operator is on. A card whose image
  -- position is still unknown (the page-N read has not landed) or whose row read names a
  -- different client is left alone and counted as skipped, never guessed.
  -- ⚠ A client holding MORE THAN ONE card on the folder is also skipped: fn_generated_sheet_slot
  -- resolves the client's FIRST printed row, so placing both here would stack the second permit on
  -- the first one's row (the trap documented for the insert trigger). Those cards are placed by
  -- derm.assign_card_to_slot or by dragging, never by this button.
  -- p_page is deliberately NOT a filter here: the cards belong where the paper says, and rostering
  -- on COALESCE(stamp_page, page) is what listed page-2 cards under the page-1 tab in the first place.
  -- (The resolution runs in a subquery because an UPDATE's LATERAL may not reference its target.)
  IF derm.fn_sheet_is_generated(v_sheet) THEN
    UPDATE derm.address_row_map a
       SET stamp_x_pct = round(t.o_x_pct, 3),
           stamp_y_pct = round(t.o_y_pct, 3),
           stamp_page  = t.img,
           stamp_placed_at = now(),
           stamp_placed_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
      FROM (
        SELECT r.id, geo.o_x_pct, geo.o_y_pct,
               derm.fn_sheet_image_position(r.dump_folder, geo.o_page) AS img
          FROM derm.address_row_map r
          JOIN public.clients c ON c.id = r.matched_client_id
          CROSS JOIN LATERAL derm.fn_generated_row_geometry(derm.fn_generated_sheet_slot(r.matched_manifest_id)) geo
         WHERE r.dump_folder = p_dump_folder
           AND r.stamp_placed_at IS NULL
           AND geo.o_y_pct IS NOT NULL
           AND derm.fn_sheet_image_position(r.dump_folder, geo.o_page) IS NOT NULL
           AND derm.fn_row_read_confirms(r.dump_folder,
                                         derm.fn_sheet_image_position(r.dump_folder, geo.o_page),
                                         ((derm.fn_generated_sheet_slot(r.matched_manifest_id) - 1) % 5) + 1,
                                         c.client_code) IS NOT FALSE
           AND (SELECT count(*) FROM derm.address_row_map s
                 WHERE s.dump_folder = r.dump_folder AND s.matched_client_id = r.matched_client_id) = 1
      ) t
     WHERE a.id = t.id;
    GET DIAGNOSTICS v_placed = ROW_COUNT;
    SELECT count(*) INTO v_skipped FROM derm.address_row_map s
     WHERE s.dump_folder = p_dump_folder AND s.stamp_placed_at IS NULL;
    RETURN QUERY SELECT v_placed, v_skipped;
    RETURN;
  END IF;
  -- 🛑 2026-09-03: the roster keys on the EFFECTIVE page, COALESCE(stamp_page, page), not on
  -- raw `page`. On a folder scanned as one sheet, derm._materialize_card writes page = 1 for every
  -- card, so `page` is a constant and cannot say which scan a card belongs on: 23 of 138 folders
  -- (193 cards) are in that state. Rostering on it offered a page-2 card from the PAGE-1 tab and
  -- re-filed it against page 1's scan. Paired with clear_stamp_position keeping stamp_page, this
  -- reads the operator's page intent instead.
  SELECT count(*) FILTER (WHERE g.guess_y_pct IS NULL) INTO v_skipped
    FROM derm.v_stamp_rows g
   WHERE g.dump_folder = p_dump_folder AND COALESCE(g.stamp_page, g.page) = p_page AND NOT g.placed;
  UPDATE derm.address_row_map a
     SET stamp_x_pct = round(g.guess_x_pct, 3),
         stamp_y_pct = round(g.guess_y_pct, 3),
         stamp_page  = p_page,
         stamp_placed_at = now(),
         stamp_placed_by = coalesce(nullif(current_setting('request.jwt.claim.email', true), ''), 'stamp-studio')
    FROM derm.v_stamp_rows g
   WHERE g.id = a.id AND g.dump_folder = p_dump_folder AND COALESCE(g.stamp_page, g.page) = p_page
     AND NOT g.placed AND g.guess_y_pct IS NOT NULL;
  GET DIAGNOSTICS v_placed = ROW_COUNT;
  RETURN QUERY SELECT v_placed, v_skipped;
END $function$;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_n int; v_s text; v_r record; v_old_out text; v_new_out text; v_client bigint;
BEGIN
  ------------------------------------------------------------------------------------------
  -- 1. THE FIX, ON THE SAME FIXTURE, FROM THE PAGE-1 TAB: five placed ON IMAGE 2, in printed
  --    order, witnessed by the page-2 scan, page-1 cards untouched, nothing stacked.
  ------------------------------------------------------------------------------------------
  BEGIN
    UPDATE derm.address_row_map
       SET stamp_page = NULL, stamp_x_pct = NULL, stamp_y_pct = NULL, stamp_placed_at = NULL,
           stamp_placed_by = NULL, stamp_image_url = NULL
     WHERE dump_folder = 'ticket-835076' AND stamp_page = 2;
    SELECT * INTO v_r FROM derm.auto_place_page('ticket-835076', 1);
    IF v_r.placed <> 5 OR v_r.skipped <> 0 THEN
      RAISE EXCEPTION 'VERIFY 1 FAILED: from the page-1 tab placed=% skipped=%, expected 5/0', v_r.placed, v_r.skipped;
    END IF;
    SELECT string_agg(c.client_code || '@' || r.stamp_y_pct::text, ' ' ORDER BY r.stamp_y_pct) INTO v_s
      FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
     WHERE r.dump_folder = 'ticket-835076' AND r.stamp_page = 2 AND r.stamp_image_url LIKE '%address_2.jpg'
       AND r.stamp_placed_by = 'stamp-studio';
    IF v_s IS DISTINCT FROM '049-PV@29.800 083-SHUL@37.720 082-TFC@44.480 033-LG@51.810 142-57@60.040' THEN
      RAISE EXCEPTION 'VERIFY 1 FAILED: image 2 reads "%"', COALESCE(v_s, '<nothing>');
    END IF;
    SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-835076' AND stamp_page = 1;
    IF v_n <> 5 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: image 1 now carries % stamps, expected 5', v_n; END IF;
    SELECT count(*) INTO v_n
      FROM derm.address_row_map a JOIN derm.address_row_map b
        ON b.dump_folder = a.dump_folder AND b.stamp_page = a.stamp_page AND b.id < a.id
       AND abs(a.stamp_y_pct - b.stamp_y_pct) < 1.0
     WHERE a.dump_folder = 'ticket-835076';
    IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % stacked pair(s)', v_n; END IF;
    -- the row-on-page formula used in the branch equals the canonical column, for every fixture card
    SELECT count(*) INTO v_n
      FROM derm.address_row_map r
      JOIN derm.address_sheet_manifests l ON l.manifest_id = r.matched_manifest_id
      JOIN derm.v_sheet_printed_rows pr ON pr.sheet_id = l.sheet_id AND pr.slot = l.slot AND pr.is_first_row
     WHERE r.dump_folder = 'ticket-835076'
       AND ((derm.fn_generated_sheet_slot(r.matched_manifest_id) - 1) % 5) + 1 <> pr.row_on_page;
    IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: the modulo row differs from v_sheet_printed_rows.row_on_page on % card(s)', v_n; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  ------------------------------------------------------------------------------------------
  -- 2. p_page IS NOT A FILTER ON A GENERATED SHEET: the page-2 tab gives the identical result.
  ------------------------------------------------------------------------------------------
  BEGIN
    UPDATE derm.address_row_map
       SET stamp_page = NULL, stamp_x_pct = NULL, stamp_y_pct = NULL, stamp_placed_at = NULL,
           stamp_placed_by = NULL, stamp_image_url = NULL
     WHERE dump_folder = 'ticket-835076' AND stamp_page = 2;
    SELECT * INTO v_r FROM derm.auto_place_page('ticket-835076', 2);
    IF v_r.placed <> 5 OR v_r.skipped <> 0 THEN
      RAISE EXCEPTION 'VERIFY 2 FAILED: from the page-2 tab placed=% skipped=%, expected 5/0', v_r.placed, v_r.skipped;
    END IF;
    SELECT count(*) INTO v_n FROM derm.address_row_map
     WHERE dump_folder = 'ticket-835076' AND stamp_page = 2 AND stamp_image_url LIKE '%address_2.jpg';
    IF v_n <> 5 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % on image 2, expected 5', v_n; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  ------------------------------------------------------------------------------------------
  -- 3. IMAGE UNKNOWN = SKIP, NEVER GUESS. Remove the page-2 read: the five must stay unplaced.
  --    This is the 835076 state at 15:58:33, reproduced.
  ------------------------------------------------------------------------------------------
  BEGIN
    UPDATE derm.address_row_map
       SET stamp_page = NULL, stamp_x_pct = NULL, stamp_y_pct = NULL, stamp_placed_at = NULL,
           stamp_placed_by = NULL, stamp_image_url = NULL
     WHERE dump_folder = 'ticket-835076' AND stamp_page = 2;
    DELETE FROM derm.address_sheet_scan_reads WHERE dump_folder = 'ticket-835076' AND page = 2;
    IF derm.fn_sheet_image_position('ticket-835076', 2) IS NOT NULL THEN
      RAISE EXCEPTION 'VERIFY 3 SETUP FAILED: image position of page 2 still resolves without its read';
    END IF;
    SELECT * INTO v_r FROM derm.auto_place_page('ticket-835076', 1);
    IF v_r.placed <> 0 OR v_r.skipped <> 5 THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: with no page-2 read placed=% skipped=%, expected 0/5', v_r.placed, v_r.skipped;
    END IF;
    SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-835076' AND stamp_page = 1;
    IF v_n <> 5 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: image 1 carries % stamps, expected 5 untouched', v_n; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  ------------------------------------------------------------------------------------------
  -- 4. THE PAPER DISAGREES = SKIP THAT CARD. Corrupt one row read: that client is left alone,
  --    the other four are placed.
  ------------------------------------------------------------------------------------------
  BEGIN
    UPDATE derm.address_row_map
       SET stamp_page = NULL, stamp_x_pct = NULL, stamp_y_pct = NULL, stamp_placed_at = NULL,
           stamp_placed_by = NULL, stamp_image_url = NULL
     WHERE dump_folder = 'ticket-835076' AND stamp_page = 2;
    UPDATE derm.address_sheet_row_reads SET client_code_read = '999-ZZZ'
     WHERE dump_folder = 'ticket-835076' AND page = 2 AND row_index = 1;
    SELECT * INTO v_r FROM derm.auto_place_page('ticket-835076', 1);
    IF v_r.placed <> 4 OR v_r.skipped <> 1 THEN
      RAISE EXCEPTION 'VERIFY 4 FAILED: with row 1 misread placed=% skipped=%, expected 4/1', v_r.placed, v_r.skipped;
    END IF;
    SELECT string_agg(c.client_code, ',') INTO v_s
      FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
     WHERE r.dump_folder = 'ticket-835076' AND r.stamp_placed_at IS NULL;
    IF v_s IS DISTINCT FROM '049-PV' THEN
      RAISE EXCEPTION 'VERIFY 4 FAILED: the unplaced card is "%", expected 049-PV (row 1)', v_s;
    END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  ------------------------------------------------------------------------------------------
  -- 5. A MULTI-CARD CLIENT IS SKIPPED, NOT STACKED. Give 049-PV a second card on the folder
  --    (by re-pointing 083-SHUL's card at it): both must be skipped, the other three placed.
  ------------------------------------------------------------------------------------------
  BEGIN
    UPDATE derm.address_row_map
       SET stamp_page = NULL, stamp_x_pct = NULL, stamp_y_pct = NULL, stamp_placed_at = NULL,
           stamp_placed_by = NULL, stamp_image_url = NULL
     WHERE dump_folder = 'ticket-835076' AND stamp_page = 2;
    SELECT id INTO v_client FROM public.clients WHERE client_code = '049-PV';
    UPDATE derm.address_row_map r SET matched_client_id = v_client
     WHERE r.dump_folder = 'ticket-835076'
       AND r.matched_client_id = (SELECT id FROM public.clients WHERE client_code = '083-SHUL');
    SELECT * INTO v_r FROM derm.auto_place_page('ticket-835076', 1);
    IF v_r.placed <> 3 OR v_r.skipped <> 2 THEN
      RAISE EXCEPTION 'VERIFY 5 FAILED: with a two-card client placed=% skipped=%, expected 3/2', v_r.placed, v_r.skipped;
    END IF;
    SELECT count(*) INTO v_n FROM derm.address_row_map
     WHERE dump_folder = 'ticket-835076' AND matched_client_id = v_client AND stamp_placed_at IS NOT NULL;
    IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: % of the two-card client cards were placed', v_n; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  ------------------------------------------------------------------------------------------
  -- 6. THE HANDWRITTEN BRANCH IS UNCHANGED: old and new bodies produce identical output on the
  --    same handwritten fixture (two page-1 cards of window3-sheet5 cleared).
  ------------------------------------------------------------------------------------------
  BEGIN
    UPDATE derm.address_row_map
       SET stamp_page = NULL, stamp_x_pct = NULL, stamp_y_pct = NULL, stamp_placed_at = NULL,
           stamp_placed_by = NULL, stamp_image_url = NULL,
           band_y0_pct = NULL, band_y1_pct = NULL   -- a band on an unstamped row is refused by address_row_map_band_needs_stamp_chk
     WHERE id IN (SELECT id FROM derm.v_stamp_rows WHERE dump_folder = 'window3-sheet5'
                   AND COALESCE(stamp_page, page) = 1 AND placed AND guess_y_pct IS NOT NULL
                  ORDER BY id LIMIT 2);
    SELECT * INTO v_r FROM derm._auto_place_page_pre_20260913('window3-sheet5', 1);
    SELECT format('%s/%s|', v_r.placed, v_r.skipped) ||
           string_agg(format('%s:%s,%s,%s,%s', id, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_by), ';' ORDER BY id)
      INTO v_old_out FROM derm.address_row_map WHERE dump_folder = 'window3-sheet5';
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;
  BEGIN
    UPDATE derm.address_row_map
       SET stamp_page = NULL, stamp_x_pct = NULL, stamp_y_pct = NULL, stamp_placed_at = NULL,
           stamp_placed_by = NULL, stamp_image_url = NULL,
           band_y0_pct = NULL, band_y1_pct = NULL   -- a band on an unstamped row is refused by address_row_map_band_needs_stamp_chk
     WHERE id IN (SELECT id FROM derm.v_stamp_rows WHERE dump_folder = 'window3-sheet5'
                   AND COALESCE(stamp_page, page) = 1 AND placed AND guess_y_pct IS NOT NULL
                  ORDER BY id LIMIT 2);
    SELECT * INTO v_r FROM derm.auto_place_page('window3-sheet5', 1);
    SELECT format('%s/%s|', v_r.placed, v_r.skipped) ||
           string_agg(format('%s:%s,%s,%s,%s', id, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_by), ';' ORDER BY id)
      INTO v_new_out FROM derm.address_row_map WHERE dump_folder = 'window3-sheet5';
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;
  IF v_old_out IS DISTINCT FROM v_new_out THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: handwritten output differs. old=% new=%', v_old_out, v_new_out;
  END IF;
  IF v_old_out NOT LIKE '2/%' THEN
    RAISE EXCEPTION 'VERIFY 6 CONTROL FAILED: the handwritten fixture placed nothing ("%"), so equality is vacuous', v_old_out;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 7. GRANTS, SECDEF AND search_path UNCHANGED. Read proacl, do not trust CREATE OR REPLACE.
  ------------------------------------------------------------------------------------------
  SELECT p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg INTO v_r
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'derm' AND p.proname = 'auto_place_page';
  IF v_r.acl IS DISTINCT FROM (SELECT acl FROM _apf_before)
     OR v_r.prosecdef IS DISTINCT FROM (SELECT prosecdef FROM _apf_before)
     OR v_r.cfg IS DISTINCT FROM (SELECT cfg FROM _apf_before) THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: acl/secdef/search_path moved: % / % / %', v_r.acl, v_r.prosecdef, v_r.cfg;
  END IF;
  IF NOT has_function_privilege('authenticated', 'derm.auto_place_page(text,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'derm.auto_place_page(text,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: EXECUTE grants are not authenticated=yes / anon=no';
  END IF;

  ------------------------------------------------------------------------------------------
  -- 8. THE CONTROL FUNCTION IS DROPPED.
  ------------------------------------------------------------------------------------------
  DROP FUNCTION derm._auto_place_page_pre_20260913(text, integer);
  IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'derm' AND p.proname = '_auto_place_page_pre_20260913') THEN
    RAISE EXCEPTION 'VERIFY 8 FAILED: the control function survived';
  END IF;

  ------------------------------------------------------------------------------------------
  -- 9. LIVE DATA IS BYTE-IDENTICAL. Every fixture above was rolled back.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM (
    (SELECT * FROM _cards_before
     EXCEPT
     SELECT id, dump_folder, page, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, stamp_placed_by,
            stamp_image_url, image_url, gdo_id, band_y0_pct, band_y1_pct, matched_client_id
       FROM derm.address_row_map)
    UNION ALL
    (SELECT id, dump_folder, page, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, stamp_placed_by,
            stamp_image_url, image_url, gdo_id, band_y0_pct, band_y1_pct, matched_client_id
       FROM derm.address_row_map
     EXCEPT
     SELECT * FROM _cards_before)) x;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 9 FAILED: % card row(s) differ from before this migration', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.address_sheet_scan_reads WHERE dump_folder = 'ticket-835076' AND page = 2;
  IF v_n < 1 THEN RAISE EXCEPTION 'VERIFY 9 FAILED: the page-2 scan read did not come back'; END IF;
  SELECT count(*) INTO v_n FROM derm.address_sheet_row_reads
   WHERE dump_folder = 'ticket-835076' AND page = 2 AND row_index = 1 AND client_code_read = '049-PV';
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 9 FAILED: the row-1 read did not come back'; END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: generated sheets now place each card on the image of its own '
               'printed page from any tab; skip when the image is unknown, when the paper disagrees, '
               'or when the client holds several cards; handwritten branch unchanged; grants '
               'unchanged; live data untouched.';
END
$verify$;

COMMIT;
