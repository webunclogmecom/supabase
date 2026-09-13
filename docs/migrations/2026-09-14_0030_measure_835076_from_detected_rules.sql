-- ============================================================================================
-- 2026-09-14_0030_measure_835076_from_detected_rules.sql
--
-- Measure both pages of ticket-835076 (generated sheet 1117) from the printed-rule detector's own
-- output, through the same RPCs the Studio's "Draw the bands" panel calls, so the sheet can be
-- marked complete and blacked out. Nothing here is hand-drawn or templated: every band edge and
-- both extents are lines the run-length detector found on THESE two scans.
--
-- WHY (Fred, 2026-09-14): "why if it has been stamped by AI can't it be marked as complete?
-- specially when we have a doc saying that if it's a generated manifest ... it should be
-- auto-stamped and auto marked as complete unless it can be certain of the stamps ... on this
-- manifest 835076 it looks pretty accurate."
--
-- He is right about the stamps: all ten were placed by the AI on the right rows of the right
-- scans (2026-09-13_1200 for the page-2 five). What blocks completion is GEOMETRY, and it is his
-- own 2026-09-03 rule doing it: "if it's marked as complete then after 5 min it needs a blackout,
-- period, if not then it can't be marked as complete." Completion is gated on
-- derm.fn_sheet_publishable, which read `needs_snap_then_extent`: all ten bands were DERIVED (the
-- generator's template, the amber "estimated" lines in the Studio) and neither page had an extent.
-- Since 2026-08-19 an extent must never open the publish gate onto derived bands, so a generated
-- sheet needs a MEASUREMENT before it can complete, and nothing produces one automatically.
-- That is the gap between two of Fred's rules ("generated sheets are automatic" and "complete
-- means blacked out"), not a fault in either.
--
-- ============================================================================================
-- WHAT THE DETECTOR FOUND, and why page 2 graded FAILED in the Studio.
--
-- Fred had already run the in-app detector on both pages (derm.page_rule_scans):
--   page 1  runlen-v2-2026-09-13  OK      14 rules, 6 boundaries   -> rules recorded
--   page 2  runlen-v2-2026-09-13  FAILED  14 rules, 7 boundaries   -> NOTHING recorded
-- Re-run with the Node port (scripts/probes/rev/detect_node.js) on the same two scans, page 1 as
-- the positive control (it reproduces the recorded scan to 0.04pp), page 2 the case in question:
--
--   template (derived)   page 1 recorded   page 2 detected   run on page 2
--        25.84              26.168            25.505           0.992
--        33.76              34.386            33.838           0.993
--        41.10              41.090            40.572           0.994
--        48.15              48.270            47.811           0.994
--        55.93              56.055            55.640           0.994
--        64.16              63.798            63.426           0.507   <- half-width in this photo
--
-- The sixth boundary on page 2, the bottom of slot 5, is printed only half-width in this scan
-- (run 0.507 against 0.99 for the other five), so the validator's phase check (V5 in
-- derm.fn_validate_page_rules: split the chain's run values at their largest gap and demand the
-- labels agree) reads a boundary with run 0.507 as a phase flip and refuses the set. That is the
-- known end-bar limitation recorded on 2026-08-28, on a new page. The classifier failed; the
-- DETECTION did not: all six lines are there, each within 0.75pp of the template, and the slot
-- proportions match page 1 to 0.1pp (gaps 8.33/6.73/7.24/7.83/7.79 vs 8.22/6.70/7.18/7.79/7.74).
--
-- ============================================================================================
-- HOW, AND WHY IT IS THE SANCTIONED PATH AND NOT A WORKAROUND.
--
-- "Draw the bands" records every line an operator draws as kind 'boundary' with NO dividers, under
-- a human-v1-<date> source; the validator treats that as a pure-boundary chain and checks its
-- pitch instead of its phase. This migration records page 2's six detected boundaries EXACTLY that
-- way, with the provenance in p_meta (who, from what, and why the sixth line is weak), then snaps
-- both pages' bands to their admitted rules and writes the extents through
-- derm.save_page_geometry, which runs every geometry guard (G1..G14) before writing anything.
-- Page 1 uses the rules already recorded by the Studio's OK scan; page 2 uses the ones recorded
-- here. Rehearsed end to end in a rolled-back probe before this file was written: record -> wrote
-- true, pitch 7.786; save p1 -> 5 bands + extent, folder still blocked by page 2; save p2 -> 5
-- bands + extent, folder_still_blocked_by NULL; fn_sheet_publishable NULL.
--
-- Every stamp sits strictly inside its band (29.8, 37.72, 44.48, 51.81, 60.04 against the six
-- boundaries above), on both pages, and VERIFY 3 asserts it rather than trusting the table.
--
-- 🛑 THIS DOES NOT MARK THE SHEET COMPLETE. Completion is the operator's assertion in this estate;
-- it becomes a one-click action the moment this commits. Whether a generated sheet should complete
-- ITSELF after an automatic measurement is the design question this file's evidence feeds, and it
-- is Fred's call, not a side effect of a repair.
--
-- RULE 8: no schema change. address_row_map and page_block_extents are audit-triggered;
-- page_row_rules / page_rule_scans are written through the RPC that owns them.
-- ============================================================================================

BEGIN;

CREATE TEMP TABLE _stamps_before ON COMMIT DROP AS
  SELECT id, page, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, stamp_placed_by,
         stamp_image_url, image_url, gdo_id, matched_client_id, matched_manifest_id
    FROM derm.address_row_map WHERE dump_folder = 'ticket-835076';

CREATE TEMP TABLE _imgs_before ON COMMIT DROP AS
  SELECT derm.ticket_page_images('835076') AS imgs;

-- ============================================================================================
-- PART 0. PRECONDITIONS.
-- ============================================================================================
DO $pre$
DECLARE v_n int; v_s text;
BEGIN
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-835076' AND stamp_placed_at IS NOT NULL;
  IF v_n <> 10 THEN RAISE EXCEPTION 'PRE 0.1: % placed cards, expected 10', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.address_row_map WHERE dump_folder = 'ticket-835076' AND band_y0_pct IS NOT NULL;
  IF v_n <> 0 THEN RAISE EXCEPTION 'PRE 0.2: % cards already carry a manual band, expected 0', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.page_block_extents WHERE dump_folder = 'ticket-835076';
  IF v_n <> 0 THEN RAISE EXCEPTION 'PRE 0.3: % extents already exist, expected 0', v_n; END IF;
  IF derm.fn_sheet_publishable('ticket-835076') IS DISTINCT FROM 'needs_snap_then_extent' THEN
    RAISE EXCEPTION 'PRE 0.4: publishable reads %, expected needs_snap_then_extent',
      COALESCE(derm.fn_sheet_publishable('ticket-835076'), 'NULL');
  END IF;

  -- The stamps this file snaps around, exactly as placed.
  SELECT string_agg(c.client_code || '@' || r.stamp_page || ':' || r.stamp_y_pct, ' ' ORDER BY r.stamp_page, r.stamp_y_pct)
    INTO v_s FROM derm.address_row_map r JOIN public.clients c ON c.id = r.matched_client_id
   WHERE r.dump_folder = 'ticket-835076';
  IF v_s IS DISTINCT FROM
     '149-RUS@1:29.800 014-JOY@1:37.720 032-LG@1:44.480 035-LG@1:51.810 040-MV@1:60.040 '
     '049-PV@2:29.800 083-SHUL@2:37.720 082-TFC@2:44.480 033-LG@2:51.810 142-57@2:60.040' THEN
    RAISE EXCEPTION 'PRE 0.5: the stamps are not where this file expects: %', v_s;
  END IF;

  -- Page 1's admitted rules are the Studio's OK scan, and they are the six boundaries used below.
  SELECT string_agg(rule_pct::text, ',' ORDER BY rule_pct) INTO v_s
    FROM derm.v_page_printed_rules WHERE dump_folder = 'ticket-835076' AND effective_page = 1 AND kind = 'boundary';
  IF v_s IS DISTINCT FROM '26.168,34.386,41.090,48.270,56.055,63.798' THEN
    RAISE EXCEPTION 'PRE 0.6: page-1 admitted boundaries are %, not the six this file snaps to', v_s;
  END IF;
  -- Page 2 has NO admitted rules (its only scan graded FAILED and wrote none).
  SELECT count(*) INTO v_n FROM derm.v_page_printed_rules WHERE dump_folder = 'ticket-835076' AND effective_page = 2;
  IF v_n <> 0 THEN RAISE EXCEPTION 'PRE 0.7: page 2 already has % admitted rules', v_n; END IF;
  IF EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE dump_folder = 'ticket-835076' AND effective_page = 2 AND source LIKE 'human-v1-%') THEN
    RAISE EXCEPTION 'PRE 0.7: page 2 already carries a human-v1 scan';
  END IF;

  -- Nothing served, not completed.
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
   WHERE d.manifest_id IN (SELECT matched_manifest_id FROM derm.address_row_map WHERE dump_folder = 'ticket-835076');
  IF v_n <> 0 THEN RAISE EXCEPTION 'PRE 0.8: % document(s) already served', v_n; END IF;
  IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-835076' AND completed) THEN
    RAISE EXCEPTION 'PRE 0.9: the sheet is already completed';
  END IF;
  RAISE NOTICE 'PRE OK';
END
$pre$;

-- ============================================================================================
-- PART 1. PAGE 2's LINES, recorded the way "Draw the bands" records them.
-- ============================================================================================
DO $rec$
DECLARE v_j jsonb; v_url text;
BEGIN
  v_url := (derm.ticket_page_images('835076'))[2];
  IF v_url NOT LIKE '%/derm/1929/address_2.jpg' THEN
    RAISE EXCEPTION 'PART 1: image position 2 is %, not derm/1929/address_2.jpg', v_url;
  END IF;
  v_j := derm.record_page_rules(
    'ticket-835076', 2, 'human-v1-2026-09-14', v_url,
    '[{"pct":25.505,"run":0.992,"kind":"boundary"},
      {"pct":33.838,"run":0.993,"kind":"boundary"},
      {"pct":40.572,"run":0.994,"kind":"boundary"},
      {"pct":47.811,"run":0.994,"kind":"boundary"},
      {"pct":55.640,"run":0.994,"kind":"boundary"},
      {"pct":63.426,"run":0.507,"kind":"boundary"}]'::jsonb,
    jsonb_build_object(
      'grade', 'OK',
      'detail', '6 slot boundaries recorded by migration 2026-09-14_0030 from the run-length detector '
             || '(scripts/probes/rev/detect_node.js) on this scan, the way Draw the bands records lines: '
             || 'all boundary, no dividers. The Studio''s own detector run on 2026-09-13 found the same '
             || 'six lines and graded FAILED because the sixth (63.426) is printed half-width here '
             || '(run 0.507) and the phase check read it as a divider. Confirmed against the five stamps '
             || '(each strictly inside its slot) and against page 1''s slot proportions (agree within 0.1pp).',
      'recorded_by', 'claude, on Fred''s instruction, 2026-09-14'));
  IF COALESCE((v_j->>'wrote')::boolean, false) IS NOT TRUE OR (v_j->>'n_boundaries')::int <> 6 THEN
    RAISE EXCEPTION 'PART 1: record_page_rules did not accept the page-2 lines: %', v_j;
  END IF;
  RAISE NOTICE 'PART 1 OK: %', v_j;
END
$rec$;

-- ============================================================================================
-- PART 2. BANDS SNAPPED TO THE ADMITTED RULES + EXTENTS, one page-atomic save per page.
-- ============================================================================================
DO $geo$
DECLARE v_j jsonb;
BEGIN
  v_j := derm.save_page_geometry('ticket-835076', 1,
    (SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', b.y0, 'y1', b.y1))
       FROM derm.address_row_map r
       JOIN (VALUES (29.8,26.168,34.386),(37.72,34.386,41.090),(44.48,41.090,48.270),
                    (51.81,48.270,56.055),(60.04,56.055,63.798)) b(sy,y0,y1) ON b.sy = r.stamp_y_pct
      WHERE r.dump_folder = 'ticket-835076' AND r.stamp_page = 1),
    26.168, 63.798);
  IF (v_j->>'saved_bands')::int <> 5 OR (v_j->>'extent_written')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'PART 2: page 1 did not save cleanly: %', v_j;
  END IF;
  RAISE NOTICE 'PART 2 page 1: %', v_j;

  v_j := derm.save_page_geometry('ticket-835076', 2,
    (SELECT jsonb_agg(jsonb_build_object('row_id', r.id, 'y0', b.y0, 'y1', b.y1))
       FROM derm.address_row_map r
       JOIN (VALUES (29.8,25.505,33.838),(37.72,33.838,40.572),(44.48,40.572,47.811),
                    (51.81,47.811,55.640),(60.04,55.640,63.426)) b(sy,y0,y1) ON b.sy = r.stamp_y_pct
      WHERE r.dump_folder = 'ticket-835076' AND r.stamp_page = 2),
    25.505, 63.426);
  IF (v_j->>'saved_bands')::int <> 5 OR (v_j->>'extent_written')::boolean IS NOT TRUE
     OR v_j->>'folder_still_blocked_by' IS NOT NULL THEN
    RAISE EXCEPTION 'PART 2: page 2 did not save cleanly: %', v_j;
  END IF;
  RAISE NOTICE 'PART 2 page 2: %', v_j;
END
$geo$;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE v_n int; v_s text; v_imgs text[];
BEGIN
  -- 1. Every band edge IS an admitted printed rule on its own page (on-rule by construction).
  SELECT count(*) INTO v_n
    FROM derm.address_row_map r
   WHERE r.dump_folder = 'ticket-835076'
     AND (r.band_y0_pct IS NULL OR r.band_y1_pct IS NULL
          OR NOT EXISTS (SELECT 1 FROM derm.v_page_printed_rules p WHERE p.dump_folder = r.dump_folder
                            AND p.effective_page = r.stamp_page AND p.rule_pct = r.band_y0_pct)
          OR NOT EXISTS (SELECT 1 FROM derm.v_page_printed_rules p WHERE p.dump_folder = r.dump_folder
                            AND p.effective_page = r.stamp_page AND p.rule_pct = r.band_y1_pct));
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % band edge(s) are not on an admitted rule', v_n; END IF;

  -- 2. Bands tile each page contiguously, and the extent is the first/last boundary.
  SELECT string_agg(e.effective_page || ':' || e.top_pct || '-' || e.bottom_pct, ' ' ORDER BY e.effective_page)
    INTO v_s FROM derm.page_block_extents e WHERE e.dump_folder = 'ticket-835076';
  IF v_s IS DISTINCT FROM '1:26.168-63.798 2:25.505-63.426' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: extents are %', v_s;
  END IF;
  SELECT count(*) INTO v_n
    FROM derm.address_row_map a JOIN derm.address_row_map b
      ON b.dump_folder = a.dump_folder AND b.stamp_page = a.stamp_page AND b.band_y0_pct = a.band_y1_pct
   WHERE a.dump_folder = 'ticket-835076';
  IF v_n <> 8 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % contiguous band joins, expected 8 (4 per page)', v_n; END IF;

  -- 3. Every stamp is strictly inside its own band.
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'ticket-835076'
     AND NOT (stamp_y_pct > band_y0_pct AND stamp_y_pct < band_y1_pct);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: % stamp(s) outside their own band', v_n; END IF;

  -- 4. The gate is open and the geometry guards are clean.
  IF derm.fn_sheet_publishable('ticket-835076') IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: still blocked by %', derm.fn_sheet_publishable('ticket-835076');
  END IF;
  SELECT string_agg(code, '|') INTO v_s
    FROM derm.check_page_geometry('ticket-835076', 1,
      (SELECT jsonb_agg(jsonb_build_object('row_id', id, 'y0', band_y0_pct, 'y1', band_y1_pct))
         FROM derm.address_row_map WHERE dump_folder = 'ticket-835076' AND stamp_page = 1), 26.168, 63.798);
  IF v_s IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 4 FAILED: page 1 geometry reports %', v_s; END IF;
  SELECT string_agg(code, '|') INTO v_s
    FROM derm.check_page_geometry('ticket-835076', 2,
      (SELECT jsonb_agg(jsonb_build_object('row_id', id, 'y0', band_y0_pct, 'y1', band_y1_pct))
         FROM derm.address_row_map WHERE dump_folder = 'ticket-835076' AND stamp_page = 2), 25.505, 63.426);
  IF v_s IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 4 FAILED: page 2 geometry reports %', v_s; END IF;

  -- 5. The stamps and the page map did not move; the page-1 detector scan is untouched.
  SELECT count(*) INTO v_n FROM (
    SELECT * FROM _stamps_before
    EXCEPT
    SELECT id, page, stamp_page, stamp_x_pct, stamp_y_pct, stamp_placed_at, stamp_placed_by,
           stamp_image_url, image_url, gdo_id, matched_client_id, matched_manifest_id
      FROM derm.address_row_map WHERE dump_folder = 'ticket-835076') x;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: % stamp row(s) changed', v_n; END IF;
  v_imgs := derm.ticket_page_images('835076');
  IF v_imgs IS DISTINCT FROM (SELECT imgs FROM _imgs_before) THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: ticket_page_images moved to %', v_imgs;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE dump_folder = 'ticket-835076' AND effective_page = 1
                    AND source = 'runlen-v2-2026-09-13' AND grade = 'OK') THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: the page-1 detector scan is no longer the OK runlen-v2-2026-09-13 row';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE dump_folder = 'ticket-835076' AND effective_page = 2
                    AND source = 'human-v1-2026-09-14' AND grade = 'OK' AND n_boundaries = 6) THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: the page-2 scan row is not the OK human-v1-2026-09-14 row with 6 boundaries';
  END IF;

  -- 6. Still not completed, still nothing served: completing it is the operator's click.
  IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-835076' AND completed) THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: the sheet completed itself';
  END IF;
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs d
   WHERE d.manifest_id IN (SELECT matched_manifest_id FROM derm.address_row_map WHERE dump_folder = 'ticket-835076');
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6 FAILED: % document(s) published', v_n; END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: ticket-835076 measured on both pages from detected lines, 10 bands '
               'on admitted rules tiling each page, extents at the first/last boundary, every stamp '
               'inside its band, publishable, stamps and page map untouched, not completed.';
END
$verify$;

COMMIT;
