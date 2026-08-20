-- ============================================================================
-- 2026-08-20_1610  ticket-310607 p1: snap 4 bands by fitting the roster tiling
-- ============================================================================
--
-- Follows 2026-08-20_1538, which snapped 63 rows and left 17 that its gate refused.
-- This file closes 4 of those 17. It does NOT close the other 13; see the bottom.
--
-- WHY THE EARLIER GATE REFUSED THIS PAGE, AND WHY THAT WAS THE WRONG TEST
--
-- 2026-08-19_2355 already records that G1 evaluated against a DERIVED band is "the
-- wrong operand": a derived band failing G1 is G1 working. 2026-08-20_1538 used it as
-- a refusal gate anyway and dropped 8 pages on that basis. Re-examined, the real
-- obstacle is different and more interesting:
--
--   THE DERM FORM PRINTS MID-SLOT DIVIDERS AS WELL AS SLOT BOUNDARIES.
--
-- Detected rules on this page sit ~3.5pp apart while a client's printed slot is
-- ~7.8pp. So "snap each edge to the nearest rule" can land on a divider. For row 909
-- the two candidates were 1.82 and 2.34 away: a coin flip, not a measurement. That
-- ambiguity is what made the page unsafe, not the magnitude of the derived error.
--
-- WHAT WAS DONE INSTEAD: fit a contiguous tiling across the whole roster and let three
-- independent checks decide whether to believe it.
--   T1  every client's stamp_y_pct falls strictly inside the slot assigned to it.
--       This is the strong one: a human placed each stamp on that client's own row.
--   T2  the tiling is contiguous, monotonic, and no two clients share a slot
--   T3  the chain's first and last boundary match the independently measured extent
--
-- Fitted tiling, step 7.78pp:  24.023  32.598  39.533  46.974  55.170  63.367
--   extent on file is 23.7 / 63.6, so startErr = 0.32 and endErr = 0.23.
--   The final slot 55.170-63.367 is empty; the sheet has 5 printed slots and 4 clients.
--
--   row  client    stamp    old (derived)      new (fitted)     worst edge move
--   909  165-LPB   29.80    25.840 -> 33.760   24.023 -> 32.598   1.82
--   910  192-FRK   37.72    33.760 -> 41.100   32.598 -> 39.533   1.57
--   912  056-STM   44.48    41.100 -> 48.145   39.533 -> 46.974   1.57
--   911  139-LTG   51.81    48.145 -> 55.475   46.974 -> 55.170   1.17
--
-- WHAT THIS ACTUALLY FIXES: every one of those old bands reached PAST a printed rule
-- into the row below, by 1.16 to 1.57pp. For scale, the leak confirmed on 2026-08-19,
-- where one client's document showed a full text line of a neighbour's street address,
-- measured 1.665pp. This page was the same defect, still being served.
--
-- 🛑 NOT DONE HERE: 13 rows across 7 pages. Do not assume they are fine.
--
--   ticket-311045 p1, ticket-832194 p2      tiling fits but misses the measured extent
--   ticket-831102 p1, ticket-831102 p2      dark scans (roster median 212-215 against
--   ticket-831325 p1                        244-255 everywhere detection worked)
--   ticket-831047 p1, ticket-831710 p1      a tiling was found but its slots are
--                                           unevenly spaced (11.7 / 14.4 / 11.9) and on
--                                           831710 the stamp sits 0.08pp off a boundary,
--                                           so T1 passes on a technicality. Rejected.
--
--   ⚠ ticket-831710 is measured at ZERO outward error: its band sits INSIDE the true
--     slot, so it crops its own row and reveals nobody. It is the one page in that list
--     that is safe as it stands.
--
--   ⚠ A PROVABLY SAFE FALLBACK EXISTS AND IS NOT APPLIED HERE BECAUSE IT NEEDS FRED.
--     Setting each band to the two detected rules that BRACKET its stamp is guaranteed
--     to sit inside the client's true slot, because every slot boundary is itself a
--     detected rule, so a bracketing interval can never cross one. It cannot leak. The
--     cost is that where a mid-slot divider falls between them the client sees roughly
--     half of their own row, which is a customer-visible degradation and therefore a
--     product decision, not a cleanup. Withdrawing the documents is the other option
--     and produces the blank FOG card Fred objected to on 2026-08-19.
--
-- ⚠ INDEPENDENT CORROBORATION OF THE TILING, not part of the fit: the boundaries it
--   chose are measurably darker rules than the dividers between them. Chosen edges ink
--   at 0.774 / 0.815 / 0.751 / 0.791 / 0.843 / 0.923 (mean 0.82); the five rules the fit
--   skipped ink at 0.774 / 0.714 / 0.761 / 0.714 / 0.772 (mean 0.75). That is the
--   strong/weak alternation 2026-08-03_0340 describes, and nothing in the fit used ink.
--
-- ⚠ No extent change: 23.7 <= 24.023 and 63.6 >= 55.170 already.

BEGIN;

INSERT INTO derm.page_row_rules (dump_folder, effective_page, rule_pct, ink_frac, source) VALUES
  ('ticket-310607', 1, 24.023, 0.774, 'claude-tilingfit-2026-08-20'),
  ('ticket-310607', 1, 32.598, 0.815, 'claude-tilingfit-2026-08-20'),
  ('ticket-310607', 1, 39.533, 0.751, 'claude-tilingfit-2026-08-20'),
  ('ticket-310607', 1, 46.974, 0.791, 'claude-tilingfit-2026-08-20'),
  ('ticket-310607', 1, 55.170, 0.843, 'claude-tilingfit-2026-08-20'),
  ('ticket-310607', 1, 63.367, 0.923, 'claude-tilingfit-2026-08-20')
ON CONFLICT (dump_folder, effective_page, rule_pct) DO NOTHING;

UPDATE derm.address_row_map SET band_y0_pct=24.023, band_y1_pct=32.598, band_source='claude-tilingfit-2026-08-20', band_set_at=now() WHERE id=909;  -- 165-LPB
UPDATE derm.address_row_map SET band_y0_pct=32.598, band_y1_pct=39.533, band_source='claude-tilingfit-2026-08-20', band_set_at=now() WHERE id=910;  -- 192-FRK
UPDATE derm.address_row_map SET band_y0_pct=39.533, band_y1_pct=46.974, band_source='claude-tilingfit-2026-08-20', band_set_at=now() WHERE id=912;  -- 056-STM
UPDATE derm.address_row_map SET band_y0_pct=46.974, band_y1_pct=55.170, band_source='claude-tilingfit-2026-08-20', band_set_at=now() WHERE id=911;  -- 139-LTG

DO $$
DECLARE v_n int; v_unbound int; v_overlap int; v_stampout int; v_outside int;
BEGIN
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE band_source='claude-tilingfit-2026-08-20';
  IF v_n <> 4 THEN RAISE EXCEPTION 'expected 4 rows, found %', v_n; END IF;

  -- every edge must BE a detected rule
  SELECT count(*) INTO v_unbound FROM derm.address_row_map r
   WHERE r.band_source='claude-tilingfit-2026-08-20'
     AND ( NOT EXISTS (SELECT 1 FROM derm.page_row_rules pr WHERE pr.dump_folder=r.dump_folder
                        AND pr.effective_page=COALESCE(r.stamp_page,r.page) AND pr.rule_pct=r.band_y0_pct)
        OR NOT EXISTS (SELECT 1 FROM derm.page_row_rules pr WHERE pr.dump_folder=r.dump_folder
                        AND pr.effective_page=COALESCE(r.stamp_page,r.page) AND pr.rule_pct=r.band_y1_pct) );
  IF v_unbound <> 0 THEN RAISE EXCEPTION '% edges are not detected rules', v_unbound; END IF;

  -- T1 again, in the database: each stamp strictly inside its own band
  SELECT count(*) INTO v_stampout FROM derm.address_row_map r
   WHERE r.band_source='claude-tilingfit-2026-08-20'
     AND NOT (r.stamp_y_pct > r.band_y0_pct AND r.stamp_y_pct < r.band_y1_pct);
  IF v_stampout <> 0 THEN RAISE EXCEPTION '% stamps fall outside their own band', v_stampout; END IF;

  SELECT count(*) INTO v_overlap FROM derm.address_row_map r
   JOIN derm.address_row_map q ON q.dump_folder=r.dump_folder
    AND COALESCE(q.stamp_page,q.page)=COALESCE(r.stamp_page,r.page) AND q.id<>r.id
    AND q.band_y0_pct IS NOT NULL AND r.band_y0_pct IS NOT NULL
    AND q.band_y0_pct < r.band_y1_pct AND q.band_y1_pct > r.band_y0_pct
   WHERE r.band_source='claude-tilingfit-2026-08-20';
  IF v_overlap <> 0 THEN RAISE EXCEPTION '% bands overlap a sibling', v_overlap; END IF;

  SELECT count(*) INTO v_outside FROM derm.address_row_map r
   JOIN derm.page_block_extents e ON e.dump_folder=r.dump_folder
    AND e.effective_page=COALESCE(r.stamp_page,r.page)
   WHERE r.band_source='claude-tilingfit-2026-08-20'
     AND (r.band_y0_pct < e.top_pct OR r.band_y1_pct > e.bottom_pct);
  IF v_outside <> 0 THEN RAISE EXCEPTION '% bands fall outside the page extent', v_outside; END IF;

  RAISE NOTICE 'OK: 4 bands fitted, every edge a detected rule, every stamp inside its own band';
END $$;

COMMIT;
