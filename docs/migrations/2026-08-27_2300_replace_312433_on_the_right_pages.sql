-- 2026-08-27_2300_replace_312433_on_the_right_pages.sql
--
-- WHY: PUT SHEET 1102's TEN STAMPS ON THE PAGES THEY BELONG TO, AND GIVE CASA NEOS ITS THREE.
-- ---------------------------------------------------------------------------
-- Fred: ticket-312433 "was showing as completed by AI but ALL the stamps were incorrect."
--
-- Diagnosed in `2026-08-27_2230`: the two scans are stored in REVERSE order, the sheet number had
-- never been read, so `derm.fn_sheet_image_position` fell back to identity and all 8 stamps landed
-- on the opposite scan. That predicate is now fixed. The sheet has since been read
-- (image1 = "1102-2", image2 = "1102-1", both HIGH confidence), so the mapping is now correct:
--
--     printed page 1 -> image 2        printed page 2 -> image 1
--
-- Fred cleared the 8 bad stamps by hand, so every card is currently unplaced. This places all ten.
--
-- THE FULL PRINTED LAYOUT of sheet 1102, from derm.v_sheet_printed_rows (PERMIT grain) crossed with
-- derm.fn_generated_row_geometry, and independently corroborated row-for-row by the row OCR:
--
--   row page client    permit      nickname   image   y
--    1    1   195-MYK  GDO-09807   Main         2    29.800
--    2    1   309-KEB  (none)      -            2    37.720
--    3    1   061-TCE  (none)      -            2    44.480
--    4    1   133-MUT  GDO-11986   Main         2    51.810
--    5    1   087-BB   (none)      -            2    60.040
--    6    2   091-SB   GDO-08940   Main         1    29.800
--    7    2   009-CN   GDO-10877   Kitchen      1    37.720
--    8    2   009-CN   GDO-15062   Bar          1    44.480   <- NO CARD EXISTED
--    9    2   009-CN   GDO-16389   Lounge       1    51.810   <- NO CARD EXISTED
--   10    2   154-PV   GDO-15264   Main         1    60.040
--
-- 🛑 CASA NEOS IS THE MULTI-GDO CASE AND IT WAS UNDER-CARDED. It holds three ACTIVE permits, the
-- generator correctly printed three rows for it (`rows_printed = 3`, frozen at generation), and the
-- folder held ONE card with `gdo_id IS NULL`. So even placed perfectly, rows 8 and 9 would have been
-- unowned printed rows: the exact shape that made ticket-310590 p2 a real leak on 2026-08-19.
-- This binds the existing card to Kitchen and creates the Bar and Lounge cards.
--
-- 🛑 `page` STAYS 1 ON EVERY CARD. ONLY `stamp_page` VARIES.
-- `derm.ticket_page_images` builds its array from `address_row_map.page`, so a card claiming page 2
-- would append a duplicate entry and re-point every later ordinal at a different scan - the
-- `ticket-833049` defect, which this same estate hit while adding 043-MIL's second card earlier
-- today. All 8 existing cards use `page = 1`; the two new ones match. VERIFY 6 asserts the array is
-- byte-identical before and after.
--
-- 🛑 THE NEW CARDS ARE INSERTED ALREADY STAMPED. `trg_ab_autoplace_generated` fires BEFORE INSERT
-- only when `stamp_placed_at IS NULL`, and its slot resolves the client's FIRST printed row, so
-- letting it run would stack Bar and Lounge on top of Kitchen's row 7. Supplying the stamp bypasses
-- it through the trigger's own guard.
--
-- ⚠ SAFE TO DO NOW: this folder serves ZERO documents (no page_block_extents), so nothing
-- customer-facing changes. It cannot publish until someone measures the page, which is deliberate.
--
-- RULE 8 (audit trail): `derm.address_row_map` is audited; every placement and both new cards are
-- captured with old_row and are individually revertible.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 0. Assert the ground.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer;
BEGIN
  -- the corrected mapping must actually be in place, or this would repeat the original defect
  IF derm.fn_sheet_image_position('ticket-312433', 1) <> 2
     OR derm.fn_sheet_image_position('ticket-312433', 2) <> 1 THEN
    RAISE EXCEPTION 'PART 0: the page->image mapping is not the corrected one (p1->%, p2->%)',
      derm.fn_sheet_image_position('ticket-312433',1), derm.fn_sheet_image_position('ticket-312433',2);
  END IF;
  -- both scan reads must be HIGH confidence, or the mapping is a guess
  SELECT count(*) INTO v_n FROM derm.address_sheet_scan_reads
   WHERE dump_folder='ticket-312433' AND confidence='high';
  IF v_n <> 2 THEN RAISE EXCEPTION 'PART 0: expected 2 high-confidence scan reads, found %', v_n; END IF;
  -- 8 cards, all unplaced, all page 1
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder='ticket-312433';
  IF v_n <> 8 THEN RAISE EXCEPTION 'PART 0: expected 8 cards, found %', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder='ticket-312433' AND page <> 1;
  IF v_n <> 0 THEN RAISE EXCEPTION 'PART 0: % card(s) are not page 1; the image array would move', v_n; END IF;
  -- and it must be serving nothing, so this cannot change a live document
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
    JOIN derm.address_row_map r ON r.matched_manifest_id = d.manifest_id
   WHERE r.dump_folder='ticket-312433';
  IF v_n <> 0 THEN RAISE EXCEPTION 'PART 0: the folder serves % document(s); this is no longer inert', v_n; END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- PART 1. Bind Casa Neos's existing card to its FIRST printed permit (Kitchen, row 7).
-- ---------------------------------------------------------------------------
UPDATE derm.address_row_map r
   SET gdo_id = g.id
  FROM public.gdos g, public.clients c
 WHERE r.dump_folder = 'ticket-312433'
   AND c.id = r.matched_client_id AND c.client_code = '009-CN'
   AND g.client_id = c.id AND g.gdo_number = 'GDO-10877' AND g.status = 'ACTIVE'
   AND r.gdo_id IS NULL;

-- ---------------------------------------------------------------------------
-- PART 2. Place all EIGHT existing cards on the correct image at the correct row.
-- ---------------------------------------------------------------------------
UPDATE derm.address_row_map r
   SET stamp_page      = v.img,
       stamp_x_pct     = 8.000,
       stamp_y_pct     = v.y,
       stamp_placed_at = now(),
       stamp_placed_by = 'claude-replace-2026-08-27'
  FROM (VALUES
    (1033, 2, 29.800::numeric),   -- row 1  195-MYK
    (1032, 2, 37.720::numeric),   -- row 2  309-KEB
    (1031, 2, 44.480::numeric),   -- row 3  061-TCE
    (1028, 2, 51.810::numeric),   -- row 4  133-MUT
    (1030, 2, 60.040::numeric),   -- row 5  087-BB
    (1027, 1, 29.800::numeric),   -- row 6  091-SB
    (1029, 1, 37.720::numeric),   -- row 7  009-CN Kitchen
    (1026, 1, 60.040::numeric)    -- row 10 154-PV
  ) AS v(card_id, img, y)
 WHERE r.id = v.card_id AND r.dump_folder = 'ticket-312433';

-- ---------------------------------------------------------------------------
-- PART 3. Casa Neos's two missing per-permit cards, created ALREADY STAMPED.
-- ---------------------------------------------------------------------------
INSERT INTO derm.address_row_map
  (dump_folder, white_manifest_number, page, row_index, image_url,
   matched_client_id, matched_manifest_id, gdo_id,
   assignment_status, confidence, source, flags,
   stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, stamp_placed_by)
SELECT base.dump_folder, base.white_manifest_number, 1,
       (SELECT max(row_index) FROM derm.address_row_map WHERE dump_folder='ticket-312433') + n.ord,
       base.image_url,
       base.matched_client_id, base.matched_manifest_id, g.id,
       'matched', 'high', 'extra-stamp', '{"extra_stamp":true}'::jsonb,
       1, 8.000, n.y, now(), 'claude-replace-2026-08-27'
  FROM (SELECT r.* FROM derm.address_row_map r
          JOIN public.clients c ON c.id = r.matched_client_id
         WHERE r.dump_folder='ticket-312433' AND c.client_code='009-CN'
         ORDER BY r.id LIMIT 1) base
  CROSS JOIN (VALUES ('GDO-15062', 1, 44.480::numeric),   -- row 8  Bar
                     ('GDO-16389', 2, 51.810::numeric)    -- row 9  Lounge
             ) AS n(gdo_number, ord, y)
  JOIN public.gdos g ON g.client_id = base.matched_client_id
                    AND g.gdo_number = n.gdo_number AND g.status = 'ACTIVE';

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_bad integer; v_imgs text;
BEGIN
  -- 1. Ten cards, all placed.
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder='ticket-312433';
  IF v_n <> 10 THEN RAISE EXCEPTION 'VERIFY 1 failed: % cards, expected 10', v_n; END IF;
  SELECT count(*) INTO v_bad FROM derm.address_row_map
   WHERE dump_folder='ticket-312433' AND stamp_placed_at IS NULL;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % unplaced; the folder is frozen', v_bad; END IF;

  -- 2. Casa Neos has THREE cards, one per permit, in printed order and on ascending rows.
  SELECT count(*) INTO v_n FROM derm.address_row_map r
    JOIN public.clients c ON c.id=r.matched_client_id
   WHERE r.dump_folder='ticket-312433' AND c.client_code='009-CN';
  IF v_n <> 3 THEN RAISE EXCEPTION 'VERIFY 2 failed: % Casa Neos cards, expected 3', v_n; END IF;
  SELECT count(*) INTO v_bad FROM (
    SELECT g.gdo_number, r.stamp_y_pct,
           rank() OVER (ORDER BY g.gdo_number) AS by_permit,
           rank() OVER (ORDER BY r.stamp_y_pct) AS by_position
      FROM derm.address_row_map r
      JOIN public.clients c ON c.id=r.matched_client_id
      JOIN public.gdos g ON g.id=r.gdo_id
     WHERE r.dump_folder='ticket-312433' AND c.client_code='009-CN') z
   WHERE by_permit <> by_position;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: Casa Neos permit order does not match top-to-bottom position';
  END IF;

  -- 3. 🛑 EVERY STAMP IS ON THE IMAGE THE ROW OCR SAYS HOLDS THAT CLIENT. This is the assertion the
  --    original defect would have failed: it compares against the PAPER, not against our arithmetic.
  SELECT count(*) INTO v_bad
    FROM derm.address_row_map r
    JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder='ticket-312433'
     AND NOT EXISTS (SELECT 1 FROM derm.address_sheet_row_reads rr
                      WHERE rr.dump_folder = r.dump_folder
                        AND rr.page = r.stamp_page
                        AND rr.client_code_read = c.client_code);
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % stamp(s) are on an image whose row OCR does not name that client', v_bad;
  END IF;

  -- 4. No two stamps share a position, and every y is one of the five printed row positions.
  SELECT count(*) INTO v_bad FROM (
    SELECT stamp_page, stamp_y_pct FROM derm.address_row_map
     WHERE dump_folder='ticket-312433'
     GROUP BY 1,2 HAVING count(*) > 1) d;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: % duplicated stamp position(s)', v_bad; END IF;
  SELECT count(*) INTO v_bad FROM derm.address_row_map
   WHERE dump_folder='ticket-312433'
     AND stamp_y_pct NOT IN (29.800, 37.720, 44.480, 51.810, 60.040);
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: % stamp(s) off the printed row grid', v_bad; END IF;

  -- 5. Five stamps on each image, which is what a 10-row / 5-per-page sheet must produce.
  SELECT count(*) INTO v_bad FROM (
    SELECT stamp_page FROM derm.address_row_map WHERE dump_folder='ticket-312433'
     GROUP BY stamp_page HAVING count(*) <> 5) s;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: the stamps are not 5 per image'; END IF;

  -- 6. 🛑 THE IMAGE ARRAY DID NOT MOVE. Adding cards with page <> 1 would append a duplicate entry
  --    and silently re-point every stamp_page ordinal at a different scan (the ticket-833049 shape).
  SELECT string_agg(split_part(u,'/',-1), '|' ORDER BY ord) INTO v_imgs
    FROM unnest(derm.ticket_page_images('312433')) WITH ORDINALITY AS i(u, ord);
  IF v_imgs IS DISTINCT FROM 'address_1.jpg|address_2.jpg' THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: ticket_page_images is now [%]', v_imgs;
  END IF;

  -- 7. Still serving nothing, so this remains inert until someone measures the page.
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
    JOIN derm.address_row_map r ON r.matched_manifest_id = d.manifest_id
   WHERE r.dump_folder='ticket-312433';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 7 FAILED: the folder now serves % document(s)', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: 10 cards placed 5-per-image, Casa Neos has 3 in printed order, every stamp is on the image the row OCR names, image array unchanged, still serving nothing.';
END $do$;

COMMIT;
