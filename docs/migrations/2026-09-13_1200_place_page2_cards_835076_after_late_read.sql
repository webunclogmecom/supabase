-- ============================================================================================
-- 2026-09-13_1200_place_page2_cards_835076_after_late_read.sql
--
-- Place the five page-2 cards of ticket-835076 (generated sheet 1117) exactly where the insert-time
-- AI placement would have put them, had the page-2 sheet-number read landed 0.75 s earlier.
--
-- WHY (Fred, 2026-09-13): "why is the manifest 835076 at the stamp app with AI Stamps on the 1st
-- page only but not the 2nd page?"
--
-- ============================================================================================
-- THE MECHANISM, MEASURED TO THE MILLISECOND. It is a race, and the trigger LOST IT CORRECTLY.
--
--   15:58:28.05 .. 15:58:33.28 UTC   the ten cards are materialised by the derm-link filing
--   15:58:32.28                      image 1 sheet number read: "1117-1", high confidence
--   15:58:33.28                      trg_ab_autoplace_generated places the five PAGE-1 cards
--   15:58:34.03                      image 2 sheet number read: "1117-2", high confidence
--
-- derm.trg_autoplace_generated resolves each card's printed page through
-- derm.fn_sheet_image_position(dump_folder, o_page) and refuses to place when that is NULL, with
-- the comment "NULL = we do not know which image this page is, so do not place." At 15:58:33 the
-- image position for printed page 2 was NULL, because the read that establishes it arrived
-- three quarters of a second later. The five page-2 cards were therefore left unplaced, which is
-- the fail-closed outcome that stopped three earlier folders from stamping every client onto the
-- wrong scan. Nothing is wrong with the trigger.
--
-- The trigger is BEFORE INSERT only, so once the read landed nothing re-ran it, and unattended
-- re-placement after a page-map change is DELIBERATELY not shipped (2026-09-03_2210: "a second
-- unattended placement path firing on freshly-changed page maps is how that class returns").
-- The detector that exists for this state, derm.v_cards_awaiting_page_map, lists exactly these
-- five cards and nothing else in the estate.
--
-- ============================================================================================
-- 🛑 WHY THE OPERATOR CANNOT FIX IT WITH THE AUTO-PLACE BUTTON, MEASURED IN ROLLED-BACK PROBES.
--
-- The five cards carry stamp_page NULL, so COALESCE(stamp_page, page) = 1 and the Studio lists
-- them under the PAGE-1 tab; the page-2 tab says "Nothing to auto-place":
--
--     derm.auto_place_page('ticket-835076', 2)  ->  placed 0, skipped 0
--     derm.auto_place_page('ticket-835076', 1)  ->  placed 5, ALL FIVE ON IMAGE 1,
--         at y = 29.800 / 37.720 / 44.480 / 51.810 / 60.040, i.e. EXACTLY on top of the five
--         page-1 clients' stamps, witness address_1.jpg. Ten stamps on a scan that prints five.
--
-- auto_place_page writes `stamp_page = p_page` unconditionally: it takes the TAB as the target
-- image and never consults the card's own printed page. That is a separate defect and it is NOT
-- fixed here (see the note at the end); this migration removes the five cards that make it
-- reachable on this folder today.
--
-- ============================================================================================
-- WHY THIS PLACEMENT IS SAFE, and it is safer than the insert-time one was.
--
-- Every gate trg_autoplace_generated applies is evaluated NOW, in SQL, not copied from a probe:
--   1. fn_generated_sheet_slot(manifest)            -> printed rows 6..10, all resolved
--   2. fn_generated_row_geometry(slot)              -> o_page 2, o_y 29.80/37.72/44.48/51.81/60.04
--   3. fn_sheet_image_position('ticket-835076', 2)  -> 2, from the high-confidence "1117-2" read
--   4. fn_row_read_confirms(folder, 2, row, code)   -> TRUE for all five
-- Gate 4 is the part the insert-time placement never had: the ROW OCR of image 2 has since read
-- "049-PV Pura Vida, 083-SHUL The Shul, 082-TFC The fresh Carrot, 033-LG La Granja, 142-57 57
-- Ocean" on rows 1..5 at high confidence, which is the printed order of slots 6..10. Two
-- independent reads of the paper agree with the generator's own layout.
--
-- The UPDATE below computes every value through those functions and REFUSES if any of them
-- resolves NULL; no coordinate is hardcoded. stamp_placed_by is 'stamp-studio-ai' because these
-- are the AI placement's own values from its own resolution chain; the audit row carries
-- app_source = 'sql' and this file, so the provenance of the replay is not hidden. Keeping that
-- label also keeps the resolver's anti-AI auto-complete clause in force: a person still has to
-- look at this sheet before it completes.
--
-- The witness (stamp_image_url) is captured by trg_ac_stamp_witness on the placement, and
-- VERIFY 2 asserts it names address_2.jpg. page and image_url are untouched, so
-- trg_zz_page_image_injective has nothing to say and ticket_page_images cannot move.
--
-- RULE 8: no schema change. derm.address_row_map is audit-triggered.
-- ============================================================================================

BEGIN;

CREATE TEMP TABLE _placed_before ON COMMIT DROP AS
  SELECT id, page, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, stamp_placed_by,
         stamp_image_url, image_url, gdo_id, band_y0_pct, band_y1_pct
    FROM derm.address_row_map
   WHERE dump_folder = 'ticket-835076' AND stamp_placed_at IS NOT NULL;

CREATE TEMP TABLE _imgs_before ON COMMIT DROP AS
  SELECT derm.ticket_page_images('835076') AS imgs;

-- ============================================================================================
-- PART 0. PRECONDITIONS.
-- ============================================================================================
DO $pre$
DECLARE v_n int; v_pos int; v_read text;
BEGIN
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-835076';
  IF v_n <> 10 THEN RAISE EXCEPTION 'PRE 0.1: folder holds % cards, expected 10', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-835076' AND stamp_placed_at IS NULL AND stamp_page IS NULL;
  IF v_n <> 5 THEN RAISE EXCEPTION 'PRE 0.2: % unplaced cards, expected the 5 page-2 cards', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-835076' AND stamp_placed_at IS NOT NULL AND stamp_page = 1
     AND stamp_placed_by = 'stamp-studio-ai';
  IF v_n <> 5 THEN RAISE EXCEPTION 'PRE 0.3: % AI-placed page-1 cards, expected 5', v_n; END IF;

  -- The unplaced five are exactly the printed-page-2 rows of sheet 1117.
  SELECT count(*) INTO v_n
    FROM derm.address_row_map r
    JOIN derm.address_sheet_manifests l ON l.manifest_id = r.matched_manifest_id
    JOIN derm.v_sheet_printed_rows pr ON pr.sheet_id = l.sheet_id AND pr.slot = l.slot AND pr.is_first_row
   WHERE r.dump_folder = 'ticket-835076' AND r.stamp_placed_at IS NULL
     AND l.sheet_id = 155 AND pr.printed_page = 2;
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'PRE 0.4: only % of the unplaced cards resolve to printed page 2 of sheet 1117', v_n;
  END IF;

  -- The page map is established by a high-confidence suffixed read of image 2.
  v_pos := derm.fn_sheet_image_position('ticket-835076', 2);
  IF v_pos IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'PRE 0.5: fn_sheet_image_position(page 2) is %, expected 2', v_pos;
  END IF;
  SELECT sheet_no_read INTO v_read FROM derm.address_sheet_scan_reads
   WHERE dump_folder = 'ticket-835076' AND page = 2 AND confidence = 'high'
     AND image_url LIKE '%address_2.jpg' ORDER BY read_at DESC LIMIT 1;
  IF v_read IS DISTINCT FROM '1117-2' THEN
    RAISE EXCEPTION 'PRE 0.6: image 2 reads %, expected 1117-2', COALESCE(v_read, '<no read>');
  END IF;

  -- The row OCR of image 2 confirms every one of the five on its printed row.
  SELECT count(*) INTO v_n
    FROM derm.address_row_map r
    JOIN public.clients c ON c.id = r.matched_client_id
    JOIN derm.address_sheet_manifests l ON l.manifest_id = r.matched_manifest_id
    JOIN derm.v_sheet_printed_rows pr ON pr.sheet_id = l.sheet_id AND pr.slot = l.slot AND pr.is_first_row
   WHERE r.dump_folder = 'ticket-835076' AND r.stamp_placed_at IS NULL
     AND derm.fn_row_read_confirms('ticket-835076', 2, pr.row_on_page, c.client_code) IS TRUE;
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'PRE 0.7: the row OCR confirms only % of the 5 cards on image 2', v_n;
  END IF;

  -- The detector agrees this is the whole population, estate-wide.
  SELECT count(*) INTO v_n FROM derm.v_cards_awaiting_page_map;
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'PRE 0.8: v_cards_awaiting_page_map holds % rows, expected exactly these 5', v_n;
  END IF;
  SELECT count(*) INTO v_n FROM derm.v_cards_awaiting_page_map WHERE dump_folder <> 'ticket-835076';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 0.8: % awaiting cards belong to other folders; this file targets one', v_n;
  END IF;

  -- Nothing served, not completed: this cannot change what a client sees.
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
   WHERE d.manifest_id IN (SELECT matched_manifest_id FROM derm.address_row_map
                            WHERE dump_folder = 'ticket-835076' AND matched_manifest_id IS NOT NULL);
  IF v_n <> 0 THEN RAISE EXCEPTION 'PRE 0.9: % document(s) already served', v_n; END IF;
  IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-835076' AND completed) THEN
    RAISE EXCEPTION 'PRE 0.10: the sheet is marked completed';
  END IF;

  RAISE NOTICE 'PRE OK: 5 unplaced page-2 cards, image 2 = 1117-2 (high), row OCR confirms all 5, '
               'detector lists exactly these 5, 0 documents served.';
END
$pre$;

-- ============================================================================================
-- PART 1. THE CONTROL: what the operator's Auto-place button does to these cards TODAY.
--         Rolled back. It must put all five on image 1, or the reason for this file is gone.
-- ============================================================================================
DO $ctl$
DECLARE v_n int;
BEGIN
  BEGIN
    PERFORM derm.auto_place_page('ticket-835076', 1);
    SELECT count(*) INTO v_n FROM derm.address_row_map
     WHERE dump_folder = 'ticket-835076' AND stamp_page = 1;
    IF v_n <> 10 THEN
      RAISE EXCEPTION 'CONTROL FAILED: auto_place_page(page 1) left % stamps on image 1, expected 10 '
                      '(the five page-2 clients stacked on the five page-1 clients)', v_n;
    END IF;
    RAISE EXCEPTION 'ROLLBACK_CONTROL';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_CONTROL' THEN RAISE; END IF;
  END;
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-835076' AND stamp_placed_at IS NULL;
  IF v_n <> 5 THEN RAISE EXCEPTION 'CONTROL CLEANUP FAILED: % unplaced remain, expected 5', v_n; END IF;
  RAISE NOTICE 'CONTROL OK: the Auto-place button would have stacked all five on image 1 (rolled back).';
END
$ctl$;

-- ============================================================================================
-- PART 2. THE CHANGE. The insert trigger''s own resolution chain, evaluated now.
-- ============================================================================================
UPDATE derm.address_row_map a
   SET stamp_page      = derm.fn_sheet_image_position(a.dump_folder, geo.o_page),
       stamp_x_pct     = round(geo.o_x_pct, 3),
       stamp_y_pct     = round(geo.o_y_pct, 3),
       stamp_placed_at = now(),
       stamp_placed_by = 'stamp-studio-ai'
  FROM derm.address_sheet_manifests l
  JOIN derm.v_sheet_printed_rows pr ON pr.sheet_id = l.sheet_id AND pr.slot = l.slot AND pr.is_first_row
  CROSS JOIN LATERAL derm.fn_generated_row_geometry(pr.printed_row) geo
  JOIN public.clients c ON TRUE
 WHERE a.dump_folder = 'ticket-835076'
   AND a.stamp_placed_at IS NULL
   AND l.manifest_id = a.matched_manifest_id
   AND c.id = a.matched_client_id
   AND pr.printed_row = derm.fn_generated_sheet_slot(a.matched_manifest_id)
   AND geo.o_page = 2
   AND geo.o_y_pct IS NOT NULL
   AND derm.fn_sheet_image_position(a.dump_folder, geo.o_page) IS NOT NULL
   AND derm.fn_row_read_confirms(a.dump_folder,
                                 derm.fn_sheet_image_position(a.dump_folder, geo.o_page),
                                 pr.row_on_page, c.client_code) IS NOT FALSE;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE v_n int; v_s text; v_imgs text[];
BEGIN
  -- 1. All ten placed; the five page-1 cards did not move by a single byte.
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-835076' AND stamp_placed_at IS NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % card(s) still unplaced', v_n; END IF;

  SELECT count(*) INTO v_n FROM (
    SELECT * FROM _placed_before
    EXCEPT
    SELECT id, page, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, stamp_placed_by,
           stamp_image_url, image_url, gdo_id, band_y0_pct, band_y1_pct
      FROM derm.address_row_map WHERE dump_folder = 'ticket-835076') x;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % page-1 card(s) changed', v_n; END IF;

  -- 2. The five landed on IMAGE 2, witnessed by address_2.jpg, one per printed row, in printed
  --    order, at the generator''s own row geometry.
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-835076' AND stamp_page = 2
     AND stamp_image_url LIKE '%address_2.jpg' AND stamp_placed_by = 'stamp-studio-ai';
  IF v_n <> 5 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % card(s) on image 2 with the page-2 witness, expected 5', v_n;
  END IF;

  SELECT string_agg(c.client_code || '@' || r.stamp_y_pct::text, ' ' ORDER BY r.stamp_y_pct)
    INTO v_s
    FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder = 'ticket-835076' AND r.stamp_page = 2;
  IF v_s IS DISTINCT FROM
     '049-PV@29.800 083-SHUL@37.720 082-TFC@44.480 033-LG@51.810 142-57@60.040' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: image 2 reads "%"', v_s;
  END IF;

  -- 3. No two stamps share a row on either image (the exact shape the control produced).
  SELECT count(*) INTO v_n
    FROM derm.address_row_map a JOIN derm.address_row_map b
      ON b.dump_folder = a.dump_folder AND b.stamp_page = a.stamp_page AND b.id < a.id
     AND abs(a.stamp_y_pct - b.stamp_y_pct) < 1.0
   WHERE a.dump_folder = 'ticket-835076';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: % stamp pair(s) stacked on one row', v_n; END IF;

  -- 4. The page map did not move, and the detector is empty.
  v_imgs := derm.ticket_page_images('835076');
  IF v_imgs IS DISTINCT FROM (SELECT imgs FROM _imgs_before) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: ticket_page_images changed to %', v_imgs;
  END IF;
  SELECT count(*) INTO v_n FROM derm.v_cards_awaiting_page_map;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: % card(s) still awaiting a page map', v_n; END IF;

  -- 5. Still not completed and nothing served. Completing it is a person''s click.
  IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-835076' AND completed) THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: the sheet completed itself';
  END IF;
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
   WHERE d.manifest_id IN (SELECT matched_manifest_id FROM derm.address_row_map
                            WHERE dump_folder = 'ticket-835076' AND matched_manifest_id IS NOT NULL);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: % document(s) published', v_n; END IF;

  SET CONSTRAINTS ALL IMMEDIATE;

  RAISE NOTICE 'ALL VERIFY PASSED: 10 of 10 placed, five page-2 cards on image 2 in printed order '
               'with the page-2 witness, page-1 cards byte-identical, no stacked stamps, page map '
               'unchanged, v_cards_awaiting_page_map empty.';
END
$verify$;


-- ============================================================================================
-- 🛑 NOT FIXED HERE, AND IT WILL RECUR: derm.auto_place_page writes stamp_page = p_page.
--
-- The next generated sheet whose page-2 read lands after the filing (the margin here was 0.75 s;
-- on ticket-834742 it was 9 minutes) reproduces this state, and the Auto-place button on the
-- page-1 tab then stamps the page-2 clients onto image 1. The function should resolve each card
-- of a GENERATED sheet through fn_generated_sheet_slot -> fn_generated_row_geometry ->
-- fn_sheet_image_position, exactly as the insert trigger does, place it on THAT image, and skip
-- it when the image position is NULL. Handwritten sheets have no printed order and keep the
-- p_page behaviour. That is its own migration with the pre-fix body as a failing control.
-- ============================================================================================

COMMIT;
