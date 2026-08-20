-- ============================================================================
-- 2026-08-20_2145  Snap the remaining DERIVED redaction bands onto printed form rules
-- ============================================================================
--
-- Closes the systemic item PART 0 of 2026-08-19_2355 flagged and deliberately
-- did not fix: served redacted documents still built on DERIVED bands. A derived
-- band is a stamp-midpoint heuristic from derm.v_stamp_row_bands. It does not sit
-- on the printed form rules, and that is the mechanism that put 165-LPB's name on
-- 004-BAO's document and its street address on 186-PV's.
--
-- MEASURED 2026-08-20 before touching anything:
--   621 served redacted documents; 550 already carry a manual/snapped override.
--   80 rows across 25 (dump_folder, effective_page) pages were still DERIVED.
--   Rule detection had ever run on 5 of the 121 serving folders.
--
-- THIS FILE WRITES 63 ROWS ACROSS 17 PAGES. It deliberately leaves the rest.
--
-- HOW THE RULES WERE FOUND: ink density over the roster column (x in [2%,45%]);
-- a printed form rule inks >60% of that width, body text never does. Same detector
-- as 2026-08-03_0340, run against each page's OWN source image, taken from
-- derm.redacted_manifest_docs.source_url rather than address_row_map.image_url.
-- ⚠ That distinction matters: 14 of the 25 pages have rows whose image_url is the
--   literal string 'pending', and 4 folders have two effective_pages whose rows
--   all point at address_1. Reading image_url would have mapped page 2 onto page
--   1's image, which is the ticket-833049 shape. source_url proves it does not
--   happen: every page-2 document is built from address_2. Checked all four.
--
-- GATES, both per page, neither waived:
--   G1  every band edge finds a detected rule within 1.5% of page height
--   G2  after snapping, bands stay monotonic and non-overlapping
-- Against the bands written here G1 passes at distance 0.000 by construction,
-- because every edge below IS a detected rule. The VERIFY block asserts exactly
-- that, and it is the only check that fails on a derived band.
--
-- 🛑 NOT FIXED HERE, AND IT NEEDS FRED. 8 pages / 17 rows failed the gates:
--
--   MEASURED NEIGHBOUR EXPOSURE (detection sound, band reaches past a printed rule):
--     ticket-311045 p1   1.60pp   205-SAS
--     ticket-310607 p1   1.57pp   165-LPB, 192-FRK, 056-STM, 139-LTG
--     ticket-832194 p2   1.40pp   025-GRO, 167-FEN
--     ticket-831047 p1   1.01pp   032-LG
--   For scale, the confirmed 2026-08-19 leak that showed a full text line of a
--   neighbour's address measured 1.665pp. These are the same order.
--
--   DETECTION FAILED, EXPOSURE UNKNOWN (dark scans, roster median luminance 210-216
--   against 244-255 on every page that worked):
--     ticket-831102 p1, ticket-831102 p2, ticket-831325 p1   (7 rows)
--   ⚠ Their raw numbers look catastrophic (23.3pp, 17.4pp, 11.4pp). DO NOT QUOTE
--     THOSE. Only 3 rules were found where 4 edges were needed, so every edge
--     snapped to the same rule and the arithmetic is an artifact of a failed
--     instrument, not a measurement. The honest statement is "unknown".
--
--   NO EXPOSURE, LEFT ALONE ON PURPOSE:
--     ticket-831710 p1  214-MYK. It fails G1 at 1.512 but every error is INWARD:
--     the band sits inside the true slot, so it crops the client's own row and
--     reveals nobody. Outward error is the only kind that leaks.
--
-- ⚠ band_source is written. CLAUDE.md warns band_is_manual=true can mean "snapped
--   by machine", not "confirmed by a human". These rows say so in band_source.
-- ⚠ Changing a band re-stales the fingerprint, so redact-manifest-sweep (*/5,
--   limit 1) regenerates these documents. The OLD document stays served until it
--   does. That is the pre-existing state, not a regression introduced here.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1  The detected printed rules. Evidence for the snap, and the operand
--         the VERIFY block checks against.
-- ---------------------------------------------------------------------------
INSERT INTO derm.page_row_rules (dump_folder, effective_page, rule_pct, ink_frac, source) VALUES
  ('ticket-309661', 1, 29.902, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 1, 35.784, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 1, 41.667, 0.957, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 1, 47.549, 0.957, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 1, 53.431, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 1, 59.454, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 1, 65.336, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 2, 29.247, 0.848, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 2, 35.274, 0.739, 'claude-rulesnap-2026-08-20'),
  ('ticket-309661', 2, 41.301, 0.693, 'claude-rulesnap-2026-08-20'),
  ('ticket-309898', 1, 24.429, 0.936, 'claude-rulesnap-2026-08-20'),
  ('ticket-309898', 1, 33.185, 0.939, 'claude-rulesnap-2026-08-20'),
  ('ticket-309898', 1, 40.165, 0.939, 'claude-rulesnap-2026-08-20'),
  ('ticket-309898', 1, 47.779, 0.939, 'claude-rulesnap-2026-08-20'),
  ('ticket-309898', 1, 56.028, 0.939, 'claude-rulesnap-2026-08-20'),
  ('ticket-309898', 1, 64.15, 0.939, 'claude-rulesnap-2026-08-20'),
  ('ticket-309944', 1, 26.028, 0.982, 'claude-rulesnap-2026-08-20'),
  ('ticket-309944', 1, 34.383, 0.982, 'claude-rulesnap-2026-08-20'),
  ('ticket-309944', 1, 41.067, 0.98, 'claude-rulesnap-2026-08-20'),
  ('ticket-309944', 1, 48.265, 0.982, 'claude-rulesnap-2026-08-20'),
  ('ticket-820714', 1, 27.742, 0.936, 'claude-rulesnap-2026-08-20'),
  ('ticket-820714', 1, 33.227, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-820714', 1, 38.712, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-820714', 1, 44.196, 0.966, 'claude-rulesnap-2026-08-20'),
  ('ticket-820714', 1, 49.681, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-820714', 1, 55.166, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-829788', 1, 28.042, 0.961, 'claude-rulesnap-2026-08-20'),
  ('ticket-829788', 1, 33.462, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-829788', 1, 38.993, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-829788', 1, 44.303, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-830088', 1, 27.375, 0.922, 'claude-rulesnap-2026-08-20'),
  ('ticket-830088', 1, 32.818, 0.955, 'claude-rulesnap-2026-08-20'),
  ('ticket-830088', 1, 38.26, 0.959, 'claude-rulesnap-2026-08-20'),
  ('ticket-830088', 1, 43.597, 0.957, 'claude-rulesnap-2026-08-20'),
  ('ticket-830088', 1, 49.039, 0.969, 'claude-rulesnap-2026-08-20'),
  ('ticket-830088', 1, 54.376, 0.969, 'claude-rulesnap-2026-08-20'),
  ('ticket-830088', 1, 59.712, 0.813, 'claude-rulesnap-2026-08-20'),
  ('ticket-830310', 1, 26.907, 0.804, 'claude-rulesnap-2026-08-20'),
  ('ticket-830310', 1, 38.206, 0.765, 'claude-rulesnap-2026-08-20'),
  ('ticket-830413', 1, 27.427, 0.963, 'claude-rulesnap-2026-08-20'),
  ('ticket-830413', 1, 32.83, 0.963, 'claude-rulesnap-2026-08-20'),
  ('ticket-830413', 1, 38.233, 0.951, 'claude-rulesnap-2026-08-20'),
  ('ticket-830574', 1, 28.037, 0.929, 'claude-rulesnap-2026-08-20'),
  ('ticket-830574', 1, 33.495, 0.895, 'claude-rulesnap-2026-08-20'),
  ('ticket-830574', 1, 38.864, 0.966, 'claude-rulesnap-2026-08-20'),
  ('ticket-830574', 1, 44.322, 0.965, 'claude-rulesnap-2026-08-20'),
  ('ticket-830574', 1, 49.692, 0.966, 'claude-rulesnap-2026-08-20'),
  ('ticket-830673', 1, 25.697, 0.982, 'claude-rulesnap-2026-08-20'),
  ('ticket-830673', 1, 34.057, 0.982, 'claude-rulesnap-2026-08-20'),
  ('ticket-830673', 1, 40.779, 0.982, 'claude-rulesnap-2026-08-20'),
  ('ticket-830673', 1, 47.992, 0.982, 'claude-rulesnap-2026-08-20'),
  ('ticket-830673', 1, 55.861, 0.899, 'claude-rulesnap-2026-08-20'),
  ('ticket-830673', 1, 63.566, 0.981, 'claude-rulesnap-2026-08-20'),
  ('ticket-831220', 1, 24.097, 1, 'claude-rulesnap-2026-08-20'),
  ('ticket-831220', 1, 36.426, 0.851, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 1, 25.205, 0.985, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 1, 33.538, 0.985, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 1, 40.232, 0.96, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 1, 47.609, 0.985, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 1, 55.396, 0.98, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 1, 63.32, 0.985, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 2, 25.351, 0.983, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 2, 33.638, 0.983, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 2, 40.379, 0.983, 'claude-rulesnap-2026-08-20'),
  ('ticket-831938', 2, 47.683, 0.983, 'claude-rulesnap-2026-08-20'),
  ('ticket-832194', 1, 24.565, 0.976, 'claude-rulesnap-2026-08-20'),
  ('ticket-832194', 1, 33.188, 0.996, 'claude-rulesnap-2026-08-20'),
  ('ticket-832194', 1, 40.15, 0.996, 'claude-rulesnap-2026-08-20'),
  ('ticket-832194', 1, 47.508, 1, 'claude-rulesnap-2026-08-20'),
  ('ticket-832194', 1, 55.498, 1, 'claude-rulesnap-2026-08-20'),
  ('ticket-832194', 1, 63.489, 1, 'claude-rulesnap-2026-08-20'),
  ('ticket-828604', 1, 28.108, 0.976, 'claude-rulesnap-2026-08-20'),
  ('ticket-828604', 1, 33.633, 0.978, 'claude-rulesnap-2026-08-20'),
  ('ticket-828604', 1, 39.019, 0.976, 'claude-rulesnap-2026-08-20'),
  ('ticket-828604', 1, 44.406, 0.978, 'claude-rulesnap-2026-08-20'),
  ('ticket-828604', 1, 49.931, 0.978, 'claude-rulesnap-2026-08-20'),
  ('ticket-830714', 1, 38.712, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-830714', 1, 44.196, 0.966, 'claude-rulesnap-2026-08-20'),
  ('ticket-830714', 1, 49.681, 0.968, 'claude-rulesnap-2026-08-20'),
  ('ticket-830714', 1, 55.166, 0.968, 'claude-rulesnap-2026-08-20')
ON CONFLICT (dump_folder, effective_page, rule_pct) DO NOTHING;

-- ---------------------------------------------------------------------------
-- PART 2  Snap the bands. Every value below is a rule_pct inserted above.
-- ---------------------------------------------------------------------------
-- ticket-309661 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=29.902, band_y1_pct=35.784, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=855;  -- 295-NAD
UPDATE derm.address_row_map SET band_y0_pct=35.784, band_y1_pct=41.667, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=850;  -- 152-DAV
UPDATE derm.address_row_map SET band_y0_pct=41.667, band_y1_pct=47.549, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=848;  -- 064-TCE
UPDATE derm.address_row_map SET band_y0_pct=47.549, band_y1_pct=53.431, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=849;  -- 081-TCE
UPDATE derm.address_row_map SET band_y0_pct=53.431, band_y1_pct=59.454, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=847;  -- 103-BWC
UPDATE derm.address_row_map SET band_y0_pct=59.454, band_y1_pct=65.336, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=846;  -- 229-BAK
-- ticket-309661 p2   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=29.247, band_y1_pct=35.274, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=844;  -- 067-TCE
UPDATE derm.address_row_map SET band_y0_pct=35.274, band_y1_pct=41.301, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=845;  -- 090-OAK
-- ticket-309898 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=24.429, band_y1_pct=33.185, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=870;  -- 089-COW
UPDATE derm.address_row_map SET band_y0_pct=33.185, band_y1_pct=40.165, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=868;  -- 208-HUB
UPDATE derm.address_row_map SET band_y0_pct=40.165, band_y1_pct=47.779, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=869;  -- 249-LOU
UPDATE derm.address_row_map SET band_y0_pct=47.779, band_y1_pct=56.028, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=866;  -- 248-CHA
UPDATE derm.address_row_map SET band_y0_pct=56.028, band_y1_pct=64.15, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=867;  -- 170-PV
-- ticket-309944 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=26.028, band_y1_pct=34.383, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=871;  -- 195-MYK
UPDATE derm.address_row_map SET band_y0_pct=34.383, band_y1_pct=41.067, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=873;  -- 111-YC
UPDATE derm.address_row_map SET band_y0_pct=41.067, band_y1_pct=48.265, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=872;  -- 176-SOU
-- ticket-820714 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=27.742, band_y1_pct=33.227, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=860;  -- 009-CN
UPDATE derm.address_row_map SET band_y0_pct=33.227, band_y1_pct=38.712, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=882;  -- 009-CN
UPDATE derm.address_row_map SET band_y0_pct=38.712, band_y1_pct=44.196, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=883;  -- 009-CN
UPDATE derm.address_row_map SET band_y0_pct=44.196, band_y1_pct=49.681, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=859;  -- 034-LG
UPDATE derm.address_row_map SET band_y0_pct=49.681, band_y1_pct=55.166, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=858;  -- 187-HAI
-- ticket-829788 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=28.042, band_y1_pct=33.462, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=673;  -- 117-BH
UPDATE derm.address_row_map SET band_y0_pct=33.462, band_y1_pct=38.993, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=675;  -- 035-LG
UPDATE derm.address_row_map SET band_y0_pct=38.993, band_y1_pct=44.303, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=674;  -- 214-MYK
-- ticket-830088 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=27.375, band_y1_pct=32.818, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=667;  -- 082-TFC
UPDATE derm.address_row_map SET band_y0_pct=32.818, band_y1_pct=38.26, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=671;  -- 083-SHUL
UPDATE derm.address_row_map SET band_y0_pct=38.26, band_y1_pct=43.597, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=672;  -- 029-JOS
UPDATE derm.address_row_map SET band_y0_pct=43.597, band_y1_pct=49.039, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=670;  -- 150-KOS
UPDATE derm.address_row_map SET band_y0_pct=49.039, band_y1_pct=54.376, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=669;  -- 149-RUS
UPDATE derm.address_row_map SET band_y0_pct=54.376, band_y1_pct=59.712, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=668;  -- 049-PV
-- ticket-830310 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=26.907, band_y1_pct=38.206, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=678;  -- 071-TCE
-- ticket-830413 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=27.427, band_y1_pct=32.83, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=676;  -- 191-TEN
UPDATE derm.address_row_map SET band_y0_pct=32.83, band_y1_pct=38.233, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=677;  -- 032-LG
-- ticket-830574 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=28.037, band_y1_pct=33.495, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=755;  -- 214-MYK
UPDATE derm.address_row_map SET band_y0_pct=33.495, band_y1_pct=38.864, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=757;  -- 026-HAP
UPDATE derm.address_row_map SET band_y0_pct=38.864, band_y1_pct=44.322, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=758;  -- 069-TCE
UPDATE derm.address_row_map SET band_y0_pct=44.322, band_y1_pct=49.692, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=756;  -- 035-LG
-- ticket-830673 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=25.697, band_y1_pct=34.057, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=865;  -- 065-TCE
UPDATE derm.address_row_map SET band_y0_pct=34.057, band_y1_pct=40.779, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=864;  -- 175-PV
UPDATE derm.address_row_map SET band_y0_pct=40.779, band_y1_pct=47.992, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=861;  -- 068-TCE
UPDATE derm.address_row_map SET band_y0_pct=47.992, band_y1_pct=55.861, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=862;  -- 092-TCE
UPDATE derm.address_row_map SET band_y0_pct=55.861, band_y1_pct=63.566, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=863;  -- 036-LG
-- ticket-831220 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=24.097, band_y1_pct=36.426, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=908;  -- 214-MYK
-- ticket-831938 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=25.205, band_y1_pct=33.538, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=929;  -- 091-SB
UPDATE derm.address_row_map SET band_y0_pct=33.538, band_y1_pct=40.232, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=926;  -- 110-CLA
UPDATE derm.address_row_map SET band_y0_pct=40.232, band_y1_pct=47.609, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=925;  -- 087-BB
UPDATE derm.address_row_map SET band_y0_pct=47.609, band_y1_pct=55.396, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=927;  -- 008-CV
UPDATE derm.address_row_map SET band_y0_pct=55.396, band_y1_pct=63.32, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=928;  -- 035-LG
-- ticket-831938 p2   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=25.351, band_y1_pct=33.638, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=924;  -- 061-TCE
UPDATE derm.address_row_map SET band_y0_pct=33.638, band_y1_pct=40.379, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=922;  -- 062-TCE
UPDATE derm.address_row_map SET band_y0_pct=40.379, band_y1_pct=47.683, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=923;  -- 042-MT
-- ticket-832194 p1   (from derived)
UPDATE derm.address_row_map SET band_y0_pct=24.565, band_y1_pct=33.188, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=950;  -- 012-DKC
UPDATE derm.address_row_map SET band_y0_pct=33.188, band_y1_pct=40.15, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=949;  -- 134-SC
UPDATE derm.address_row_map SET band_y0_pct=40.15, band_y1_pct=47.508, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=947;  -- 017-FIA
UPDATE derm.address_row_map SET band_y0_pct=47.508, band_y1_pct=55.498, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=944;  -- 182-PAL
UPDATE derm.address_row_map SET band_y0_pct=55.498, band_y1_pct=63.489, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=945;  -- 043-MIL
-- ticket-828604 p1   (from frozen doc band)
UPDATE derm.address_row_map SET band_y0_pct=28.108, band_y1_pct=33.633, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=980;  -- 092-TCE
UPDATE derm.address_row_map SET band_y0_pct=33.633, band_y1_pct=39.019, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=981;  -- 104-PV
UPDATE derm.address_row_map SET band_y0_pct=39.019, band_y1_pct=44.406, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=978;  -- 110-CLA
UPDATE derm.address_row_map SET band_y0_pct=44.406, band_y1_pct=49.931, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=979;  -- 147-OST
-- ticket-830714 p1   (from frozen doc band)
UPDATE derm.address_row_map SET band_y0_pct=38.712, band_y1_pct=44.196, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=984;  -- 009-CN
UPDATE derm.address_row_map SET band_y0_pct=44.196, band_y1_pct=49.681, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=983;  -- 034-LG
UPDATE derm.address_row_map SET band_y0_pct=49.681, band_y1_pct=55.166, band_source='claude-rulesnap-2026-08-20', band_set_at=now() WHERE id=982;  -- 187-HAI

-- ---------------------------------------------------------------------------
-- PART 3  Widen extents that the snap moved a band outside of. UNION ONLY.
--         Narrowing is the leak direction; widening can only add black.
-- ---------------------------------------------------------------------------
UPDATE derm.page_block_extents SET top_pct=26.028, bottom_pct=67.1, measured_at=now() WHERE dump_folder='ticket-309944' AND effective_page=1;  -- was 26.09/67.1
UPDATE derm.page_block_extents SET top_pct=28.037, bottom_pct=64.96, measured_at=now() WHERE dump_folder='ticket-830574' AND effective_page=1;  -- was 28.08/64.96
UPDATE derm.page_block_extents SET top_pct=25.205, bottom_pct=64.4, measured_at=now() WHERE dump_folder='ticket-831938' AND effective_page=1;  -- was 25.8/64.4
UPDATE derm.page_block_extents SET top_pct=25.351, bottom_pct=64.4, measured_at=now() WHERE dump_folder='ticket-831938' AND effective_page=2;  -- was 25.8/64.4

-- ---------------------------------------------------------------------------
-- VERIFY  Every band edge written above MUST equal a detected rule. This is the
--         one assertion that fails on a derived band, so it is the whole point.
-- ---------------------------------------------------------------------------
DO $$
DECLARE v_unbound int; v_overlap int; v_written int; v_outside int;
BEGIN
  SELECT count(*) INTO v_written FROM derm.address_row_map WHERE band_source = 'claude-rulesnap-2026-08-20';
  IF v_written <> 63 THEN RAISE EXCEPTION 'expected 63 snapped rows, found %', v_written; END IF;

  SELECT count(*) INTO v_unbound
    FROM derm.address_row_map r
   WHERE r.band_source = 'claude-rulesnap-2026-08-20'
     AND ( NOT EXISTS (SELECT 1 FROM derm.page_row_rules pr
                        WHERE pr.dump_folder = r.dump_folder
                          AND pr.effective_page = COALESCE(r.stamp_page, r.page)
                          AND pr.rule_pct = r.band_y0_pct)
        OR NOT EXISTS (SELECT 1 FROM derm.page_row_rules pr
                        WHERE pr.dump_folder = r.dump_folder
                          AND pr.effective_page = COALESCE(r.stamp_page, r.page)
                          AND pr.rule_pct = r.band_y1_pct) );
  IF v_unbound <> 0 THEN RAISE EXCEPTION '% snapped rows have an edge that is not a detected rule', v_unbound; END IF;

  -- G2 again, in the database, against what was actually written
  SELECT count(*) INTO v_overlap FROM (
    SELECT r.id FROM derm.address_row_map r JOIN derm.address_row_map q
      ON q.dump_folder = r.dump_folder
     AND COALESCE(q.stamp_page,q.page) = COALESCE(r.stamp_page,r.page)
     AND q.id <> r.id
     AND q.band_y0_pct IS NOT NULL AND r.band_y0_pct IS NOT NULL
     AND q.band_y0_pct < r.band_y1_pct AND q.band_y1_pct > r.band_y0_pct
   WHERE r.band_source = 'claude-rulesnap-2026-08-20') o;
  IF v_overlap <> 0 THEN RAISE EXCEPTION '% snapped rows overlap a sibling band', v_overlap; END IF;

  -- the extent must still cover every band on the page
  SELECT count(*) INTO v_outside
    FROM derm.address_row_map r
    JOIN derm.page_block_extents e
      ON e.dump_folder = r.dump_folder AND e.effective_page = COALESCE(r.stamp_page, r.page)
   WHERE r.band_source = 'claude-rulesnap-2026-08-20'
     AND (r.band_y0_pct < e.top_pct OR r.band_y1_pct > e.bottom_pct);
  IF v_outside <> 0 THEN RAISE EXCEPTION '% snapped bands fall outside their page extent', v_outside; END IF;

  RAISE NOTICE 'OK: % rows snapped, every edge on a detected rule, no overlap, all inside their extent', v_written;
END $$;

COMMIT;
