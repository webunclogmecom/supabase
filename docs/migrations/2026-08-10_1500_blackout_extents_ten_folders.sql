-- 2026-08-10_1500_blackout_extents_ten_folders.sql
--
-- WHAT: measured Section-B page extents for the remaining 10 stamped dump folders (14 pages), so the
--       Field Portal blackout pipeline can generate their per-client redacted DERM eManifests.
--
-- WHY: Fred, 2026-08-10: "Go with the fix." These were the folders left after
--      2026-08-07_0410 fixed ticket-831938. Symptom on each: customer.work_orders.derm_manifest_url
--      is NULL while manifest_number is populated, so the FP card renders the number and a
--      DOCUMENTED chip with no image. 40 work orders across 38 clients.
--
-- ROOT CAUSE (unchanged from 2026-08-07_0410, restated because this file may be read alone):
--   derm.fn_blackout_targets() INNER JOINs derm.page_block_extents ("HARD GATE: measured pages
--   only"). No extent row => the ticket is never selected, never processed, no redacted file, NULL
--   url. The gate is correct and fail-closed. There is no automated measurement path; all 140
--   pre-existing extents came from dated manual passes.
--
-- 🛑 THE EXTENT IS NOT THE BAND RANGE. blocks_top = LEAST(extent_top, min(band)) and
--   blocks_bottom = GREATEST(extent_bottom, max(band)), so deriving the extent from the bands is an
--   algebraic no-op that blacks out only the STAMPED rows. Empty printed slots have no band and
--   would stay visible. That is the 2026-07-10 v2 leak.
--
--   ⚠ THIS BATCH CONTAINS A LIVE INSTANCE OF EXACTLY THAT CASE, which is why it is worth the care:
--   **ticket-309661 page 2 has 6 printed slots and only 2 filled.** Its band range stops at
--   41.143% (the slot-2/slot-3 rule) while the printed block runs to 66.164%. A band-derived extent
--   would have left FOUR blank printed slots outside the blackout. Measured extent: 28.7 / 66.4.
--
-- HOW THESE NUMBERS WERE OBTAINED
--   Every one of the 14 pages was measured TWICE, independently, from the actual page image, by
--   detecting the printed horizontal form rules (per-row dark-pixel profiling, cross-checked in
--   several x-windows to rule out skew) rather than from the stamps. The two readings were then
--   merged by taking the OUTWARD extreme of each pair (min of the two tops, max of the two bottoms),
--   because a wider extent can only black more of the form while a narrower one exposes a
--   neighbour's name and address. 14/14 pages carry two measurements; 0 pages were flagged as
--   possibly-narrow by the second reader.
--
-- ⚠ FOUR SHEETS ARE THE **6-SLOT** DERM FORM VARIANT, not our 5-slot generated template:
--   ticket-309661, ticket-820714, ticket-831047, ticket-831102. Their footer reads "...more than 6
--   Grease Interceptors Pumped!". They legitimately do NOT match the 25.8 / 64.4 generated-sheet
--   reference, and a future reviewer should not "correct" them toward it.
--
-- ⚠ ticket-310590: the image URL order is the REVERSE of the printed page numbers (address_1.JPG is
--   printed "1074-2"). effective_page follows the ARRAY order, which is what fn_blackout_targets
--   indexes (l.imgs[l.effective_page]), and the band data corroborates array order. Both pages
--   measured to the same extent anyway, so the mapping is not load-bearing here. Do not "fix" it.
--
-- AUDIT (ADR 010): derm.page_block_extents is measurement metadata, carries no audit trigger. This
--   file is the record. Keyed (dump_folder, effective_page); insert is ON CONFLICT DO NOTHING so a
--   replay cannot silently overwrite a later, better measurement.

BEGIN;

INSERT INTO derm.page_block_extents (dump_folder, effective_page, top_pct, bottom_pct, source, measured_at)
SELECT v.folder, v.page, v.top, v.bottom, 'dual-measured-2026-08-10', now()
FROM (VALUES
  ('ticket-309661', 1, 29.3, 65.8),
  ('ticket-309661', 2, 28.7, 66.4),
  ('ticket-310590', 1, 24.8, 64.6),
  ('ticket-310590', 2, 24.8, 64.6),
  ('ticket-310607', 1, 23.7, 63.6),
  ('ticket-311045', 1, 24.85, 63.44),
  ('ticket-820714', 1, 27.55, 60.84),
  ('ticket-831047', 1, 24, 60.9),
  ('ticket-831102', 1, 26.6, 60.9),
  ('ticket-831102', 2, 23.3, 58.9),
  ('ticket-831220', 1, 23.9, 64.3),
  ('ticket-831710', 1, 25.9, 64.2),
  ('ticket-832194', 1, 24.4, 64.7),
  ('ticket-832194', 2, 23.9, 63.5)
) AS v(folder, page, top, bottom)
ON CONFLICT (dump_folder, effective_page) DO NOTHING;

DO $$
DECLARE r record; n int; bad int;
BEGIN
  -- (a) all 14 present
  SELECT count(*) INTO n FROM derm.page_block_extents
   WHERE source = 'dual-measured-2026-08-10';
  IF n <> 14 THEN RAISE EXCEPTION 'expected 14 new extents, found %', n; END IF;

  -- (b) 🛑 THE SAFETY ASSERTION. Every extent must BRACKET every band on its page, or the redaction
  --     leaves part of the roster visible. This is the check that would have caught the v2 leak.
  bad := 0;
  FOR r IN
    SELECT e.dump_folder, e.effective_page, e.top_pct, e.bottom_pct,
           min(b.band_y0_pct) AS lo, max(b.band_y1_pct) AS hi
      FROM derm.page_block_extents e
      JOIN derm.v_stamp_row_bands b
        ON b.dump_folder = e.dump_folder AND b.effective_page = e.effective_page
     WHERE e.source = 'dual-measured-2026-08-10'
     GROUP BY e.dump_folder, e.effective_page, e.top_pct, e.bottom_pct
  LOOP
    IF r.top_pct > r.lo OR r.bottom_pct < r.hi THEN
      bad := bad + 1;
      RAISE WARNING '% p%: extent %..% does NOT bracket bands %..%',
        r.dump_folder, r.effective_page, r.top_pct, r.bottom_pct, r.lo, r.hi;
    END IF;
  END LOOP;
  IF bad > 0 THEN RAISE EXCEPTION '% page(s) would leave roster rows visible', bad; END IF;

  -- (c) CONTROL: prove (b) can actually fail. Without a page to check, the loop above passes
  --     vacuously and proves nothing.
  SELECT count(*) INTO n
    FROM derm.page_block_extents e
    JOIN derm.v_stamp_row_bands b
      ON b.dump_folder = e.dump_folder AND b.effective_page = e.effective_page
   WHERE e.source = 'dual-measured-2026-08-10';
  IF n = 0 THEN
    RAISE EXCEPTION 'CONTROL FAILED: the bracket loop matched no band rows, so it tested nothing';
  END IF;
  RAISE NOTICE 'bracket check ran against % banded page-rows', n;

  -- (d) the gate opens: every one of the 10 folders must now yield blackout work
  SELECT count(DISTINCT ticket_key) INTO n FROM derm.fn_blackout_targets(500);
  IF n < 10 THEN
    RAISE EXCEPTION 'expected >= 10 distinct tickets queued, got % - a gate other than the extent is refusing', n;
  END IF;

  -- (e) no pre-existing extent was touched.
  --     142 = the 140 that existed before this work, PLUS the 2 that
  --     2026-08-07_0410 added for ticket-831938 (source 'generated-form-rules-2026-08-07').
  --     ⚠ The first run of this migration ABORTED here expecting 140, which was my own stale
  --     baseline, and the abort was correct: it is exactly the check earning its keep. Verified the
  --     two extra rows are mine before changing the number, rather than bumping it to make it pass.
  SELECT count(*) INTO n FROM derm.page_block_extents WHERE source <> 'dual-measured-2026-08-10';
  IF n <> 142 THEN RAISE EXCEPTION 'pre-existing extent count changed: expected 142, got %', n; END IF;

  RAISE NOTICE 'OK: 14 extents added across 10 folders, all bracket their bands, % tickets queued',
    (SELECT count(DISTINCT ticket_key) FROM derm.fn_blackout_targets(500));
END $$;

COMMIT;
