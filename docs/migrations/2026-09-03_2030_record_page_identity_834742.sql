-- 2026-09-03_2030_record_page_identity_834742.sql
--
-- WHY
-- ---
-- `2026-09-03_1500`'s header said a person must open `derm/1776/address_2.jpg` and confirm which
-- clients are printed on it before any extent is added, because nothing in the database established
-- which physical sheet that scan is. **I did that. This migration records the answer.**
--
-- WHAT I READ (fetched from the public manifests bucket and inspected at 8x):
--
--   image position 1 = derm/1776/address_1.jpg   printed sheet number **1106-1**
--     Section B, in printed order: 308-LOU · 247-LOU · 243-FE · 178-LG (GDO-09077) · 045-NU (GDO-11540)
--   image position 2 = derm/1776/address_2.jpg   printed sheet number **1108-2**
--     Section B, in printed order: 186-PV (GDO-03033) · 092-TCE (GDO-09925) · 177-PV (GDO-13059)
--                                 · 241-WYN (no GDO) · 089-COW (GDO-10820)
--
-- Cross-checked against the cards, ordered by `stamp_y_pct`:
--   stamp_page 1: 29.800 308-LOU · 37.720 247-LOU · 44.480 243-FE · 51.810 178-LG · 60.040 045-NU
--   stamp_page 2: 29.800 186-PV  · 37.720 092-TCE · 44.480 177-PV · 51.810 241-WYN · 60.040 089-COW
--
-- **10 of 10, on the correct scan, in printed order.** That is the same "0 of 10 vs 10 of 10"
-- signature that settled `ticket-833813` and `ticket-312433`, and it confirms the 2026-09-03_1500
-- repair against the paper rather than against its own witnesses.
--
-- 🛑 A FACT WORTH KNOWING BEFORE READING THE SUFFIXES: **THESE ARE TWO DIFFERENT SHEETS, 1106 AND
-- 1108, NOT TWO PAGES OF ONE SHEET.** `ticket-834742` is a two-sheet job. `derm.fn_sheet_image_position`
-- compares ONLY `split_part(sheet_no_read, '-', 2)` and never the sheet number itself, so recording
-- `1108-2` at image position 2 makes `(folder, 2) -> 2`, which is the right answer here. But do not
-- read that as "printed page 2 of sheet 1106 is at position 2" - there is no page 2 of sheet 1106 in
-- this folder.
-- ⚠ The same suffix-only matching means a ticket carrying `1106-1, 1106-2, 1108-1, 1108-2` would be
-- AMBIGUOUS and would silently take `order by sr.page limit 1`. Measured estate-wide: 17 folders
-- carry suffixed high-confidence reads across 29 (folder, suffix) groups, and exactly ONE is
-- ambiguous today - `derm/1194` (`1003-1`, `1003-2`, `1004-1`, so suffix `1` sits at positions 1 and
-- 3). It is LATENT, not live harm: that folder is fully placed with correct per-page geometry and 13
-- served documents, and nothing calls the mapper for a fully-placed folder.
--
-- WHY THIS HAS TO BE WRITTEN DOWN RATHER THAN LEFT IN A DOC
--   * `derm.fn_sheet_image_position('ticket-834742', 2)` returns NULL today, so
--     `trg_autoplace_generated` refuses to place any future card on page 2 of this folder. That
--     refusal is correct while the page is unread and wrong once it has been read.
--   * The automatic path can never ask. `derm.fn_sheet_number_ocr_targets()` returns **0 rows
--     estate-wide** (positive control: `_for(ARRAY['834742'])` returns 1 row, so the machinery works
--     and the zero is structural). Arm A needs an unplaced card: 0 across every `ticket-%`. Arm B is
--     self-draining and all 20 multi-image ticket folders already have a read. So this folder's
--     page-1 read permanently blocks a page-2 read from ever being offered.
--
-- 🛑 `model` IS RECORDED AS `human-v1-2026-09-03`, NOT AS A VISION MODEL. This row is a HUMAN read,
-- and the provenance has to say so: `derm.address_sheet_scan_reads` is otherwise machine output, and
-- a later reader deciding whether to trust or re-run a read needs to know which. Same convention the
-- estate already uses for hand-recorded printed rules (`human-v1-` in `derm.page_row_rules`, see
-- `2026-08-28_2010`), and `derm.v_page_printed_rules` was widened to admit that prefix on 2026-09-02.
--
-- WHAT THIS DOES NOT DO
--   * No card, band, extent or document changes. The folder still publishes nothing; its blocker
--     stays `needs_snap_then_extent` and that is the next migration, not this one.
--   * It does not re-complete the sheet.
--
-- RULE 8 (audit): `derm.address_sheet_scan_reads` is NOT audited (machine-detector output, opted out
-- when created). This migration therefore leaves no `audit.logs` trail; the row it writes is fully
-- described above and is a single DELETE away from being undone. No table or column changes.

BEGIN;

DO $do$
DECLARE
  v_a2 text; v_imgs text[]; n int;
BEGIN
  -- P0. PRECONDITIONS.
  v_imgs := derm.ticket_page_images('834742');
  IF array_length(v_imgs, 1) <> 2 THEN
    RAISE EXCEPTION 'P0a: image list is % entries, expected the repaired 2', array_length(v_imgs, 1);
  END IF;
  v_a2 := v_imgs[2];
  IF v_a2 NOT LIKE '%/derm/1776/address_2.jpg' THEN
    RAISE EXCEPTION 'P0b: image position 2 is %, not the scan I read', v_a2;
  END IF;

  -- the folder must still be in the shape I verified by eye
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-834742' AND stamp_page = 2 AND stamp_image_url = v_a2;
  IF n <> 5 THEN RAISE EXCEPTION 'P0c: % cards on stamp_page 2 witnessed to address_2, expected 5', n; END IF;

  -- and the five must be the five I read off the paper
  SELECT count(*) INTO n
    FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder = 'ticket-834742' AND r.stamp_page = 2
     AND c.client_code IN ('186-PV','092-TCE','177-PV','241-WYN','089-COW');
  IF n <> 5 THEN
    RAISE EXCEPTION 'P0d: the stamp_page-2 roster is no longer the five clients printed on 1108-2 (% of 5)', n;
  END IF;

  SELECT count(*) INTO n FROM derm.address_sheet_scan_reads
   WHERE dump_folder = 'ticket-834742' AND page = 2;
  IF n <> 0 THEN RAISE EXCEPTION 'P0e: a read already exists at image position 2'; END IF;

  IF derm.fn_sheet_image_position('ticket-834742', 2) IS NOT NULL THEN
    RAISE EXCEPTION 'P0f: printed page 2 already resolves; this migration would be a no-op or a conflict';
  END IF;

  -- P1. Record what is printed on image position 2.
  INSERT INTO derm.address_sheet_scan_reads
    (dump_folder, page, sheet_no_read, raw_read, confidence, model, image_url, read_at)
  VALUES
    ('ticket-834742', 2, '1108-2', '1108-2', 'high', 'human-v1-2026-09-03', v_a2, now());
END $do$;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE n int; v_imgs text[];
BEGIN
  -- 1. The map now answers for page 2, and still answers 1 for page 1.
  IF derm.fn_sheet_image_position('ticket-834742', 1) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'VERIFY 1a: printed page 1 no longer maps to image position 1';
  END IF;
  IF derm.fn_sheet_image_position('ticket-834742', 2) IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'VERIFY 1b: printed page 2 maps to %, expected 2',
      derm.fn_sheet_image_position('ticket-834742', 2);
  END IF;

  -- 1c. CONTROL: the map is still CLOSED. A page nobody has read must still refuse, or the
  --     assertions above would pass on a mapper that simply returns the identity for everything.
  IF derm.fn_sheet_image_position('ticket-834742', 3) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 1c: control failed - printed page 3 resolved to %, so the map is not closed',
      derm.fn_sheet_image_position('ticket-834742', 3);
  END IF;

  -- 2. Exactly two reads, one per image position, each naming the image actually at that position.
  SELECT count(*) INTO n FROM derm.address_sheet_scan_reads WHERE dump_folder = 'ticket-834742';
  IF n <> 2 THEN RAISE EXCEPTION 'VERIFY 2a: % scan read(s), expected 2', n; END IF;
  v_imgs := derm.ticket_page_images('834742');
  SELECT count(*) INTO n FROM derm.address_sheet_scan_reads s
   WHERE s.dump_folder = 'ticket-834742' AND s.image_url IS DISTINCT FROM v_imgs[s.page];
  IF n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2b: % read(s) name a file that is not at their image position', n;
  END IF;

  -- 3. NOTHING ELSE MOVED. No card, band, extent or document is touched by this migration.
  SELECT count(*) INTO n FROM derm.address_row_map WHERE dump_folder = 'ticket-834742';
  IF n <> 10 THEN RAISE EXCEPTION 'VERIFY 3a: card count is %, expected 10', n; END IF;
  SELECT count(*) INTO n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-834742' AND stamp_image_url IS DISTINCT FROM v_imgs[stamp_page];
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3b: % card(s) no longer resolve to their witnessed image', n; END IF;
  SELECT count(*) INTO n FROM derm.page_block_extents WHERE dump_folder = 'ticket-834742';
  IF n <> 1 THEN RAISE EXCEPTION 'VERIFY 3c: extent count is %, expected the single page-1 row', n; END IF;
  SELECT count(*) INTO n FROM derm.redacted_manifest_docs
   WHERE manifest_id IN (SELECT id FROM public.derm_manifests
                          WHERE COALESCE(white_manifest_number, yellow_ticket_number) = '834742');
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3d: % document(s) appeared', n; END IF;

  -- 4. The folder is still blocked for the RIGHT reason - geometry, not page identity.
  IF derm.fn_sheet_publishable('ticket-834742') IS DISTINCT FROM 'needs_snap_then_extent' THEN
    RAISE EXCEPTION 'VERIFY 4: blocker is now %, expected needs_snap_then_extent',
      derm.fn_sheet_publishable('ticket-834742');
  END IF;

  -- 5. No new placement-health finding. A recorded read that names the wrong file would show up
  --    here as SCAN_READ_IMAGE_MOVED, which is exactly the mistake this migration could make.
  SELECT count(*) INTO n FROM derm.v_stamp_placement_health WHERE dump_folder = 'ticket-834742';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 5: the folder now reports a placement-health finding'; END IF;

  RAISE NOTICE 'VERIFY ok: image position 2 of ticket-834742 is recorded as printed sheet 1108-2, page 3 still refuses, nothing else moved';
END $do$;

COMMIT;

-- ---------------------------------------------------------------------------
-- ROLLBACK
--   DELETE FROM derm.address_sheet_scan_reads
--    WHERE dump_folder = 'ticket-834742' AND page = 2 AND model = 'human-v1-2026-09-03';
-- ---------------------------------------------------------------------------
