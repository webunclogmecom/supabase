-- ============================================================================
-- 2026-08-19_2355  Repair the DERM blackout: measure 3 sheets, withdraw 1, stop a leak
-- ============================================================================
-- Fred, 2026-08-19: "do the measurement pass on the three stamped sheets", then, shown
-- the evidence below: "yes, pull them and ship the corrected migration."
--
-- Follow-on from 2026-08-19_2340, which closed the WWTP half of his Field Portal question
-- and recorded the FOG half as open: visits with a manifest document but no redacted copy,
-- because derm.fn_blackout_targets HARD-GATES on a row in derm.page_block_extents.
--
-- ============================================================================
-- PART 0  WHAT ACTUALLY HAPPENED, because this stopped being a measurement pass
-- ============================================================================
-- At 2026-08-19 21:06:58Z, while the sheets were being stamped in Stamp Studio (audit
-- shows fred@ and yannick@ on ticket-311780 and ticket-832996 at 20:57-21:06), SIX
-- page_block_extents rows were inserted for ticket-311780, ticket-832487 AND ticket-833049
-- with the blanket values 25.8 / 64.4 and source 'generated-form-rules-2026-08-19'. Those
-- values are the ones 2026-08-03_0309 measured for a DIFFERENT sheet family; they were not
-- measured for these scans. page_block_extents carries no audit trigger, so there is no
-- record of who wrote them.
--
-- The */5 redact-manifest-sweep then generated THIRTY redacted documents at 21:07-21:08,
-- and customer.work_orders began serving them.
--
-- 🛑 WHAT WAS EXPOSED. Three distinct failures, all verified by opening the served files,
--    not by reasoning about them:
--
--  (1) ticket-833049, 10 documents. The five effective_page-1 clients were each served a
--      page they do not appear on. Proof is in the filenames, since the object name carries
--      the fingerprint md5(etag|y0|y1|btop|bbot):
--          114-CI  m1713-a6eaf476ac.jpg   ==   179-CIG  m1716-a6eaf476ac.jpg
--          168-AVA m1712-2af2e48e97.jpg   ==   083-SHUL m1715-2af2e48e97.jpg
--          221-YAS m1710-5bd85adf3a.jpg   ==   092-TCE  m1718-5bd85adf3a.jpg
--          222-SPE m1711-9379ec1c45.jpg   ==   029-JOS  m1719-9379ec1c45.jpg
--          214-MYK m1714-a27ebb12f7.jpg   ==   082-TFC  m1717-a27ebb12f7.jpg
--      All five pairs share a fingerprint and are byte-identical at 144,028 bytes. Opened
--      114-CI's copy: it shows "179 CiG Espanola Cigars" and nothing of Ceviche Inka's own
--      row. Cause is in PART 5.
--
--  (2) ticket-311780 and ticket-832487, 20 documents. 25.8/64.4 is wrong for these scans.
--      On 832487 p2 the printed roster starts at 23.871 but btop resolved to 25.8, so the
--      top of 174-17's slot was never blacked and was legible in all four page-mates'
--      copies. The bands were also still DERIVED, adding interior slivers up to 1.665pp
--      (about 10px, a full text line).
--
--  (3) ticket-310590 p2, 2 documents, LIVE SINCE 2026-08-10 and unrelated to tonight.
--      165-LPB "La Plaza Bakery And Coffee" is PRINTED on that sheet but has no
--      address_row_map row, so it owns no band. The derived bands stretched across its slot
--      from both sides: 004-BAO's band ran to 43.893 and 186-PV's began at 45.638, while
--      the printed slot is 40.496-47.727. Opened both served files:
--          004-BAO's document shows "GDO-15328  165-LPB La Plaza Bakery And Coffee"
--          186-PV's  document shows "2104 Northeast 123rd Street, North Miami, Florida, 33181"
--      i.e. 165-LPB's identity went to one client and their street address to another.
--
-- ⇒ THE COMMON CAUSE IS NOT THE EXTENT. It is that an extent OPENS THE GATE onto whatever
--   bands exist, and a DERIVED band is a stamp-midpoint heuristic that does not sit on the
--   printed rules. Adding an extent to a sheet whose bands are derived is the unsafe act.
--   That is why PART 3 (snapping) is a PREREQUISITE of PART 2 here and not an improvement
--   on it, and why the two must never be shipped apart.
--
-- ⚠ SYSTEMIC, NOT FIXED HERE, DO NOT LET IT DISAPPEAR: 31 already-serving pages carrying
--   109 documents still run on DERIVED bands. Tonight's three sheets are simply the ones
--   that got extents today. Every one of those pages has the same class of misalignment and
--   needs the same snap. Recorded for Fred as a separate decision.
--
-- ============================================================================
-- METHOD, AND THE CONTROL THAT MAKES IT WORTH ANYTHING
-- ============================================================================
-- Rules are found by ink density over the roster column (x in [2%,45%]); a printed form rule
-- inks >60% of that width, body text never does. That is the detector of 2026-08-03_0340.
--
-- ✅ POSITIVE CONTROL: run against ticket-310429, whose geometry was hand-measured and
--    shipped in 2026-08-03_0340, it reproduced ALL 23 shipped values, worst error 0.067
--    percentage points (about half a pixel), zero misses.
-- ✅ INDEPENDENT RE-MEASUREMENT: four separate agents measured the four 311780/832487 pages
--    blind and agreed with these values to 0.000 pp on all 24 boundaries, all reporting 5
--    printed slots and confirming the "Attach Additional Sheets" line and the
--    "B: Origination of Waste" header both fall OUTSIDE the blacked region.
--
-- Each page shows clean STRONG/WEAK alternation: 6 strong rules (ink 0.88-1.00) are the
-- slot-to-slot boundaries, 5 weaker ones (~0.85) divide Facility Name from Complete Facility
-- Address INSIDE each slot. Both are recorded in PART 1; only strong ones become boundaries.
--
-- ⚠ PAGE IDENTITY WAS VERIFIED BY EYE, AND THAT IS NOT OPTIONAL HERE. fn_blackout_targets'
--   page-identity check is scoped to rows with source='claude-vision-v1'. Every row on all
--   four sheets is 'derm-link', so that check matches nothing and passes trivially. It is
--   INERT for this entire class of sheet, and a person reading the client names off each
--   scan is currently the only page-identity check that exists. That is what caught (1).
--
-- ⚠ AND "REVERSE IMAGE ORDER" IS NOT ITSELF A DEFECT. ticket-310590's images are stored
--   opposite to their printed page numbers (address_1 is the sheet marked "Page 2 of 2") and
--   it is CORRECT, because what matters is only that imgs[effective_page] contains the
--   clients assigned to that effective_page. Verified by name on both pages. 2026-08-10_1500
--   shipped it on that basis and was right to. ticket-833049 fails the real test, not this one.
--
-- ============================================================================
-- ⚠ G1 IS NOT BEING OVERRIDDEN. AN EARLIER DRAFT OF THIS FILE SAID IT WAS. THAT WAS WRONG.
-- ============================================================================
-- 2026-08-03_0340 defines a per-page gate G1: "every band boundary finds a rule within 1.5%
-- of page height". Against the CURRENT DERIVED bands, 832487 p2 fails it at TWO boundaries
-- (25.840 vs 23.871 = 1.969, and 41.100 vs 39.435 = 1.665) and p1 is a 1% near-miss (1.485).
--
-- The correct reading is that G1 was being evaluated against THE WRONG OPERAND. A derived
-- band is a stamp-midpoint heuristic, and G1 reporting that it is not on a printed line is
-- G1 working. Against the SNAPPED bands this migration writes, G1 passes at distance 0.000
-- by construction, because every band edge IS a detected rule. Nothing is waived.
--
-- 🛑 Note that the leak table in PART 0 item (2) IS the G1 residual table: 1.665 appears in
--    both. An earlier draft printed that number as the worst leak PART 3 prevents while
--    separately claiming G1 failed only at the top edge. Same number, two contradictory
--    roles. If you find yourself writing "G1 is a proxy that misfires here", stop: G1 is
--    measuring the thing you are about to fix.
--
-- ⚠ AND DO NOT COPY AN OVERRIDE OUT OF THIS FILE. G1 correctly rejected ticket-831325 p1,
--   whose scan is too light to detect rules at all. A gate waived per-page in a migration
--   header is a gate that dies quietly.
--
-- WHAT ACTUALLY BINDS THE BANDS TO THE PAPER is asserted in the VERIFY block: every
-- band_y0_pct and band_y1_pct written below must EQUAL a rule_pct in derm.page_row_rules for
-- that page. That single check fails on the pre-snap derived bands, on any uniformly shifted
-- tiling, and on a partially-stamped roster. Checks that bands "tile contiguously" or that
-- "each stamp sits inside its own band" do NOT: the derived bands that produced leak (2)
-- satisfy both.
--
-- ⚠ THE EXTENT IS BOUND TO THE PRINTED ROSTER, NOT TO THE BANDS, AND THE DIRECTION MATTERS.
--   Its job (2026-08-03_0046) is to cover every PRINTED slot INCLUDING ones no client owns.
--   So the assertion is top_pct <= min(band_y0) AND bottom_pct >= max(band_y1), plus equality
--   with the FIRST and LAST roster rule. Equality with the band envelope would be the wrong
--   invariant and is exactly how leak (3) is possible. Live proof in this very migration:
--   ticket-310590 p1's fifth slot is EMPTY, so its extent (25.318-63.273) is deliberately
--   WIDER than its band envelope (25.318-55.455). An equality check would have shrunk the
--   extent onto the bands and stopped covering the empty slot.
--
-- ============================================================================
-- REVERSIBILITY - CORRECTED, BECAUSE THE OBVIOUS ROLLBACK PERFORMS THE LEAK
-- ============================================================================
-- 🛑 DELETING THE EXTENTS DOES NOT WITHDRAW ANY DOCUMENT. customer.work_orders reads
--    derm.redacted_manifest_docs.url directly with no fallback, and nothing garbage-collects
--    that table. Closing the gate only stops NEW work; every already-published document keeps
--    being served forever, and can no longer be regenerated because the gate is shut.
--    Withdrawing a document means deleting its redacted_manifest_docs row. That is why
--    PART 4 exists and why PART 2 alone would not have been enough.
--
-- 🛑 AND THE ORDER IS LOAD-BEARING. Setting the bands back to NULL while the extents still
--    exist re-stales the fingerprint, and the */5 sweep regenerates all of them from the
--    DERIVED bands, i.e. it re-creates leak (2) and deletes the good file while doing it.
--    To roll back: (i) DELETE the extents, (ii) then NULL the bands, (iii) then DELETE the
--    redacted_manifest_docs rows. Never (ii) before (i).
--
-- Pre-delete backup of every row touched, including all 38 redacted_manifest_docs rows and
-- the 8 extents, with a restore hint:
--     backups/2026-08-19_derm_blackout_incident_pre_delete.json
-- It is the ONLY record for redacted_manifest_docs and page_block_extents, neither of which
-- is audited (checked, not assumed, per the 2026-08-14 rule).
--
-- AUDIT (rule 8): page_row_rules and page_block_extents are MEASUREMENT tables (machine
-- geometry, no human-editable business fields) -> audit OPT-OUT, consistent with how both
-- were created. The band writes land on derm.address_row_map, which IS audited, so what each
-- customer can see is recorded there with old_row.
--
-- ⚠ band_source IS WRITTEN. CLAUDE.md warns that band_is_manual=true can mean "snapped by
--   machine", not "confirmed by a human". These 28 rows say so in band_source rather than
--   silently presenting as human-confirmed.
--
-- 🛑 EVERYTHING BELOW, INCLUDING THE VERIFY, IS ONE TRANSACTION. 2026-08-03_0046 probed
--    rolled back before applying; a VERIFY placed after COMMIT would leave a bad state live
--    with a */5 sweep ready to publish it.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1  The detected printed rules. Evidence for the snap, and the operand the
--         VERIFY block checks every band edge against.
-- ---------------------------------------------------------------------------
INSERT INTO derm.page_row_rules (dump_folder, effective_page, rule_pct, ink_frac, source) VALUES
 ('ticket-311780',1,23.548,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',1,25.887,0.89,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',1,29.919,0.86,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',1,34.113,0.97,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',1,37.419,0.86,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',1,40.726,0.98,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',1,43.952,0.86,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',1,47.903,0.98,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',1,51.532,0.86,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',1,55.726,0.94,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',1,59.355,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',1,63.468,0.98,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,23.377,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,25.649,0.98,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,29.789,0.84,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,34.091,0.97,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,37.419,0.86,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,40.747,0.98,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,43.912,0.86,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,47.971,0.98,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,51.623,0.86,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,55.763,0.98,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,59.416,0.86,'claude-rulesnap-2026-08-19'),
 ('ticket-311780',2,63.555,0.98,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,21.855,0.89,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,24.355,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,28.548,0.86,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,32.984,1.00,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,36.452,0.86,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,39.919,1.00,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,43.306,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,47.339,1.00,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,51.129,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,55.403,1.00,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,59.194,0.71,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',1,63.468,0.91,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,21.452,0.84,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,23.871,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,28.065,0.82,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,32.500,1.00,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,36.048,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,39.435,1.00,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,42.823,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,46.935,1.00,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,50.726,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,55.081,1.00,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,58.790,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-832487',2,63.065,1.00,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,22.955,0.88,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,25.318,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,29.318,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,33.636,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,36.955,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,40.364,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,43.591,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,47.591,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,51.227,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,55.455,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,59.091,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',1,63.273,0.98,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,23.140,0.87,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,25.517,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,29.494,0.84,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,33.781,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,37.138,0.85,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,40.496,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,43.750,0.84,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,47.727,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,51.395,0.84,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,55.475,0.99,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,59.143,0.84,'claude-rulesnap-2026-08-19'),
 ('ticket-310590',2,63.326,0.99,'claude-rulesnap-2026-08-19')
ON CONFLICT (dump_folder, effective_page, rule_pct) DO NOTHING;

-- ---------------------------------------------------------------------------
-- PART 2  Extents. top_pct = FIRST roster rule, bottom_pct = LAST ROSTER rule (never the
--         rule below "Attach Additional Sheets", which must stay visible).
--         ticket-833049's two rows are DELETED: it must not generate anything (PART 5).
-- ---------------------------------------------------------------------------
DELETE FROM derm.page_block_extents WHERE dump_folder = 'ticket-833049';

INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at) VALUES
 ('ticket-311780', 1, 25.887, 63.468, 'claude-formrules-2026-08-19', now()),
 ('ticket-311780', 2, 25.649, 63.555, 'claude-formrules-2026-08-19', now()),
 ('ticket-832487', 1, 24.355, 63.468, 'claude-formrules-2026-08-19', now()),
 ('ticket-832487', 2, 23.871, 63.065, 'claude-formrules-2026-08-19', now()),
 ('ticket-310590', 1, 25.318, 63.273, 'claude-formrules-2026-08-19', now()),
 ('ticket-310590', 2, 25.517, 63.326, 'claude-formrules-2026-08-19', now())
ON CONFLICT (dump_folder, effective_page)
DO UPDATE SET top_pct = EXCLUDED.top_pct, bottom_pct = EXCLUDED.bottom_pct,
              source  = EXCLUDED.source,  measured_at = EXCLUDED.measured_at;

-- ---------------------------------------------------------------------------
-- PART 3  Snap every band to exactly one printed slot. Adjacent bands SHARE a boundary
--         on purpose: contiguity, so no strip is owned by nobody.
-- ---------------------------------------------------------------------------
-- ticket-311780 page 1
UPDATE derm.address_row_map SET band_y0_pct=25.887, band_y1_pct=34.113, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=994;  -- 233-AH
UPDATE derm.address_row_map SET band_y0_pct=34.113, band_y1_pct=40.726, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=990;  -- 013-DIM
UPDATE derm.address_row_map SET band_y0_pct=40.726, band_y1_pct=47.903, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=991;  -- 040-MV
UPDATE derm.address_row_map SET band_y0_pct=47.903, band_y1_pct=55.726, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=992;  -- 014-JOY
UPDATE derm.address_row_map SET band_y0_pct=55.726, band_y1_pct=63.468, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=993;  -- 001-VIN
-- ticket-311780 page 2
UPDATE derm.address_row_map SET band_y0_pct=25.649, band_y1_pct=34.091, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=988;  -- 306-16
UPDATE derm.address_row_map SET band_y0_pct=34.091, band_y1_pct=40.747, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=985;  -- 293-ALC
UPDATE derm.address_row_map SET band_y0_pct=40.747, band_y1_pct=47.971, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=989;  -- 227-PER
UPDATE derm.address_row_map SET band_y0_pct=47.971, band_y1_pct=55.763, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=987;  -- 249-LOU
UPDATE derm.address_row_map SET band_y0_pct=55.763, band_y1_pct=63.555, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=986;  -- 141-NEY
-- ticket-832487 page 1
UPDATE derm.address_row_map SET band_y0_pct=24.355, band_y1_pct=32.984, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=962;  -- 031-KRU
UPDATE derm.address_row_map SET band_y0_pct=32.984, band_y1_pct=39.919, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=959;  -- 015-FLA
UPDATE derm.address_row_map SET band_y0_pct=39.919, band_y1_pct=47.339, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=960;  -- 058-SOH
UPDATE derm.address_row_map SET band_y0_pct=47.339, band_y1_pct=55.403, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=961;  -- 244-URI
UPDATE derm.address_row_map SET band_y0_pct=55.403, band_y1_pct=63.468, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=954;  -- 231-CHE
-- ticket-832487 page 2
UPDATE derm.address_row_map SET band_y0_pct=23.871, band_y1_pct=32.500, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=956;  -- 174-17
UPDATE derm.address_row_map SET band_y0_pct=32.500, band_y1_pct=39.435, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=953;  -- 110-CLA
UPDATE derm.address_row_map SET band_y0_pct=39.435, band_y1_pct=46.935, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=958;  -- 084-ULT
UPDATE derm.address_row_map SET band_y0_pct=46.935, band_y1_pct=55.081, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=957;  -- 032-LG
UPDATE derm.address_row_map SET band_y0_pct=55.081, band_y1_pct=63.065, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=955;  -- 132-PUM
-- ticket-310590 page 1  (slot 5, 55.455-63.273, is printed but EMPTY: owned by nobody, blacked for all)
UPDATE derm.address_row_map SET band_y0_pct=25.318, band_y1_pct=33.636, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=917;  -- 010-CS
UPDATE derm.address_row_map SET band_y0_pct=33.636, band_y1_pct=40.364, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=918;  -- 189-FRE
UPDATE derm.address_row_map SET band_y0_pct=40.364, band_y1_pct=47.591, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=920;  -- 070-TCE
UPDATE derm.address_row_map SET band_y0_pct=47.591, band_y1_pct=55.455, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=919;  -- 191-TEN
-- ticket-310590 page 2  (slot 3, 40.496-47.727, is 165-LPB, printed but owning NO row: this
--                        is leak (3). Snapping is what puts it inside both black boxes.)
UPDATE derm.address_row_map SET band_y0_pct=25.517, band_y1_pct=33.781, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=914;  -- 047-PAM
UPDATE derm.address_row_map SET band_y0_pct=33.781, band_y1_pct=40.496, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=915;  -- 004-BAO
UPDATE derm.address_row_map SET band_y0_pct=47.727, band_y1_pct=55.475, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=913;  -- 186-PV
UPDATE derm.address_row_map SET band_y0_pct=55.475, band_y1_pct=63.326, band_source='claude-rulesnap-2026-08-19', band_set_at=now() WHERE id=916;  -- 081-TCE

-- ---------------------------------------------------------------------------
-- PART 4  Withdraw every mis-redacted document.
--         833049's 10 are withdrawn PERMANENTLY (its gate is now shut, PART 5).
--         The other 28 are withdrawn so the */5 sweep regenerates them from the corrected
--         geometry; until it does, the Field Portal card shows its honest
--         "On file, not available for online viewing" placeholder, which is fail-closed.
--   Pinned to primary keys via the sheet membership that makes them in scope, per the
--   2026-08-14 rule, so it cannot fire wider if the world changed since the backup.
-- ---------------------------------------------------------------------------
DELETE FROM derm.redacted_manifest_docs rd
 WHERE rd.manifest_id IN (
   SELECT DISTINCT r.matched_manifest_id FROM derm.address_row_map r
    WHERE r.dump_folder IN ('ticket-311780','ticket-832487','ticket-833049','ticket-310590')
      AND r.matched_manifest_id IS NOT NULL);

-- ---------------------------------------------------------------------------
-- PART 5  🛑 ticket-833049 IS HELD, AND THE HOLD IS NOW A DATABASE FACT.
-- ---------------------------------------------------------------------------
-- A comment cannot hold anything. Tonight proves it: this sheet was already flagged and an
-- extent was inserted for it anyway, within hours. The constraint below means unlocking it
-- requires deleting a named constraint, which is a deliberate act that surfaces this file.
--
-- THE DEFECT. derm.ticket_page_images builds its page array by GROUPING address_row_map on
-- `page` and taking the mode image per group. On this sheet nine rows carry page=1 and one
-- carries page=2, so it emits [address_1, address_1, address_2] - a DUPLICATE at index 2.
-- Combined with the images being stored opposite to their printed page numbers, effective_page
-- 1 resolves to the PHYSICAL PAGE 2 image. That is leak (1).
--
-- 🛑 THE OBVIOUS ONE-LINE FIX DOUBLES THE EXPOSURE. DO NOT DO IT.
--    "Normalise the stray page=2 to page=1" makes the array [address_1, address_2]. Then
--    effective_page 1 still resolves to address_1 (still wrong) and effective_page 2 flips
--    from accidentally-correct to wrong. Exposed clients go from 5 to 10. It also erases the
--    duplicate-slot signature, which is currently the only machine-visible tell.
--
-- 🛑 AND ROW_INDEX 10 IS NOT "STRAY" - IT IS THE ONLY ROW THAT AGREES WITH THE PAPER.
--    effective_page is COALESCE(stamp_page, page). Five clients sit on effective_page 2, and
--    only one of them carries page=2. It is the other four whose `page` contradicts the scan
--    their client is printed on. An earlier draft of this file called row_index 10 stray and
--    proposed normalising it, which inverts which data is defective.
--
-- ⚠ INDEPENDENT SECOND BLOCKER, so page mapping is not one fix away: it is a HANDWRITTEN
--   6-SLOT form ("more than 6 Grease Interceptors Pumped!"), 5 filled and 1 empty, with rule
--   spacing near 5.6pp, while every band on it comes from the 5-slot template shared by the
--   other sheets (29.80/37.72/44.48/51.81/60.04). The y geometry is wrong WITHIN the page
--   whichever image it is paired with, and the empty sixth slot must sit inside the extent.
--
-- ⚠ DO NOT REPEAT THE "1 of 128 sheets" SCOPE CLAIM AS EVIDENCE OF SAFETY. It measures the
--   duplicate-slot PROXY, not page-to-image mismatch. No automated page-identity check covers
--   source='derm-link' rows, which is every row on all four sheets, so the fleet has never
--   been swept for the actual defect. ticket-831938 and ticket-310590 were checked BY EYE
--   tonight and are correctly mapped; nothing else has been.
-- ---------------------------------------------------------------------------
ALTER TABLE derm.page_block_extents
  ADD CONSTRAINT page_block_extents_no_ticket_833049
  CHECK (dump_folder <> 'ticket-833049');

COMMENT ON CONSTRAINT page_block_extents_no_ticket_833049 ON derm.page_block_extents IS
  'ticket-833049 is HELD: derm.ticket_page_images emits a duplicate page slot for it, so '
  'effective_page 1 resolves to the physical page 2 image and five clients were served a page '
  'they do not appear on (2026-08-19). It is also a 6-slot handwritten form carrying 5-slot '
  'template bands. Read PART 5 of docs/migrations/2026-08-19_2355 before dropping this.';

-- ---------------------------------------------------------------------------
-- VERIFY - inside the transaction, so a failure rolls the whole thing back.
-- ---------------------------------------------------------------------------
DO $verify$
DECLARE
  fail text := '';
  v_unbound int; v_ext int; v_bad int; v_gap int; v_docs int; v_targets int; v_snapped int;
BEGIN
  -- ✅ THE BINDING CHECK. Every band edge must BE a detected printed rule. This is the only
  --    assertion here that fails on the pre-snap derived bands, on a uniformly shifted
  --    tiling, and on a partially-stamped roster. Everything else can pass on leaky data.
  SELECT count(*) INTO v_unbound
    FROM derm.address_row_map r
    JOIN derm.v_stamp_row_bands b ON b.id = r.id
   WHERE r.dump_folder IN ('ticket-311780','ticket-832487','ticket-310590')
     AND ( NOT EXISTS (SELECT 1 FROM derm.page_row_rules pr
                        WHERE pr.dump_folder = r.dump_folder AND pr.effective_page = b.effective_page
                          AND pr.rule_pct = b.band_y0_pct)
        OR NOT EXISTS (SELECT 1 FROM derm.page_row_rules pr
                        WHERE pr.dump_folder = r.dump_folder AND pr.effective_page = b.effective_page
                          AND pr.rule_pct = b.band_y1_pct) );
  IF v_unbound > 0 THEN
    fail := fail || format('%s band edges are not on a detected printed rule; ', v_unbound);
  END IF;

  -- 28 bands snapped, and each records HOW (not silently presenting as human-confirmed)
  SELECT count(*) INTO v_snapped FROM derm.address_row_map
   WHERE dump_folder IN ('ticket-311780','ticket-832487','ticket-310590')
     AND band_source = 'claude-rulesnap-2026-08-19';
  IF v_snapped <> 28 THEN fail := fail || format('expected 28 snapped bands, found %s; ', v_snapped); END IF;

  -- each client's stamp must sit strictly inside its own band (row-to-slot mapping)
  SELECT count(*) INTO v_bad FROM derm.address_row_map r
    JOIN derm.v_stamp_row_bands b ON b.id = r.id
   WHERE r.dump_folder IN ('ticket-311780','ticket-832487','ticket-310590')
     AND NOT (r.stamp_y_pct > b.band_y0_pct AND r.stamp_y_pct < b.band_y1_pct);
  IF v_bad > 0 THEN fail := fail || format('%s stamps fall outside their own band; ', v_bad); END IF;

  -- bands must not OVERLAP. They may leave a gap where a printed slot is unowned
  -- (310590 p1 slot 5 empty, p2 slot 3 = 165-LPB); such a gap is covered by the extent and
  -- belongs to no one, which is correct. An OVERLAP would mean two owners for one strip.
  SELECT count(*) INTO v_gap FROM (
    SELECT b.band_y1_pct AS y1,
           lead(b.band_y0_pct) OVER (PARTITION BY r.dump_folder, b.effective_page
                                     ORDER BY b.band_y0_pct) AS next_y0
      FROM derm.address_row_map r JOIN derm.v_stamp_row_bands b ON b.id = r.id
     WHERE r.dump_folder IN ('ticket-311780','ticket-832487','ticket-310590')
  ) t WHERE next_y0 IS NOT NULL AND next_y0 < y1;
  IF v_gap > 0 THEN fail := fail || format('%s band pairs OVERLAP; ', v_gap); END IF;

  -- extent must COVER the band envelope (widening direction) and equal the printed roster
  IF EXISTS (
    SELECT 1 FROM derm.page_block_extents e
     WHERE e.dump_folder IN ('ticket-311780','ticket-832487','ticket-310590')
       AND ( e.top_pct    > (SELECT min(b.band_y0_pct) FROM derm.address_row_map r
                               JOIN derm.v_stamp_row_bands b ON b.id=r.id
                              WHERE r.dump_folder=e.dump_folder AND b.effective_page=e.effective_page)
          OR e.bottom_pct < (SELECT max(b.band_y1_pct) FROM derm.address_row_map r
                               JOIN derm.v_stamp_row_bands b ON b.id=r.id
                              WHERE r.dump_folder=e.dump_folder AND b.effective_page=e.effective_page))
  ) THEN fail := fail || 'an extent does not cover its band envelope; '; END IF;

  -- The extent must be the printed ROSTER, pinned structurally rather than by an ink
  -- threshold. ⚠ An ink cutoff CANNOT separate the roster-top rule from the
  -- "B: Origination of Waste" header rule above it: on 832487 p1 the header inks 0.89 while
  -- on 311780 p1 the roster top itself inks 0.89. Any single threshold mislabels one of them.
  --   top_pct    = the LOWEST printed rule at or above the first owned band
  --   bottom_pct = the last roster rule, which is the greatest rule recorded for the page
  --                (PART 1 deliberately stops at the last roster rule and does not record
  --                 the rule below the "Attach Additional Sheets" row)
  IF EXISTS (
    SELECT 1 FROM derm.page_block_extents e
     WHERE e.dump_folder IN ('ticket-311780','ticket-832487','ticket-310590')
       AND ( e.top_pct    IS DISTINCT FROM (
               SELECT max(pr.rule_pct) FROM derm.page_row_rules pr
                WHERE pr.dump_folder=e.dump_folder AND pr.effective_page=e.effective_page
                  AND pr.rule_pct <= (SELECT min(b.band_y0_pct) FROM derm.address_row_map r
                                        JOIN derm.v_stamp_row_bands b ON b.id=r.id
                                       WHERE r.dump_folder=e.dump_folder
                                         AND b.effective_page=e.effective_page))
          OR e.bottom_pct IS DISTINCT FROM (
               SELECT max(pr.rule_pct) FROM derm.page_row_rules pr
                WHERE pr.dump_folder=e.dump_folder AND pr.effective_page=e.effective_page))
  ) THEN fail := fail || 'an extent is not the first/last roster rule; '; END IF;

  SELECT count(*) INTO v_ext FROM derm.page_block_extents
   WHERE dump_folder IN ('ticket-311780','ticket-832487','ticket-310590') AND bottom_pct > top_pct;
  IF v_ext <> 6 THEN fail := fail || format('expected 6 sane extents, found %s; ', v_ext); END IF;

  -- every mis-redacted document is withdrawn
  SELECT count(*) INTO v_docs FROM derm.redacted_manifest_docs rd
   WHERE rd.manifest_id IN (SELECT DISTINCT matched_manifest_id FROM derm.address_row_map
                             WHERE dump_folder IN ('ticket-311780','ticket-832487','ticket-833049','ticket-310590'));
  IF v_docs <> 0 THEN fail := fail || format('%s mis-redacted documents still published; ', v_docs); END IF;

  -- POSITIVE CONTROL: the three repaired sheets must actually be QUEUED for regeneration.
  -- If this is 0 the gate never opened and every check above passed while achieving nothing.
  SELECT count(*) INTO v_targets FROM derm.fn_blackout_targets(200) t
    JOIN derm.address_row_map r ON r.matched_manifest_id = t.manifest_id
   WHERE r.dump_folder IN ('ticket-311780','ticket-832487','ticket-310590');
  IF v_targets = 0 THEN fail := fail || 'nothing queued for regeneration - the gate did not open; '; END IF;

  -- NEGATIVE CONTROL: 833049 must be queued for NOTHING, ever.
  IF EXISTS (SELECT 1 FROM derm.fn_blackout_targets(200) t
               JOIN derm.address_row_map r ON r.matched_manifest_id = t.manifest_id
              WHERE r.dump_folder = 'ticket-833049') THEN
    fail := fail || 'ticket-833049 is queued - it is HELD, see PART 5; ';
  END IF;

  IF fail <> '' THEN RAISE EXCEPTION 'VERIFY FAILED: %', fail; END IF;
  RAISE NOTICE 'bands snapped 28 (all edges on printed rules), extents 6, docs withdrawn, % queued to regenerate', v_targets;
END
$verify$;

COMMIT;
