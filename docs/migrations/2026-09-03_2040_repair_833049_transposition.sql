-- 2026-09-03_2040_repair_833049_transposition.sql
--
-- WHY
-- ---
-- `ticket-833049` has served **0 documents to 10 clients since 2026-08-17**. It is the estate's only
-- injectivity violation and its only completed-but-unpublished sheet, frozen by the deliberate CHECK
-- `page_block_extents_no_ticket_833049` added by `2026-08-19_2355` after a real leak.
--
-- 🛑 THE RECORDED DIAGNOSIS WAS WRONG, AND THAT IS WHY THIS SAT FOR 17 DAYS.
-- `Supabase/CLAUDE.md` said the page=2 row (card 972) "is in fact the only one that agrees with the
-- paper". That is true of that ONE CARD and false as a description of the folder, and reading it as
-- a lone witness is what made the folder look unadjudicable.
--
-- I FETCHED BOTH SCANS AND READ THEM (public manifests bucket, inspected at 3x):
--
--   derm/1710/address_1.jpg  printed pad number **338**, Section B in printed order:
--       179-CIG Espanola Cigars, 409 Espanola Way Miami Beach
--       83-SHUL The Shul, 9540 Collins Av FL 33154
--       The Carrot Express Coral Gables (092-TCE), 259 Miracle Mile Coral Gables FL 33134
--       029-JOS Josh's Deli, 9517 Harding Av Surfside FL 33154
--       082 The Fresh Carrot of Surfside, 9519 Harding Av Surfside FL 33154
--       [6th slot EMPTY]
--
--   derm/1710/address_2.jpg  printed pad number **387**, Section B in printed order:
--       Ceviche Inka (114-CI), 3155 NE 163rd St NMB FL 33160
--       AVA (168-AVA), 2589 Mc Farlane Rd Miami FL
--       Yaya (221-YAS), 151 NE 41st St Miami FL 33137
--       La Spaziotto (222-SPE), 40 NE 41 St Miami FL 33137
--       MYK Brickell (214-MYK), 777 Brickell Av Miami FL
--       [6th slot EMPTY]
--
-- The five clients printed on address_1 are the five currently at `effective_page 2`; the five
-- printed on address_2 are the five currently at `effective_page 1`. Each group's stamps run
-- 29.800 -> 60.040 in EXACT printed order.
--
-- ⇒ **IT IS A STRAIGHT TWO-PAGE TRANSPOSITION. 0 of 10 correct today, 10 of 10 after a swap.** That
-- is the same signature that settled `ticket-833813` (2026-08-27_1035) and `ticket-312433`
-- (2026-08-27_2300).
--
-- 🛑 THE "DOUBLES THE EXPOSURE" WARNING STANDS, AND NOW HAS A BETTER REASON. Normalising `page`
-- WITHOUT swapping `stamp_page` would move the CORRECT group (the one on address_1) onto the wrong
-- scan as well - taking the folder from 5 wrong to 10 wrong. The two MUST ship together, which is
-- why they are one transaction here.
--
-- 🛑 THE WITNESS CANNOT ADJUDICATE THIS FOLDER, SO IT IS NOT USED AS THE ORACLE. All ten
-- `stamp_image_url` values read `address_1.jpg`, because they were backfilled from each stamp's own
-- ordinal on 2026-08-24 while `imgs[1]` and `imgs[2]` were BOTH address_1. That is the documented
-- circularity. The new witness is written from the PAPER, via the de-duplicated image list.
-- ⚠ `derm.fn_stamp_witness` re-derives only on INSERT or when `stamp_placed_at` changes (verified in
-- the live body). This migration touches neither, so the explicit witness write survives.
--
-- ⚠ Also read off the paper: **338 and 387 are two SEPARATE handwritten pads**, not two pages of one
-- sheet, and neither number carries a `-N` suffix - so `derm.fn_sheet_image_position` correctly falls
-- through to identity for this folder, before and after.
--
-- WHAT THIS CHANGES
--   P1  card 972  page 2 -> 1                    (image list 3 -> 2, injectivity violation clears)
--   P2  scan reads: DELETE the position-2 row (it was read THROUGH the duplicate and names
--       address_1); move the position-3 row (pad 387, address_2) to position 2
--   P3  all 10 cards: stamp_page 1 <-> 2, and stamp_image_url re-pointed FROM THE PAPER
--
-- 🛑 THE CHECK CONSTRAINT STAYS ON. This migration does NOT add an extent, does NOT drop the
-- constraint and does NOT publish anything. The folder still serves 0 documents when it commits.
-- Measuring the geometry, dropping the CHECK and serving the 10 clients is a SEPARATE migration and
-- is **Fred's decision**, not a repair to be done unattended. See section 6 of
-- `docs/superpowers/specs/2026-09-03-derm-page-integrity-plan.md`.
--
-- ⚠ EXPECTED SIDE EFFECT: `trg_zz_dirty_on_card_change` fires on the `stamp_page` UPDATE and sets
-- `derm.stamp_sheet_status.completed = false`. That is CORRECT - the sheet changed and must be
-- re-confirmed by a person - but it means the folder DROPS OFF `derm.v_blackout_completed_unpublished`
-- (which requires `completed`). It remains visible on `derm.v_blackout_blocked_sheets` as
-- `held_by_constraint`, so the 10-client backlog does not become invisible. VERIFY 7 asserts that.
--
-- 🛑 P2 IS A DELETE ON AN UNAUDITED TABLE. `derm.address_sheet_scan_reads` has no triggers, so there
-- is no `audit.logs.old_row`. The deleted row is fully described in the ROLLBACK block below, and the
-- pre-image is backed up to `backups/2026-09-03_ticket-833049_pre_repair.json`.
--
-- RULE 8 (audit): no table or column changes. `derm.address_row_map` is audited, so P1 and P3 are
-- captured. `address_sheet_scan_reads` is not - hence the backup.

BEGIN;

DO $do$
DECLARE
  v_a1 text; v_a2 text; v_imgs text[]; n int;
BEGIN
  -- ---- P0. PRECONDITIONS -------------------------------------------------
  v_imgs := derm.ticket_page_images('833049');
  IF array_length(v_imgs, 1) <> 3 OR v_imgs[1] IS DISTINCT FROM v_imgs[2] THEN
    RAISE EXCEPTION 'P0a: image list is not the measured [a1,a1,a2] defect: %', v_imgs;
  END IF;
  v_a1 := v_imgs[1];
  v_a2 := v_imgs[3];
  IF v_a1 NOT LIKE '%/derm/1710/address_1.jpg' OR v_a2 NOT LIKE '%/derm/1710/address_2.jpg' THEN
    RAISE EXCEPTION 'P0b: the folder no longer holds the two scans I read (% / %)', v_a1, v_a2;
  END IF;

  SELECT count(*) INTO n FROM derm.address_row_map WHERE dump_folder = 'ticket-833049';
  IF n <> 10 THEN RAISE EXCEPTION 'P0c: expected 10 cards, found %', n; END IF;

  -- the two groups must still be the ones I read off the paper, or the swap is not the right change
  SELECT count(*) INTO n
    FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder = 'ticket-833049' AND r.stamp_page = 2
     AND c.client_code IN ('179-CIG','083-SHUL','092-TCE','029-JOS','082-TFC');
  IF n <> 5 THEN RAISE EXCEPTION 'P0d: the stamp_page-2 group is not the five printed on pad 338 (% of 5)', n; END IF;
  SELECT count(*) INTO n
    FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder = 'ticket-833049' AND r.stamp_page = 1
     AND c.client_code IN ('114-CI','168-AVA','221-YAS','222-SPE','214-MYK');
  IF n <> 5 THEN RAISE EXCEPTION 'P0e: the stamp_page-1 group is not the five printed on pad 387 (% of 5)', n; END IF;

  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-833049' AND (stamp_placed_at IS NULL OR stamp_page NOT IN (1,2));
  IF n <> 0 THEN RAISE EXCEPTION 'P0f: % card(s) unplaced or off pages 1/2', n; END IF;

  -- nothing is published, and the freeze is still on
  SELECT count(*) INTO n FROM derm.page_block_extents WHERE dump_folder = 'ticket-833049';
  IF n <> 0 THEN RAISE EXCEPTION 'P0g: an extent exists; this folder should be frozen'; END IF;
  SELECT count(*) INTO n FROM derm.redacted_manifest_docs
   WHERE manifest_id IN (SELECT matched_manifest_id FROM derm.address_row_map
                          WHERE dump_folder = 'ticket-833049' AND matched_manifest_id IS NOT NULL);
  IF n <> 0 THEN RAISE EXCEPTION 'P0h: % document(s) are being served', n; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'page_block_extents_no_ticket_833049') THEN
    RAISE EXCEPTION 'P0i: the freeze constraint is gone; refusing to repair an unfrozen folder';
  END IF;

  -- no manual bands to preserve
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-833049' AND band_y0_pct IS NOT NULL;
  IF n <> 0 THEN RAISE EXCEPTION 'P0j: % manual band(s) exist; this migration assumes none', n; END IF;

  -- ---- P1. DE-DUPLICATE THE IMAGE LIST -----------------------------------
  UPDATE derm.address_row_map
     SET page = 1
   WHERE dump_folder = 'ticket-833049' AND id = 972 AND page = 2;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'P1: updated % row(s), expected exactly 1', n; END IF;

  v_imgs := derm.ticket_page_images('833049');
  IF v_imgs IS DISTINCT FROM ARRAY[v_a1, v_a2] THEN
    RAISE EXCEPTION 'P1b: image list is % after de-duplication, expected [a1,a2]', v_imgs;
  END IF;

  -- ---- P2. THE POSITION MAP FOLLOWS THE LIST -----------------------------
  -- The position-2 read was taken THROUGH the duplicate: it read imgs[2], which was the second copy
  -- of address_1, and unsurprisingly read pad 338 again. It asserts nothing true about position 2.
  DELETE FROM derm.address_sheet_scan_reads
   WHERE dump_folder = 'ticket-833049' AND page = 2 AND image_url = v_a1;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'P2a: deleted % read(s), expected exactly 1', n; END IF;

  UPDATE derm.address_sheet_scan_reads
     SET page = 2
   WHERE dump_folder = 'ticket-833049' AND page = 3 AND image_url = v_a2;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'P2b: moved % read(s), expected exactly 1', n; END IF;

  -- ---- P3. THE SWAP, WITH THE WITNESS WRITTEN FROM THE PAPER -------------
  UPDATE derm.address_row_map r
     SET stamp_page      = 3 - r.stamp_page,
         stamp_image_url = v_imgs[3 - r.stamp_page]
   WHERE r.dump_folder = 'ticket-833049'
     AND r.stamp_page IN (1, 2);
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 10 THEN RAISE EXCEPTION 'P3: swapped % card(s), expected 10', n; END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_imgs text[]; n int; v_codes text[];
BEGIN
  v_imgs := derm.ticket_page_images('833049');

  -- 1. The image list is de-duplicated.
  IF array_length(v_imgs, 1) <> 2 THEN RAISE EXCEPTION 'VERIFY 1a: image list is % entries', array_length(v_imgs, 1); END IF;
  IF (SELECT count(DISTINCT u) FROM unnest(v_imgs) u) <> 2 THEN RAISE EXCEPTION 'VERIFY 1b: a duplicate survives'; END IF;
  SELECT count(DISTINCT page) INTO n FROM derm.address_row_map WHERE dump_folder = 'ticket-833049';
  IF n <> 1 THEN RAISE EXCEPTION 'VERIFY 1c: the folder still spans % OCR pages', n; END IF;

  -- 2. THE ONE THAT MATTERS: each group now sits on the scan it is PRINTED on, IN PRINTED ORDER.
  --    Asserted as an ordered array so a right-set-wrong-order result still fails.
  SELECT array_agg(c.client_code ORDER BY r.stamp_y_pct) INTO v_codes
    FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder = 'ticket-833049' AND r.stamp_page = 1;
  IF v_codes IS DISTINCT FROM ARRAY['179-CIG','083-SHUL','092-TCE','029-JOS','082-TFC'] THEN
    RAISE EXCEPTION 'VERIFY 2a: image position 1 (pad 338) holds %, expected the printed order of pad 338', v_codes;
  END IF;
  SELECT array_agg(c.client_code ORDER BY r.stamp_y_pct) INTO v_codes
    FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder = 'ticket-833049' AND r.stamp_page = 2;
  IF v_codes IS DISTINCT FROM ARRAY['114-CI','168-AVA','221-YAS','222-SPE','214-MYK'] THEN
    RAISE EXCEPTION 'VERIFY 2b: image position 2 (pad 387) holds %, expected the printed order of pad 387', v_codes;
  END IF;

  -- 2c. MUTATION CONTROL: the two images must be distinguishable, or every witness assertion below
  --     would pass whatever ordinal each card carried.
  IF v_imgs[1] = v_imgs[2] THEN RAISE EXCEPTION 'VERIFY 2c: control failed - the two images are identical'; END IF;

  -- 3. Every witness matches the image at its ordinal, and the split is 5/5.
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-833049' AND stamp_image_url IS DISTINCT FROM v_imgs[stamp_page];
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3a: % card(s) do not resolve to their witnessed image', n; END IF;
  SELECT count(*) INTO n FROM derm.address_row_map WHERE dump_folder='ticket-833049' AND stamp_page = 1;
  IF n <> 5 THEN RAISE EXCEPTION 'VERIFY 3b: % cards on position 1, expected 5', n; END IF;
  SELECT count(*) INTO n FROM derm.address_row_map WHERE dump_folder='ticket-833049' AND stamp_page = 2;
  IF n <> 5 THEN RAISE EXCEPTION 'VERIFY 3c: % cards on position 2, expected 5', n; END IF;

  -- 4. The position map is consistent: one read per position, each naming the file at that position.
  SELECT count(*) INTO n FROM derm.address_sheet_scan_reads WHERE dump_folder = 'ticket-833049';
  IF n <> 2 THEN RAISE EXCEPTION 'VERIFY 4a: % scan read(s), expected 2', n; END IF;
  SELECT count(*) INTO n FROM derm.address_sheet_scan_reads s
   WHERE s.dump_folder = 'ticket-833049' AND s.image_url IS DISTINCT FROM v_imgs[s.page];
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 4b: % read(s) name a file that is not at their position', n; END IF;

  -- 5. THE ESTATE'S ONLY INJECTIVITY VIOLATION IS GONE.
  SELECT count(DISTINCT r.white_manifest_number) INTO n
    FROM derm.address_row_map r
   WHERE r.white_manifest_number IS NOT NULL AND r.image_url <> 'pending'
     AND EXISTS (SELECT 1 FROM derm.address_row_map r2
                  WHERE r2.white_manifest_number = r.white_manifest_number
                    AND r2.image_url = r.image_url AND r2.image_url <> 'pending'
                    AND r2.page <> r.page);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 5: % violating white manifest(s) remain, expected 0', n; END IF;

  -- 6. STILL FROZEN AND STILL PUBLISHING NOTHING. This migration must not have served anybody.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'page_block_extents_no_ticket_833049') THEN
    RAISE EXCEPTION 'VERIFY 6a: the freeze constraint was dropped';
  END IF;
  SELECT count(*) INTO n FROM derm.page_block_extents WHERE dump_folder = 'ticket-833049';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 6b: an extent appeared'; END IF;
  SELECT count(*) INTO n FROM derm.redacted_manifest_docs
   WHERE manifest_id IN (SELECT matched_manifest_id FROM derm.address_row_map
                          WHERE dump_folder = 'ticket-833049' AND matched_manifest_id IS NOT NULL);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 6c: % document(s) were published', n; END IF;

  -- 7. The 10-client backlog is still VISIBLE. The dirty trigger clears `completed`, which drops the
  --    folder off v_blackout_completed_unpublished; it must still be reported by the other watchlist
  --    or the backlog becomes invisible.
  IF (SELECT completed FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-833049') IS NOT FALSE THEN
    RAISE EXCEPTION 'VERIFY 7a: the sheet is still marked completed; the dirty trigger did not fire';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.v_blackout_blocked_sheets WHERE dump_folder = 'ticket-833049') THEN
    RAISE EXCEPTION 'VERIFY 7b: the folder is no longer on any worklist - the backlog just went invisible';
  END IF;

  -- 8. No new placement-health finding.
  SELECT count(*) INTO n FROM derm.v_stamp_placement_health WHERE dump_folder = 'ticket-833049';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 8: the folder now reports a placement-health finding'; END IF;

  RAISE NOTICE 'VERIFY ok: ticket-833049 transposition corrected 10/10 against the paper, still frozen, still 0 documents';
END $do$;

COMMIT;

-- ---------------------------------------------------------------------------
-- ROLLBACK (exact; valid while 0 documents are served)
-- BEGIN;
-- UPDATE derm.address_row_map r SET stamp_page = 3 - r.stamp_page,
--        stamp_image_url = 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1710/address_1.jpg'
--  WHERE r.dump_folder = 'ticket-833049' AND r.stamp_page IN (1,2);                     -- 10 rows
-- UPDATE derm.address_sheet_scan_reads SET page = 3
--  WHERE dump_folder = 'ticket-833049' AND page = 2;                                    -- 1 row
-- INSERT INTO derm.address_sheet_scan_reads
--   (dump_folder, page, sheet_no_read, raw_read, confidence, model, image_url, read_at)
-- VALUES ('ticket-833049', 2, '338', '338', 'high', 'claude-sonnet-5',
--         'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1710/address_1.jpg',
--         now());
-- UPDATE derm.address_row_map SET page = 2 WHERE dump_folder = 'ticket-833049' AND id = 972;  -- 1 row
-- COMMIT;
-- ---------------------------------------------------------------------------
