-- ============================================================================================
-- 2026-09-09_2000_add_mila_bar_lounge_card_834986.sql
--
-- Give 043-MIL its SECOND card on ticket-834986, for GDO-14117 "Bar & Lounge", and drop it into
-- the printed slot that has been standing empty for it.
--
-- WHY (Fred, 2026-09-09): "But we're missing the Card for Mila Bar/Lounge."
--
-- He is right. 2026-09-09_1400 bound the existing card to GDO-11024 and DELIBERATELY stopped there,
-- on the grounds that creating the second card means choosing a `page` and that is an operator
-- decision. **That reason has been measured away and no longer holds**, so this migration finishes
-- the job. What changed: Fred has since drawn the page-2 slots by hand, which makes the target
-- unambiguous.
--
-- ============================================================================================
-- THE MEASUREMENT THAT MAKES THIS SAFE, AND IT IS THE SLOTS THAT PROVIDE IT.
--
-- derm.page_slots for (ticket-834986, effective_page 2), source human-v1-2026-09-09:
--       slot 1   25.673 - 33.706   043-MIL "Restaurant"  (card 2915, y 29.690)
--       slot 2   33.706 - 40.535   ** NOBODY **
--       slot 3   40.535 - 47.765   239-COM               (card 2914, y 43.815)
--       slot 4   47.765 - 55.698   168-AVA               (card 2911, y 51.732)
--       slot 5   55.698 - 63.430   017-FIA               (card 2909, y 59.564)
--
-- and derm.v_sheet_printed_rows for sheet 149 (sheet_no 1111) says why slot 2 is empty:
--       printed_row 6  printed_page 2  043-MIL  is_first_row = true
--       printed_row 7  printed_page 2  043-MIL  is_first_row = false
--       printed_row 8  printed_page 2  239-COM
--
-- 🛑 SO PRINTED ROW 7 IS PRINTED-BUT-UNROWED, WHICH IS A LEAK SHAPE, NOT A COSMETIC GAP. It is the
-- ticket-310590 p2 condition that became a real exposure on 2026-08-19. It is inert TODAY only
-- because this folder publishes nothing (0 redacted documents, completed = false), and because the
-- neighbouring bands are snapped so the strip currently belongs to nobody and is blacked for
-- everyone. The moment the sheet is completed it stops being inert.
--
-- ============================================================================================
-- HOW, AND WHY THE SANCTIONED RPCs RATHER THAN AN INSERT.
--
--   derm.add_extra_client_card('ticket-834986', 298, 1)   -> creates the card, binds the next
--                                                            unclaimed ACTIVE permit
--   derm.assign_card_to_slot(<new id>, 2, 2)              -> places the stamp AND writes the band
--                                                            from the slot, in that order
--
-- ⚠ THE ORDER INSIDE assign_card_to_slot IS LOAD-BEARING and is why it is used instead of two
-- writes: derm.set_row_band refuses a band on a row with no stamp point, because
-- derm.v_stamp_row_bands is built WHERE stamp_y_pct IS NOT NULL, so a banded-but-unstamped row
-- drops out of it and freezes EVERY document in the folder through the closed-world gate. That is
-- ticket-828604.
--
-- ⚠ AND A NEW CARD MUST NOT BE LEFT UNSTAMPED for the same reason. Both statements run here, in one
-- transaction, so the folder is never observable in the half-added state.
--
-- ============================================================================================
-- WHY p_page = 1 AND NOT 2, WHICH IS THE ONE JUDGEMENT CALL IN THIS FILE.
--
-- `page` is the OCR page and feeds derm.ticket_page_images; `stamp_page` is the scan the stamp is
-- drawn on, and effective_page = COALESCE(stamp_page, page) is what fn_blackout_targets indexes
-- imgs[] with. All eight existing cards on this folder carry page = 1, including 043-MIL's own
-- Restaurant card, which Fred placed himself.
--
-- BOTH VALUES WERE PROBED AGAINST LIVE PROD IN ROLLED-BACK TRANSACTIONS BEFORE CHOOSING, because
-- the app's own path passes the operator's current page tab as p_page, so p_page = 2 is reachable
-- by clicking and had to be shown safe rather than assumed unsafe:
--
--   p_page = 2 -> page 2, image_url address_2.jpg, ticket_page_images IDENTICAL,
--                 trg_zz_page_image_injective PASSES (1 -> address_1, 2 -> address_2)
--   p_page = 1 -> page 1, image_url address_1.jpg, ticket_page_images IDENTICAL,
--                 check_page_geometry(p2) CLEAN, v_blackout_blocked_sheets NOT BLOCKED
--
-- Neither corrupts the page map. **1 is chosen only for consistency with the sibling card and the
-- other seven**, not because 2 is dangerous. Recorded so nobody later "fixes" a page-2 card that
-- the app legitimately created.
--
-- ⚠ Note what does NOT happen: derm.trg_ab_autoplace_generated does not fire on this card. Measured
-- in the probe, the card comes back with stamp_placed_at NULL and no band, so the documented trap
-- of autoplace resolving the client's FIRST printed row and stacking the second permit on top of
-- the first one's row is not reachable here. assign_card_to_slot is what places it.
--
-- RULE 8: no schema change. derm.address_row_map is audit-triggered, so both writes are captured.
-- ============================================================================================

BEGIN;

-- Snapshot every OTHER card, so "nothing else moved" is measured rather than claimed.
CREATE TEMP TABLE _cards_before ON COMMIT DROP AS
  SELECT id, page, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, gdo_id,
         band_y0_pct, band_y1_pct, slot_index, image_url
    FROM derm.address_row_map
   WHERE dump_folder = 'ticket-834986';

CREATE TEMP TABLE _imgs_before ON COMMIT DROP AS
  SELECT derm.ticket_page_images('834986') AS imgs;

-- ============================================================================================
-- PART 0. PRECONDITIONS.
-- ============================================================================================
DO $pre$
DECLARE v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-834986';
  IF v_n <> 8 THEN
    RAISE EXCEPTION 'PRE 0.1: folder holds % cards, expected the 8 this file was written against', v_n;
  END IF;

  -- 043-MIL holds exactly one card, and it is bound to GDO-11024 (2026-09-09_1400).
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-834986' AND matched_client_id = 298;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'PRE 0.2: 043-MIL holds % cards, expected exactly 1', v_n;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map r JOIN public.gdos g ON g.id = r.gdo_id
                  WHERE r.id = 2915 AND g.gdo_number = 'GDO-11024') THEN
    RAISE EXCEPTION 'PRE 0.3: card 2915 is not bound to GDO-11024; run 2026-09-09_1400 first';
  END IF;

  -- The permit we are about to hand out is ACTIVE, Mila's, and unclaimed on this folder.
  IF NOT EXISTS (SELECT 1 FROM public.gdos
                  WHERE id = 156 AND client_id = 298 AND status = 'ACTIVE'
                    AND gdo_number = 'GDO-14117') THEN
    RAISE EXCEPTION 'PRE 0.4: gdo 156 is not Mila''s ACTIVE GDO-14117';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map
              WHERE dump_folder = 'ticket-834986' AND gdo_id = 156) THEN
    RAISE EXCEPTION 'PRE 0.5: GDO-14117 is already claimed by a card on this folder';
  END IF;

  -- The sheet really prints two Mila rows, both on printed page 2.
  SELECT count(*) INTO v_n FROM derm.v_sheet_printed_rows
   WHERE sheet_id = 149 AND client_id = 298 AND printed_page = 2;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'PRE 0.6: sheet 1111 prints % 043-MIL row(s) on printed page 2, expected 2', v_n;
  END IF;

  -- Slot 2 exists on effective_page 2 and NOBODY is in it. This is the whole target.
  IF NOT EXISTS (SELECT 1 FROM derm.page_slots
                  WHERE dump_folder = 'ticket-834986' AND effective_page = 2 AND slot_index = 2
                    AND y0_pct = 33.706 AND y1_pct = 40.535) THEN
    RAISE EXCEPTION 'PRE 0.7: page-2 slot 2 is not the 33.706-40.535 slot this file targets';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map
              WHERE dump_folder = 'ticket-834986'
                AND COALESCE(stamp_page, page) = 2 AND slot_index = 2) THEN
    RAISE EXCEPTION 'PRE 0.8: page-2 slot 2 is already claimed';
  END IF;

  -- Nothing is served and the sheet is not complete, so this cannot change what a client sees.
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
   WHERE d.manifest_id IN (SELECT matched_manifest_id FROM derm.address_row_map
                            WHERE dump_folder = 'ticket-834986' AND matched_manifest_id IS NOT NULL);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 0.9: % document(s) are already served from this folder', v_n;
  END IF;
  IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status
              WHERE dump_folder = 'ticket-834986' AND completed IS TRUE) THEN
    RAISE EXCEPTION 'PRE 0.10: the sheet is marked completed; a person should be looking at this';
  END IF;

  RAISE NOTICE 'PRE OK: 8 cards, one 043-MIL card bound to GDO-11024, GDO-14117 unclaimed, two '
               'printed Mila rows on page 2, page-2 slot 2 empty, 0 documents served.';
END
$pre$;

-- ============================================================================================
-- THE CHANGE. Two sanctioned RPC calls, one transaction.
-- ============================================================================================
DO $do$
DECLARE v_new bigint;
BEGIN
  v_new := derm.add_extra_client_card('ticket-834986', 298, 1);
  IF v_new IS NULL THEN
    RAISE EXCEPTION 'add_extra_client_card returned NULL';
  END IF;
  PERFORM derm.assign_card_to_slot(v_new, 2, 2);
  RAISE NOTICE 'created card % and assigned it to page-2 slot 2', v_new;
END
$do$;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_n    int;
  v_r    record;
  v_v    text;
  v_imgs text[];
BEGIN
  ------------------------------------------------------------------------------------------
  -- 1. EXACTLY ONE CARD ADDED, AND NOT ONE EXISTING CARD MOVED.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-834986';
  IF v_n <> 9 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: folder holds % cards, expected 9', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM (
    (SELECT * FROM _cards_before
     EXCEPT
     SELECT id, page, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, gdo_id,
            band_y0_pct, band_y1_pct, slot_index, image_url
       FROM derm.address_row_map WHERE dump_folder = 'ticket-834986')) x;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % pre-existing card(s) changed', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 2. THE NEW CARD IS EXACTLY WHAT WAS INTENDED. Named field by field, because a card that
  --    merely EXISTS is not the point: a card on the wrong page or the wrong row is the defect
  --    this migration is preventing.
  ------------------------------------------------------------------------------------------
  SELECT r.id, r.page, r.stamp_page, COALESCE(r.stamp_page, r.page) AS eff, r.stamp_y_pct,
         r.stamp_x_pct, (r.stamp_placed_at IS NOT NULL) AS placed, r.gdo_id,
         r.band_y0_pct AS b0, r.band_y1_pct AS b1, r.slot_index, r.image_url, r.stamp_image_url
    INTO v_r
    FROM derm.address_row_map r
   WHERE r.dump_folder = 'ticket-834986' AND r.gdo_id = 156;
  IF v_r.id IS NULL THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: no card carries GDO-14117';
  END IF;
  IF v_r.page <> 1 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: page is %, expected 1 (matching all eight siblings)', v_r.page;
  END IF;
  IF v_r.stamp_page <> 2 OR v_r.eff <> 2 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: stamp_page % / effective_page %, expected 2 / 2',
      v_r.stamp_page, v_r.eff;
  END IF;
  IF NOT v_r.placed THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the card is unstamped, which freezes the whole folder';
  END IF;
  IF v_r.slot_index <> 2 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: slot_index is %, expected 2', v_r.slot_index;
  END IF;
  IF v_r.b0 <> 33.706 OR v_r.b1 <> 40.535 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: band is [%,%], expected the slot [33.706,40.535]', v_r.b0, v_r.b1;
  END IF;
  IF NOT (v_r.stamp_y_pct > v_r.b0 AND v_r.stamp_y_pct < v_r.b1) THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: stamp y % is not strictly inside its own band [%,%]',
      v_r.stamp_y_pct, v_r.b0, v_r.b1;
  END IF;
  -- The witness must name the scan the stamp is actually on, or fn_reconcile_stamp_pages cannot
  -- repair this card if a page is ever deleted.
  IF v_r.stamp_image_url IS NULL OR v_r.stamp_image_url NOT LIKE '%address_2.jpg' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: stamp_image_url is %, expected the page-2 scan',
      COALESCE(v_r.stamp_image_url, '<null>');
  END IF;
  IF v_r.image_url NOT LIKE '%address_1.jpg' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: image_url is %, expected address_1.jpg like its siblings',
      v_r.image_url;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 3. THE PAGE MAP DID NOT MOVE. A card insert that changes ticket_page_images re-points every
  --    later ordinal at a different scan: the ticket-833049 / ticket-834742 defect.
  ------------------------------------------------------------------------------------------
  v_imgs := derm.ticket_page_images('834986');
  IF v_imgs IS DISTINCT FROM (SELECT imgs FROM _imgs_before) THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: ticket_page_images changed to %', v_imgs;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 4. THE PAGE STILL PASSES ITS OWN GEOMETRY GUARDS, and G14 in particular. G14 counts the
  --    client's printed rows and divides by the cards it holds on the page, so an UNDER-carded
  --    client is exactly what it refuses. Adding the card is what satisfies it.
  ------------------------------------------------------------------------------------------
  SELECT string_agg(code, ' | ') INTO v_v
    FROM derm.check_page_geometry('ticket-834986', 2,
      (SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', r.band_y0_pct, 'y1', r.band_y1_pct))
         FROM derm.address_row_map r
        WHERE r.dump_folder = 'ticket-834986'
          AND COALESCE(r.stamp_page, r.page) = 2 AND r.band_y0_pct IS NOT NULL),
      25.673, 63.430);
  IF v_v IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: check_page_geometry(p2) reports %', v_v;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 5. NO PRINTED SLOT ON PAGE 2 IS LEFT UNOWNED BY A STAMP. This is the leak-shape check and
  --    it is the reason the migration exists.
  --    ⚠ It is keyed on a stamp falling inside the slot, NOT on slot_index, because card 2914
  --    (239-COM) carries the correct band for slot 3 with a NULL slot_index: it was placed by
  --    dragging before the slots existed, not through assign_card_to_slot. Keying on slot_index
  --    would report a false unowned slot and fail this migration for a state it did not create.
  ------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_n
    FROM derm.page_slots ps
   WHERE ps.dump_folder = 'ticket-834986' AND ps.effective_page = 2
     AND NOT EXISTS (
       SELECT 1 FROM derm.address_row_map r
        WHERE r.dump_folder = ps.dump_folder
          AND COALESCE(r.stamp_page, r.page) = ps.effective_page
          AND r.stamp_y_pct >= ps.y0_pct AND r.stamp_y_pct < ps.y1_pct);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: % printed slot(s) on page 2 hold no stamp', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 6. THE FOLDER IS NO WORSE OFF. Still unblocked, still serving nothing, still not completed.
  ------------------------------------------------------------------------------------------
  SELECT string_agg(blocker, ',') INTO v_v
    FROM derm.v_blackout_blocked_sheets WHERE dump_folder = 'ticket-834986';
  IF v_v IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: the folder is now blocked by %', v_v;
  END IF;

  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
   WHERE d.manifest_id IN (SELECT matched_manifest_id FROM derm.address_row_map
                            WHERE dump_folder = 'ticket-834986' AND matched_manifest_id IS NOT NULL);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: % document(s) published', v_n;
  END IF;

  ------------------------------------------------------------------------------------------
  -- 7. THE DEFERRED PAGE-IMAGE INJECTIVITY GUARD. It fires at COMMIT, so a migration that never
  --    forces it can pass while the write is refused seconds later.
  ------------------------------------------------------------------------------------------
  SET CONSTRAINTS ALL IMMEDIATE;

  RAISE NOTICE 'ALL VERIFY PASSED: 043-MIL now holds two cards on ticket-834986, GDO-11024 in '
               'page-2 slot 1 and GDO-14117 in page-2 slot 2 (33.706-40.535). No existing card '
               'moved, the page map is byte-identical, page 2 has no unowned printed slot, and '
               'the folder is still unblocked and serving nothing.';
END
$verify$;

COMMIT;
