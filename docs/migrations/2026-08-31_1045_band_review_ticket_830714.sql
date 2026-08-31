-- 2026-08-31_1045_band_review_ticket_830714.sql
--
-- WHY: FINISH THE ticket-830714 BAND REVIEW, THE LAST TWO SEVERITY-1 ROWS ON THE WORKLIST.
-- ---------------------------------------------------------------------------
-- Fred: "finish the 830714 band review properly."
--
-- This folder is the only one in the fleet SERVING documents built from DERIVED bands, and it has
-- 0 page_block_extents, so it cannot regenerate. Two of its three bands have sat on
-- derm.v_band_edges_off_rule at severity 1 since 2026-08-27, unreviewed.
--
-- WHAT WAS ACTUALLY DONE: the three served documents were downloaded and LOOKED AT, together with
-- the source scan. Not inferred from the row OCR, which is the mistake this migration corrects
-- below.
--
-- THE PAPER. derm/1622/address_1.jpeg is HANDWRITTEN pad sheet 416, a SIX-slot form:
--
--   slot 1  27.742 - 33.227   GDO 10877  009-CN CASA NEOS KITCHENS   40 SW N. River Dr
--   slot 2  33.227 - 38.712   GDO 15062  009-CN CASA NEOS - BARI     40 SW N. River Dr
--   slot 3  38.712 - 44.133   GDO 16389  009-CN CASA NEOS - LOUNGE   40 SW N. River Dr
--   slot 4  44.133 - 49.681   GDO 15094  034-LG LA GRANJA CAFE       700 SW 17th Av
--   slot 5  49.681 - 55.166   GDO 137    187-4Ai SHALOM HAITS        18593 W Dixie Hwy
--   slot 6  55.166 - 60.587   EMPTY
--
-- Boundaries are the detector's own (runlen-v2-2026-08-21, run 0.984 to 0.986) alternating with
-- dividers at run 0.357 to 0.359. A textbook bimodal split, and it matches the scan exactly.
--
-- 🛑 009-CN OWNS THREE PRINTED ROWS HERE AND HOLDS ONE CARD, so its band must span all three. That
-- is the same shape as 242-WYN on a generated sheet: blacking two of them would hide the client's
-- own compliance record from itself.
--
-- ---------------------------------------------------------------------------
-- FINDING 1: WHAT THE CLIENTS SEE TODAY IS CLEAN. Verified by opening all three files.
-- ---------------------------------------------------------------------------
-- The served documents were built from geometry that no longer matches the current bands, because
-- the bands are DERIVED and moved when Fred re-stamped the folder on 2026-08-27 20:56.
--
--   client    served window        built            what the file shows
--   009-CN    27.742 - 44.196      2026-08-27       its own three rows, nothing below
--   034-LG    44.196 - 49.681      2026-08-20       its own single row only
--   187-HAI   49.681 - 55.166      2026-08-20       its own single row only
--
-- All three carry header_y 27.550 and blocks_bottom 60.840, so the empty slot 6 is blacked for
-- everyone. NO CLIENT IS BEING SHOWN ANOTHER CLIENT'S DATA. Nothing needs withdrawing.
--
-- ---------------------------------------------------------------------------
-- 🛑 FINDING 2: THE CURRENT BANDS WOULD LEAK IF THIS PAGE WERE EVER PUBLISHED.
-- ---------------------------------------------------------------------------
-- 034-LG's derived band starts at 41.762. The true slot-4 boundary is 44.133. The 2.371pp strip
-- between them was cropped out of the source scan and inspected at 3x: it contains
--
--     "Complete Facility Address (if no GDO#):  40 SW N. RILER DR. MIAMI 33128"
--
-- which is CASA NEOS LOUNGE's address line, fully legible. That is the ticket-310590 leak shape.
--
-- ⚠ AND THIS IS WHY THE REVIEW HAD TO OPEN THE IMAGE. Reading the row OCR alone, I concluded a day
-- earlier that both severity-1 flags were false positives of the N=1 fallback. That was RIGHT for
-- 009-CN and WRONG for 034-LG, and the wrong half is the one that leaks. The OCR says which client
-- owns which row; it cannot say where a band edge falls between them.
--
-- It is INERT TODAY only because the folder has no extent, so nothing republishes. It is a trap
-- armed for whoever measures this page next, which the blocked-sheets worklist is actively asking
-- someone to do.
--
-- ---------------------------------------------------------------------------
-- 🛑 FINDING 3: THE CORRECT GEOMETRY CANNOT CURRENTLY BE SAVED. A GUARD REFUSES IT.
-- ---------------------------------------------------------------------------
-- The right answer is known exactly: 009-CN 27.742-44.133, 034-LG 44.133-49.681,
-- 187-HAI 49.681-55.166, every edge a detected boundary. All three routes are refused:
--
--   submit only the two single-row clients   -> G6_MISSING_ROW    (the save is page-atomic)
--   009-CN cut to one slot                   -> G13_STAMP_OUTSIDE_BAND (its stamp is at 36.244,
--                                               in the Bari slot, so no single slot contains it)
--   009-CN spanning its real three slots     -> G14_SPANS_EXTRA_SLOTS
--        "encloses 2 printed slot boundaries but the client owns 1 printed row(s) on this page"
--
-- G14 counts printed rows through derm.v_sheet_printed_rows, which resolves only for a GENERATED
-- sheet. On a handwritten pad it finds nothing and falls back to 1, so it forbids the correct band
-- for any multi-row client on a pad. This is the SAME root cause as the expected_slots defect fixed
-- in 2026-08-28_2150, in a second consumer.
--
-- ⚠ NOT FIXED HERE, deliberately. The obvious repair is to fall back to derm.address_sheet_row_reads
-- (which reads 3 high-confidence Casa Neos rows on this page). But G14 guards the LEAK direction:
-- relaxing it on the strength of OCR would let a bad read authorise a too-wide band on a
-- customer-facing document. That is Fred's call, not a cleanup, and it wants its own migration with
-- the whole fleet re-validated.
--
-- ⇒ SO THE THREE BANDS ARE RECORDED AS `repair_needed`, NOT `accepted`. Only 'accepted' drops a row
-- off derm.v_band_edges_off_rule, so 009-CN and 034-LG deliberately STAY on the worklist. A review
-- that finds a live leak must not clear the flag that would remind someone about it.
--
-- RULE 8 (audit trail): derm.band_review is itself the review trail (who, when, why). Opt-out,
-- consistent with the three prior review migrations.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 0. Assert the ground, so this cannot land against geometry that has moved.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer;
BEGIN
  -- the three bands must still be exactly what was reviewed
  SELECT count(*) INTO v_n FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-830714'
     AND (row_id, round(band_y0_pct,3), round(band_y1_pct,3)) IN
         ((984, 30.727, 41.762), (983, 41.762, 50.024), (982, 50.024, 55.513));
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'PART 0: expected the 3 reviewed bands, found %. The geometry moved; RE-REVIEW '
      'before recording anything, because a review is a statement about one geometry.', v_n;
  END IF;

  -- the boundaries quoted in the header must still be detected rules
  SELECT count(*) INTO v_n FROM derm.v_page_printed_rules
   WHERE dump_folder = 'ticket-830714' AND effective_page = 1
     AND kind = 'boundary' AND round(rule_pct,3) IN (27.742, 33.227, 38.712, 44.133, 49.681, 55.166);
  IF v_n <> 6 THEN
    RAISE EXCEPTION 'PART 0: expected 6 named boundaries in the canonical scan, found %', v_n;
  END IF;

  -- and the folder must still be publishing nothing, or finding 2 is not merely a latent trap
  SELECT count(*) INTO v_n FROM derm.page_block_extents WHERE dump_folder = 'ticket-830714';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'PART 0: the folder now has % extent(s). It can publish, so the 034-LG band is '
      'no longer latent and this is an INCIDENT, not a review.', v_n;
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- PART 1. Record the review.
-- ---------------------------------------------------------------------------
INSERT INTO derm.band_review (row_id, band_y0_pct, band_y1_pct, verdict, reason, reviewed_by)
VALUES
  (984, 30.727, 41.762, 'repair_needed',
   'Casa Neos, 009-CN. Owns printed slots 1-3 (Kitchens / Bari / Lounge) and holds ONE card, so its '
   'band must span 27.742-44.133. The current derived band crops its OWN record at both ends: the '
   'slot-1 facility name and the slot-3 address line. Contains no other client, so it is a '
   'degradation and not an exposure. SPANS_MULTIPLE here is a false positive of the N=1 fallback '
   '(handwritten pad, no generated sheet to count rows from). Correct band cannot be saved today: '
   'derm.save_page_geometry refuses it with G14_SPANS_EXTRA_SLOTS.',
   'claude-review-2026-08-31'),

  (983, 41.762, 50.024, 'repair_needed',
   'La Granja, 034-LG. LEAK IF PUBLISHED, verified by cropping the source scan at 3x: the band '
   'starts 2.371pp above the true slot-4 boundary (44.133) and the strip contains Casa Neos '
   'Lounge''s full address line, "40 SW N. RILER DR. MIAMI 33128", legible. Inert only because the '
   'folder holds no page_block_extents and therefore cannot regenerate. Correct band 44.133-49.681. '
   'NOT a false positive: reading the row OCR alone suggested it was, which is exactly why the '
   'served image had to be opened.',
   'claude-review-2026-08-31'),

  (982, 50.024, 55.513, 'repair_needed',
   'Shalom Haits, 187-HAI. Contains only its own printed row; no exposure. Off the detected '
   'boundaries by 0.343pp at the top and 0.347pp at the bottom, both just inside the 0.35pp '
   'tolerance, so it grades ON_RULE/ONE_CLIENT and is not on the worklist. Recorded anyway because '
   'the whole page was reviewed together and the next person should not have to re-derive that the '
   'third band was looked at. Correct band 49.681-55.166; the bottom edge currently reaches 0.347pp '
   'into the EMPTY slot 6, which is harmless.',
   'claude-review-2026-08-31')
ON CONFLICT (row_id, band_y0_pct, band_y1_pct) DO UPDATE
   SET verdict = EXCLUDED.verdict,
       reason = EXCLUDED.reason,
       reviewed_by = EXCLUDED.reviewed_by,
       reviewed_at = now();

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE v_n integer; v_wl integer;
BEGIN
  SELECT count(*) INTO v_n FROM derm.band_review
   WHERE reviewed_by = 'claude-review-2026-08-31' AND verdict = 'repair_needed';
  IF v_n <> 3 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: recorded % of 3 rows', v_n; END IF;

  -- 🛑 THE ASSERTION THAT MATTERS. The two flagged bands must STILL be on the worklist. If a review
  -- of a live leak silenced its own alarm, this migration would have made things worse.
  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule
   WHERE dump_folder = 'ticket-830714';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: ticket-830714 has % worklist rows, expected the same 2. '
      'repair_needed must NOT clear a row.', v_n;
  END IF;

  -- and the fleet worklist is unchanged at 4
  SELECT count(*) INTO v_wl FROM derm.v_band_edges_off_rule;
  IF v_wl <> 4 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: fleet worklist is %, expected 4', v_wl; END IF;

  -- 🛑 CONTROL: prove 'accepted' WOULD have cleared it, so VERIFY 2 is testing something real and
  -- not merely observing that nothing happened. Rolled back.
  BEGIN
    UPDATE derm.band_review SET verdict = 'accepted'
     WHERE row_id = 983 AND band_y0_pct = 41.762 AND band_y1_pct = 50.024;
    SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule WHERE dump_folder = 'ticket-830714';
    RAISE EXCEPTION 'ctrl_rollback';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ctrl_rollback' THEN RAISE; END IF;
  END;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: flipping 983 to accepted left % rows, expected 1. The ledger '
      'is not actually driving the worklist, so VERIFY 2 proves nothing.', v_n;
  END IF;

  -- nothing served went short
  SELECT count(*) INTO v_n FROM derm.v_served_blackout_short;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: % served document(s) short', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: 3 bands recorded repair_needed, both flagged rows still on the worklist, '
    'fleet worklist still 4, and an accepted verdict provably would have cleared one.';
END $do$;

COMMIT;
