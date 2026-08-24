-- ============================================================================
-- 2026-08-24_0012  Severity 2 worklist reviewed: 25 bands, 13 pages, ZERO leaks
-- ============================================================================
--
-- Severity 2 is "the band starts or ends INSIDE a slot", an edge on a mid-slot divider or a header
-- bar. It is the 226-JER shape, the one that actually leaked, so this tier had the strongest prior
-- of the four. Every one of the 25 was rendered with its page's detected rules drawn over the scan
-- and read. **None of them leaks.**
--
-- With 2026-08-23_2333 that is 47 flagged bands reviewed across both tiers and zero real leaks.
--
-- WHAT THE 25 ACTUALLY WERE:
--   * 13 are the PHASE INVERSION already recorded for severity 1: on a dark or handwritten scan the
--     faint divider inside a slot goes undetected, or a rule is missing entirely, and every
--     boundary/divider label below that point flips. The band then reads as "boundary to divider"
--     while being exactly one printed slot. ticket-830574 p1 and ticket-831102 p1/p2 are the clean
--     examples: the top two intervals are a full 5.4pp pitch because their dividers were missed.
--   * 6 are COARSE DETECTION on a handwritten sheet, where only every other printed rule was found,
--     so a real mid-slot divider is labelled a boundary.
--   * 6 are a shape not seen before and worth knowing:
--
-- 🛑 THE WRITER SOMETIMES FITS MORE CLIENTS ON THE FORM THAN IT HAS SLOTS, BY HALVING THE ROWS.
--    window7-sheet6 p1 carries EIGHT clients on a six-slot form: the first four take a normal
--    5.5pp slot each, and the last four are squeezed one per printed ROW at 2.7pp, name and address
--    on a single line. window10-sheet3 p1 does the same with seven.
--    Their bands are correctly 2.7pp, and PART_SLOT fires only because the model assumes two
--    printed rows per client. **These four were verified against the SERVED DOCUMENTS, not the
--    overlay**, because a 2.7pp band is too tight to judge from a whole-page render: each document
--    shows exactly one client's line and nothing else.
--
-- ⚠ TWO FINDINGS THAT ARE NOT LEAKS AND ARE NOT NOTHING. Both are facilities PRINTED on a sheet
-- that we hold no address_row_map row for, which CLAUDE.md names as the shape with no detector:
--     window10-sheet4 p2   CHIMA STEAKHOUSE, 2400 East Las Olas Blvd, printed between 044-MP's
--                          band and 019-G7's band
--     window3-sheet5 p2    a CARROT EXPRESS, printed between 071-TCE's band and 036-LG's band
-- Both currently sit in a GAP between bands, so both are blacked for every client and neither
-- leaks today. But an unrowed printed facility is exactly what turned ticket-310590 p2 into a leak
-- on 2026-08-19, and it means these two tickets may be missing a manifest link. Raised for Fred
-- rather than acted on.
--
-- ADR 010 rule 8 (audit): derm.band_review already carries an audit trigger from 2026-08-23_2333.

BEGIN;

INSERT INTO derm.band_review (row_id, band_y0_pct, band_y1_pct, verdict, reason, reviewed_by) VALUES
  (755, 28.037, 33.495, 'accepted', 'the dividers in the top two slots went undetected so the labels invert; the band is exactly its printed slot 28.081 to 33.495 and holds only MYK brickell FT LLC and 797 Brickell Av', 'claude-sev2-review-2026-08-24'),
  (757, 33.495, 38.864, 'accepted', 'same phase inversion; the band is the printed slot 33.495 to 38.908 and holds only HAP Happies and 1250 S Miami Av', 'claude-sev2-review-2026-08-24'),
  (876, 32.967, 38.727, 'accepted', 'dark scan, dividers undetected in the top slots; the band holds only Mutra and 2188 NE 123rd St', 'claude-sev2-review-2026-08-24'),
  (879, 29.818, 35.836, 'accepted', 'same page shape; the band holds only the carrot express Oakland Park and 3337 N Federal Highway', 'claude-sev2-review-2026-08-24'),
  (950, 24.565, 33.188, 'accepted', 'the top rule is a boundary mislabelled as a divider; the band holds only Danziguer Kosher Catering and 4101 pine tree drive, and 134-SC begins below it', 'claude-sev2-review-2026-08-24'),
  (417, 54.600, 57.300, 'accepted', 'THE WRITER FITTED SEVEN CLIENTS ON A SIX-SLOT FORM by halving the last rows; the 2.7pp band holds only LA GRANJA and 2333 NW 12th Av', 'claude-sev2-review-2026-08-24'),
  (418, 57.300, 60.100, 'accepted', 'same squeezed pair; the 2.8pp band holds only The Carrot Xpress and Collins Av Miami Bch', 'claude-sev2-review-2026-08-24'),
  (575, 33.260, 37.440, 'accepted', 'coarse detection on a handwritten sheet; the band holds only MR PASTA and 220 SW 31 St Fort Lauderdale', 'claude-sev2-review-2026-08-24'),
  (577, 43.920, 48.240, 'accepted', 'same; the band holds only G7 KITCHEN 34 and 35 and 5450 S State Rd 7', 'claude-sev2-review-2026-08-24'),
  (576, 49.120, 53.740, 'accepted', 'same; the band holds only THE CARROT EXPRESS CENTRAL KITCHEN and 105 East Hallandale Bch Blvd', 'claude-sev2-review-2026-08-24'),
  (431, 27.712, 32.993, 'accepted', 'only band on the sheet; it holds Ava Ava and 2889 McFarlane Rd, and everything below is empty form', 'claude-sev2-review-2026-08-24'),
  (461, 39.170, 44.528, 'accepted', 'a rule is missing between 39.153 and 44.530 so the labels invert below it; the band holds only Vincenzos Pizzeria and 7105 Collins Ave', 'claude-sev2-review-2026-08-24'),
  (161, 27.605, 33.033, 'accepted', 'the band holds only its own address line 5850 Sunset Drive; the next printed facility begins below 33.131', 'claude-sev2-review-2026-08-24'),
  (206, 28.800, 34.000, 'accepted', 'coarse detection, only every other rule found; the band holds only AROMAS DEL PERU and 13123 NW 88th St', 'claude-sev2-review-2026-08-24'),
  (207, 34.600, 39.300, 'accepted', 'same; the band holds only its own name and 18218 NW 74 Ave Miami Gardens', 'claude-sev2-review-2026-08-24'),
  (208, 39.700, 42.100, 'accepted', 'the client wrote name and address on ONE line; the 2.4pp band holds exactly that line', 'claude-sev2-review-2026-08-24'),
  (210, 50.400, 55.000, 'accepted', 'same coarse detection; the band holds only BAOLI MIAMI and its Collins Ave address', 'claude-sev2-review-2026-08-24'),
  (211, 29.400, 34.300, 'accepted', 'both edges sit on header-bar detections on this handwritten sheet; the band holds only MAISON VALENTINE and 1112 15th St', 'claude-sev2-review-2026-08-24'),
  (213, 40.600, 45.500, 'accepted', 'coarse detection; the band holds only true BARISTA truck 977 and Brickell Ave Miami', 'claude-sev2-review-2026-08-24'),
  (235, 34.600, 39.000, 'accepted', 'faint handwritten sheet; the band holds only LA GRANJA ALLAPATTAH and 223 NW 17th Ave', 'claude-sev2-review-2026-08-24'),
  (236, 40.200, 44.400, 'accepted', 'same; the band holds only its own name and 1250 S Miami Ave', 'claude-sev2-review-2026-08-24'),
  (339, 49.800, 52.470, 'accepted', 'EIGHT CLIENTS ON A SIX-SLOT FORM, last four squeezed one per row. VERIFIED ON THE SERVED DOCUMENT: it shows only LA GRANJA CALLE 8 Little Havana 17th Av Miami 33125', 'claude-sev2-review-2026-08-24'),
  (340, 52.470, 55.240, 'accepted', 'same sheet. VERIFIED ON THE SERVED DOCUMENT: it shows only LA GRANJA SOUTH MIAMI 6144 South Dixie Hwy 33143', 'claude-sev2-review-2026-08-24'),
  (341, 55.300, 57.980, 'accepted', 'same sheet. VERIFIED ON THE SERVED DOCUMENT: it shows only PURA VIDA DADELAND 7535 North Kendall Dr 33156', 'claude-sev2-review-2026-08-24'),
  (342, 57.980, 60.800, 'accepted', 'same sheet. VERIFIED ON THE SERVED DOCUMENT: it shows only PURA VIDA 244 Miracle Mile Coral Gables 33134', 'claude-sev2-review-2026-08-24')
ON CONFLICT (row_id, band_y0_pct, band_y1_pct) DO UPDATE
  SET verdict = EXCLUDED.verdict, reason = EXCLUDED.reason,
      reviewed_by = EXCLUDED.reviewed_by, reviewed_at = now();

DO $$
DECLARE v_rev int; v_sev2 int; v_sev1 int; v_work int; v_reopen int;
BEGIN
  SELECT count(*) INTO v_rev FROM derm.band_review
   WHERE verdict = 'accepted' AND reviewed_by LIKE 'claude-sev2-review-%';
  IF v_rev <> 25 THEN RAISE EXCEPTION 'expected 25 severity-2 reviews, found %', v_rev; END IF;

  SELECT count(*) INTO v_sev2 FROM derm.v_band_edges_off_rule WHERE severity = 2;
  IF v_sev2 <> 0 THEN RAISE EXCEPTION '% severity-2 bands are still on the worklist', v_sev2; END IF;

  -- severity 1 must still be clear: this file must not have disturbed the earlier review
  SELECT count(*) INTO v_sev1 FROM derm.v_band_edges_off_rule WHERE severity = 1;
  IF v_sev1 <> 0 THEN RAISE EXCEPTION 'severity 1 reopened (% bands), so something moved', v_sev1; END IF;

  -- the ledger must still not be a blanket exemption
  CREATE TEMP TABLE _p AS
    SELECT row_id, band_y0_pct FROM derm.band_review WHERE reviewed_by LIKE 'claude-sev2-review-%' LIMIT 1;
  UPDATE derm.band_review SET band_y0_pct = band_y0_pct + 1.0
   WHERE row_id = (SELECT row_id FROM _p) AND band_y0_pct = (SELECT band_y0_pct FROM _p);
  SELECT count(*) INTO v_reopen FROM derm.v_band_edges_off_rule WHERE severity = 2;
  IF v_reopen <> 1 THEN
    RAISE EXCEPTION 'moving a reviewed band did not reopen it (%), so the ledger is a standing exemption', v_reopen;
  END IF;
  UPDATE derm.band_review SET band_y0_pct = (SELECT band_y0_pct FROM _p)
   WHERE row_id = (SELECT row_id FROM _p) AND band_y0_pct = (SELECT band_y0_pct FROM _p) + 1.0;
  DROP TABLE _p;

  SELECT count(*) INTO v_work FROM derm.v_band_edges_off_rule;
  RAISE NOTICE 'OK: % severity-2 bands accepted, tiers 1 and 2 clear, % remain on the worklist', v_rev, v_work;
END $$;

COMMIT;
