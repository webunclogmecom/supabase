-- 2026-09-02_1240_snap_and_measure_834287.sql
--
-- WHY
-- ---
-- Fred: the DERM FOG eManifest for ticket-834287 (214-MYK, manifest 1768) never appeared on the
-- Field Portal even though the sheet was AI-stamped. Root cause: the card was stamped but its band
-- was still DERIVED (stamp-midpoint heuristic) and the page had NO derm.page_block_extents row, so
-- derm.fn_blackout_targets' "measured pages only" HARD GATE excluded it and nothing was ever
-- redacted. This is the "needs_snap_then_extent" state named by derm.v_blackout_blocked_sheets.
--
-- SNAP THE BAND FIRST, THEN THE EXTENT, IN ONE MIGRATION (the 2026-08-19 leak rule). An extent does
-- not redact anything; it opens the gate onto whatever bands exist, and publishing a derived band as
-- measured is what leaked client data on 2026-08-19.
--
-- THE PAGE, read off the scan (derm/1768/address_1.jpg), a GENERATED sheet (template top-right 1104):
-- Section B "Origination of Waste" has 5 interceptor rows and ONLY ROW 1 IS FILLED:
--   row 1: GDO-08422, 214-MYK Myka Brickell FT LLC, 777 Brickell Avenue, Miami, Florida 33131.
--   rows 2-5: EMPTY (blank GDO#, blank facility, blank address; the diagonal "FOG" scrawl carries no
--             client data). Confirmed by derm.address_sheet_row_reads: row 1 = 214-MYK (high), rows
--             2-5 = null facility. So there is NO printed-but-unrowed facility (the ticket-310590 p2
--             leak shape is absent).
--
-- THE GEOMETRY comes from the EXISTING detector scan runlen-v2-2026-09-01 (grade OK, 6 boundaries,
-- pitch 7.808) already in derm.page_row_rules -- no new detection. The six boundaries are
-- 25.630 / 34.005 / 40.743 / 48.048 / 55.856 / 63.665 (all run >= 0.99). Row 1 = [25.630, 34.005].
--   * BAND for 214-MYK (card 1054, stamp_y 29.800, comfortably inside): [25.630, 34.005].
--   * EXTENT: 25.630 .. 63.665 (first boundary to LAST boundary, so the four empty rows 2-5 are
--     blacked). Every band falls inside it.
--
-- VALIDATED BY THE ESTATE'S OWN GUARD BEFORE WRITING: derm.check_page_geometry('ticket-834287', 1,
-- [{1054, 25.630, 34.005}], 25.630, 63.665) returned ZERO violations (all G1-G14 pass).
--
-- RULE 8: derm.address_row_map is audited (band write carries old_row); derm.page_block_extents is
-- audited since 2026-08-27_0347 (this extent write is captured). No new detector rows are written.

BEGIN;

-- PART 1. Snap the band onto the two detected boundaries (was derived: band_y0/y1 were NULL).
UPDATE derm.address_row_map r
   SET band_y0_pct = 25.630, band_y1_pct = 34.005,
       band_source = 'runlen-snap-2026-09-02', band_set_at = now(),
       band_set_by = 'claude-runlen-2026-09-02'
 WHERE r.dump_folder = 'ticket-834287'
   AND COALESCE(r.stamp_page, r.page) = 1
   AND r.stamp_y_pct = 29.800;

-- PART 2. AND ONLY NOW THE EXTENT. This is what opens the gate.
INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at)
VALUES ('ticket-834287', 1, 25.630, 63.665, 'runlen-v2-2026-09-01', now());

-- VERIFY
DO $do$
DECLARE v_n integer; v_viol text;
BEGIN
  -- 1. exactly one card banded on this folder, onto the detected boundaries
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder='ticket-834287' AND band_y0_pct=25.630 AND band_y1_pct=34.005;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 1: % cards banded to 25.630/34.005 (want 1)', v_n; END IF;

  -- 2. both band edges are recorded boundaries on this page
  SELECT count(*) INTO v_n FROM (VALUES (25.630::numeric),(34.005::numeric)) e(v)
   WHERE NOT EXISTS (SELECT 1 FROM derm.page_row_rules p
                      WHERE p.dump_folder='ticket-834287' AND p.effective_page=1
                        AND p.kind='boundary' AND p.rule_pct=e.v);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 2: % band edge(s) not on a detected boundary', v_n; END IF;

  -- 3. the estate's own geometry validator passes with ZERO violations
  SELECT string_agg((v).code, ', ') INTO v_viol
    FROM derm.check_page_geometry('ticket-834287', 1,
      '[{"row_id":1054,"y0":25.630,"y1":34.005}]'::jsonb, 25.630, 63.665) v;
  IF v_viol IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 3: check_page_geometry violations: %', v_viol; END IF;

  -- 4. the card becomes a blackout target (the point of the migration)
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(500) t WHERE t.manifest_id = 1768;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 4: 214-MYK produced % targets (want 1)', v_n; END IF;

  -- 5. nothing else moved: exactly one extent added, for this folder
  SELECT count(*) INTO v_n FROM derm.page_block_extents WHERE dump_folder <> 'ticket-834287' AND measured_at > now() - interval '1 minute';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5: % extent(s) written for other folders', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: 214-MYK banded 25.630/34.005 onto detected boundaries, extent 25.630/63.665 blacks the 4 empty rows, check_page_geometry clean, 1 blackout target.';
END $do$;

COMMIT;
