-- 2026-09-02_1300_snap_and_measure_312500.sql
--
-- WHY
-- ---
-- ticket-312500 (white 312500, manifests 1769/1770 = 023-GRO / 051-PV) is AI-stamped but had NO
-- detector scan, NO printed rules, DERIVED bands and NO page_block_extents, so derm.fn_blackout_targets
-- excluded it and both clients saw no FOG eManifest on the Field Portal. This is the
-- "needs_snap_then_extent" state from derm.v_blackout_blocked_sheets. SNAP THE BANDS FIRST, THEN THE
-- EXTENT, IN ONE MIGRATION (the 2026-08-19 leak rule).
--
-- THE PAGE, read off the scan (derm/1769/address_1.jpg), a GENERATED sheet (template top-right 1103):
-- Section B "Origination of Waste" has 5 interceptor rows; ROWS 1-2 FILLED, ROWS 3-5 EMPTY:
--   row 1: 023-GRO Grove Kosher LLC (Delray Beach), 7351 West Atlantic Avenue, Delray Beach FL 33446.
--   row 2: 051-PV Pura Vida Delray, 6 South Ocean Boulevard, Delray Beach FL 33483.
--   rows 3-5: EMPTY. So there is NO printed-but-unrowed facility (the ticket-310590 p2 leak shape is
--   absent). Verified by eye on the scan.
--
-- THE GEOMETRY, freshly detected with the proven v2 run-length detector
-- (scripts/probes/derm_band_review/detect.js) run in a same-origin browser canvas over
-- derm/1769/address_1.jpg (W=1024 H=784, skew 0). Six full-width roster boundaries, clean b-d-b-d
-- alternation, pitch 7.844:
--   24.043 / 32.462 / 39.349 / 46.620 / 54.464 / 62.372   (rows 1..5)
--   header line 11.862 and footers 65.497 / 67.921 / 78.316 are OUTSIDE the roster (header-footer).
--   * BAND 023-GRO (card 1055, stamp_y 29.800, inside): [24.043, 32.462] = row 1.
--   * BAND 051-PV  (card 1056, stamp_y 37.720, inside): [32.462, 39.349] = row 2.
--   * EXTENT: 24.043 .. 62.372 (row-1 top to row-5 bottom), so the three empty rows 3-5 are blacked.
--
-- VALIDATED: derm.check_page_geometry(...) is asserted to return ZERO violations in the VERIFY block
-- below, against the just-inserted rules.
--
-- RULE 8: derm.address_row_map + derm.page_block_extents are audited (writes captured).
-- derm.page_rule_scans / page_row_rules are machine detector output, regenerable, opt-out.

BEGIN;

-- PART 1. Record that the detector ran and how it graded the page.
INSERT INTO derm.page_rule_scans
  (dump_folder, effective_page, source_url, image_w, image_h, skew, n_rules, n_boundaries,
   pitch_pct, grade, detail, source, source_etag, scanned_at)
VALUES
  ('ticket-312500', 1,
   'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1769/address_1.jpg',
   1024, 784, 0, 17, 6, 7.844, 'OK',
   'generated sheet 1103; 6 roster boundaries, clean alternation, pitch 7.844; rows 1-2 filled (023-GRO, 051-PV), rows 3-5 empty.',
   'runlen-v2-2026-09-02', '"9173991ab17bf01edd9b4b9a6acc9493"', now());

-- PART 2. Every detected rule, classified by alternation. 11.862 and 65.497/67.921/78.316 are
-- header-footer (outside the roster); the roster is 24.043..62.372.
INSERT INTO derm.page_row_rules
  (dump_folder, effective_page, rule_pct, run_frac, ink_frac, kind, kind_confirmed, source, detected_at)
VALUES
  ('ticket-312500', 1, 11.862, 0.993, 0.639, 'header-footer', true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 21.684, 0.403, 0.302, 'divider',       true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 24.043, 0.993, 0.905, 'boundary',      true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 28.189, 0.405, 0.079, 'divider',       true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 32.462, 0.996, 0.525, 'boundary',      true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 35.842, 0.406, 0.041, 'divider',       true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 39.349, 0.996, 0.964, 'boundary',      true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 42.538, 0.406, 0.424, 'divider',       true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 46.620, 0.996, 0.893, 'boundary',      true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 50.255, 0.406, 0.050, 'divider',       true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 54.464, 0.996, 0.094, 'boundary',      true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 58.163, 0.403, 0.418, 'divider',       true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 62.372, 0.996, 0.184, 'boundary',      true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 65.497, 0.997, 0.598, 'header-footer', true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 67.921, 0.993, 0.892, 'header-footer', true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 77.360, 0.395, 0.303, 'header-footer', true,  'runlen-v2-2026-09-02', now()),
  ('ticket-312500', 1, 78.316, 0.997, 0.751, 'header-footer', true,  'runlen-v2-2026-09-02', now());

-- PART 3. Snap the two bands onto the detected boundaries (were derived: band_y0/y1 NULL).
UPDATE derm.address_row_map r
   SET band_y0_pct = v.y0, band_y1_pct = v.y1,
       band_source = 'runlen-snap-2026-09-02', band_set_at = now(),
       band_set_by = 'claude-runlen-2026-09-02'
  FROM (VALUES
    (29.800::numeric, 24.043::numeric, 32.462::numeric),   -- 023-GRO, row 1
    (37.720::numeric, 32.462::numeric, 39.349::numeric)    -- 051-PV,  row 2
  ) AS v(stamp_y, y0, y1)
 WHERE r.dump_folder = 'ticket-312500'
   AND COALESCE(r.stamp_page, r.page) = 1
   AND r.stamp_y_pct = v.stamp_y;

-- PART 4. AND ONLY NOW THE EXTENT.
INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at)
VALUES ('ticket-312500', 1, 24.043, 62.372, 'runlen-v2-2026-09-02', now());

-- VERIFY
DO $do$
DECLARE v_n integer; v_viol text;
BEGIN
  -- 1. both cards banded onto the detected boundaries, none missed by the stamp_y match
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder='ticket-312500' AND band_y0_pct IS NOT NULL AND band_source='runlen-snap-2026-09-02';
  IF v_n <> 2 THEN RAISE EXCEPTION 'VERIFY 1: % of 2 cards banded', v_n; END IF;

  -- 2. every band edge is a recorded boundary
  SELECT count(*) INTO v_n FROM (VALUES (24.043::numeric),(32.462::numeric),(39.349::numeric)) e(v)
   WHERE NOT EXISTS (SELECT 1 FROM derm.page_row_rules p
                      WHERE p.dump_folder='ticket-312500' AND p.effective_page=1
                        AND p.kind='boundary' AND p.rule_pct=e.v);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 2: % band edge(s) not on a detected boundary', v_n; END IF;

  -- 3. bands tile contiguously, each stamp strictly inside its own band
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder='ticket-312500'
     AND NOT (stamp_y_pct > band_y0_pct + 0.5 AND stamp_y_pct < band_y1_pct - 0.5);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 3: % stamp(s) not comfortably inside their band', v_n; END IF;

  -- 4. the estate's own geometry validator passes with ZERO violations
  SELECT string_agg((v).code, ', ') INTO v_viol
    FROM derm.check_page_geometry('ticket-312500', 1,
      '[{"row_id":1055,"y0":24.043,"y1":32.462},{"row_id":1056,"y0":32.462,"y1":39.349}]'::jsonb,
      24.043, 62.372) v;
  IF v_viol IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 4: check_page_geometry violations: %', v_viol; END IF;

  -- 5. both clients become blackout targets
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(500) t WHERE t.ticket_key='312500';
  IF v_n <> 2 THEN RAISE EXCEPTION 'VERIFY 5: 312500 produced % targets (want 2)', v_n; END IF;

  -- 6. exactly one extent for this folder, intended values
  SELECT count(*) INTO v_n FROM derm.page_block_extents
   WHERE dump_folder='ticket-312500' AND effective_page=1 AND top_pct=24.043 AND bottom_pct=62.372;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 6: % matching extent row (want 1)', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: 023-GRO + 051-PV banded to detected boundaries, extent blacks empty rows 3-5, check_page_geometry clean, 2 blackout targets.';
END $do$;

COMMIT;
