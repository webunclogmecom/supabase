-- 2026-08-03_0309  Tighten the generated-sheet extents from "generous" to the MEASURED form rules
--
-- Fred, shown two crops of the blacked output: "But you're removing too much, these top and bottom
-- parts are not needed to be blacked out."  He was right.
--
-- -- WHAT I GOT WRONG IN 2026-08-03_0046 --------------------------------------
-- I picked 22.0 / 67.5 by reasoning "widening is provably safe, so err wide". The audit did prove
-- that widening can never REVEAL anything (the two boxes are opaque overwrites and blocks_top /
-- blocks_bottom never feed the band values) -- but the SAME audit finding said, verbatim,
-- "Confidentiality cost of over-width is zero; utility cost (covering the form header and the
-- certification/disposal footer) is real." I quoted that line and then ignored its second half.
-- Safe-but-useless is still wrong: these documents are the customer's proof of service.
--
-- Blacked that should NOT have been: Section A's "Vehicle Full Load Capacity" row, the
-- "B: Origination of Waste" header bar, the "Attach Additional Sheets if more than 5 Grease
-- Interceptors Pumped!" line, and the "Total Waste this Load / Gallons" box. None of it is client
-- data; all of it is form furniture the customer needs to read the manifest.
--
-- -- MEASURED, NOT GUESSED ----------------------------------------------------
-- Found the printed horizontal RULES by full-width ink density on the raw scans (a form rule inks
-- >45% of the page width; body text never does). The roster occupies the span between the first
-- and last rule:
--     ticket-310429 p1 (H=746): rules at 26.27 34.58 41.29 48.53 56.30 [64.21] 67.29 69.71 72.25
--     ticket-310429 p2 (H=748): rules at 26.07 34.36 41.04 48.13 55.88 [63.50] 66.58 68.98
--   -> bracketed value = the LAST roster rule; the next rule down is the bottom of the
--      "Attach Additional Sheets" row, which must stay visible.
--   -> ticket-831325 p1 (H=724): that scan is too light for the threshold, so it inherits p1's
--      geometry (same printed form, same family). Its bands (25.84..41.68) sit well inside.
--
-- New values, per page, replacing 22.0 / 67.5:
--     ticket-310429 p1 -> 25.8 / 64.4
--     ticket-310429 p2 -> 25.8 / 63.7   (that page's last rule is 0.7pp higher)
--     ticket-831325 p1 -> 25.8 / 64.4
--
-- The top is effectively pinned by fn_blackout_targets' LEAST(top_pct, min(band_y0)) anyway, so
-- 25.8 mainly documents intent; the BOTTOM is the value that actually changed behaviour.
--
-- ⚠ STILL COVERS EVERY PRINTED SLOT INCLUDING EMPTY ONES. That was the whole point of
-- 2026-08-03_0046 and it is unchanged: page 2 has five printed slots with only two stamped, and the
-- extent runs to the last roster rule, not to the last stamped band. Do NOT re-derive these from
-- v_stamp_row_bands (stamped rows only) -- that is the 2026-07-10 leak shape.
--
-- No migration file needed for the regeneration: changing top_pct/bottom_pct changes the
-- fn_blackout_targets fingerprint (md5 of etag|y0|y1|btop|bbot), so all 9 docs re-targeted and
-- regenerated themselves. Filenames DO change here (unlike the off-by-one fix) because btop/bbot
-- are fingerprint inputs; the old objects are superseded by the edge function.
--
-- VERIFIED per-pixel on all 9 after regeneration:
--   upper box fully black 9/9 | lower box fully black 9/9 | own band fully visible 9/9
--   form furniture immediately ABOVE the extent visible 9/9
--   form furniture immediately BELOW the extent visible 9/9
-- Plus eyeballed 041-MB p1, 072-TCE p2 and 059-SK p1: co-clients covered, own row readable,
-- capacity row / section header / "Attach Additional Sheets" / Total Waste box all restored.
--
-- ADR 010 rule 8: measurement table, no audit trigger, unchanged.

BEGIN;

UPDATE derm.page_block_extents
   SET top_pct = 25.8, bottom_pct = 64.4,
       source = 'generated-form-rules-2026-08-03', measured_at = now()
 WHERE dump_folder = 'ticket-310429' AND effective_page = 1;

UPDATE derm.page_block_extents
   SET top_pct = 25.8, bottom_pct = 63.7,
       source = 'generated-form-rules-2026-08-03', measured_at = now()
 WHERE dump_folder = 'ticket-310429' AND effective_page = 2;

UPDATE derm.page_block_extents
   SET top_pct = 25.8, bottom_pct = 64.4,
       source = 'generated-form-rules-2026-08-03', measured_at = now()
 WHERE dump_folder = 'ticket-831325' AND effective_page = 1;

COMMIT;
