-- ============================================================================================
-- 2026-09-09_1400_bind_mila_card_to_its_permit.sql
--
-- Bind ticket-834986's 043-MIL card to GDO-11024, so its SECOND permit can be carded.
--
-- WHY (Fred, 2026-09-09): "i only see one 043-MIL card to stamp, but as it Mila have 2 GDO's
-- meaning it should have 2, and with it's nickname of the Restaurant and Bar/Lounge the other one."
--
-- He is right, and the paper agrees. Read off the scan (derm/1840/address_2.jpg), which is
-- generated sheet **1111-2**, "Page 2 of 2":
--       GDO-11024   043-MIL Mila - Restaurant      1636 Meridian Avenue
--       GDO-14117   043-MIL Mila - Bar / Lounge    1636 Meridian Avenue
--       GDO-07617   239-COM Courtyard by Marriott SOBE
-- and the database already knows it: derm.address_sheet_clients for sheet 149 (sheet_no 1111)
-- carries 043-MIL at slot 6 with **rows_printed = 2**, which derm.v_sheet_printed_rows expands to
-- printed rows 6 and 7, both on printed page 2. The folder holds ONE card.
--
-- 🛑 A CLIENT UNDER-CARDED ON A GENERATED SHEET IS A LEAK SHAPE, NOT A COSMETIC GAP. Row 7 is
-- printed-but-unrowed: no card owns it, so no band covers it, and it is exactly what turned
-- ticket-310590 p2 into a real exposure on 2026-08-19. It is inert TODAY only because this folder
-- publishes nothing (0 redacted documents, completed = false).
--
-- ============================================================================================
-- WHY IT COULD NOT BE FIXED FROM THE STUDIO, AND WHY THAT REFUSAL IS CORRECT.
-- derm.add_extra_client_card refuses outright while any of the client's cards on the sheet has a
-- NULL gdo_id, and says so: it selects "the next ACTIVE permit not already claimed by a card on
-- this sheet", so with an unbound card it cannot tell which permit is taken and would hand out the
-- FIRST one twice. Fail-closed and right. The fix is to bind, not to relax the guard.
--
-- WHICH PERMIT. Both the printed order and the function's own tie-break agree, which is the whole
-- reason this is a safe automatic answer rather than a judgement call:
--       printed row 6 (is_first_row)  = GDO-11024 "Restaurant"
--       printed row 7                 = GDO-14117 "Bar & Lounge"
--       add_extra_client_card         = ... ORDER BY g.gdo_number LIMIT 1  -> 11024 before 14117
-- So the existing card takes GDO-11024 and the next card will take GDO-14117 by construction.
-- VERIFY 3 proves that second half rather than assuming it.
--
-- ⚠ THIS MIGRATION DELIBERATELY DOES NOT CREATE THE SECOND CARD. Creating it means choosing a
-- `page`, and all eight cards in this folder currently sit on page 1 while Mila is printed on
-- image 2. `page` is the OCR page and feeds derm.ticket_page_images; `stamp_page` is where the
-- stamp goes. Getting that wrong is the ticket-833049 / ticket-834742 defect. The operator adds
-- the card from the Studio, on the page they are looking at, and stamps it in the same gesture.
--
-- RULE 8: no schema change. derm.address_row_map is audit-triggered, so this write is captured.
-- ============================================================================================

BEGIN;

-- ============================================================================================
-- PART 0. PRECONDITIONS.
-- ============================================================================================
DO $pre$
DECLARE v_n int; v_img text[];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map
                  WHERE id = 2915 AND dump_folder = 'ticket-834986'
                    AND matched_client_id = 298 AND gdo_id IS NULL
                    AND stamp_placed_at IS NULL) THEN
    RAISE EXCEPTION 'PRE 0.1: card 2915 is not the unbound, unplaced 043-MIL card this migration '
                    'was written against';
  END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-834986' AND matched_client_id = 298;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'PRE 0.2: 043-MIL holds % cards on this folder, expected exactly 1', v_n;
  END IF;

  -- The permit must be ACTIVE, Mila's, and not already claimed on this folder.
  IF NOT EXISTS (SELECT 1 FROM public.gdos
                  WHERE id = 230 AND client_id = 298 AND status = 'ACTIVE'
                    AND gdo_number = 'GDO-11024') THEN
    RAISE EXCEPTION 'PRE 0.3: gdo 230 is not Mila''s ACTIVE GDO-11024';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map
              WHERE dump_folder = 'ticket-834986' AND gdo_id = 230) THEN
    RAISE EXCEPTION 'PRE 0.4: GDO-11024 is already claimed by a card on this folder';
  END IF;

  -- The sheet really does print two Mila rows.
  SELECT count(*) INTO v_n FROM derm.v_sheet_printed_rows
   WHERE sheet_id = 149 AND client_id = 298;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'PRE 0.5: sheet 1111 prints % row(s) for 043-MIL, expected 2', v_n;
  END IF;

  -- Nothing is served from this folder, so this cannot change what a client sees.
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
   WHERE d.manifest_id IN (SELECT matched_manifest_id FROM derm.address_row_map
                            WHERE dump_folder = 'ticket-834986' AND matched_manifest_id IS NOT NULL);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PRE 0.6: % document(s) are already served from this folder', v_n;
  END IF;

  RAISE NOTICE 'PRE OK: one unbound unplaced 043-MIL card, GDO-11024 unclaimed, sheet prints 2 '
               'Mila rows, 0 documents served.';
END
$pre$;

-- ============================================================================================
-- THE CHANGE. One column on one row.
-- ============================================================================================
UPDATE derm.address_row_map
   SET gdo_id = 230
 WHERE id = 2915 AND dump_folder = 'ticket-834986' AND matched_client_id = 298
   AND gdo_id IS NULL;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_n     int;
  v_new   bigint;
  v_gdo   bigint;
  v_imgs  text[];
BEGIN
  -- 1. The binding landed, and NOTHING else on that row moved.
  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map
                  WHERE id = 2915 AND gdo_id = 230 AND page = 1 AND stamp_page IS NULL
                    AND stamp_placed_at IS NULL AND band_y0_pct IS NULL AND band_y1_pct IS NULL
                    AND image_url LIKE '%address_1.jpg') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: card 2915 is not bound-and-otherwise-unchanged';
  END IF;

  -- 2. The page map did not move. A card insert or a page change here is the 833049 defect.
  v_imgs := derm.ticket_page_images('834986');
  IF array_length(v_imgs,1) <> 2 OR v_imgs[1] = v_imgs[2] THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: ticket_page_images is now %', v_imgs;
  END IF;
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder='ticket-834986';
  IF v_n <> 8 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the folder now holds % cards, expected the same 8', v_n;
  END IF;

  -- 3. THE POINT OF THE WHOLE MIGRATION: adding the second card is now possible, and it takes
  --    GDO-14117. Exercised for real in a rolled-back savepoint, because "it should work now" is
  --    a claim and this is the one thing the operator is blocked on.
  BEGIN
    v_new := derm.add_extra_client_card('ticket-834986', 298, 1);
    SELECT gdo_id INTO v_gdo FROM derm.address_row_map WHERE id = v_new;
    IF v_gdo IS NULL THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: the new card came out with no permit bound';
    END IF;
    IF v_gdo <> 156 THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: the new card took gdo % rather than 156 (GDO-14117)', v_gdo;
    END IF;
    RAISE EXCEPTION 'ROLLBACK_FIXTURE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_FIXTURE' THEN
      RAISE EXCEPTION 'VERIFY 3 FAILED: add_extra_client_card still refuses after the binding: %',
        SQLERRM;
    END IF;
  END;

  -- 3b. MUTATION CONTROL. With the binding removed the call must go back to REFUSING, or VERIFY 3
  --     proves only that the function works, not that the binding is what unblocked it.
  BEGIN
    UPDATE derm.address_row_map SET gdo_id = NULL WHERE id = 2915;
    BEGIN
      v_new := derm.add_extra_client_card('ticket-834986', 298, 1);
      RAISE EXCEPTION 'VERIFY 3b CONTROL FAILED: it succeeded with the card unbound, so the '
                      'binding is not what unblocked it';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE '%CONTROL FAILED%' THEN RAISE; END IF;
      IF SQLERRM NOT LIKE '%no gdo_id%' THEN
        RAISE EXCEPTION 'VERIFY 3b CONTROL FAILED: refused for the wrong reason: %', SQLERRM;
      END IF;
    END;
    RAISE EXCEPTION 'ROLLBACK_FIXTURE';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ROLLBACK_FIXTURE' THEN RAISE; END IF;
  END;

  -- 4. The fixtures left nothing behind and the binding survived them.
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder='ticket-834986';
  IF v_n <> 8 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: % cards remain, expected 8; a fixture card survived', v_n;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map WHERE id=2915 AND gdo_id=230) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: the binding did not survive the rolled-back controls';
  END IF;

  -- 5. Still unpublishable, still nothing served.
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
   WHERE d.manifest_id IN (SELECT matched_manifest_id FROM derm.address_row_map
                            WHERE dump_folder='ticket-834986' AND matched_manifest_id IS NOT NULL);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: % document(s) published', v_n; END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: card 2915 bound to GDO-11024, page map and card count unchanged, '
               'and add_extra_client_card now yields GDO-14117 (proven, and proven to refuse again '
               'when the binding is removed).';
END
$verify$;

COMMIT;
