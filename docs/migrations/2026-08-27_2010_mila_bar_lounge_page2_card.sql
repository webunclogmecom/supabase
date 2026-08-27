-- 2026-08-27_2010_mila_bar_lounge_page2_card.sql
--
-- WHY: THE LAST STEP. 043-MIL CAN NOW BE SERVED BOTH OF ITS OWN PRINTED ROWS.
-- ---------------------------------------------------------------------------
-- 043-MIL (Mila) holds two ACTIVE permits and sheet 1082 prints one row per permit. Those two rows
-- fall either side of the 5-row page break, so they are on DIFFERENT images:
--
--   image 1, printed row 5   GDO-11024  "Mila - Restaurant"     <- the only card that existed
--   image 2, printed row 1   GDO-14117  "Mila - Bar / Lounge"   <- no card at all
--
-- Confirmed by the row OCR on both pages at HIGH confidence, and independently by the client's own
-- generated FOG PDF, which lists exactly those two facilities.
--
-- Until `2026-08-27_1830` a manifest could serve only one page, so creating this card would have
-- FLIPPED which facility the client sees rather than adding one: the election tie-breaks on
-- `stamp_placed_at DESC`, so a freshly placed card wins and page 1 would have disappeared. That is
-- why this is last and not first.
--
-- WHAT IT DOES
--   1. Binds the EXISTING card 945 to GDO-11024, its page-1 printed row. It carried `gdo_id IS NULL`,
--      which is what made `derm.add_extra_client_card` refuse (2026-08-27_1650): with nothing
--      claimed it would have handed out the FIRST permit again and duplicated Restaurant.
--   2. Creates the page-2 card for GDO-14117, stamped and banded in the SAME statement.
--
-- 🛑 THE CARD IS INSERTED ALREADY STAMPED, AND THAT IS LOAD-BEARING TWICE OVER.
--   (a) An unstamped card fails `fn_blackout_targets`' whole-folder closed-world gate, which would
--       freeze all 7 of this folder's serving documents until someone placed it.
--   (b) `trg_ab_autoplace_generated` fires BEFORE INSERT and only `if NEW.stamp_placed_at is null`.
--       Its slot comes from `fn_generated_sheet_slot(matched_manifest_id)`, which resolves a client's
--       FIRST printed row, i.e. page 1 slot 5. Letting it run would place this card on top of the
--       Restaurant row. Supplying the stamp bypasses it through the trigger's own guard.
--
-- THE GEOMETRY, measured not chosen:
--   band 24.068..32.669  -- both edges are DETECTED `boundary` rules of the winning runlen-v2 scan
--                        -- for ticket-832194 page 2 (24.068 32.669 39.619 47.119 55.212 63.220)
--   stamp x 8.000        -- the value both page-2 neighbours use
--   stamp y 29.900       -- ~68% into the band, matching how 025-GRO and 167-FEN sit in theirs
--
-- ⚠ It does NOT touch the neighbours. 025-GRO is 32.754..39.703 and 167-FEN 39.703..47.076, so the
-- new band ends 0.085pp clear of 025-GRO. A gap there is legal; an overlap would not be.
--
-- 🛑 `page` IS 1 AND ONLY `stamp_page` IS 2, AND GETTING THIS WRONG REPRODUCES A KNOWN DEFECT.
-- The first draft set `page = 2` and its own VERIFY caught it: 3 documents went stale instead of 1.
-- The cause is that `derm.ticket_page_images` builds the page array from `address_row_map.page`, so a
-- row claiming page 2 while carrying `address_1.JPG` APPENDS a duplicate entry. Measured in a
-- rolled-back probe, the array went
--     [address_1.JPG, address_2.JPG]  ->  [address_1.JPG, address_1.JPG, address_2.JPG]
-- which moves `imgs[2]` from address_2 to address_1. The two page-2 neighbours, 025-GRO and 167-FEN,
-- would have started redacting THE WRONG PAGE of a regulator-facing document. That is exactly the
-- `ticket-833049` defect this estate has frozen behind a CHECK constraint.
-- Every card on this folder uses `page = 1`; the page-2 ones are `page = 1, stamp_page = 2`
-- (025-GRO card 946, 167-FEN card 948). This card matches them. VERIFY 8 asserts the image array is
-- byte-identical before and after, which is the check that would have caught it directly.
--
-- ⚠ AND IT REPUBLISHES NOTHING ELSE. The page-2 extent is 23.9..63.5, so `btop = LEAST(23.9, min
-- band_y0)` stays 23.9 even though the minimum band moves from 32.754 to 24.068, and `bbot` is
-- unchanged. The page-mates' fingerprints therefore do not move. Exactly ONE new document appears.
--
-- RULE 8 (audit trail): `derm.address_row_map` is audited, so both the binding and the new card are
-- captured with old_row and are individually revertible.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 0. Assert the ground has not moved.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer;
BEGIN
  IF (SELECT count(*) FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
       WHERE r.dump_folder='ticket-832194' AND c.client_code='043-MIL') <> 1 THEN
    RAISE EXCEPTION 'PART 0: expected exactly one 043-MIL card on ticket-832194';
  END IF;
  -- every existing card is stamped, so the folder is not already frozen
  IF (SELECT count(*) FROM derm.address_row_map
       WHERE dump_folder='ticket-832194' AND stamp_placed_at IS NULL) <> 0 THEN
    RAISE EXCEPTION 'PART 0: the folder already has an unstamped card';
  END IF;
  -- the two boundaries this card snaps to must exist in the winning scan
  SELECT count(*) INTO v_n FROM derm.v_page_printed_rules
   WHERE dump_folder='ticket-832194' AND effective_page=2 AND kind='boundary'
     AND rule_pct IN (24.068, 32.669);
  IF v_n <> 2 THEN RAISE EXCEPTION 'PART 0: expected both page-2 boundaries, found %', v_n; END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- PART 1. Bind the existing card to the permit it represents (page 1, Restaurant).
-- ---------------------------------------------------------------------------
UPDATE derm.address_row_map r
   SET gdo_id = g.id
  FROM public.gdos g, public.clients c
 WHERE r.id = 945
   AND c.id = r.matched_client_id AND c.client_code = '043-MIL'
   AND g.client_id = c.id AND g.gdo_number = 'GDO-11024' AND g.status = 'ACTIVE'
   AND r.gdo_id IS NULL;

-- ---------------------------------------------------------------------------
-- PART 2. The page-2 card: created, stamped and banded in ONE statement.
-- ---------------------------------------------------------------------------
INSERT INTO derm.address_row_map
  (dump_folder, white_manifest_number, page, row_index, image_url,
   matched_client_id, matched_manifest_id, gdo_id,
   assignment_status, confidence, source, flags,
   stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, stamp_placed_by,
   band_y0_pct, band_y1_pct, band_source, band_set_at, band_set_by)
SELECT r.dump_folder, r.white_manifest_number, 1,   -- ⚠ page = 1, see the note above. NOT 2.
       (SELECT max(row_index) + 1 FROM derm.address_row_map WHERE dump_folder = 'ticket-832194'),
       r.image_url,
       r.matched_client_id, r.matched_manifest_id, g.id,
       'matched', 'high', 'extra-stamp', '{"extra_stamp":true}'::jsonb,
       2, 8.000, 29.900, now(), 'claude-perpermit-2026-08-27',
       24.068, 32.669, 'runlen-snap-2026-08-27', now(), 'claude-perpermit-2026-08-27'
  FROM derm.address_row_map r
  JOIN public.clients c ON c.id = r.matched_client_id
  JOIN public.gdos g ON g.client_id = c.id AND g.gdo_number = 'GDO-14117' AND g.status = 'ACTIVE'
 WHERE r.id = 945;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_bad integer; v_new bigint;
BEGIN
  -- 1. Two cards now, bound to the two permits IN PRINTED ORDER.
  SELECT count(*) INTO v_n FROM derm.address_row_map r
    JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder='ticket-832194' AND c.client_code='043-MIL';
  IF v_n <> 2 THEN RAISE EXCEPTION 'VERIFY 1 failed: % cards, expected 2', v_n; END IF;

  SELECT count(*) INTO v_bad FROM derm.address_row_map r
    JOIN public.gdos g ON g.id = r.gdo_id
    JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder='ticket-832194' AND c.client_code='043-MIL'
     AND NOT ((COALESCE(r.stamp_page, r.page) = 1 AND g.gdo_number = 'GDO-11024')
           OR (COALESCE(r.stamp_page, r.page) = 2 AND g.gdo_number = 'GDO-14117'));
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % card(s) bound to the wrong permit for their page', v_bad;
  END IF;

  SELECT r.id INTO v_new FROM derm.address_row_map r
    JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder='ticket-832194' AND c.client_code='043-MIL'
     AND COALESCE(r.stamp_page, r.page) = 2;

  -- 2. 🛑 THE AUTOPLACER DID NOT TOUCH IT. If it had run, the stamp would sit on page 1 at the
  --    Restaurant row's geometry rather than where this migration put it.
  SELECT count(*) INTO v_bad FROM derm.address_row_map
   WHERE id = v_new AND stamp_page = 2 AND stamp_x_pct = 8.000 AND stamp_y_pct = 29.900;
  IF v_bad <> 1 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the new card is not at the geometry this migration set; trg_ab_autoplace_generated overrode it';
  END IF;

  -- 3. Both band edges are DETECTED boundaries of the winning scan.
  SELECT count(*) INTO v_bad FROM derm.address_row_map r
   WHERE r.id = v_new
     AND (NOT EXISTS (SELECT 1 FROM derm.v_page_printed_rules p
                       WHERE p.dump_folder=r.dump_folder AND p.effective_page=2
                         AND p.kind='boundary' AND p.rule_pct=r.band_y0_pct)
       OR NOT EXISTS (SELECT 1 FROM derm.v_page_printed_rules p
                       WHERE p.dump_folder=r.dump_folder AND p.effective_page=2
                         AND p.kind='boundary' AND p.rule_pct=r.band_y1_pct));
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: a band edge is not on a printed rule'; END IF;

  -- 4. The stamp is inside its own band, and the band overlaps NO neighbour.
  IF NOT EXISTS (SELECT 1 FROM derm.address_row_map
                  WHERE id=v_new AND stamp_y_pct > band_y0_pct AND stamp_y_pct < band_y1_pct) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: the stamp is outside its own band';
  END IF;
  SELECT count(*) INTO v_bad
    FROM derm.address_row_map a JOIN derm.v_stamp_row_bands ab ON ab.id = a.id
    JOIN derm.address_row_map b ON b.dump_folder = a.dump_folder
     AND COALESCE(b.stamp_page,b.page) = COALESCE(a.stamp_page,a.page) AND b.id <> a.id
    JOIN derm.v_stamp_row_bands bb ON bb.id = b.id
   WHERE a.id = v_new AND ab.band_y0_pct < bb.band_y1_pct AND bb.band_y0_pct < ab.band_y1_pct;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 4 FAILED: the new band overlaps % neighbour(s)', v_bad; END IF;

  -- 5. THE FOLDER IS NOT FROZEN. Every card still carries a stamp point, so the closed-world gate
  --    still passes and the other 7 documents keep regenerating.
  SELECT count(*) INTO v_bad FROM derm.address_row_map
   WHERE dump_folder='ticket-832194' AND stamp_y_pct IS NULL;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: % unstamped card(s); the whole folder is now frozen', v_bad;
  END IF;

  -- 6. THE POINT: manifest 1692 now emits a target for page 2, and page 1 keeps its document.
  IF NOT EXISTS (SELECT 1 FROM derm.fn_blackout_targets(2000)
                  WHERE manifest_id = 1692 AND effective_page = 2) THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: manifest 1692 page 2 is not a target';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.redacted_manifest_docs
                  WHERE manifest_id = 1692 AND effective_page = 1) THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: page 1 lost its document';
  END IF;

  -- 7. AND NOTHING ELSE REPUBLISHES. The page-2 extent (23.9) is above the new band top (24.068),
  --    so btop does not move and the page-mates are untouched.
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(2000);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: % documents stale, expected exactly 1 (1692 page 2)', v_n;
  END IF;

  -- 8. 🛑 THE IMAGE ARRAY MUST NOT MOVE. stamp_page is an ORDINAL into derm.ticket_page_images, and
  --    that array is recomputed from the card rows. A card whose `page` disagrees with its image
  --    appends a duplicate entry and silently re-points every later ordinal at a different scan.
  IF (SELECT array_to_string(derm.ticket_page_images('832194'), '|'))
     IS DISTINCT FROM (SELECT array_to_string(ARRAY[
        (SELECT DISTINCT image_url FROM derm.address_row_map
          WHERE dump_folder='ticket-832194' AND image_url LIKE '%address_1%' LIMIT 1),
        replace((SELECT DISTINCT image_url FROM derm.address_row_map
          WHERE dump_folder='ticket-832194' AND image_url LIKE '%address_1%' LIMIT 1),
          'address_1','address_2')], '|')) THEN
    RAISE EXCEPTION 'VERIFY 8 FAILED: ticket_page_images moved to [%]; every stamp_page ordinal now points at a different scan',
      (SELECT array_to_string(derm.ticket_page_images('832194'), ' | '));
  END IF;

  RAISE NOTICE 'VERIFY ok: 043-MIL has 2 cards bound in printed order, the page-2 band is on detected rules, no overlap, folder not frozen, exactly 1 new document.';
END $do$;

COMMIT;
