-- 2026-08-27_1015_withdraw_w4s1_g7_overlapping_bands.sql
--
-- WHY
-- ---
-- A LIVE customer-facing exposure, found 2026-08-27 while checking whether a hand-drawn rectangle
-- could overlap a neighbour's printed row. It turned out one pair ALREADY overlaps.
--
-- `window4-sheet1` page 1, cards 173 (019-G7 "G7 Kitchens 34") and 607 (215-G7 "Kitchen 35"):
-- BYTE-IDENTICAL bands, 38.712 .. 44.154. Measured, not inferred -- the two served documents
-- (m1034-f532bdac0f.jpg and m1293-f532bdac0f.jpg) are the same 918,537 bytes with the same
-- sha256. The strip they reveal contains exactly ONE printed facility row.
--
-- 🛑 SO ONE OF THESE TWO CLIENTS IS BEING SHOWN THE OTHER'S FACILITY NAME AND STREET ADDRESS.
-- That is certain regardless of which one owns the row, because the strip holds one facility and
-- they are different clients on different manifests (1034 vs 1293).
--
-- 🛑 AND I COULD NOT DETERMINE WHICH WAY ROUND IT IS. The printed row reads "Kitchen 3?" and the
-- final digit is OVERWRITTEN -- a correction, one digit on top of another. At 10x on the original
-- scan, with autocontrast, it reads as plausibly 4 or 5. The two candidate clients are "G7
-- Kitchens 34" and "Kitchen 35", i.e. the digit IS the discriminator, and it is illegible.
-- This estate has twice attributed a permit to the wrong tenant in exactly this shape (Wynd 27 vs
-- Wynd 28, demoted 2026-06-27 and again 2026-08-24), so guessing is the one thing not to do.
--
-- WHAT THIS DOES, AND WHY IT COVERS BOTH DIRECTIONS
-- -------------------------------------------------
-- Withdraws BOTH documents and stops BOTH cards republishing. Withdrawing only one would require
-- knowing which client is the victim, which is the thing that cannot be established. A blank FOG
-- card is a complaint; a regulator-facing document showing another client's line is the failure
-- this whole lane exists to prevent.
--
-- 🛑 WITHDRAWING ALONE WOULD NOT HAVE HELD, AND THIS IS THE TRAP. derm.fn_blackout_targets emits
-- when `t.manifest_id IS NULL OR t.fingerprint IS DISTINCT FROM f.fprint`. Deleting a document row
-- makes `t.manifest_id` NULL, so the pair becomes a TARGET and `redact-manifest-sweep` (*/5)
-- republishes the identical leak within five minutes. Measured before the change: the pair is
-- currently NOT a target (fingerprint matches, idle), which is exactly why the delete would arm it.
-- So the stamp timestamp is cleared in the SAME transaction; fn_blackout_targets requires
-- `r.stamp_placed_at IS NOT NULL` per card, so neither card can be emitted.
--
-- ⚠ WHY `stamp_placed_at` AND NOT THE STAMP POINT. Clearing `stamp_y_pct` would remove the row
-- from derm.v_stamp_row_bands, which fails the WHOLE-FOLDER closed-world gate and would freeze the
-- other five clients on that page as collateral (see 2026-08-27_0356). Clearing only the timestamp
-- leaves the row in that view, so the folder still passes and the innocent five are untouched.
-- It also lands the two cards in the `no_stamp_timestamp` state that
-- derm.v_blackout_blocked_sheets already reports with the right instruction: "The stamp needs to
-- be re-placed through the Studio."
--
-- RECOVERABILITY
-- --------------
-- derm.redacted_manifest_docs has ZERO triggers and is NOT audited, so a DELETE there leaves no
-- record of any kind. Both rows were backed up FIRST, with a restore hint, to
--   backups/2026-08-27_w4s1_g7_overlap_containment.json
-- (workspace root, outside this PUBLIC repo). That file is the only restore path for them.
-- derm.address_row_map IS audited, so the stamp_placed_at change is recoverable from
-- audit.logs.old_row independently.
--
-- 🛑 THIS IS CONTAINMENT, NOT A FIX. Somebody has to read the paper and say which client owns that
-- row. The other one has a manifest on this dump ticket but NO printed row on the sheet, which is
-- why card 607 was created through `add_extra_client_card` in the first place. Until that is
-- settled, neither client should be served this page.
--
-- ⚠ Both stamps were placed by a HUMAN (`stamp_placed_by = 'stamp-studio'`) on 2026-07-07, seconds
-- apart. This was a deliberate act, not an OCR artifact, so whoever did it may remember which is
-- which -- ask before re-deriving it from the scan.
--
-- RULE 8 (audit trail): derm.address_row_map is already audited (audit_address_row_map), so the
-- UPDATE is captured with old_row. derm.redacted_manifest_docs is deliberately NOT audited
-- (machine-generated publication metadata, regenerable by design); the JSON backup above stands in
-- for it, per the rule-6 note in CLAUDE.md about checking recoverability BEFORE a sanctioned delete.

BEGIN;

-- Pin by primary key AND re-assert the predicate that made these rows withdrawable, so the
-- statement cannot fire if the world changed between the read and the write.
DELETE FROM derm.redacted_manifest_docs d
 USING derm.address_row_map a, derm.address_row_map b
 WHERE a.id = 173 AND b.id = 607
   AND d.manifest_id = a.matched_manifest_id AND d.client_id = a.matched_client_id
   AND a.band_y0_pct = b.band_y0_pct AND a.band_y1_pct = b.band_y1_pct
   AND a.matched_client_id <> b.matched_client_id;

DELETE FROM derm.redacted_manifest_docs d
 USING derm.address_row_map a, derm.address_row_map b
 WHERE a.id = 173 AND b.id = 607
   AND d.manifest_id = b.matched_manifest_id AND d.client_id = b.matched_client_id
   AND a.band_y0_pct = b.band_y0_pct AND a.band_y1_pct = b.band_y1_pct
   AND a.matched_client_id <> b.matched_client_id;

-- Stop both cards being re-emitted by the */5 sweep. Deliberately NOT clearing stamp_y_pct.
UPDATE derm.address_row_map
   SET stamp_placed_at = NULL
 WHERE id IN (173, 607)
   AND stamp_placed_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_n integer; v_cid_a bigint; v_cid_b bigint;
BEGIN
  SELECT matched_client_id INTO v_cid_a FROM derm.address_row_map WHERE id = 173;
  SELECT matched_client_id INTO v_cid_b FROM derm.address_row_map WHERE id = 607;

  -- 1. Both documents are gone.
  SELECT count(*) INTO v_n FROM derm.redacted_manifest_docs
   WHERE (manifest_id, client_id) IN ((1034, v_cid_a), (1293, v_cid_b));
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 1 failed: % mis-redacted document(s) still published', v_n;
  END IF;

  -- 2. Neither card can be re-emitted. THIS IS THE ONE THAT MATTERS: without it the sweep
  --    republishes the identical leak within five minutes. Limit is explicit because the argument
  --    DEFAULTS TO 3 and a bare call reads like an empty backlog.
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(500) t
   WHERE (t.manifest_id, t.client_id) IN ((1034, v_cid_a), (1293, v_cid_b));
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 failed: % withdrawn pair(s) are STILL blackout targets and would republish', v_n;
  END IF;

  -- 3. THE INNOCENT FIVE ARE UNTOUCHED. The other page-1 cards keep their stamps and their
  --    documents. This is the control against over-reach.
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'window4-sheet1' AND id NOT IN (173, 607) AND stamp_placed_at IS NULL;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 failed: % other card(s) on this folder lost their stamp timestamp', v_n;
  END IF;

  SELECT count(*) INTO v_n
    FROM derm.address_row_map r
    JOIN derm.redacted_manifest_docs d
      ON d.manifest_id = r.matched_manifest_id AND d.client_id = r.matched_client_id
   WHERE r.dump_folder = 'window4-sheet1' AND r.id NOT IN (173, 607);
  IF v_n <> 7 THEN
    RAISE EXCEPTION 'VERIFY 3 failed: the other cards now hold % documents, expected 7', v_n;
  END IF;

  -- 4. THE FOLDER IS NOT FROZEN. Clearing the timestamp must not have removed either row from
  --    derm.v_stamp_row_bands, which would fail the whole-folder closed-world gate and take the
  --    innocent five down with it.
  SELECT count(*) INTO v_n FROM derm.address_row_map
   WHERE dump_folder = 'window4-sheet1' AND stamp_y_pct IS NULL;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 failed: % row(s) lost their stamp point, the folder is now frozen', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets
   WHERE dump_folder = 'window4-sheet1' AND blocker = 'frozen_closed_world';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 failed: window4-sheet1 now reports as frozen_closed_world';
  END IF;

  -- 5. And no OTHER overlapping pair exists, so this really was the only one.
  SELECT count(*) INTO v_n FROM (
    SELECT 1 FROM derm.address_row_map x
      JOIN derm.address_row_map y
        ON y.dump_folder = x.dump_folder
       AND COALESCE(y.stamp_page, y.page) = COALESCE(x.stamp_page, x.page)
       AND y.id < x.id
       AND x.band_y0_pct < y.band_y1_pct AND x.band_y1_pct > y.band_y0_pct
     WHERE x.band_y0_pct IS NOT NULL AND y.band_y0_pct IS NOT NULL
       AND x.matched_client_id IS DISTINCT FROM y.matched_client_id) s;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 5: expected exactly the 1 known overlapping pair to remain in the data, found %', v_n;
  END IF;

  RAISE NOTICE 'VERIFY ok: both documents withdrawn, neither pair can republish, the other five clients on window4-sheet1 keep all 7 of their documents, and the folder is not frozen.';
END $do$;

COMMIT;
