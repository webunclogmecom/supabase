-- ============================================================================
-- 2026-08-24_1700  The remaining 33 band-worklist entries reviewed: ZERO leaks
-- ============================================================================
--
-- Fred: "check the remaining 33 worklist bands".
--
-- With this, ALL FOUR severity tiers have been reviewed: 22 severity-1 (2026-08-23_2333), 25
-- severity-2 (2026-08-24_0012), and now 26 severity-4 plus 7 severity-5. **80 flagged bands, zero
-- real leaks.** The four leaks this estate has actually had were all found before these tiers
-- existed, and all four sat in what is now the flagged population -- so the screen catches the
-- defect class, and is simply, and expectedly, mostly false.
--
-- ---------------------------------------------------------------------------
-- PART 0.  🛑 THE MEASUREMENT THAT DID MOST OF THE WORK: SIGN THE ERROR
-- ---------------------------------------------------------------------------
--
-- Severity 4 is "both edges land on the right two boundaries, but not precisely ON them"
-- (OFF_RULE + ONE_CLIENT). The SIZE of the gap says nothing about safety. The DIRECTION does, and
-- it is one subtraction:
--
--     top edge  BELOW its boundary   -> inward, crops the client's OWN row
--     top edge  ABOVE its boundary   -> OUTWARD, into the slot above
--     bottom    ABOVE its boundary   -> inward
--     bottom    BELOW its boundary   -> OUTWARD, into the slot below
--
-- **22 of the 26 are inward on BOTH edges.** They cannot expose a neighbour no matter how large the
-- offset: window4-sheet5 p2 / 136-BB is 2.618pp and 1.849pp inward, by far the worst number on the
-- worklist and completely harmless. That is why this file accepts them on the arithmetic and spends
-- the looking on the other four.
--
-- ⇒ This generalises: **a band-geometry check should report the SIGNED offset, not the absolute
-- one.** derm.v_band_edge_check exposes top_gap_pct / bottom_gap_pct as absolute distances, which
-- discards the half of the information that decides whether a finding matters. Worth adding, and
-- deliberately NOT done here: changing the check and reviewing its output in one migration would
-- mean the review was done against a different instrument than the one that produced the worklist.
--
-- ---------------------------------------------------------------------------
-- PART 1.  THE FOUR OUTWARD ONES, EACH VERIFIED INDIVIDUALLY
-- ---------------------------------------------------------------------------
--
-- Worst outward error on the entire worklist: **0.334pp**, about two pixels. For scale, the
-- confirmed 226-JER leak (2026-08-21_0651) was 1.665pp and showed two thirds of an address line.
--
--   ticket-831325 p1 059-SK    0.334pp top     SAFE BY STRUCTURE: first band on the page, nothing
--                                              above it but the form's header bar
--   ticket-309661 p2 090-OAK   0.274pp top     served document at 16x: blank paper and one vertical
--                                              form line; the neighbour's text is inside the black
--   ticket-311045 p1 106-ALC   0.257pp bottom  original scan: run 0.005, ink 0.065 -- column lines
--   window5-sheet3 p2 206-CAC  0.237pp bottom  original scan: run 0.016 -- the rule's underside
--
-- The ink probe (scripts/probes/derm_band_review/sliver-ink.js) is the reusable half: per scanline
-- it reports the longest dark RUN as well as the ink fraction, because ink ALONE cannot separate a
-- printed rule from a dense line of text -- the same measurement error that made the 2026-08-03
-- detector fail on a light scan.
--
-- ⚠ AND THE INK PROBE ALONE WAS NOT ENOUGH, which is the part worth carrying. On the two TOP-side
-- slivers it returned ink 0.46-0.65, which reads alarming and is an ARTEFACT: those strips are two
-- pixels tall and straddle the printed rule itself, so the rule's own ink dominates the fraction.
-- The served document at 16x is what settled them. Neither instrument was sufficient alone.
--
-- ---------------------------------------------------------------------------
-- PART 2.  SEVERITY 5 IS AN EVIDENCE GAP, NOT A GEOMETRY PROBLEM
-- ---------------------------------------------------------------------------
--
-- All 7 are ON_RULE + UNKNOWN on two pages, and UNKNOWN is not a statement about the band: those
-- pages carry page_grade=FAILED, so the detector could not establish the boundary/divider
-- alternation and every rule is 'unclassified'. The edges are within 0.002 to 0.065pp of a detected
-- rule, which is as close as anything on this fleet gets.
--
-- Both are handwritten SIX-slot forms, which is itself worth knowing: the alternation model assumes
-- the five-slot layout, and a six-slot form is one reason a page grades FAILED.
--
-- Verified by reading the pages: every band holds exactly one facility name and its address line.
--
-- ---------------------------------------------------------------------------
-- PART 3.  🛑 A THIRD PRINTED-BUT-UNROWED FACILITY, AND IT IS FOR FRED
-- ---------------------------------------------------------------------------
--
-- **window4-sheet1 p2 (ticket 824713) carries a THIRD handwritten facility, "Pari Pari",
-- 127 NW 27th St suite 105 Miami FL 33127 -- the Wynd 28 address -- and we hold NO card for it.**
--
-- It does not leak today: the page's two bands stop at 38.691 while the extent runs to 61.300, so
-- that row sits inside the lower black box for both 110-CLA and 214-MYK. But this is the shape that
-- turned ticket-310590 p2 into a real leak on 2026-08-19, because a DERIVED band stretches across a
-- slot nobody owns. These bands are snapped, which is exactly what makes it safe here.
--
-- It is the THIRD instance found by eye and there is still no detector for it: window10-sheet4 p2
-- (Chima Steakhouse) and window3-sheet5 p2 (a Carrot Express) were recorded on 2026-08-24_0012.
-- All three suggest a missing manifest link on their ticket. Raised, not acted on.
--
-- ADR 010 rule 8 (audit): derm.band_review carries an audit trigger from 2026-08-23_2333.
-- ============================================================================

BEGIN;

INSERT INTO derm.band_review (row_id, band_y0_pct, band_y1_pct, verdict, reason, reviewed_by) VALUES
  (68, 34.71, 40.1, 'accepted', 'INWARD ONLY (top +0.938pp, bottom -0.314pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (69, 41.35, 46.99, 'accepted', 'INWARD ONLY (top +0.936pp, bottom -0.566pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (70, 47.99, 54.51, 'accepted', 'INWARD ONLY (top +0.434pp, bottom -0.691pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (71, 55.89, 62.16, 'accepted', 'INWARD ONLY (top +0.689pp, bottom -0.747pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (72, 25.44, 32.62, 'accepted', 'INWARD ONLY (top +0.251pp, bottom -0.944pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (74, 40.55, 46.98, 'accepted', 'INWARD ONLY (top +0.311pp, bottom -0.438pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (573, 47.73, 54.79, 'accepted', 'INWARD ONLY (top +0.312pp, bottom -0.563pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (75, 55.67, 62.47, 'accepted', 'INWARD ONLY (top +0.317pp, bottom -0.691pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (551, 25.78, 32.78, 'accepted', 'INWARD ONLY (top +0.391pp, bottom -0.998pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (548, 34.56, 40.11, 'accepted', 'INWARD ONLY (top +0.782pp, bottom -0.334pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (550, 40.89, 47.11, 'accepted', 'INWARD ONLY (top +0.446pp, bottom -0.612pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (547, 48.22, 54.78, 'accepted', 'INWARD ONLY (top +0.498pp, bottom -0.831pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (549, 56.11, 62.56, 'accepted', 'INWARD ONLY (top +0.499pp, bottom -0.773pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (647, 23.075, 31.775, 'accepted', 'INWARD ONLY (top +0.03pp, bottom -0.926pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (845, 35.274, 41.301, 'accepted', 'OUTWARD 0.274pp at the top, and there IS a client above it (not the first band on the page), so this one needed the evidence. Opened the SERVED document at 16x: above the band edge the page is solid black, and the visible sliver between 35.274 and the printed boundary 35.548 is blank paper crossed by one vertical form line. The neighbour''s address line sits inside the black. No neighbour ink reaches the customer.', 'claude-sev45-review-2026-08-24'),
  (951, 25.84, 33.76, 'accepted', 'OUTWARD 0.257pp at the bottom, with a client below. Measured on the ORIGINAL scan: the two scanlines inside the sliver read run 0.005/0.006 and ink 0.067/0.065 -- essentially no ink and no horizontal run, which is the form''s vertical column lines and nothing else. The two high-ink lines (0.99, 0.89) sit AT the printed boundary and are the rule itself. The neighbour''s facility-name line starts well below. Served document confirms at 16x.', 'claude-sev45-review-2026-08-24'),
  (638, 25.14, 32.38, 'accepted', 'INWARD ONLY (top +0.686pp, bottom -0.68pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (634, 33.74, 39.62, 'accepted', 'INWARD ONLY (top +0.68pp, bottom -0.339pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (637, 40.57, 46.86, 'accepted', 'INWARD ONLY (top +0.611pp, bottom -0.613pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (633, 47.95, 54.78, 'accepted', 'INWARD ONLY (top +0.477pp, bottom -0.753pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (632, 56.01, 62.84, 'accepted', 'INWARD ONLY (top +0.477pp, bottom -0.753pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (889, 25.84, 33.76, 'accepted', 'OUTWARD 0.334pp at the top, the largest outward error on the worklist, and SAFE BY STRUCTURE: this is the FIRST band on the page, so there is no client above it to expose. The 0.334pp reaches into the form''s "B: Origination of Waste" header bar, which is furniture, not client data. Confirmed on the served document at 16x.', 'claude-sev45-review-2026-08-24'),
  (639, 27.97, 32.16, 'accepted', 'INWARD ONLY (top +0.811pp, bottom -0.373pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (574, 54.85, 59.38, 'accepted', 'INWARD ONLY (top +0.621pp, bottom -0.356pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (215, 53, 59.2, 'accepted', 'INWARD ONLY (top +2.618pp, bottom -1.849pp): the band sits INSIDE both of its printed slot boundaries, so it crops a little of the client''s OWN row and cannot reach a neighbour''s. Structurally incapable of leaking, whatever the size of the offset. Both edges are nearest a boundary rule, so the slot assignment is right and only the precision is off.', 'claude-sev45-review-2026-08-24'),
  (240, 28.8, 33.5, 'accepted', 'OUTWARD 0.237pp at the bottom, with a client below. On the ORIGINAL scan the sliver reads run 0.016 with ink 0.10-0.17 across three scanlines: no horizontal run at all, which is the underside of the thick printed rule plus vertical column lines on a 2800px-wide scan. No text glyphs. Served document confirms at 16x: rule, then black.', 'claude-sev45-review-2026-08-24'),
  (9, 28.329, 33.787, 'accepted', 'Handwritten SIX-slot form ("more than 6 Grease Interceptors"), page_grade=FAILED so the detector could not classify boundary vs divider and slot_verdict is UNKNOWN. The geometry is textbook: five bands tiling 28.329 to 55.851 contiguously at a uniform 5.44pp pitch, gaps under 0.09pp, every edge within 0.065pp of a detected rule. READ OFF THE PAGE, each band holds exactly one facility: Pura Vida / La Granja / Wynd 27 / Pura Vida SM / Casa Neas, each with its own address line. The sixth printed slot is blank and correctly carries no band.', 'claude-sev45-review-2026-08-24'),
  (10, 33.845, 39.285, 'accepted', 'Handwritten SIX-slot form ("more than 6 Grease Interceptors"), page_grade=FAILED so the detector could not classify boundary vs divider and slot_verdict is UNKNOWN. The geometry is textbook: five bands tiling 28.329 to 55.851 contiguously at a uniform 5.44pp pitch, gaps under 0.09pp, every edge within 0.065pp of a detected rule. READ OFF THE PAGE, each band holds exactly one facility: Pura Vida / La Granja / Wynd 27 / Pura Vida SM / Casa Neas, each with its own address line. The sixth printed slot is blank and correctly carries no band.', 'claude-sev45-review-2026-08-24'),
  (11, 39.362, 44.796, 'accepted', 'Handwritten SIX-slot form ("more than 6 Grease Interceptors"), page_grade=FAILED so the detector could not classify boundary vs divider and slot_verdict is UNKNOWN. The geometry is textbook: five bands tiling 28.329 to 55.851 contiguously at a uniform 5.44pp pitch, gaps under 0.09pp, every edge within 0.065pp of a detected rule. READ OFF THE PAGE, each band holds exactly one facility: Pura Vida / La Granja / Wynd 27 / Pura Vida SM / Casa Neas, each with its own address line. The sixth printed slot is blank and correctly carries no band.', 'claude-sev45-review-2026-08-24'),
  (12, 44.877, 50.318, 'accepted', 'Handwritten SIX-slot form ("more than 6 Grease Interceptors"), page_grade=FAILED so the detector could not classify boundary vs divider and slot_verdict is UNKNOWN. The geometry is textbook: five bands tiling 28.329 to 55.851 contiguously at a uniform 5.44pp pitch, gaps under 0.09pp, every edge within 0.065pp of a detected rule. READ OFF THE PAGE, each band holds exactly one facility: Pura Vida / La Granja / Wynd 27 / Pura Vida SM / Casa Neas, each with its own address line. The sixth printed slot is blank and correctly carries no band.', 'claude-sev45-review-2026-08-24'),
  (13, 50.399, 55.851, 'accepted', 'Handwritten SIX-slot form ("more than 6 Grease Interceptors"), page_grade=FAILED so the detector could not classify boundary vs divider and slot_verdict is UNKNOWN. The geometry is textbook: five bands tiling 28.329 to 55.851 contiguously at a uniform 5.44pp pitch, gaps under 0.09pp, every edge within 0.065pp of a detected rule. READ OFF THE PAGE, each band holds exactly one facility: Pura Vida / La Granja / Wynd 27 / Pura Vida SM / Casa Neas, each with its own address line. The sixth printed slot is blank and correctly carries no band.', 'claude-sev45-review-2026-08-24'),
  (177, 27.811, 33.245, 'accepted', 'Handwritten SIX-slot form, page_grade=FAILED so kinds are unclassified and slot_verdict is UNKNOWN. Both bands sit within 0.021pp of a detected rule, tile contiguously at 5.43pp, and READ OFF THE PAGE hold exactly one facility each: CLAUDIE / 1101 Brickell Avenue, and MYK MYKA / 777 Brickell Ave. See the migration header for the unrowed third facility below them, which is blacked for both clients and is a separate question.', 'claude-sev45-review-2026-08-24'),
  (178, 33.279, 38.691, 'accepted', 'Handwritten SIX-slot form, page_grade=FAILED so kinds are unclassified and slot_verdict is UNKNOWN. Both bands sit within 0.021pp of a detected rule, tile contiguously at 5.43pp, and READ OFF THE PAGE hold exactly one facility each: CLAUDIE / 1101 Brickell Avenue, and MYK MYKA / 777 Brickell Ave. See the migration header for the unrowed third facility below them, which is blacked for both clients and is a separate question.', 'claude-sev45-review-2026-08-24')
ON CONFLICT (row_id, band_y0_pct, band_y1_pct) DO UPDATE
  SET verdict = EXCLUDED.verdict, reason = EXCLUDED.reason,
      reviewed_by = EXCLUDED.reviewed_by, reviewed_at = now();

DO $verify$
DECLARE v_n int; v_reopen int; v_txt text; v_id bigint;
BEGIN
  SELECT count(*) INTO v_n FROM derm.band_review
   WHERE verdict = 'accepted' AND reviewed_by = 'claude-sev45-review-2026-08-24';
  IF v_n <> 33 THEN
    RAISE EXCEPTION 'expected 33 reviews, found %', v_n;
  END IF;

  -- THE WORKLIST MUST NOW BE EMPTY. Every tier has been reviewed.
  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule;
  IF v_n <> 0 THEN
    SELECT string_agg(dump_folder || ' ' || client_code || ' sev' || severity, ', ')
      INTO v_txt FROM derm.v_band_edges_off_rule;
    RAISE EXCEPTION 'the worklist is not empty: %', v_txt;
  END IF;

  SELECT count(*) INTO v_n FROM derm.band_review WHERE verdict = 'accepted';
  IF v_n <> 80 THEN RAISE EXCEPTION 'expected 80 acceptances across all four tiers, found %', v_n; END IF;

  -- 🛑 and the ledger must still not be a standing exemption: change one reviewed band's KEY and it
  -- must come back. Keyed on the SERVED geometry (2026-08-23_2322), so perturb the review rather
  -- than the card -- an edit to the card does not reach the check until the sweep republishes.
  SELECT min(row_id) INTO v_id FROM derm.band_review
   WHERE reviewed_by = 'claude-sev45-review-2026-08-24';
  UPDATE derm.band_review SET band_y0_pct = band_y0_pct + 1.0
   WHERE reviewed_by = 'claude-sev45-review-2026-08-24' AND row_id = v_id;
  SELECT count(*) INTO v_reopen FROM derm.v_band_edges_off_rule;
  IF v_reopen <> 1 THEN
    RAISE EXCEPTION 'moving a reviewed band reopened % rows, expected exactly 1', v_reopen;
  END IF;
  UPDATE derm.band_review SET band_y0_pct = band_y0_pct - 1.0
   WHERE reviewed_by = 'claude-sev45-review-2026-08-24' AND row_id = v_id;

  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule;
  IF v_n <> 0 THEN RAISE EXCEPTION 'the worklist did not go empty again'; END IF;

  RAISE NOTICE 'OK: 33 reviewed, worklist EMPTY, 80 acceptances, ledger still value-keyed';
END $verify$;

COMMIT;
