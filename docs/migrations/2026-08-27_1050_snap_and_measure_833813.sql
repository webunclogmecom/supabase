-- 2026-08-27_1050_snap_and_measure_833813.sql
--
-- WHY
-- ---
-- Fred, 2026-08-27: "now do the bands and measurement for 833813." This is the operation that
-- leaked client data on 2026-08-19, so it follows the worklist's own instruction exactly: SNAP THE
-- BANDS FIRST, THEN add the extent, IN ONE MIGRATION. An extent does not redact anything -- it
-- opens the gate onto whatever bands exist -- so adding one over stamp-midpoint DERIVED bands is
-- the act that published 30 wrong documents in 90 seconds that day.
--
-- This unblocks 10 clients on `ticket-833813` and publishes their FOG sheet for the first time.
--
-- 🛑 PREREQUISITE, ALREADY DONE: `2026-08-27_1035` corrected this folder's transposed page images.
-- Measuring it BEFORE that would have built every client's redaction from the wrong page. Do not
-- reorder these two migrations.
--
-- THE GEOMETRY, AND HOW IT WAS OBTAINED
-- -------------------------------------
-- The proven v2 run-length detector (`scripts/probes/derm_band_review/detect.js`) was run over
-- both scans, its body transported verbatim rather than re-derived -- four earlier scorers were
-- measured against known truth and rejected, so this is not a place to write a fifth.
--
--   image 1 (= printed page 2, sheet 1100-2)  H=568  skew 0
--   image 2 (= printed page 1, sheet 1100-1)  H=564  skew -0.008
--
-- Roster boundaries, full-width printed rules:
--   effective_page 1 : 25.880  34.243  40.933  48.151  56.250  63.996
--   effective_page 2 : 23.848  32.535  39.273  46.720  54.699  62.855
--
-- ⚠ ONE BOUNDARY IS UNDER-SCORED AND IS USED ANYWAY: 48.151 on page 1 has run 0.601, below the
-- 0.80 full-width threshold. It is accepted because three independent things agree it is a real
-- slot boundary, and it is recorded with `kind_confirmed = false` so nobody has to rediscover that:
--   1. Without it, slot 3 would span 40.933..56.250 (15.3pp, two slots) and BOTH 035-LG (44.48)
--      and 036-LG (51.81) would fall inside it, i.e. the stamp test fails.
--   2. With it, the five gaps are 8.363 / 6.690 / 7.218 / 8.099 / 7.746 -- one pitch each.
--   3. A second detection at 48.504 sits 0.353pp away, which is the documented signature of ONE
--      printed line detected twice after peak refinement, not two lines. The stronger read wins;
--      the weaker is recorded as `unclassified` so it can never be taken for a boundary.
--
-- ✅ THE CORROBORATION THAT MAKES THIS TRUSTWORTHY, and it is the strongest evidence here.
-- The two pages are SEPARATE PHOTOGRAPHS of the same printed template. Normalising each page's
-- slot heights by its own roster height:
--
--   slot         1       2       3       4       5
--   page 1    0.219   0.176   0.189   0.212   0.203
--   page 2    0.223   0.173   0.191   0.205   0.209
--   delta     0.004   0.003   0.002   0.007   0.006
--
-- Two independent photographs agreeing to within 0.7% of roster height on every slot cannot be
-- detection noise. It is the form's real geometry, and it also explains why the slots are NOT
-- evenly spaced: the printed template's first row is genuinely taller. A uniformity test would
-- have wrongly rejected this page.
--
-- ✅ NO PRINTED-BUT-UNROWED FACILITY, verified with data rather than assumed. The row OCR run
-- earlier today read exactly 5 rows on each image at high confidence, and each page carries
-- exactly 5 cards, every one matching the code printed on its row (the 10-of-10 cross-check in
-- `2026-08-27_1035`). So every printed slot is owned and none is empty. That is the check whose
-- absence turned `ticket-310590` p2 into a real leak, and it is why the extent here can sit
-- exactly on the first and last boundary instead of needing to reach past an empty slot.
--
-- RULE 8 (audit trail): `derm.address_row_map` is audited by `audit_address_row_map`, so the band
-- writes carry old_row. `derm.page_block_extents` became audited earlier today (2026-08-27_0347),
-- so the extents do too -- this is the first extent write ever captured by that trigger.
-- `page_row_rules` / `page_rule_scans` are machine detector output, regenerable by re-running the
-- detector, and remain opt-out.

BEGIN;

-- ---------------------------------------------------------------------------
-- PART 1. Record that the detector RAN, and how it graded each page.
-- ---------------------------------------------------------------------------
-- derm.page_rule_scans is what makes "no rules found" distinguishable from "never looked".
INSERT INTO derm.page_rule_scans
  (dump_folder, effective_page, source_url, image_w, image_h, skew, n_rules, n_boundaries,
   pitch_pct, grade, detail, source, scanned_at)
VALUES
  ('ticket-833813', 1, 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1750/address_1.jpg',
   732, 568, 0, 19, 6, 7.746, 'OK',
   'sheet 1100-2. Boundary at 48.151 under-scored (run 0.601) but confirmed by pitch, by the stamp test, and by the page-2 proportion match; 48.504 is the same line detected twice.',
   'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1750/address_2.jpg',
   732, 564, -0.008, 14, 6, 7.979, 'OK',
   'sheet 1100-1. All six roster boundaries full-width. Mid-slot dividers detected in slots 4 and 5 only; the fainter three are simply undetected, which does not affect boundary placement.',
   'runlen-v2-2026-08-27', now());

-- ---------------------------------------------------------------------------
-- PART 2. Every rule the detector found, classified by ALTERNATION down the roster.
-- ---------------------------------------------------------------------------
-- Rules outside the roster are recorded as header-footer (full-width) or unclassified, never as
-- boundaries: that is what stops a band edge later "snapping" onto the form's header bar.
INSERT INTO derm.page_row_rules
  (dump_folder, effective_page, rule_pct, run_frac, ink_frac, kind, kind_confirmed, source, detected_at)
VALUES
  -- effective_page 1  (image 1 = printed page 2)
  ('ticket-833813', 1, 11.092, 0.918, 0.924, 'header-footer', true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 13.732, 0.476, 0.847, 'unclassified',  true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 23.327, 0.381, 0.124, 'unclassified',  true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 25.880, 1.000, 0.788, 'boundary',      true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 29.930, 0.387, 0.375, 'divider',       true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 34.243, 1.000, 0.545, 'boundary',      true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 37.676, 0.411, 0.416, 'divider',       true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 40.933, 1.000, 0.329, 'boundary',      true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 44.278, 0.413, 0.080, 'divider',       true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 48.151, 0.601, 0.126, 'boundary',      false, 'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 48.504, 0.378, 0.105, 'unclassified',  false, 'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 51.849, 0.413, 0.023, 'divider',       true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 56.250, 1.000, 0.986, 'boundary',      true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 59.771, 0.413, 0.352, 'divider',       true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 63.996, 1.000, 0.672, 'boundary',      true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 67.165, 0.451, 0.633, 'unclassified',  true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 69.454, 0.451, 0.392, 'unclassified',  true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 75.792, 0.355, 0.584, 'unclassified',  true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 1, 78.961, 0.411, 0.534, 'unclassified',  true,  'runlen-v2-2026-08-27', now()),
  -- effective_page 2  (image 2 = printed page 1)
  ('ticket-833813', 2, 11.968, 0.520, 0.564, 'unclassified',  true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 21.543, 0.404, 0.348, 'unclassified',  true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 23.848, 0.949, 0.588, 'boundary',      true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 32.535, 1.000, 0.882, 'boundary',      true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 39.273, 1.000, 0.766, 'boundary',      true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 46.720, 1.000, 0.816, 'boundary',      true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 50.266, 0.403, 0.345, 'divider',       true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 54.699, 0.950, 0.863, 'boundary',      true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 58.333, 0.403, 0.383, 'divider',       true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 62.855, 1.000, 0.810, 'boundary',      true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 65.957, 0.617, 0.593, 'unclassified',  true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 68.351, 0.507, 0.655, 'unclassified',  true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 74.557, 0.344, 0.769, 'unclassified',  true,  'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 79.167, 0.637, 0.597, 'unclassified',  true,  'runlen-v2-2026-08-27', now());

-- ---------------------------------------------------------------------------
-- PART 3. SNAP THE BANDS. Every edge is a recorded `boundary`, never a computed midpoint.
-- ---------------------------------------------------------------------------
-- Written by (dump_folder, effective_page, stamp_y_pct) rather than by id, so the statement cannot
-- silently attach a band to a card that moved. Bands TILE the roster: each slot's y1 is the next
-- slot's y0, leaving no strip belonging to nobody.
UPDATE derm.address_row_map r
   SET band_y0_pct = v.y0, band_y1_pct = v.y1,
       band_source = 'runlen-snap-2026-08-27', band_set_at = now(),
       band_set_by = 'claude-runlen-2026-08-27'
  FROM (VALUES
    -- effective_page 1 (printed page 2): 214-MYK, 236-LOU, 035-LG, 036-LG, 238-PV
    (1, 29.800::numeric, 25.880::numeric, 34.243::numeric),
    (1, 37.720,          34.243,          40.933),
    (1, 44.480,          40.933,          48.151),
    (1, 51.810,          48.151,          56.250),
    (1, 60.040,          56.250,          63.996),
    -- effective_page 2 (printed page 1): 077-TCE, 221-YAS, 197-BGT, 034-LG, 222-SPE
    (2, 29.800,          23.848,          32.535),
    (2, 37.720,          32.535,          39.273),
    (2, 44.480,          39.273,          46.720),
    (2, 51.810,          46.720,          54.699),
    (2, 60.040,          54.699,          62.855)
  ) AS v(pg, stamp_y, y0, y1)
 WHERE r.dump_folder = 'ticket-833813'
   AND COALESCE(r.stamp_page, r.page) = v.pg
   AND r.stamp_y_pct = v.stamp_y;

-- ---------------------------------------------------------------------------
-- PART 4. AND ONLY NOW THE EXTENT. This is what opens the gate.
-- ---------------------------------------------------------------------------
-- Bounded by the printed roster: first boundary to last boundary. Equal to the band envelope here
-- ONLY because every printed slot is owned and none is empty, which PART 0 verified from the row
-- OCR. On a page with an empty trailing slot the extent must reach PAST the bands instead.
INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at)
VALUES
  ('ticket-833813', 1, 25.880, 63.996, 'runlen-v2-2026-08-27', now()),
  ('ticket-833813', 2, 23.848, 62.855, 'runlen-v2-2026-08-27', now());

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_n integer; v_bad integer;
BEGIN
  -- 1. All ten cards banded, none missed by the stamp_y match in PART 3.
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-833813' AND band_y0_pct IS NOT NULL AND band_y1_pct IS NOT NULL;
  IF v_n <> 10 THEN RAISE EXCEPTION 'VERIFY 1 failed: % of 10 cards banded', v_n; END IF;

  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-833813' AND band_source <> 'runlen-snap-2026-08-27';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1 failed: % card(s) kept a derived band', v_n; END IF;

  -- 2. EVERY BAND EDGE IS A RECORDED BOUNDARY. This is the check that fails on derived bands, on a
  --    uniformly shifted tiling, and on a partly-stamped roster. "Bands tile contiguously" and
  --    "each stamp sits in its own band" both PASS on the bands that leaked, so neither is enough.
  SELECT count(*) INTO v_bad
    FROM derm.address_row_map r
   WHERE r.dump_folder = 'ticket-833813'
     AND (NOT EXISTS (SELECT 1 FROM derm.page_row_rules p
                       WHERE p.dump_folder = r.dump_folder
                         AND p.effective_page = COALESCE(r.stamp_page, r.page)
                         AND p.kind = 'boundary' AND p.rule_pct = r.band_y0_pct)
       OR NOT EXISTS (SELECT 1 FROM derm.page_row_rules p
                       WHERE p.dump_folder = r.dump_folder
                         AND p.effective_page = COALESCE(r.stamp_page, r.page)
                         AND p.kind = 'boundary' AND p.rule_pct = r.band_y1_pct));
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: % band edge pair(s) are not on a detected boundary', v_bad;
  END IF;

  -- 3. Each stamp STRICTLY inside its own band, with real clearance.
  SELECT count(*) INTO v_bad FROM derm.address_row_map r
   WHERE r.dump_folder = 'ticket-833813'
     AND NOT (r.stamp_y_pct > r.band_y0_pct + 0.5 AND r.stamp_y_pct < r.band_y1_pct - 0.5);
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 failed: % stamp(s) not comfortably inside their own band', v_bad;
  END IF;

  -- 4. Bands TILE each page: monotonic, contiguous, no overlap, no gap belonging to nobody.
  SELECT count(*) INTO v_bad FROM (
    SELECT COALESCE(stamp_page, page) AS pg, band_y1_pct AS y1,
           lead(band_y0_pct) OVER (PARTITION BY COALESCE(stamp_page, page) ORDER BY band_y0_pct) AS next_y0
      FROM derm.address_row_map WHERE dump_folder = 'ticket-833813') s
   WHERE next_y0 IS NOT NULL AND next_y0 <> y1;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 failed: % gap/overlap between consecutive bands', v_bad;
  END IF;

  -- 5. No two cards on a page share a band, i.e. the window4-sheet1 shape cannot exist here.
  SELECT count(*) INTO v_bad FROM (
    SELECT COALESCE(stamp_page, page) AS pg, band_y0_pct, band_y1_pct, count(*) AS n
      FROM derm.address_row_map WHERE dump_folder = 'ticket-833813'
     GROUP BY 1,2,3 HAVING count(*) > 1) d;
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 5 failed: % duplicated band(s)', v_bad; END IF;

  -- 6. THE EXTENT CONTAINS EVERY BAND. Narrowing is the leak direction; widening is not.
  SELECT count(*) INTO v_bad
    FROM derm.page_block_extents e
    JOIN derm.address_row_map r
      ON r.dump_folder = e.dump_folder AND COALESCE(r.stamp_page, r.page) = e.effective_page
   WHERE e.dump_folder = 'ticket-833813'
     AND (r.band_y0_pct < e.top_pct OR r.band_y1_pct > e.bottom_pct);
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: % band(s) fall outside the extent and would be served', v_bad;
  END IF;

  -- 7. EVERY PRINTED SLOT IS OWNED. The row OCR read 5 rows per image and each page holds 5 cards,
  --    so there is no printed-but-unrowed facility hiding in the roster. This is the check whose
  --    absence turned ticket-310590 p2 into a real leak.
  SELECT count(*) INTO v_bad FROM (
    SELECT rr.page,
           (SELECT count(*) FROM derm.address_sheet_row_reads x
             WHERE x.dump_folder = 'ticket-833813' AND x.page = rr.page) AS printed,
           (SELECT count(*) FROM derm.address_row_map y
             WHERE y.dump_folder = 'ticket-833813' AND COALESCE(y.stamp_page, y.page) = rr.page) AS owned
      FROM (SELECT DISTINCT page FROM derm.address_sheet_row_reads WHERE dump_folder='ticket-833813') rr) t
   WHERE printed <> owned;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: % page(s) print more rows than we hold cards for', v_bad;
  END IF;

  -- 8. THE GEOMETRY CHECK THE ESTATE ALREADY RUNS MUST STAY CLEAN. It was 0 before this migration.
  SELECT count(*) INTO v_n FROM derm.v_band_edges_off_rule;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 8 FAILED: v_band_edges_off_rule now reports % band(s)', v_n;
  END IF;

  -- 9. THE POINT OF THE MIGRATION: all ten pairs are now publishable.
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(500) t
    JOIN derm.address_row_map r
      ON r.matched_manifest_id = t.manifest_id AND r.matched_client_id = t.client_id
   WHERE r.dump_folder = 'ticket-833813';
  IF v_n <> 10 THEN
    RAISE EXCEPTION 'VERIFY 9 failed: % of 10 cards became blackout targets', v_n;
  END IF;

  -- 10. AND NOTHING ELSE MOVED. No other folder gained or lost an extent or a band.
  SELECT count(*) INTO v_n FROM derm.page_block_extents;
  IF v_n <> 164 THEN RAISE EXCEPTION 'VERIFY 10 failed: extents went to %, expected 164', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE band_y0_pct IS NOT NULL;
  IF v_n <> 651 THEN RAISE EXCEPTION 'VERIFY 10 failed: banded rows went to %, expected 651', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: 10 bands snapped onto detected boundaries, tiling both rosters with no gap, every stamp inside its own band, both extents contain their bands, every printed slot owned, v_band_edges_off_rule still 0, and all 10 pairs are now blackout targets.';
END $do$;

COMMIT;
