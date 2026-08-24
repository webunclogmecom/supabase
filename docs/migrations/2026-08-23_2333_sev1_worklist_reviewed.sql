-- ============================================================================
-- 2026-08-23_2333  Severity 1 worklist reviewed: 22 bands, 15 pages, ZERO leaks
-- ============================================================================
--
-- Fred: "start on the worklist, severity 1 first."
--
-- Severity 1 is "the band covers more than one client's printed slot", the shape that leaked the
-- whole of Marie Blachere to 032-LG. Every one of the 22 was rendered with its page's detected
-- rules drawn over the scan and read by eye. **None of them leaks.** Each band holds its own
-- client's name and address and nothing else.
--
-- 🛑 22 CANDIDATES, 0 HITS. A tier that screens at zero precision will be ignored within a week,
-- so the four causes are written down here rather than left to be rediscovered:
--
--   1. THE FORM HEADER BAR READS AS A SLOT BOUNDARY (4 bands). The bottom edge of the
--      "B: Origination of Waste" bar is a full-width printed line and is indistinguishable from a
--      slot boundary by any local measurement: on ticket-831047 p1 it runs 0.990 and is 2px thick
--      against 0.991 and 3px for the real boundary below it. A band whose top sits above the bar
--      therefore "contains a boundary".
--   2. UNDETECTED MID-SLOT DIVIDERS FLIP THE PHASE (9 bands). Classification is the alternation of
--      boundary and divider down the roster. On a dark or handwritten scan the faint divider inside
--      a slot is missed, or one rule is missing entirely, and every label below that point inverts.
--      window11-sheet8 p1 has a 5.38pp gap where a rule should be, and the labels invert there.
--   3. THE EXTRA SLOT IS EMPTY (5 bands). ticket-831220 p1 has a single client and a 12.3pp band;
--      the second slot it covers is blank form. Nothing to leak.
--   4. THE CLIENT OWN HANDWRITING OVERFLOWS THE PRINTED SLOT (2 bands). On window5-sheet3 p2,
--      204-JCC's address runs onto the next printed row and 114-CI's runs below the footer rule.
--      **Here the band SHOULD span more than one printed slot**, so SPANS_MULTIPLE is not merely
--      imprecise, it is sometimes the correct state.
--
-- ⚠ WHAT WOULD HAVE CAUGHT THE REAL ONES, AND WHY IT IS NOT AVAILABLE. The four confirmed leaks
-- were bands containing ANOTHER FACILITY'S PRINTED TEXT. Neither an overlapping band nor a
-- neighbouring stamp identifies that: on ticket-831047 the neighbour, Marie Blachere, has no row on
-- the sheet at all, so there was nothing in the database to collide with. Distinguishing "covers an
-- empty slot" from "covers an occupied one" means reading the page. That is the same wall the four
-- rejected scorers hit (see 2026-08-21_0651), and it is why this tier screens rather than decides.
--
-- ⇒ SO THE TIER EARNED ITS KEEP EXACTLY ONCE, HERE: it turned 635 served documents into 22 to look
--   at, and an hour cleared them. It is a screen, not a verdict. Keep it, and expect it to be
--   mostly false.
--
-- WHAT THIS SHIPS: a review ledger, so a band that a person has looked at and accepted drops off
-- the worklist and "empty is healthy" stays true.
--
-- 🛑 THE LEDGER IS KEYED ON THE BAND VALUES, NOT JUST THE ROW. If the band is ever edited, the
-- review no longer matches and the row RETURNS to the worklist automatically. An acceptance is a
-- statement about a specific geometry, not a permanent exemption, and a permanent exemption is how
-- a check quietly stops checking.
--
-- ADR 010 rule 8 (audit): derm.band_review records a human judgement, which is exactly the kind of
-- human-editable content rule 8 wants audited, and it is small. Audit OPT-IN.

BEGIN;

CREATE TABLE IF NOT EXISTS derm.band_review (
  row_id      bigint       NOT NULL REFERENCES derm.address_row_map(id) ON DELETE CASCADE,
  band_y0_pct numeric(7,3) NOT NULL,
  band_y1_pct numeric(7,3) NOT NULL,
  verdict     text         NOT NULL,
  reason      text         NOT NULL,
  reviewed_by text         NOT NULL,
  reviewed_at timestamptz  NOT NULL DEFAULT now(),
  PRIMARY KEY (row_id, band_y0_pct, band_y1_pct),
  CONSTRAINT band_review_verdict_chk CHECK (verdict IN ('accepted','repair_needed'))
);

COMMENT ON TABLE derm.band_review IS
  'A person looked at this band over its page and recorded a judgement. Rows with verdict '
  '''accepted'' drop off derm.v_band_edges_off_rule so the worklist stays a work queue. '
  'KEYED ON THE BAND VALUES: edit the band and the review stops matching, so the row returns to '
  'the worklist. An acceptance is a statement about one geometry, never a standing exemption.';
COMMENT ON COLUMN derm.band_review.reason IS
  'Why it is acceptable, in enough detail that the next person does not have to re-open the scan.';

CREATE TRIGGER audit_band_review
  AFTER INSERT OR UPDATE OR DELETE ON derm.band_review
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

INSERT INTO derm.band_review (row_id, band_y0_pct, band_y1_pct, verdict, reason, reviewed_by) VALUES
  (648, 31.775, 40.269, 'accepted', 'band starts 0.93pp above its own slot boundary; the strip is blank paper below 028-HUM address line', 'claude-sev1-review-2026-08-23'),
  (952, 33.760, 41.680, 'accepted', 'band extends 1.56pp past its slot boundary into the next slot, which is EMPTY', 'claude-sev1-review-2026-08-23'),
  (678, 26.907, 38.206, 'accepted', 'interior boundary 29.590 is the bottom edge of the B: Origination of Waste header bar; the second slot the band covers is EMPTY', 'claude-sev1-review-2026-08-23'),
  (874, 25.029, 33.019, 'accepted', 'interior boundary 27.397 is the header bar; Marie Blachere sits below 32.905 and is OUTSIDE the band, verified twice', 'claude-sev1-review-2026-08-23'),
  (875, 27.207, 32.967, 'accepted', 'the mid-slot dividers went undetected on the top slots, so the phase flips; the band is its own printed slot, offset 0.56pp', 'claude-sev1-review-2026-08-23'),
  (877, 23.870, 29.818, 'accepted', 'same page shape: undetected dividers flip the phase; band holds only its own name and address', 'claude-sev1-review-2026-08-23'),
  (878, 35.836, 41.924, 'accepted', 'same page shape: undetected dividers flip the phase; band holds only its own name and address', 'claude-sev1-review-2026-08-23'),
  (908, 24.097, 36.426, 'accepted', 'band is 1.5 slots tall and the second slot is EMPTY; only 214-MYK is printed on this sheet', 'claude-sev1-review-2026-08-23'),
  (890, 33.760, 41.680, 'accepted', 'band starts 1.12pp above its slot boundary; the strip is blank between 059-SK address and its own name', 'claude-sev1-review-2026-08-23'),
  (405, 29.500, 35.300, 'accepted', 'band is its own slot offset 0.46pp; everything below is empty rows', 'claude-sev1-review-2026-08-23'),
  (459, 28.437, 33.760, 'accepted', 'a rule is missing between 39.153 and 44.530 so the phase flips below it; the band holds its own two handwritten lines', 'claude-sev1-review-2026-08-23'),
  (460, 33.806, 39.149, 'accepted', 'same missing-rule phase flip; the band holds only Pamplemousse name and address', 'claude-sev1-review-2026-08-23'),
  (485, 26.900, 32.600, 'accepted', 'the strip above its slot is the header bar region; the band holds only Sarahs Tent Market', 'claude-sev1-review-2026-08-23'),
  (209, 42.500, 47.400, 'accepted', 'only every other printed rule was detected, so the interior boundary is really a mid-slot divider; the band holds its own two lines', 'claude-sev1-review-2026-08-23'),
  (212, 34.600, 40.000, 'accepted', 'coarse detection on a handwritten sheet; the interior boundary is a mid-slot divider and the band holds its own two lines', 'claude-sev1-review-2026-08-23'),
  (214, 45.800, 51.000, 'accepted', 'coarse detection on a handwritten sheet; the band holds only the carrot express name and address', 'claude-sev1-review-2026-08-23'),
  (216, 59.500, 61.800, 'accepted', 'coarse detection on a handwritten sheet; the band holds only the single TENDS line', 'claude-sev1-review-2026-08-23'),
  (237, 45.600, 50.100, 'accepted', 'coarse detection on a faint handwritten sheet; the band holds only La Granja calle 8 name and address', 'claude-sev1-review-2026-08-23'),
  (238, 51.000, 58.200, 'accepted', 'THE CLIENT OWN HANDWRITING OVERFLOWS the printed slot onto the next row, so the band correctly spans more than one printed slot', 'claude-sev1-review-2026-08-23'),
  (239, 58.800, 65.400, 'accepted', 'same overflow: the address is written below the footer rule, so the band correctly extends past it', 'claude-sev1-review-2026-08-23'),
  (291, 28.200, 33.900, 'accepted', 'band ends 0.79pp past its slot boundary into blank paper before 012-DKC name row', 'claude-sev1-review-2026-08-23'),
  (292, 33.900, 39.500, 'accepted', 'band ends 0.99pp past its slot boundary into blank paper before the next empty slot', 'claude-sev1-review-2026-08-23')
ON CONFLICT (row_id, band_y0_pct, band_y1_pct) DO UPDATE
  SET verdict = EXCLUDED.verdict, reason = EXCLUDED.reason,
      reviewed_by = EXCLUDED.reviewed_by, reviewed_at = now();

CREATE OR REPLACE VIEW derm.v_band_edges_off_rule AS
SELECT v.*,
       CASE WHEN v.slot_verdict = 'SPANS_MULTIPLE'            THEN 1
            WHEN v.slot_verdict IN ('PART_SLOT','ODD_SLOT')   THEN 2
            WHEN v.edge_verdict IN ('STALE','UNSCANNED')      THEN 3
            WHEN v.edge_verdict = 'OFF_RULE'                  THEN 4
            ELSE 5 END AS severity
  FROM derm.v_band_edge_check v
 WHERE NOT (v.edge_verdict = 'ON_RULE' AND v.slot_verdict = 'ONE_SLOT')
   AND NOT EXISTS (
     SELECT 1 FROM derm.band_review br
      WHERE br.row_id = v.row_id
        AND br.verdict = 'accepted'
        AND br.band_y0_pct = round(v.band_y0_pct, 3)
        AND br.band_y1_pct = round(v.band_y1_pct, 3)
   );

COMMENT ON VIEW derm.v_band_edges_off_rule IS
  'The worklist. EMPTY IS HEALTHY. Everything that is not provably one whole slot with no line of '
  'text bisected AND has not been looked at and accepted in derm.band_review. severity 1 the band '
  'covers more than one client, 2 it starts or ends inside a slot, 3 never scanned or the image '
  'moved, 4 the edges are off the rules but the slot is right. Check after any stamping session '
  'and after any band edit. '
  'Severity 1 was cleared on 2026-08-23: 22 bands, 15 pages, zero leaks. Expect this tier to be '
  'mostly false positives and keep it anyway, because it is what turns 635 documents into 22.';

DO $$
DECLARE v_rev int; v_sev1 int; v_work int; v_audited int; v_reopen int;
BEGIN
  SELECT count(*) INTO v_rev FROM derm.band_review WHERE verdict = 'accepted';
  IF v_rev <> 22 THEN RAISE EXCEPTION 'expected 22 accepted reviews, found %', v_rev; END IF;

  -- rule 8: the ledger must actually be audited
  SELECT count(*) INTO v_audited FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'derm' AND c.relname = 'band_review' AND NOT t.tgisinternal;
  IF v_audited = 0 THEN RAISE EXCEPTION 'derm.band_review carries no audit trigger'; END IF;

  -- the 22 must be gone from the worklist
  SELECT count(*) INTO v_sev1 FROM derm.v_band_edges_off_rule WHERE severity = 1;
  IF v_sev1 <> 0 THEN RAISE EXCEPTION '% severity-1 bands are still on the worklist', v_sev1; END IF;

  -- 🛑 AND THE LEDGER MUST NOT BE A BLANKET EXEMPTION. Move a reviewed band and it must come back.
  CREATE TEMP TABLE _probe AS SELECT row_id, band_y0_pct, band_y1_pct FROM derm.band_review LIMIT 1;
  UPDATE derm.band_review SET band_y0_pct = band_y0_pct + 1.0
   WHERE row_id = (SELECT row_id FROM _probe) AND band_y0_pct = (SELECT band_y0_pct FROM _probe);
  SELECT count(*) INTO v_reopen FROM derm.v_band_edges_off_rule WHERE severity = 1;
  IF v_reopen <> 1 THEN
    RAISE EXCEPTION 'moving a reviewed band did not reopen it (% back on the worklist): the ledger is a standing exemption', v_reopen;
  END IF;
  UPDATE derm.band_review SET band_y0_pct = (SELECT band_y0_pct FROM _probe)
   WHERE row_id = (SELECT row_id FROM _probe) AND band_y0_pct = (SELECT band_y0_pct FROM _probe) + 1.0;
  DROP TABLE _probe;

  SELECT count(*) INTO v_work FROM derm.v_band_edges_off_rule;
  IF v_work = 0 THEN RAISE EXCEPTION 'the whole worklist is empty, which is not what was reviewed'; END IF;

  RAISE NOTICE 'OK: % bands accepted, severity 1 clear, % remain on the worklist', v_rev, v_work;
END $$;

COMMIT;
