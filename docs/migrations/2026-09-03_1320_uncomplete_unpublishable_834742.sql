-- 2026-09-03_1320_uncomplete_unpublishable_834742.sql
--
-- WHY
-- ---
-- `ticket-834742` was filed today and AUTO-COMPLETED by `stamp-studio-ai` at 16:20:39 UTC, FIVE
-- MINUTES before 2026-09-03_1230 installed the completion gate. It carries 10 cards, all 10 placed,
-- and **0 page_block_extents / 0 redacted documents** - so `derm.fn_sheet_publishable` returns
-- `needs_snap_then_extent` and its 10 clients would have silently sat on a placeholder, which is the
-- exact complaint that started this work. It is a live instance of the defect, caught by the new
-- watchdog within minutes of the gate landing.
--
-- The gate only fires on the false->true TRANSITION, so it could not retroactively refuse this row.
-- This migration makes the state HONEST: a sheet that cannot be blacked out is not complete. The
-- existing derm.fn_stamp_sheet_reopen_pin stamps reopened_at on the flip, which is what stops
-- trg_zy_generated_sheet_complete re-completing it on the next card change (the hole closed by
-- 2026-09-03_1230 PART 4).
--
-- 🛑 THIS WITHDRAWS NOTHING. The folder has 0 published documents, so there is no client document to
-- lose - unlike a normal dirty flip, where the old document deliberately keeps serving. Verified in
-- the VERIFY block below rather than asserted here.
--
-- ⇒ WHAT HAPPENS NEXT, and it needs a person: somebody measures ticket-834742 in the Stamp Studio
-- (drag the boundary to the first and last printed rule, snap every band), then marks it complete.
-- At that point the gate admits it, trg_zz_publish_on_complete kicks the sweep, and its 10 clients
-- get their FOG eManifest. Until then it is correctly visible as unfinished work rather than
-- falsely reported as done.
--
-- RULE 8 (audit): derm.stamp_sheet_status is audited, so this flip and its reason are in audit.logs.

BEGIN;

-- Pinned to the folder AND re-asserting the predicate that makes it uncompletable, so this cannot
-- fire if somebody measured the sheet between the read and the write.
UPDATE derm.stamp_sheet_status
   SET completed = false, completed_at = NULL, completed_by = NULL, updated_at = now()
 WHERE dump_folder = 'ticket-834742'
   AND completed
   AND derm.fn_sheet_publishable('ticket-834742') IS NOT NULL;

-- VERIFY
DO $do$
DECLARE v_n integer; v_stored boolean; v_txt text;
BEGIN
  -- 1. It really is unpublishable, and for the reason claimed.
  v_txt := derm.fn_sheet_publishable('ticket-834742');
  IF v_txt IS DISTINCT FROM 'needs_snap_then_extent' THEN
    RAISE EXCEPTION 'VERIFY 1: 834742 returned % (want needs_snap_then_extent)', coalesce(v_txt, 'NULL');
  END IF;

  -- 2. NOTHING WAS WITHDRAWN: it had, and still has, zero published documents.
  SELECT count(*) INTO v_n
    FROM derm.address_row_map r
    JOIN derm.redacted_manifest_docs d ON d.manifest_id = r.matched_manifest_id
   WHERE r.dump_folder = 'ticket-834742';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2: 834742 has % published document(s); this migration must not run', v_n;
  END IF;

  -- 3. It is now honestly incomplete, and the reopen pin is set so no machine re-completes it.
  SELECT completed INTO v_stored FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-834742';
  IF v_stored IS NOT FALSE THEN RAISE EXCEPTION 'VERIFY 3: 834742 still reads completed=%', v_stored; END IF;
  SELECT count(*) INTO v_n FROM derm.stamp_sheet_status
   WHERE dump_folder = 'ticket-834742' AND reopened_at IS NOT NULL;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 3: reopen pin not set'; END IF;

  -- 4. THE END-TO-END PROOF ON REAL DATA, which the install migration could only do with a sentinel:
  --    asking to complete an unpublishable sheet must leave it incomplete.
  UPDATE derm.stamp_sheet_status SET completed = true, completed_at = now(), completed_by = 'gate-e2e-probe'
   WHERE dump_folder = 'ticket-834742';
  SELECT completed INTO v_stored FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-834742';
  IF v_stored IS NOT FALSE THEN
    RAISE EXCEPTION 'VERIFY 4: the gate let an unpublishable sheet be completed (completed=%)', v_stored;
  END IF;
  SELECT count(*) INTO v_n FROM derm.stamp_sheet_status
   WHERE dump_folder = 'ticket-834742' AND completed_by IS NULL AND completed_at IS NULL;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 4: gate did not clear completed_at/by'; END IF;

  -- 5. And it did not leak into anything else: every other folder is still complete.
  SELECT count(*) INTO v_n FROM derm.stamp_sheet_status
   WHERE NOT completed AND dump_folder <> 'ticket-834742';
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5: % other folder(s) went incomplete', v_n; END IF;

  RAISE NOTICE 'VERIFY ok: 834742 is honestly incomplete with the pin set, 0 documents withdrawn, and the gate provably refuses to re-complete it on real data.';
END $do$;

COMMIT;
