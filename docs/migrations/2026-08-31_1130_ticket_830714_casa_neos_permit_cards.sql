-- 2026-08-31_1130_ticket_830714_casa_neos_permit_cards.sql
--
-- WHY: THE MULTI-GDO CHIPS WOULD NOT APPLY ON ticket-830714, AND THE FOLDER HAD NO BANDS.
-- ---------------------------------------------------------------------------
-- Fred: "On 830714 it seems it's not applying the multiple chips with nickname for the manifests on
-- the Stamp App, so i uncompleted it to work on it."
--
-- MEASURED, not inferred: calling derm.add_extra_client_card('ticket-830714', 369, 1) in a rolled
-- back probe returns
--
--   REFUSED: client 369 on sheet ticket-830714 has a card with no gdo_id; bind it to its permit
--            before adding another, or the next card would duplicate the first permit
--
-- That guard is correct and fail-closed: with the existing card unbound the function cannot know
-- which permit is already taken, so "the next unclaimed one" would hand out the first permit twice.
-- The 2026-08-27_1720 backfill deliberately skipped this card because Casa Neos holds THREE active
-- permits, which is exactly the ambiguous case it refused to guess at.
--
-- ⇒ So the blocker is one unbound card, and binding it is a question only a person can answer.
-- Fred, 2026-08-31: "Kitchen is the first card, 2nd is bar which the chips is at, and the 3rd one is
-- lounge." The existing stamp sits at y 36.244, inside printed slot 2 (33.227-38.712), so it IS the
-- Bar row and is bound to GDO-15062. Kitchen and Lounge are ADDED around it. No existing stamp is
-- moved: a human placed it and it is already on the right row.
--
-- ---------------------------------------------------------------------------
-- THE TWO FOLDERS, because the geometry below is copied and not re-derived
-- ---------------------------------------------------------------------------
-- The same physical paper (handwritten pad 416) is carded twice:
--
--   ticket-830714   3 cards, no bands, correct name    <- this folder, what the Studio shows Fred
--   ticket-820714   5 cards, snapped bands, TYPO name  <- holds the finished work
--
-- 🛑 `820714` IS NOT A REAL TICKET. No row in derm_manifests carries white_manifest_number
-- '820714'; all three manifests on this paper (1622, 1623, 1624) are white '830714'. It is a
-- transposed digit from the 2026-07-28/30 stamping session. `ticket-830714` is the correct folder.
--
-- The typo folder nonetheless holds a HUMAN-VERIFIED layout: Casa Neos already split per permit
-- with stamps on the right rows, and bands snapped to the printed rules. That layout is what
-- generated the three documents currently being served, which Fred checked on 2026-08-31 and
-- confirmed look right. So this migration PORTS it rather than re-deriving it.
--
-- ⚠ ticket-820714 is deliberately NOT retired here. Copy first, verify, THEN retire: doing both in
-- one migration would destroy the reference geometry in the same breath as copying it, with no way
-- to check the copy afterwards. It is inert meanwhile (830714 already wins the folder election on
-- stamp_placed_at, and neither folder can publish while 830714 has no extent).
--
-- ---------------------------------------------------------------------------
-- THE PRINTED LAYOUT, from the canonical scan runlen-v2-2026-08-21
-- ---------------------------------------------------------------------------
--   slot 1  27.742 - 33.227   GDO-10877  009-CN Casa Neos KITCHEN
--   slot 2  33.227 - 38.712   GDO-15062  009-CN Casa Neos BAR      <- the existing card
--   slot 3  38.712 - 44.133   GDO-16389  009-CN Casa Neos LOUNGE
--   slot 4  44.133 - 49.681   GDO-15094  034-LG La Granja
--   slot 5  49.681 - 55.166   (no GDO-n) 187-HAI Shalom Haits
--   slot 6  55.166 - 60.587   EMPTY
--
-- All six boundaries are `kind = 'boundary'` in derm.v_page_printed_rules, asserted in PART 0.
-- ⚠ The row3/row4 boundary is taken as 44.133, the CANONICAL detector value, not the 44.196 the
-- typo folder carries. That older value predates the current scan by a day; the two differ by
-- 0.063pp, about half a pixel, and both sit on the same printed rule. Using the canonical one keeps
-- the bands exactly on the rules derm.v_band_edge_check grades against.
--
-- 🛑 `page` STAYS 1 ON EVERY CARD. Only stamp_page varies. derm.ticket_page_images builds its array
-- from `page`, so a card claiming page 2 appends a duplicate entry and re-points every later ordinal
-- at a different scan: the ticket-833049 defect. VERIFY 5 asserts the array is byte-identical.
--
-- 🛑 THE NEW CARDS ARE INSERTED ALREADY STAMPED. trg_ab_autoplace_generated fires only when
-- stamp_placed_at IS NULL, and its slot resolves the client's FIRST printed row, so letting it run
-- would stack Kitchen and Lounge on top of Bar. Supplying the stamp bypasses it through the
-- trigger's own guard. An unstamped card would also FREEZE the whole folder through the
-- closed-world gate in fn_blackout_targets.
--
-- ⚠ stamp_placed_by records the real provenance, 'ported:ticket-820714', rather than a person. The
-- positions are a human's work on the sibling folder and must not be relabelled as either mine or
-- Fred's.
--
-- ⚠ NOTHING IS PUBLISHED BY THIS. The folder holds no page_block_extents, so it cannot regenerate;
-- setting the page boundary is a deliberate act in the Studio and is Fred's to make. VERIFY 6
-- asserts the extent count is still zero. The completion flag is left as Fred set it (reopened).
--
-- RULE 8 (audit trail): derm.address_row_map is audited. Both inserts, the permit binding and all
-- five band writes are captured with old_row and are individually revertible.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 0. Assert the ground.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer;
BEGIN
  -- the folder is in the state described above
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-830714';
  IF v_n <> 3 THEN RAISE EXCEPTION 'PART 0: expected 3 cards on ticket-830714, found %', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-830714' AND matched_client_id = 369;
  IF v_n <> 1 THEN RAISE EXCEPTION 'PART 0: expected exactly 1 Casa Neos card, found %', v_n; END IF;

  -- and that card is the unbound one at the Bar row
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE id = 984 AND dump_folder = 'ticket-830714' AND matched_client_id = 369
     AND gdo_id IS NULL AND matched_manifest_id = 1624
     AND round(stamp_y_pct, 3) = 36.244 AND page = 1 AND stamp_page = 1;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'PART 0: card 984 is not the unbound Casa Neos card at 36.244 any more. '
      'Someone has worked this folder; re-read it before porting anything.';
  END IF;

  -- 36.244 must actually fall inside printed slot 2, or "it is the Bar row" is an assumption
  IF NOT (36.244 > 33.227 AND 36.244 < 38.712) THEN
    RAISE EXCEPTION 'PART 0: 36.244 is not inside slot 2; the Bar binding is unfounded';
  END IF;

  -- all six boundaries exist in the canonical scan
  SELECT count(*) INTO v_n FROM derm.v_page_printed_rules
   WHERE dump_folder = 'ticket-830714' AND effective_page = 1 AND kind = 'boundary'
     AND round(rule_pct, 3) IN (27.742, 33.227, 38.712, 44.133, 49.681, 55.166);
  IF v_n <> 6 THEN RAISE EXCEPTION 'PART 0: expected 6 canonical boundaries, found %', v_n; END IF;

  -- the three permits exist, are ACTIVE and belong to Casa Neos
  SELECT count(*) INTO v_n FROM public.gdos
   WHERE client_id = 369 AND status = 'ACTIVE'
     AND gdo_number IN ('GDO-10877', 'GDO-15062', 'GDO-16389');
  IF v_n <> 3 THEN RAISE EXCEPTION 'PART 0: expected 3 ACTIVE Casa Neos permits, found %', v_n; END IF;

  -- and the folder publishes nothing, so none of this is customer-visible yet
  SELECT count(*) INTO v_n FROM derm.page_block_extents WHERE dump_folder = 'ticket-830714';
  IF v_n <> 0 THEN RAISE EXCEPTION 'PART 0: folder now has % extent(s); it can publish', v_n; END IF;
END $do$;

-- remember the image array so VERIFY 5 can prove it did not move
CREATE TEMP TABLE _imgs_before AS SELECT derm.ticket_page_images('830714') AS imgs;

-- ---------------------------------------------------------------------------
-- PART 1. Bind the existing card to Bar. This is what unblocks add_extra_client_card.
-- ---------------------------------------------------------------------------
UPDATE derm.address_row_map a
   SET gdo_id = g.id
  FROM public.gdos g
 WHERE a.id = 984
   AND g.client_id = 369 AND g.gdo_number = 'GDO-15062' AND g.status = 'ACTIVE';

-- ---------------------------------------------------------------------------
-- PART 2. Add Kitchen and Lounge, already stamped, at the positions the sibling folder proved.
-- ---------------------------------------------------------------------------
INSERT INTO derm.address_row_map
  (dump_folder, white_manifest_number, page, row_index, image_url,
   matched_client_id, matched_manifest_id, gdo_id,
   assignment_status, confidence, source, flags,
   stamp_x_pct, stamp_y_pct, stamp_page, stamp_placed_at, stamp_placed_by)
SELECT 'ticket-830714', '830714', 1, v.row_index, src.image_url,
       369, 1624, g.id,
       'matched', 'high', 'extra-stamp', '{"extra_stamp": true}'::jsonb,
       v.stamp_x, v.stamp_y, 1, now(), 'ported:ticket-820714'
  FROM (VALUES
         ('GDO-10877', 4, 7.609::numeric, 30.578::numeric),   -- Kitchen, printed slot 1
         ('GDO-16389', 5, 7.392::numeric, 41.292::numeric)    -- Lounge,  printed slot 3
       ) AS v(gdo_number, row_index, stamp_x, stamp_y)
  JOIN public.gdos g
    ON g.client_id = 369 AND g.gdo_number = v.gdo_number AND g.status = 'ACTIVE'
  CROSS JOIN LATERAL (
    -- take the image_url the folder already uses, never a literal
    SELECT a2.image_url FROM derm.address_row_map a2
     WHERE a2.dump_folder = 'ticket-830714' AND a2.image_url <> 'pending'
     ORDER BY a2.id LIMIT 1
  ) src;

-- ---------------------------------------------------------------------------
-- PART 3. Snap all five bands onto the canonical printed boundaries.
-- ---------------------------------------------------------------------------
UPDATE derm.address_row_map a
   SET band_y0_pct = b.y0,
       band_y1_pct = b.y1,
       band_source = 'ported-rulesnap-2026-08-31',
       band_set_at = now(),
       band_set_by = 'ported:ticket-820714'
  FROM (VALUES
         ('GDO-10877', 27.742::numeric, 33.227::numeric),   -- Casa Neos Kitchen
         ('GDO-15062', 33.227::numeric, 38.712::numeric),   -- Casa Neos Bar
         ('GDO-16389', 38.712::numeric, 44.133::numeric),   -- Casa Neos Lounge
         ('GDO-15094', 44.133::numeric, 49.681::numeric)    -- 034-LG La Granja
       ) AS b(gdo_number, y0, y1)
  JOIN public.gdos g ON g.gdo_number = b.gdo_number AND g.status = 'ACTIVE'
 WHERE a.dump_folder = 'ticket-830714' AND a.gdo_id = g.id;

-- 187-HAI carries no GDO-n permit (its number on the paper is a bare "137"), so it is keyed by card.
UPDATE derm.address_row_map
   SET band_y0_pct = 49.681, band_y1_pct = 55.166,
       band_source = 'ported-rulesnap-2026-08-31',
       band_set_at = now(), band_set_by = 'ported:ticket-820714'
 WHERE id = 982 AND dump_folder = 'ticket-830714';

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_txt text; v_geo text; v_before text; v_after text;
BEGIN
  -- 1. five cards, all placed, all banded, and Casa Neos split three ways
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-830714';
  IF v_n <> 5 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % cards, expected 5', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-830714'
     AND (stamp_placed_at IS NULL OR band_y0_pct IS NULL OR band_y1_pct IS NULL);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % card(s) unplaced or unbanded. An unstamped card FREEZES the '
      'whole folder through the closed-world gate.', v_n;
  END IF;

  -- 2. each Casa Neos permit appears exactly once, on its own slot, with its stamp inside its band
  SELECT count(*) INTO v_n FROM derm.address_row_map a
    JOIN public.gdos g ON g.id = a.gdo_id
   WHERE a.dump_folder = 'ticket-830714' AND a.matched_client_id = 369
     AND g.gdo_number IN ('GDO-10877','GDO-15062','GDO-16389');
  IF v_n <> 3 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % Casa Neos permit cards, expected 3', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-830714'
     AND NOT (stamp_y_pct > band_y0_pct AND stamp_y_pct < band_y1_pct);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % card(s) have their stamp outside their own band', v_n;
  END IF;

  -- 3. 🛑 THE BINDING FRED CHOSE. The card that already existed must be BAR, not Kitchen.
  SELECT g.gdo_number || ' ' || coalesce(g.nickname,'?') INTO v_txt
    FROM derm.address_row_map a JOIN public.gdos g ON g.id = a.gdo_id WHERE a.id = 984;
  IF v_txt IS DISTINCT FROM 'GDO-15062 Bar' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: card 984 bound to %, expected GDO-15062 Bar', coalesce(v_txt,'NULL');
  END IF;

  -- 4. the bands tile the roster with no gap and no overlap
  SELECT string_agg(band_y0_pct::text || '-' || band_y1_pct::text, ' ' ORDER BY band_y0_pct)
    INTO v_txt FROM derm.address_row_map WHERE dump_folder = 'ticket-830714';
  IF v_txt <> '27.742-33.227 33.227-38.712 38.712-44.133 44.133-49.681 49.681-55.166' THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: bands do not tile as expected: %', v_txt;
  END IF;

  -- 5. 🛑 THE IMAGE ARRAY MUST NOT HAVE MOVED. A card claiming the wrong page re-points every later
  --    ordinal at a different scan, which is how ticket-833049 became a frozen defect.
  SELECT imgs::text INTO v_before FROM _imgs_before;
  SELECT derm.ticket_page_images('830714')::text INTO v_after;
  IF v_before IS DISTINCT FROM v_after THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: ticket_page_images changed. before=% after=%', v_before, v_after;
  END IF;
  SELECT count(DISTINCT page) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-830714';
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: % distinct page values, expected 1', v_n; END IF;

  -- 6. nothing published, and nothing served went short
  SELECT count(*) INTO v_n FROM derm.page_block_extents WHERE dump_folder = 'ticket-830714';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6 FAILED: % extent(s) appeared', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.v_served_blackout_short;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6 FAILED: % served document(s) short', v_n; END IF;

  -- 7. ✅ THE OUTCOME THAT MATTERS: the geometry is now clean by the app's OWN guard, which is the
  --    same one that refused every earlier attempt on this page.
  SELECT derm.check_page_geometry('ticket-830714', 1,
           (SELECT jsonb_agg(jsonb_build_object('row_id', id, 'y0', band_y0_pct, 'y1', band_y1_pct))
              FROM derm.address_row_map WHERE dump_folder = 'ticket-830714'))::text
    INTO v_geo;
  IF v_geo IS NOT NULL AND v_geo <> '' AND v_geo <> '()' THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: check_page_geometry still objects: %', v_geo;
  END IF;

  -- 8. the two worklist rows for this folder are gone
  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule WHERE dump_folder = 'ticket-830714';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 8 FAILED: % row(s) still on the band worklist', v_n;
  END IF;

  RAISE NOTICE 'VERIFY ok: 5 cards, Casa Neos split Kitchen/Bar/Lounge with 984 bound to Bar, bands '
    'tiling 27.742 to 55.166 on canonical boundaries, image array unchanged, 0 extents, '
    'check_page_geometry clean, worklist clear for this folder.';
END $do$;

DROP TABLE _imgs_before;

COMMIT;
