-- 2026-09-02_1245_blackout_extent_830714.sql
--
-- WHY
-- ---
-- ticket-830714 (white 830714, manifests 1622/1623/1624 = 187-HAI / 034-LG / 009-CN) is stamped and
-- its bands are already snapped (band_source 'ported-rulesnap-2026-08-31', from 2026-08-31_1130), but
-- it has NO derm.page_block_extents row, so derm.fn_blackout_targets' HARD GATE excludes it and its 3
-- clients see no FOG eManifest on the Field Portal. derm.v_blackout_blocked_sheets names it
-- "needs_extent: Bands are already snapped. Add the extent bounded by the printed roster (first to
-- last form rule, covering empty slots), and verify every band still falls inside it."
--
-- Bands are unchanged here; this migration ONLY adds the extent. That is safe BECAUSE the bands are
-- already snapped to detected rules (not derived) -- the 2026-08-19 "no extent over derived bands"
-- rule does not apply.
--
-- THE PAGE, read off the scan (derm/1622/address_1.jpeg), a handwritten pad (template top-right 416,
-- a 6-slot form): Section B rows filled:
--   row 1: GDO-10877, 009-CN Casa Neos Kitchens
--   row 2: GDO-15062, 009-CN Casa Neos - Bari
--   row 3: GDO-16389, 009-CN Casa Neos - Lounge
--   row 4: GDO-15094, 034-LG La Granja
--   row 5: GDO-137,   187-HAI Shalom Haits
--   row 6: EMPTY.
-- Confirmed by derm.address_sheet_row_reads (rows 1-5 high-confidence facilities, row 6 null). So the
-- 5 filled rows are all owned (009-CN holds 3 permit cards) and there is NO printed-but-unrowed
-- facility.
--
-- THE EXTENT: the detector scan runlen-v2-2026-08-21 places the printed roster boundaries at
-- 14.796 (Section B header line) .. 65.051 (below the empty row 6). derm.check_page_geometry REFUSED a
-- narrower extent with G11_ROSTER_NOT_COVERED ("empty printed slots would be served") and PASSED with
-- ZERO violations at 14.796 .. 65.051. The wider extent blacks the column-header strip and the empty
-- row 6, neither of which carries client data; the 5 client bands (27.742 .. 55.166) sit inside it.
-- Following the validator's own boundary is the safe (wider) direction.
--
-- RULE 8: derm.page_block_extents is audited (2026-08-27_0347); this extent write is captured. No band
-- and no detector row is written.

BEGIN;

INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at)
VALUES ('ticket-830714', 1, 14.796, 65.051, 'runlen-v2-2026-08-21', now());

-- VERIFY
DO $do$
DECLARE v_n integer; v_viol text;
BEGIN
  -- 1. every band on the page falls inside the new extent
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder='ticket-830714' AND band_y0_pct IS NOT NULL
     AND (band_y0_pct < 14.796 OR band_y1_pct > 65.051);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1: % band(s) fall outside the extent', v_n; END IF;

  -- 2. the estate's own geometry validator passes with ZERO violations
  SELECT string_agg((v).code, ', ') INTO v_viol
    FROM derm.check_page_geometry('ticket-830714', 1,
      '[{"row_id":1090,"y0":27.742,"y1":33.227},{"row_id":984,"y0":33.227,"y1":38.712},{"row_id":1091,"y0":38.712,"y1":44.133},{"row_id":983,"y0":44.133,"y1":49.681},{"row_id":982,"y0":49.681,"y1":55.166}]'::jsonb,
      14.796, 65.051) v;
  IF v_viol IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 2: check_page_geometry violations: %', v_viol; END IF;

  -- 3. the three clients become blackout targets (009-CN's 3 permit cards group to one)
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(500) t WHERE t.manifest_id IN (1622,1623,1624);
  IF v_n <> 3 THEN RAISE EXCEPTION 'VERIFY 3: 830714 produced % targets (want 3)', v_n; END IF;

  -- 4. exactly one extent now exists for this folder, with the intended values
  SELECT count(*) INTO v_n FROM derm.page_block_extents
   WHERE dump_folder='ticket-830714' AND effective_page=1 AND top_pct=14.796 AND bottom_pct=65.051;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 4: % matching extent row for ticket-830714 (want 1)', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: extent 14.796/65.051 spans the printed roster, all 5 bands inside, check_page_geometry clean, 3 blackout targets (187-HAI, 034-LG, 009-CN).';
END $do$;

COMMIT;
