-- 2026-08-03_0340  Band line-snapping, gated on confident detection of the printed form rules
--
-- Fred: "Go ahead and build it with the confidence gate."
--
-- -- THE PROBLEM ---------------------------------------------------------------
-- A "band" is the horizontal strip of a shared DERM sheet that belongs to ONE client: the redactor
-- shows that strip and blacks the rest of the roster. Today the boundaries are derived from STAMP
-- positions -- see derm.v_stamp_row_bands: derived_y0 = stamp_y - LEAST(half-gap-to-prev,
-- 0.75*median_gap), mirrored for y1. The printed form has its OWN horizontal rules dividing the
-- client blocks, and the two do not coincide, so a boundary can cut THROUGH a printed line of text.
--
-- Measured on sheet 1071 (ticket-831325 p1, H=724): 059-SK's address occupies rows 235-245, the
-- band boundary lands at row 244, and the printed rule is at row 253. Rows 244-245 of 059-SK's
-- address are therefore formally on 293-ALC's side and survive in 293-ALC's copy. That is the
-- sliver left over after the 2026-08-03 off-by-one fix, which could only ever recover ONE row.
--
-- -- WHY THIS NEEDS NO VIEW CHANGE ---------------------------------------------
-- v_stamp_row_bands already resolves `COALESCE(manual_y0, derived_y0)` where the manual values are
-- derm.address_row_map.band_y0_pct / band_y1_pct. Snapping is therefore written through the
-- EXISTING manual-override channel: no view is touched, `band_is_manual` flips to true, the table
-- carries an audit trigger so every write is recorded, and the whole thing is reversible by setting
-- the two columns back to NULL.
--
-- -- 🛑 THE CONFIDENCE GATE, AND WHY IT IS ALL-OR-NOTHING PER PAGE -------------
-- Rules are detected by full-width ink density over the roster column (x in [2%,45%]): a printed
-- rule inks >60% of that width, body text never does. Two gates, BOTH required, evaluated PER PAGE:
--   G1  every band boundary on the page finds a rule within 1.5% of page height (~11 rows)
--   G2  after snapping, bands stay monotonic and non-overlapping
-- If either fails, the ENTIRE PAGE falls back to the derived bands. Per-page rather than per-card
-- because half-snapped bands on one page would no longer tile the roster: a gap between two bands
-- is a strip belonging to nobody, which is exactly how a neighbour's row becomes visible.
--
-- Gate results, measured:
--   ticket-310429 p1 -> SNAP       all 6 boundaries matched, distances 0.4-6.2 rows
--   ticket-310429 p2 -> SNAP       all 4 boundaries matched, distances 5.5-7.0 rows
--   ticket-831325 p1 -> FALL BACK  293-ALC's lower boundary (row 302) has NO rule within 48.8 rows
-- The rejected page is exactly the one whose scan is too light for the threshold (only 4 rules found
-- vs 13-14 on the others). The gate caught it on its own; it was not hand-picked. 059-SK/293-ALC
-- therefore KEEP the existing behaviour and keep their 2-row residual until that page is measured
-- properly (export -> ocr-band-measure -> apply_bands.js, the same route used for extents).
--
-- ⚠ NOTE ON DIRECTION: snapping is NOT uniformly "wider". 224-MP's lower boundary moves UP (row 313
-- -> 306) because its derived band was overshooting into slot 3. Snapping makes each band equal
-- EXACTLY one printed slot -- some grow, some shrink. That is the point: a band that overshoots is
-- how one client ends up seeing part of the next slot.
--
-- ⚠ Adjacent bands deliberately SHARE a boundary after snapping (196-PV.y1 = 028-HUM.y0 = 34.584).
-- Contiguity is required; a gap would be an unowned strip.
--
-- ADR 010 rule 8: derm.page_row_rules is a new MEASUREMENT table (machine-detected geometry, no
-- human-editable business fields) -> audit OPT-OUT, consistent with derm.page_block_extents which
-- carries no audit trigger either. The band writes land on derm.address_row_map, which IS audited,
-- so the change to what each customer sees is recorded there.

BEGIN;

CREATE TABLE IF NOT EXISTS derm.page_row_rules (
  dump_folder    text        NOT NULL,
  effective_page integer     NOT NULL,
  rule_pct       numeric(7,3) NOT NULL,
  ink_frac       numeric(4,3) NOT NULL,
  source         text        NOT NULL,
  detected_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dump_folder, effective_page, rule_pct)
);
COMMENT ON TABLE derm.page_row_rules IS
  'Printed horizontal rules detected on a DERM address sheet page, as % of page height. Feeds band '
  'line-snapping. Detection: full-width ink density over the roster column; a rule inks >60% of it. '
  'Presence of rows here does NOT mean a page was snapped -- see the per-page confidence gate in '
  'docs/migrations/2026-08-03_0340.';

REVOKE ALL ON derm.page_row_rules FROM PUBLIC, anon;
GRANT SELECT ON derm.page_row_rules TO authenticated, service_role;

INSERT INTO derm.page_row_rules (dump_folder, effective_page, rule_pct, ink_frac, source) VALUES
 ('ticket-310429',1,23.994,0.87,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',1,26.273,0.97,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',1,30.295,0.84,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',1,34.584,0.97,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',1,37.802,0.84,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',1,41.287,0.97,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',1,44.504,0.84,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',1,48.525,0.97,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',1,52.145,0.77,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',1,56.434,0.97,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',1,60.054,0.83,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',1,64.209,0.97,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',2,23.663,0.78,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',2,26.070,0.98,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',2,29.947,0.75,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',2,34.358,0.96,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',2,37.567,0.84,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',2,40.909,0.96,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',2,44.118,0.84,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',2,48.128,0.95,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',2,51.738,0.75,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',2,55.882,0.92,'claude-rulesnap-2026-08-03'),
 ('ticket-310429',2,63.503,0.88,'claude-rulesnap-2026-08-03'),
 ('ticket-831325',1,23.757,0.89,'claude-rulesnap-2026-08-03'),
 ('ticket-831325',1,26.243,0.87,'claude-rulesnap-2026-08-03'),
 ('ticket-831325',1,30.525,0.72,'claude-rulesnap-2026-08-03'),
 ('ticket-831325',1,34.945,0.77,'claude-rulesnap-2026-08-03')
ON CONFLICT (dump_folder, effective_page, rule_pct) DO NOTHING;

-- ---- SNAP: ticket-310429 pages 1 and 2 only (both gates passed) ---------------
-- ticket-831325 p1 is deliberately absent: G1 failed.
UPDATE derm.address_row_map SET band_y0_pct = 26.273, band_y1_pct = 34.584 WHERE id = 897;  -- 196-PV  p1
UPDATE derm.address_row_map SET band_y0_pct = 34.584, band_y1_pct = 41.287 WHERE id = 896;  -- 028-HUM p1
UPDATE derm.address_row_map SET band_y0_pct = 41.287, band_y1_pct = 48.525 WHERE id = 894;  -- 044-MP  p1
UPDATE derm.address_row_map SET band_y0_pct = 48.525, band_y1_pct = 56.434 WHERE id = 895;  -- 249-LOU p1
UPDATE derm.address_row_map SET band_y0_pct = 56.434, band_y1_pct = 64.209 WHERE id = 893;  -- 041-MB  p1
UPDATE derm.address_row_map SET band_y0_pct = 26.070, band_y1_pct = 34.358 WHERE id = 892;  -- 072-TCE p2
UPDATE derm.address_row_map SET band_y0_pct = 34.358, band_y1_pct = 40.909 WHERE id = 891;  -- 224-MP  p2

COMMIT;
