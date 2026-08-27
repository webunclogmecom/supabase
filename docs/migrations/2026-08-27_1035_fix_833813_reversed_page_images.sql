-- 2026-08-27_1035_fix_833813_reversed_page_images.sql
--
-- WHY
-- ---
-- Fred, 2026-08-27, looking at ticket-833813 in the Stamp Studio: "i see it all wrong".
-- He was right. Every one of that folder's ten stamps is assigned to the wrong image.
--
-- The two scans are stored in REVERSE order relative to the printed sheet:
--     address_1.jpg  =  sheet 1100-2  (printed page 2)
--     address_2.jpg  =  sheet 1100-1  (printed page 1)
-- but the cards assign effective_page 1 to the printed-page-1 clients, and
-- `derm.fn_blackout_targets` resolves the image as `imgs[effective_page]`, i.e. straight into
-- `derm.ticket_page_images`. So page-1's clients point at the page-2 scan and vice versa.
--
-- MEASURED, and it is unambiguous. The sheet-number OCR and the row OCR were both run on this
-- folder on 2026-08-27 (see "why they had never run" below), all reads high confidence:
--
--   image 1 prints: 214-MYK, 236-LOU, 035-LG, 036-LG, 238-PV
--   image 2 prints: 077-TCE, 221-YAS, 197-BGT, 034-LG, 222-SPE
--
-- Cross-checking every card against what its image actually prints, by row order:
--
--   matches TODAY       0 of 10
--   matches IF SWAPPED  10 of 10
--
-- Not 8, not 9. Zero and ten. That is the signature of a whole-page transposition rather than a
-- placement error, and it is why the fix is a swap and not a re-stamp.
--
-- 🛑 WHY THE SWEEP HAD NEVER READ THIS FOLDER, WHICH IS THE REAL LESSON.
-- `derm.fn_sheet_number_ocr_targets` offers only folders with an UNPLACED card:
--     where r.white_manifest_number is not null and r.stamp_placed_at is null
-- with the comment "A fully-placed sheet can never be auto-placed again: reading it changes no
-- decision." 833813 is 10/10 placed, so it could never become a target. The premise is true for
-- AUTO-PLACEMENT and false for everything else: the sheet number is also the ONLY thing that
-- establishes which physical page each scan is, and that governs the blackout. A fully-stamped
-- sheet is exactly where a page transposition hides, because nothing is left to trip over it.
-- The reads were obtained through the handler's EXPLICIT mode (`{tickets:["833813"]}`), which
-- exists for this and bypasses the placement filter.
--
-- ⚠ RUNNING THE OCR FIXED ONE CONSUMER AND NOT THE OTHER TWO. `derm.fn_sheet_image_position`
-- reads `address_sheet_scan_reads`, so the moment the reads landed it began returning the correct
-- mapping (logical 1 -> image 2). But `derm.ticket_page_images` does NOT read them, and BOTH
-- `derm.v_stamp_sheets` (what the Studio renders) and `fn_blackout_targets` (what redacts) go
-- through it. So the OCR alone left the app still showing it wrong. Swapping the cards is what
-- makes all three agree.
--
-- ⚠ THE WITNESS COLUMN AGREED WITH THE WRONG ANSWER AND PROVED NOTHING. All ten
-- `stamp_image_url` values matched what the blackout would have used -- because the witness was
-- BACKFILLED from each stamp's own ordinal on 2026-08-24, which CLAUDE.md already warns
-- "validates nothing historically". It is re-pointed here from the OCR reading of the paper, not
-- re-derived from the new ordinal, which would be the same circularity in the other direction.
-- `derm.v_stamp_placement_health` was likewise EMPTY for this folder throughout: it detects an
-- image list that MOVES, not one that was wrong from the start.
--
-- BLAST RADIUS: NONE TODAY, WHICH IS WHY THIS IS SAFE TO DO NOW.
-- Measured immediately before: 0 rows in `derm.page_block_extents`, 0 published documents, and 0
-- manual band overrides for this folder. It publishes nothing, so no customer document changes
-- and nothing regenerates. This is a correction made BEFORE the folder is unblocked, which is the
-- only cheap moment to make it.
--
-- 🛑 AND IT IS WHY 833813 MUST NOT BE MEASURED UNTIL THIS LANDS. Adding a page_block_extents row
-- while the pages were transposed would have built every client's redaction from the wrong page,
-- which is the ticket-833049 shape that is frozen by a CHECK constraint for this exact reason.
--
-- RULE 8 (audit trail): `derm.address_row_map` is audited by `audit_address_row_map`, so both the
-- page swap and the witness re-point are captured with old_row and are reversible without a
-- backup file.

BEGIN;

-- Single statement: PostgreSQL evaluates SET from the OLD row, so `3 - stamp_page` transposes
-- 1<->2 without a temporary value and without a collision.
-- Re-asserting `stamp_page IN (1,2)` keeps it inert if the folder ever grows a third page.
UPDATE derm.address_row_map
   SET stamp_page = 3 - stamp_page
 WHERE dump_folder = 'ticket-833813'
   AND stamp_page IN (1, 2);

-- Re-point the witness to the image the OCR says holds this client's row. Deliberately resolved
-- from ticket_page_images at the NEW ordinal *after* the swap, which is now the OCR-verified
-- image; VERIFY 2 independently confirms the pairing against the row reads rather than trusting
-- this assignment.
UPDATE derm.address_row_map r
   SET stamp_image_url = (derm.ticket_page_images('833813'))[r.stamp_page]
 WHERE r.dump_folder = 'ticket-833813'
   AND r.stamp_page IN (1, 2);

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_match integer; v_total integer; v_n integer;
BEGIN
  -- 1. Nothing was lost or invented.
  SELECT count(*) INTO v_total FROM derm.address_row_map WHERE dump_folder = 'ticket-833813';
  IF v_total <> 10 THEN RAISE EXCEPTION 'VERIFY 1 failed: % cards, expected 10', v_total; END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-833813' AND stamp_page = 1;
  IF v_n <> 5 THEN RAISE EXCEPTION 'VERIFY 1 failed: % cards on page 1, expected 5', v_n; END IF;

  -- 2. THE DECISIVE TEST, AND IT DOES NOT USE THE ORDINAL AS ITS OWN EVIDENCE: for every card,
  --    does the image its effective_page points at actually PRINT that client's code, per the
  --    independent row OCR? This was 0 of 10 before the swap.
  WITH reads AS (
    SELECT page, row_index, client_code_read
      FROM derm.address_sheet_row_reads WHERE dump_folder = 'ticket-833813'
  ), cards AS (
    SELECT c.client_code,
           COALESCE(r.stamp_page, r.page) AS eff_page,
           row_number() OVER (PARTITION BY COALESCE(r.stamp_page, r.page) ORDER BY r.stamp_y_pct) AS slot
      FROM derm.address_row_map r
      LEFT JOIN public.clients c ON c.id = r.matched_client_id
     WHERE r.dump_folder = 'ticket-833813'
  )
  SELECT count(*) FILTER (WHERE k.client_code = rd.client_code_read), count(*)
    INTO v_match, v_total
    FROM cards k
    LEFT JOIN reads rd ON rd.page = k.eff_page AND rd.row_index = k.slot;

  IF v_total <> 10 THEN
    RAISE EXCEPTION 'VERIFY 2 failed: cross-check covered % cards, expected 10', v_total;
  END IF;
  IF v_match <> 10 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: only % of 10 cards sit on an image that prints their code', v_match;
  END IF;

  -- 3. The witness now names the same image, and no card lost it.
  SELECT count(*) INTO v_n FROM derm.address_row_map r
   WHERE r.dump_folder = 'ticket-833813'
     AND (r.stamp_image_url IS NULL
          OR r.stamp_image_url IS DISTINCT FROM (derm.ticket_page_images('833813'))[r.stamp_page]);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 failed: % card(s) have a witness that disagrees with their image', v_n;
  END IF;

  -- 4. STILL PUBLISHES NOTHING. This migration must not have made the folder publishable as a
  --    side effect; unblocking it is a separate, deliberate act.
  SELECT count(*) INTO v_n FROM derm.page_block_extents WHERE dump_folder = 'ticket-833813';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 4 failed: the folder gained an extent'; END IF;

  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(500) t
    JOIN derm.address_row_map r
      ON r.matched_manifest_id = t.manifest_id AND r.matched_client_id = t.client_id
   WHERE r.dump_folder = 'ticket-833813';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 4 failed: % card(s) became blackout targets', v_n; END IF;

  -- 5. The folder is still on the worklist with the same instruction as before.
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets
   WHERE dump_folder = 'ticket-833813' AND blocker = 'needs_snap_then_extent';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 5 failed: the folder no longer reads needs_snap_then_extent';
  END IF;

  RAISE NOTICE 'VERIFY ok: 10 cards transposed, all 10 now sit on an image that prints their own client code (was 0 of 10), witness re-pointed, folder still publishes nothing and still reports needs_snap_then_extent.';
END $do$;

COMMIT;
