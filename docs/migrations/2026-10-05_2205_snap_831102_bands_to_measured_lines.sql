-- 2026-10-05_2205_snap_831102_bands_to_measured_lines.sql
--
-- WHY
-- ---
-- Fred, 2026-10-05, on the open item "snap the three bands on ticket-831102 page 2": "go ahead with all".
-- ticket-831102 (white 831102, manifests 1639..1643) was completed 2026-07-30 with all five bands still
-- DERIVED (stamp-midpoint heuristic, band_y0/y1 NULL): the dark scans of 2026-08-20 defeated the detector.
-- Its pages got an OK measurement today by review (2026-10-05_1505, runlen-v2-2026-10-05). Measured
-- against it, the page-2 derived bands sat about 1 point ABOVE the printed lines, so the blacked-out copies
-- for 169-TCE and 076-TCE showed a thin, unreadable strip of the client above (band_review had accepted
-- them as "band holds only its own name and address" before the measurement existed).
--
-- WHY PAGE 1 TOO (5 documents, not 3): a band change reopens the sheet (trg_zz_dirty_on_card_change),
-- derm.fn_blackout_targets regenerates only COMPLETED sheets, and derm.set_sheet_completed refuses while
-- any stamped card has no saved band (fn_sheet_publishable = needs_snap_then_extent, pages 1 and 2). So the
-- page-2 fix cannot ship without saving page 1's two bands as well. Page 1: 057-BAY moves by about 0.5
-- point onto its own printed slot (review said "offset 0.56pp"), 133-MUT by at most 0.23 (already on rule).
--
-- THE GEOMETRY (every value a measured boundary on the same scan, runlen-v2-2026-10-05, grade OK):
--   page 1 boundaries 27.733 / 33.200 / 38.667 / 44.133 / 49.600 / 55.067 / 60.500
--     875 057-BAY  stamp 30.087 -> [27.733, 33.200]
--     876 133-MUT  stamp 35.847 -> [33.200, 38.667]
--   page 2 boundaries 25.407 / 30.894 / 36.382 / 41.870 / 47.392 / 52.947 / 58.537
--     877 024-GRO  stamp 26.844 -> [25.407, 30.894]
--     879 169-TCE  stamp 32.792 -> [30.894, 36.382]
--     878 076-TCE  stamp 38.880 -> [36.382, 41.870]
--   Every stamp sits inside its own row. The Limits are NOT changed (page 1 26.6/60.9, page 2 23.3/58.9):
--   both already cover every printed row, empty ones included, and a Limit never narrows.
--
-- HOW: through derm.save_page_geometry (the one sanctioned page writer; every G-guard runs), then
-- derm.set_sheet_completed (gated on fn_sheet_publishable). The redact sweep (3-59/5, one per run)
-- regenerates the 5 documents within about 25 minutes. Dry run (rolled back) before apply:
-- check_page_geometry 0 violations on both pages, all 5 bands ON_RULE + ONE_CLIENT, 0 on
-- v_band_edges_off_rule, 5 blackout targets (1639, 1640 page 1; 1641, 1642, 1643 page 2).
--
-- RULE 8: derm.address_row_map and derm.stamp_sheet_status are audited; no new table, no grant change.

BEGIN;

SELECT derm.save_page_geometry('ticket-831102', 1,
  '[{"row_id":875,"y0":27.733,"y1":33.200},{"row_id":876,"y0":33.200,"y1":38.667}]'::jsonb, null, null);

SELECT derm.save_page_geometry('ticket-831102', 2,
  '[{"row_id":877,"y0":25.407,"y1":30.894},{"row_id":879,"y0":30.894,"y1":36.382},{"row_id":878,"y0":36.382,"y1":41.870}]'::jsonb, null, null);

SELECT derm.set_sheet_completed('ticket-831102', true);

DO $verify$
DECLARE v_n integer;
BEGIN
  -- 1. the five bands are exactly the measured slots
  SELECT count(*) INTO v_n FROM derm.address_row_map r
   JOIN (VALUES (875, 27.733, 33.200), (876, 33.200, 38.667), (877, 25.407, 30.894),
                (879, 30.894, 36.382), (878, 36.382, 41.870)) w(id, y0, y1)
     ON w.id = r.id AND r.band_y0_pct = w.y0 AND r.band_y1_pct = w.y1
   WHERE r.dump_folder = 'ticket-831102';
  IF v_n <> 5 THEN RAISE EXCEPTION 'VERIFY 1: % of 5 bands on the measured slots', v_n; END IF;

  -- 2. every edge is ON_RULE and every band one client (the check that flagged them)
  SELECT count(*) INTO v_n FROM derm.v_band_edge_check
   WHERE dump_folder = 'ticket-831102' AND (edge_verdict <> 'ON_RULE' OR slot_verdict <> 'ONE_CLIENT');
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 2: % band(s) not ON_RULE/ONE_CLIENT', v_n; END IF;

  -- 3. the Limits did not move
  SELECT count(*) INTO v_n FROM derm.page_block_extents
   WHERE dump_folder = 'ticket-831102'
     AND ((effective_page = 1 AND top_pct = 26.6 AND bottom_pct = 60.9)
       OR (effective_page = 2 AND top_pct = 23.3 AND bottom_pct = 58.9));
  IF v_n <> 2 THEN RAISE EXCEPTION 'VERIFY 3: Limits changed (% of 2 unchanged)', v_n; END IF;

  -- 4. completed again, and all five documents are queued to regenerate
  IF NOT (SELECT completed FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-831102') THEN
    RAISE EXCEPTION 'VERIFY 4: sheet is not completed';
  END IF;
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(500) t WHERE t.manifest_id BETWEEN 1639 AND 1643;
  IF v_n <> 5 THEN RAISE EXCEPTION 'VERIFY 4: % of 5 documents queued', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: 5 bands on measured lines, Limits unchanged, completed, 5 documents queued';
END
$verify$;

COMMIT;
