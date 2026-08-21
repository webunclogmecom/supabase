-- ============================================================================
-- 2026-08-21_0651  derm/1194 page 3: a band boundary cutting THROUGH the neighbour's
--                  address line, found by opening the served document
-- ============================================================================
--
-- 🛑 THE LEAK. 226-JER Jerusalem Pizza's Field Portal FOG document
-- (manifests/redacted/m1206-955a4c5717.jpg, live since 2026-08-03) shows the lower two
-- thirds of "127 Northwest 27th Street, Miami, Florida, 33127" above its own row. That
-- is 242-WYN Wynd 28's street address, the client in the slot above, and it is plainly
-- readable. Confirmed by opening the file, not by inference.
--
-- 🛑 AND THE POINT OF THIS FILE IS THE METHOD, NOT THE TWO ROWS IT UPDATES.
--
-- A band's top edge at 32.571 does not sit in the whitespace between two slots. It sits
-- in the MIDDLE OF A LINE OF TEXT, and everything below the cut is what the client below
-- receives. The page's other four boundaries (40.834 / 48.113 / 56.025 / 63.868) all land
-- on the printed rule, so only the one at the top of the roster is wrong: 242-WYN's and
-- 226-JER's bands are both about 0.8pp high, and from 034-LG down the tiling is correct.
--
-- ⚠ I HAD ALREADY LOOKED AT THIS PAGE AND CALLED IT CLEAN. The band overlay drawn on the
-- raw scan showed the boundary "clipping the bottom of an address line", which I had seen
-- on a dozen pages and ruled a benign self-crop: a client's own last line losing its
-- descenders. It is not that. At a slot boundary the line being clipped belongs to the
-- client ABOVE, and the half below the cut is served to the client BELOW. Every one of
-- those "benign" calls has to be re-checked, and the four already re-checked here (the
-- 2026-08-21_0140 repairs, on ticket-831047 / ticket-831710 / ticket-832194) are clean.
--
-- 🛑 FOUR AUTOMATED INSTRUMENTS HAVE NOW FAILED ON THIS QUESTION. Do not build a fifth
-- before reading why, because each looked reasonable and each was measured against known
-- truth and rejected:
--   1. distance from a band edge to the nearest detected printed rule (2026-08-20)
--      -> ANTI-correlated with harm; ranked two real leaks as the safest on the sheet.
--   2. counting text lines inside a band (2026-08-21)
--      -> no separation in any of 15 window x threshold combinations.
--   3. text-run straddle detection on the raw scan (2026-08-21)
--      -> reported "runs" of 14.5pp on a light scan, i.e. two whole slots merged; and
--         flagged bands confirmed clean by eye.
--   4. gap from the black box edge to the first ink, on the SERVED document (2026-08-21)
--      -> the confirmed leak measured 0.130pp; a confirmed-clean band measured 0.057pp.
--         The known-good sheet ticket-832996 measured 0.276-0.414. No separation.
-- What has been right every time, on every page: rendering the roster column at high zoom
-- and looking at it. `scripts/probes/derm_band_review/ruler.js` is that view, with a y-scale in
-- page-percent so a boundary can be READ off the paper instead of inferred.
--
-- ⚠ A triage that WOULD be sound is unavailable today: a boundary that sits on a detected
-- `derm.page_row_rules` row cannot be inside a line of text, because a printed rule is not
-- text. But rule detection has only ever been run on a handful of pages: of 626 served
-- bands, 515 are on pages with ZERO detected rules. Until a fleet-wide detection pass
-- exists, that test cannot be used as an all-clear - its silence is absence of data.
--
-- MEASURED VALUES, read off the ruler view at 4pp full scale:
--   the printed rule closing 242-WYN's slot          33.30
--   226-JER's own name text begins                   34.60
--   the printed rule closing 226-JER's slot          ~40.60   (034-LG's top 40.834 clears it)
--   => a boundary anywhere in [33.4, 34.2] is clear of both. 33.500 chosen, mid-window.
--
--   row  client    old band            new band            why
--    76  242-WYN   24.566 -> 32.571    24.566 -> 33.500    ends below the rule, so its own
--                                                          address line is no longer cut
--    77  226-JER   32.571 -> 40.184    33.500 -> 40.834    starts below 242-WYN's address;
--                                                          ends at 034-LG's top, so its own
--                                                          address is whole
--
-- ⚠ 242-WYN has no served document (no manifest link), so its own band change is not
--   customer-visible today. It is corrected anyway: the tiling has to stay contiguous, and
--   if that row is ever served the same boundary would be wrong for it too.
-- ⚠ No extent change. Both bands stay inside derm/1194 page 3's extent (25.500 / 63.600);
--   the redactor already widens the top box to 24.566 to cover 242-WYN's band.
-- ⚠ Changing a band re-stales the fingerprint, so redact-manifest-sweep regenerates
--   226-JER's document. THE LEAKING DOCUMENT STAYS SERVED UNTIL IT DOES, at one per five
--   minutes.
--
-- Rule 8 (audit): `derm.address_row_map` carries no audit trigger and this migration does
-- not add one; it is consistent with the 2026-08-19 / 2026-08-20 / 2026-08-21_0140 band
-- repairs, whose old values are recorded in their own headers. Old values are in this
-- header above.

BEGIN;

UPDATE derm.address_row_map
   SET band_y1_pct = 33.500, band_source = 'claude-leakfix-2026-08-21b', band_set_at = now()
 WHERE id = 76;   -- 242-WYN, bottom moved below the printed rule

UPDATE derm.address_row_map
   SET band_y0_pct = 33.500, band_y1_pct = 40.834,
       band_source = 'claude-leakfix-2026-08-21b', band_set_at = now()
 WHERE id = 77;   -- 226-JER, top moved out of 242-WYN's address line

DO $$
DECLARE v_n int; v_stampout int; v_overlap int; v_outside int; v_tall int; v_gap numeric;
BEGIN
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE band_source = 'claude-leakfix-2026-08-21b';
  IF v_n <> 2 THEN RAISE EXCEPTION 'expected 2 rows, found %', v_n; END IF;

  -- the strong check: a human placed each stamp on that client's own printed row
  SELECT count(*) INTO v_stampout FROM derm.address_row_map r
   WHERE r.band_source = 'claude-leakfix-2026-08-21b'
     AND NOT (r.stamp_y_pct > r.band_y0_pct AND r.stamp_y_pct < r.band_y1_pct);
  IF v_stampout <> 0 THEN RAISE EXCEPTION '% stamps fall outside their own band', v_stampout; END IF;

  -- no band may overlap a sibling on the same page
  SELECT count(*) INTO v_overlap FROM derm.address_row_map r
   JOIN derm.address_row_map q
     ON q.dump_folder = r.dump_folder
    AND COALESCE(q.stamp_page, q.page) = COALESCE(r.stamp_page, r.page)
    AND q.id <> r.id
    AND q.band_y0_pct IS NOT NULL AND r.band_y0_pct IS NOT NULL
    AND q.band_y0_pct < r.band_y1_pct AND q.band_y1_pct > r.band_y0_pct
   WHERE r.band_source = 'claude-leakfix-2026-08-21b';
  IF v_overlap <> 0 THEN RAISE EXCEPTION '% bands overlap a sibling', v_overlap; END IF;

  -- neither band may grow past one printed slot (~7.9pp pitch on this sheet)
  SELECT count(*) INTO v_tall FROM derm.address_row_map r
   WHERE r.band_source = 'claude-leakfix-2026-08-21b'
     AND (r.band_y1_pct - r.band_y0_pct) > 9.2;
  IF v_tall <> 0 THEN RAISE EXCEPTION '% repaired bands exceed one slot', v_tall; END IF;

  -- the repaired boundary must clear the printed rule at 33.30 that closes 242-WYN's slot,
  -- and must stay above 226-JER's own name text at 34.60
  SELECT band_y0_pct INTO v_gap FROM derm.address_row_map WHERE id = 77;
  IF v_gap <= 33.30 OR v_gap >= 34.60 THEN
    RAISE EXCEPTION '226-JER top % is not between the printed rule (33.30) and its own name (34.60)', v_gap;
  END IF;

  SELECT count(*) INTO v_outside FROM derm.address_row_map r
   JOIN derm.page_block_extents e
     ON e.dump_folder = r.dump_folder
    AND e.effective_page = COALESCE(r.stamp_page, r.page)
   WHERE r.band_source = 'claude-leakfix-2026-08-21b'
     AND r.band_y1_pct > e.bottom_pct;
  IF v_outside <> 0 THEN RAISE EXCEPTION '% bands end below their extent', v_outside; END IF;

  RAISE NOTICE 'OK: derm/1194 p3 boundary moved out of 242-WYN address line';
END $$;

COMMIT;
