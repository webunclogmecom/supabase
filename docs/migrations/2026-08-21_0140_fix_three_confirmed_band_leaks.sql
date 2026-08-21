-- ============================================================================
-- 2026-08-21_0140  Fix three CONFIRMED redaction leaks, found by looking at the paper
-- ============================================================================
--
-- 🛑 THESE ARE NOT SUSPICIONS. Each was read off the scan and the neighbour's data was
-- identified by name. All three have been served to clients in this state.
--
--   ticket-831710 p1   214-MYK Myka Brickell FT LLC     band 31.83 -> 43.83 (12.00pp)
--       The band starts inside 053-PV Pura Vida Edgewater's ADDRESS line and ends
--       across 057-SLS Bayshore executive Plaza's FACILITY NAME. Two neighbours.
--
--   ticket-831047 p1   032-LG La Granja 36th St         band 24.19 -> 36.19 (12.00pp)
--       The band is twice a slot tall and swallows the whole of the next client:
--       "Marie Blachere" and "2421 Northwest 1st Av".
--
--   ticket-832194 p2   025-GRO Grove Kosher (Harding)   band 34.34 -> 41.10
--       Shifted down about one text line: it CUTS OFF 025-GRO's own facility name at
--       the top and reaches down onto "167-FEN Fendi Château Residences" at the bottom.
--       167-FEN's own band is shifted the same way, so it is corrected here too.
--
-- 🛑 THE MEASUREMENT THAT WAS SUPPOSED TO CATCH THESE RANKED THEM SAFEST. This is the
-- most important thing in this file. 2026-08-20_1538 scored each band by its distance
-- from the nearest detected rule and reported:
--
--       ticket-311045 p1  1.60pp  "riskiest"      -> harmless, the overhang lands on an EMPTY slot
--       ticket-832194 p2  1.40pp                  -> REAL LEAK
--       ticket-831047 p1  1.01pp  "least risky"   -> REAL LEAK, an entire extra client
--       ticket-831710 p1  0.00pp  "safe, reveals nobody, left alone on purpose"
--                                                 -> REAL LEAK, two neighbours
--
-- The ranking was anti-correlated with harm. Three reasons, all visible on the scans:
--   1. On a handwritten sheet the detector finds few, unreliable rules, so "1.01pp from
--      the nearest rule" is 1.01pp from the WRONG rule.
--   2. The metric cannot tell an empty neighbouring slot from an occupied one. Same
--      number, opposite consequence.
--   3. A band spanning two whole slots reads as a small error, because its edges still
--      land near SOME rule. 831710 scored 0.00 while covering parts of three clients.
--
-- ⇒ Distance-to-a-rule is not a safety measure. What matters is whether another
--   client's printed row is inside the band, and that has to be looked at.
--
-- ⚠ AND THE AUTOMATED REPLACEMENT ALSO FAILED, so do not reach for it. Counting text
--   lines inside the band was calibrated against 13 documents whose truth was
--   established by eye, over 5 x-windows x 3 ink thresholds: NOT ONE of the 15
--   combinations separated leaking from clean. It is not in the tree; it did not work.
--
-- HOW THESE BOUNDARIES WERE CHOSEN: read off the scan, then confirmed against detected
-- printed rules. Every value below matched a detected rule at distance 0.000, and the
-- ink measured at that rule is given. Each client's stamp falls strictly inside its new
-- band, which is the strong check: a human placed that stamp on that client's own row.
--
--   row  client    stamp    old band            new band              ink at edges
--   874  032-LG    30.19    24.190 -> 36.190    25.029 -> 33.019      0.800 / 0.966
--   921  214-MYK   37.83    31.830 -> 43.830    34.738 -> 41.229      0.995 / 0.995
--   946  025-GRO   37.72    34.340 -> 41.100    32.754 -> 39.703      1.000 / 1.000
--   948  167-FEN   44.48    41.100 -> 47.860    39.703 -> 47.076      1.000 / 1.000
--
-- ⚠ No extent changes. All four new bands already sit inside their page extent
--   (831047 24/60.9, 831710 25.9/64.2, 832194 p2 23.9/63.5).
-- ⚠ Changing a band re-stales the fingerprint, so redact-manifest-sweep regenerates
--   these four documents. THE OLD, LEAKING DOCUMENT STAYS SERVED UNTIL IT DOES, at one
--   per five minutes. That is the existing mechanism, but here it means a known leak
--   remains live for a few minutes after this applies.

BEGIN;

INSERT INTO derm.page_row_rules (dump_folder, effective_page, rule_pct, ink_frac, source) VALUES
  ('ticket-831047', 1, 25.029, 0.800, 'claude-leakfix-2026-08-21'),
  ('ticket-831047', 1, 33.019, 0.966, 'claude-leakfix-2026-08-21'),
  ('ticket-831710', 1, 34.738, 0.995, 'claude-leakfix-2026-08-21'),
  ('ticket-831710', 1, 41.229, 0.995, 'claude-leakfix-2026-08-21'),
  ('ticket-832194', 2, 32.754, 1.000, 'claude-leakfix-2026-08-21'),
  ('ticket-832194', 2, 39.703, 1.000, 'claude-leakfix-2026-08-21'),
  ('ticket-832194', 2, 47.076, 1.000, 'claude-leakfix-2026-08-21')
ON CONFLICT (dump_folder, effective_page, rule_pct) DO NOTHING;

UPDATE derm.address_row_map SET band_y0_pct=25.029, band_y1_pct=33.019, band_source='claude-leakfix-2026-08-21', band_set_at=now() WHERE id=874;  -- 032-LG,  was swallowing Marie Blachere
UPDATE derm.address_row_map SET band_y0_pct=34.738, band_y1_pct=41.229, band_source='claude-leakfix-2026-08-21', band_set_at=now() WHERE id=921;  -- 214-MYK, was showing 053-PV and 057-SLS
UPDATE derm.address_row_map SET band_y0_pct=32.754, band_y1_pct=39.703, band_source='claude-leakfix-2026-08-21', band_set_at=now() WHERE id=946;  -- 025-GRO, was showing 167-FEN's name
UPDATE derm.address_row_map SET band_y0_pct=39.703, band_y1_pct=47.076, band_source='claude-leakfix-2026-08-21', band_set_at=now() WHERE id=948;  -- 167-FEN, shifted the same way

DO $$
DECLARE v_n int; v_unbound int; v_stampout int; v_overlap int; v_outside int; v_tall int;
BEGIN
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE band_source='claude-leakfix-2026-08-21';
  IF v_n <> 4 THEN RAISE EXCEPTION 'expected 4 rows, found %', v_n; END IF;

  -- every edge must BE a detected rule
  SELECT count(*) INTO v_unbound FROM derm.address_row_map r
   WHERE r.band_source='claude-leakfix-2026-08-21'
     AND ( NOT EXISTS (SELECT 1 FROM derm.page_row_rules pr WHERE pr.dump_folder=r.dump_folder
                        AND pr.effective_page=COALESCE(r.stamp_page,r.page) AND pr.rule_pct=r.band_y0_pct)
        OR NOT EXISTS (SELECT 1 FROM derm.page_row_rules pr WHERE pr.dump_folder=r.dump_folder
                        AND pr.effective_page=COALESCE(r.stamp_page,r.page) AND pr.rule_pct=r.band_y1_pct) );
  IF v_unbound <> 0 THEN RAISE EXCEPTION '% edges are not detected rules', v_unbound; END IF;

  -- the strong check: the human-placed stamp must sit strictly inside its own band
  SELECT count(*) INTO v_stampout FROM derm.address_row_map r
   WHERE r.band_source='claude-leakfix-2026-08-21'
     AND NOT (r.stamp_y_pct > r.band_y0_pct AND r.stamp_y_pct < r.band_y1_pct);
  IF v_stampout <> 0 THEN RAISE EXCEPTION '% stamps fall outside their own band', v_stampout; END IF;

  -- no band may overlap a sibling on the same page
  SELECT count(*) INTO v_overlap FROM derm.address_row_map r
   JOIN derm.address_row_map q ON q.dump_folder=r.dump_folder
    AND COALESCE(q.stamp_page,q.page)=COALESCE(r.stamp_page,r.page) AND q.id<>r.id
    AND q.band_y0_pct IS NOT NULL AND r.band_y0_pct IS NOT NULL
    AND q.band_y0_pct < r.band_y1_pct AND q.band_y1_pct > r.band_y0_pct
   WHERE r.band_source='claude-leakfix-2026-08-21';
  IF v_overlap <> 0 THEN RAISE EXCEPTION '% bands overlap a sibling', v_overlap; END IF;

  -- the specific defect being repaired: a band twice a slot tall. None may remain here.
  SELECT count(*) INTO v_tall FROM derm.address_row_map r
   WHERE r.band_source='claude-leakfix-2026-08-21'
     AND (r.band_y1_pct - r.band_y0_pct) > 9.0;
  IF v_tall <> 0 THEN RAISE EXCEPTION '% repaired bands are still over 9pp tall', v_tall; END IF;

  SELECT count(*) INTO v_outside FROM derm.address_row_map r
   JOIN derm.page_block_extents e ON e.dump_folder=r.dump_folder
    AND e.effective_page=COALESCE(r.stamp_page,r.page)
   WHERE r.band_source='claude-leakfix-2026-08-21'
     AND (r.band_y0_pct < e.top_pct OR r.band_y1_pct > e.bottom_pct);
  IF v_outside <> 0 THEN RAISE EXCEPTION '% bands fall outside their extent', v_outside; END IF;

  RAISE NOTICE 'OK: 4 leaking bands corrected, every edge a detected rule, every stamp inside its own band';
END $$;

COMMIT;
