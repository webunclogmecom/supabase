-- ============================================================================
-- 2026-10-18_1240_ticket_838130_one_stamp_per_permit
-- Sheet 1134 (ticket-838130): one stamp per GDO permit for 043-MIL Mila and 009-CN Casa Neos.
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18, "yes obviously", to: "should I redo 838130 with one stamp per permit for Mila and Casa Neos?
--   That reopens a completed sheet."
-- WHY (measured 2026-10-17/18)
--   A person completed the sheet on 2026-10-08 with ONE card each for 043-MIL (printed on 2 rows) and 009-CN (3 rows),
--   so Mila's Bar / Lounge row and Casa Neos' Kitchens and Lounge rows had no card: they were blacked out of the
--   clients' own documents, and the edge check graded both cards ODD_SLOT. The automatic per-permit cards
--   (derm.fn_ensure_permit_cards, 2026-10-17_0050) do not touch a completed sheet or a person's stamp, so this is a
--   HAND REPAIR of one sheet, said here as root CLAUDE.md section 7 asks; the rule itself is already in place.
-- READ ON THE PAPER (both scans, sheet-number reads 1134-1 / 1134-2 high):
--   page 1 row 4  GDO-11024  043-MIL Mila - Restaurant      existing card 3068 (person's stamp, slot 4)
--   page 1 row 5  GDO-14117  043-MIL Mila - Bar / Lounge    NEW
--   page 2 row 2  GDO-10877  009-CN Casa Neos - Kitchens    NEW
--   page 2 row 3  GDO-15062  009-CN Casa Neos - Bars        existing card 3064 (person's stamp, slot 3)
--   page 2 row 4  GDO-16389  009-CN Casa Neos - Lounge      NEW
-- HOW: the 2026-09-09_2000 pattern. Bind the two existing cards to the permit on their row; add each missing permit with
--   derm.add_extra_client_card (it binds the next unclaimed permit in printed order) and drop it into the row the person
--   drew on 2026-10-08 with derm.place_stamp_in_row (the Studio's own writer: band = the row, Limit from the rows, every
--   geometry guard). Then derm.set_sheet_completed (the same gate as a person's Mark completed; completed_by reads
--   'stamp-studio'). The blackout sweep remakes the clients' copies after it.
-- VERIFIED IN A ROLLED-BACK REHEARSAL: 10 cards, the other 5 clients' cards byte-identical, each permit on its row with
--   that row as its band, image list and Limits unchanged, every card ONE_CLIENT (2 were ODD_SLOT), publishable, completed.
-- Rule 8: no schema change; derm.address_row_map and derm.stamp_sheet_status are audited.
-- No rollback file: undoing it would put the clients' own rows back under the blackout. To revert, clear the three new
--   stamps in the Studio and set gdo_id back to NULL on cards 3068 and 3064.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE TEMP TABLE _cards_before ON COMMIT DROP AS
  SELECT id, page, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, gdo_id, band_y0_pct, band_y1_pct, slot_index, image_url
    FROM derm.address_row_map WHERE dump_folder = 'ticket-838130';
CREATE TEMP TABLE _misc_before ON COMMIT DROP AS
  SELECT to_jsonb(derm.ticket_page_images('838130')) AS imgs,
         (SELECT jsonb_agg(jsonb_build_object('p', effective_page, 't', top_pct, 'b', bottom_pct) ORDER BY effective_page)
            FROM derm.page_block_extents WHERE dump_folder = 'ticket-838130') AS ext,
         (SELECT count(*) FROM derm.v_band_edge_check WHERE dump_folder = 'ticket-838130' AND (edge_verdict IS DISTINCT FROM 'ON_RULE' OR slot_verdict IS DISTINCT FROM 'ONE_CLIENT')) AS edge_issues;

-- PRE: the state this file was written against (measured 2026-10-18)
DO $pre$ BEGIN
  IF (SELECT count(*) FROM derm.address_row_map WHERE dump_folder = 'ticket-838130') <> 7
     OR (SELECT count(*) FROM derm.address_row_map WHERE dump_folder = 'ticket-838130' AND matched_client_id IN (298, 369)) <> 2
     OR EXISTS (SELECT 1 FROM derm.address_row_map WHERE dump_folder = 'ticket-838130' AND gdo_id IS NOT NULL) THEN
    RAISE EXCEPTION 'PRE 1: the folder is not the 7-card, permit-less state this file was written against';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map WHERE id = 3068 AND matched_client_id = 298 AND stamp_page = 1 AND slot_index = 4)
     OR NOT EXISTS (SELECT 1 FROM derm.address_row_map WHERE id = 3064 AND matched_client_id = 369 AND stamp_page = 2 AND slot_index = 3) THEN
    RAISE EXCEPTION 'PRE 2: the two existing stamps are not on the rows read on the paper';
  END IF;
  IF (SELECT count(*) FROM derm.page_slots WHERE dump_folder = 'ticket-838130') <> 10
     OR EXISTS (SELECT 1 FROM derm.address_row_map WHERE dump_folder = 'ticket-838130'
                 AND ((coalesce(stamp_page, page) = 1 AND slot_index = 5) OR (coalesce(stamp_page, page) = 2 AND slot_index IN (2, 4)))) THEN
    RAISE EXCEPTION 'PRE 3: the drawn rows changed, or a target row is already taken';
  END IF;
  IF (SELECT count(*) FROM public.gdos WHERE id IN (230, 156) AND client_id = 298 AND status = 'ACTIVE') <> 2
     OR (SELECT count(*) FROM public.gdos WHERE id IN (63, 64, 65) AND client_id = 369 AND status = 'ACTIVE') <> 3 THEN
    RAISE EXCEPTION 'PRE 4: the permits are not the active ones printed on sheet 1134';
  END IF;
END $pre$;

-- THE CHANGE. Bind the two existing stamps to the permit printed on their row, then add one card per missing permit
-- and drop it into its drawn row through the Studio's own writer (row from the point, band = the row, Limit rewritten).
UPDATE derm.address_row_map SET gdo_id = 230 WHERE id = 3068;   -- p1 row 4 = GDO-11024 Mila - Restaurant
UPDATE derm.address_row_map SET gdo_id = 64  WHERE id = 3064;   -- p2 row 3 = GDO-15062 Casa Neos - Bars
DO $do$
DECLARE v_mil bigint; v_kit bigint; v_lou bigint;
BEGIN
  v_mil := derm.add_extra_client_card('ticket-838130', 298, 1);            -- next unclaimed: GDO-14117 Bar / Lounge
  PERFORM derm.place_stamp_in_row(v_mil, 1, 14.0, 58.736);                  -- p1 row 5 (54.825 - 62.646)
  v_kit := derm.add_extra_client_card('ticket-838130', 369, 1);            -- next unclaimed: GDO-10877 Kitchens
  PERFORM derm.place_stamp_in_row(v_kit, 2, 14.0, 34.291);                  -- p2 row 2 (30.659 - 37.922)
  v_lou := derm.add_extra_client_card('ticket-838130', 369, 1);            -- next unclaimed: GDO-16389 Lounge
  PERFORM derm.place_stamp_in_row(v_lou, 2, 14.0, 49.465);                  -- p2 row 4 (45.411 - 53.519)
END $do$;
-- complete it again through the same gate a person's Mark completed goes through (it was completed on 2026-10-08)
SELECT derm.set_sheet_completed('ticket-838130', true);

DO $v$
DECLARE v_cards jsonb;
BEGIN
  -- 1. ten cards, and the five other clients' cards untouched
  IF (SELECT count(*) FROM derm.address_row_map WHERE dump_folder = 'ticket-838130') <> 10 THEN RAISE EXCEPTION 'VERIFY 1a: card count'; END IF;
  IF EXISTS (SELECT b.* FROM _cards_before b WHERE b.id NOT IN (3068, 3064)
             EXCEPT SELECT id, page, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, gdo_id, band_y0_pct, band_y1_pct, slot_index, image_url
                      FROM derm.address_row_map WHERE dump_folder = 'ticket-838130') THEN
    RAISE EXCEPTION 'VERIFY 1b: another client''s card moved';
  END IF;
  -- 2. each permit on the row printed for it, with the drawn row as its band
  SELECT jsonb_agg(jsonb_build_object('gdo', g.gdo_number, 'p', r.stamp_page, 'slot', r.slot_index, 'b0', r.band_y0_pct, 'b1', r.band_y1_pct, 'page', r.page)
                   ORDER BY g.gdo_number) INTO v_cards
    FROM derm.address_row_map r JOIN public.gdos g ON g.id = r.gdo_id WHERE r.dump_folder = 'ticket-838130';
  IF v_cards IS DISTINCT FROM '[
     {"gdo":"GDO-10877","p":2,"slot":2,"b0":30.659,"b1":37.922,"page":1},
     {"gdo":"GDO-11024","p":1,"slot":4,"b0":46.950,"b1":54.825,"page":1},
     {"gdo":"GDO-14117","p":1,"slot":5,"b0":54.825,"b1":62.646,"page":1},
     {"gdo":"GDO-15062","p":2,"slot":3,"b0":37.922,"b1":45.411,"page":1},
     {"gdo":"GDO-16389","p":2,"slot":4,"b0":45.411,"b1":53.519,"page":1}]'::jsonb THEN
    RAISE EXCEPTION 'VERIFY 2: permit cards are %', v_cards;
  END IF;
  -- 3. the image list, the Limits and the edge checks did not move
  IF to_jsonb(derm.ticket_page_images('838130')) IS DISTINCT FROM (SELECT imgs FROM _misc_before)
     OR (SELECT jsonb_agg(jsonb_build_object('p', effective_page, 't', top_pct, 'b', bottom_pct) ORDER BY effective_page)
           FROM derm.page_block_extents WHERE dump_folder = 'ticket-838130') IS DISTINCT FROM (SELECT ext FROM _misc_before)
     OR (SELECT count(*) FROM derm.v_band_edge_check WHERE dump_folder = 'ticket-838130' AND (edge_verdict IS DISTINCT FROM 'ON_RULE' OR slot_verdict IS DISTINCT FROM 'ONE_CLIENT')) <> 0
     OR (SELECT edge_issues FROM _misc_before) <> 2 THEN
    RAISE EXCEPTION 'VERIFY 3: images, Limits or edge checks moved';
  END IF;
  -- 4. completed again, publishable, one card per printed row
  IF derm.fn_sheet_publishable('ticket-838130') IS NOT NULL
     OR NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-838130' AND completed AND reopened_at IS NULL)
     OR derm.fn_generated_completion_blocker('ticket-838130') IS DISTINCT FROM 'This sheet is already marked complete.' THEN
    RAISE EXCEPTION 'VERIFY 4: not completed and publishable: %', derm.fn_sheet_publishable('ticket-838130');
  END IF;
  RAISE NOTICE 'VERIFY passed';
END $v$;
COMMIT;
