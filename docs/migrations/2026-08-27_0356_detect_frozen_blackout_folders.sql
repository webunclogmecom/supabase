-- 2026-08-27_0356_detect_frozen_blackout_folders.sql
--
-- WHY
-- ---
-- Found by the adversarial review of the rectangle change (2026-08-26), and it is the blocker that
-- review turned up: A FOLDER CAN BE COMPLETELY FROZEN AND NOTHING IN THIS ESTATE CAN SEE IT.
--
-- derm.fn_blackout_targets carries a WHOLE-FOLDER closed-world gate:
--     AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r2
--                     LEFT JOIN derm.v_stamp_row_bands b2 ON b2.id = r2.id
--                     WHERE r2.dump_folder = r.dump_folder AND b2.id IS NULL)
-- and derm.v_stamp_row_bands is `... WHERE stamp_y_pct IS NOT NULL`. So ONE card anywhere in a
-- folder with no stamp POINT excludes EVERY card in that folder from regenerating, for ever.
--
-- 🛑 AND derm.v_blackout_blocked_sheets, the view CLAUDE.md tells you to watch, CANNOT REPORT IT.
-- Its own WHERE is `stamp_y_pct IS NOT NULL`, so a folder whose cards are all unstamped produces
-- no GROUP at all and simply vanishes. That is not a bug in the view -- it was built to answer
-- "which stamped folders still need an extent" -- but it means "the worklist is empty" has never
-- been the all-clear it reads as.
--
-- MEASURED 2026-08-26: six folders fail the gate and ALL SIX are invisible to the view.
--
--   folder             rows  noStamp  bandWithoutStamp  publishedDocs
--   ticket-828604         4        4                 4              4   <- FROZEN AND SERVING
--   ticket-830714         3        3                 3              3   <- FROZEN AND SERVING
--   ticket-312024         9        9                 0              0      un-worked
--   window10-sheet6       6        6                 0              0      un-worked
--   window12-sheet1       1        1                 0              0      un-worked
--   window13-sheet8       6        6                 0              0      un-worked
--
-- The first two are the finding: 7 customer documents are being served RIGHT NOW that can never
-- regenerate. Improving their bands, their extent, or the redactor changes nothing about what
-- those clients see. That is the silent-failure shape this estate keeps paying for, and it had no
-- detector.
--
-- WHAT THIS DOES
-- --------------
-- Adds ONE ARM to derm.v_blackout_blocked_sheets reporting `blocker = 'frozen_closed_world'`, so
-- the existing blackout-health check and the daily escalation mail pick it up with no new wiring.
-- Arm A is SPLICED IN VERBATIM from the live pg_get_viewdef output, never retyped: CREATE OR
-- REPLACE takes the WHOLE body, so anything not reproduced is silently deleted (CLAUDE.md,
-- 2026-08-06). VERIFY 1 is the control for that splice.
--
-- 🛑 ONLY FOLDERS THAT ALREADY SERVE DOCUMENTS ARE REPORTED. The other four have nothing published
-- and are simply not stamped yet. Reporting them would put four permanent rows on a worklist whose
-- entire value is that "empty is healthy", and the real two would be buried inside a week. If a
-- detector for "un-worked folder" is ever wanted, that is a different question with a different
-- urgency and belongs in its own check.
--
-- 🛑 THIS REPORTS. IT DOES NOT REPAIR. The two frozen folders need a person to place the missing
-- stamps in the Stamp Studio. Clearing their bands does NOT unfreeze them -- the gate is on the
-- stamp POINT, not the band -- and deleting the cards would decide, silently, that those clients
-- were not on that sheet. Both are decisions for Fred and Diego, not for a migration.
--
-- ⚠ THE NEW ARM'S OWN BLIND SPOT, stated so a clean worklist is not over-read: it keys on a folder
-- ALREADY having a published document. A folder that freezes BEFORE it ever publishes is correctly
-- not reported here (nothing is being served wrongly), but it is not reported anywhere else
-- either, and it looks identical to "not started".
--
-- RULE 8 (audit trail): N/A. This creates no table and changes no data; it replaces one view.
-- derm.address_row_map, its only source, is already audited by audit_address_row_map.

BEGIN;

CREATE OR REPLACE VIEW derm.v_blackout_blocked_sheets AS
SELECT dump_folder,
    count(*) FILTER (WHERE stamp_y_pct IS NOT NULL) AS stamped_rows,
    count(DISTINCT COALESCE(stamp_page, page)) FILTER (WHERE stamp_y_pct IS NOT NULL) AS stamped_pages,
    count(DISTINCT matched_manifest_id) FILTER (WHERE matched_manifest_id IS NOT NULL) AS manifests_blocked,
    count(DISTINCT matched_client_id) FILTER (WHERE matched_client_id IS NOT NULL) AS clients_blocked,
    max(stamp_placed_at) AS last_stamp_at,
    now() - max(stamp_placed_at) AS blocked_for,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM pg_constraint con
                 JOIN pg_class c ON c.oid = con.conrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'derm'::name AND c.relname = 'page_block_extents'::name AND con.contype = 'c'::"char" AND pg_get_constraintdef(con.oid) ~~ (('%'::text || arm.dump_folder) || '%'::text))) THEN 'DELIBERATELY FROZEN by a CHECK constraint on derm.page_block_extents. Do NOT drop it to "unblock" this folder. Read 2026-08-19_2355 PART 5 first: the page grouping is wrong, and opening the gate widens the exposure instead of fixing it.'::text
            WHEN count(*) FILTER (WHERE stamp_y_pct IS NOT NULL AND stamp_placed_at IS NOT NULL) = 0 THEN 'NOT a measurement problem. Every stamped row here has a stamp POSITION but no stamp_placed_at, and derm.fn_blackout_targets requires stamp_placed_at. Measuring this folder will not produce a document. The stamp needs to be re-placed through the Studio.'::text
            WHEN count(*) FILTER (WHERE stamp_y_pct IS NOT NULL AND (band_y0_pct IS NULL OR band_y1_pct IS NULL)) > 0 THEN 'SNAP THE BANDS FIRST, THEN add the extent, in ONE migration. Some rows here still have DERIVED bands (no band_y0_pct/band_y1_pct override). An extent does not redact anything: it opens the gate onto whatever bands exist, and a derived band is a stamp-midpoint heuristic that is not on the printed rules. Adding the extent alone is what leaked client data on 2026-08-19.'::text
            ELSE 'Bands are already snapped. Add the derm.page_block_extents row for this folder, bounded by the printed roster (first to last form rule, covering empty slots), and verify every band still falls inside it.'::text
        END AS what_to_do,
    count(*) FILTER (WHERE stamp_y_pct IS NOT NULL AND stamp_placed_at IS NOT NULL) AS rows_ready,
    count(*) FILTER (WHERE stamp_y_pct IS NOT NULL AND stamp_placed_at IS NULL) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE stamp_y_pct IS NOT NULL AND (band_y0_pct IS NULL OR band_y1_pct IS NULL)) AS bands_derived,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM pg_constraint con
                 JOIN pg_class c ON c.oid = con.conrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'derm'::name AND c.relname = 'page_block_extents'::name AND con.contype = 'c'::"char" AND pg_get_constraintdef(con.oid) ~~ (('%'::text || arm.dump_folder) || '%'::text))) THEN 'held_by_constraint'::text
            WHEN count(*) FILTER (WHERE stamp_y_pct IS NOT NULL AND stamp_placed_at IS NOT NULL) = 0 THEN 'no_stamp_timestamp'::text
            WHEN count(*) FILTER (WHERE stamp_y_pct IS NOT NULL AND (band_y0_pct IS NULL OR band_y1_pct IS NULL)) > 0 THEN 'needs_snap_then_extent'::text
            ELSE 'needs_extent'::text
        END AS blocker
   FROM derm.address_row_map arm
  WHERE stamp_y_pct IS NOT NULL AND NOT (EXISTS ( SELECT 1
           FROM derm.page_block_extents e
          WHERE e.dump_folder = arm.dump_folder AND e.effective_page = COALESCE(arm.stamp_page, arm.page)))
  GROUP BY dump_folder
UNION ALL
-- ARM B (NEW). Folders that fail derm.fn_blackout_targets' WHOLE-FOLDER closed-world gate.
--
-- The gate, verbatim from the live function:
--     AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r2
--                     LEFT JOIN derm.v_stamp_row_bands b2 ON b2.id = r2.id
--                     WHERE r2.dump_folder = r.dump_folder AND b2.id IS NULL)
-- and derm.v_stamp_row_bands is `... WHERE stamp_y_pct IS NOT NULL`. So ONE card anywhere in the
-- folder with no stamp POINT excludes every card in that folder from ever regenerating.
--
-- Arm A cannot see this, and that is not an oversight in arm A: its own WHERE is
-- `stamp_y_pct IS NOT NULL`, so a folder whose cards are ALL unstamped produces no group at all.
-- Measured 2026-08-26: 6 folders fail the gate and all 6 are invisible to arm A.
--
-- Only the folders that already SERVE documents are reported. The other four (ticket-312024,
-- window10-sheet6, window12-sheet1, window13-sheet8) have no stamps, no bands and no documents:
-- that is simply un-worked, and reporting it would be noise that buries the real thing.
 SELECT arm.dump_folder,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE arm.matched_manifest_id IS NOT NULL) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE arm.matched_client_id IS NOT NULL) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    now() - max(arm.stamp_placed_at) AS blocked_for,
    'FROZEN, AND ALREADY SERVING. At least one card in this folder has no stamp POINT, which fails derm.fn_blackout_targets whole-folder closed-world gate, so NOTHING in this folder can regenerate - including the documents it is serving right now, which are frozen snapshots. Fix: place the missing stamp(s) in the Stamp Studio. Do NOT just clear the bands - that does not add a stamp and the folder stays frozen. Do NOT delete the cards without checking what the paper says.'::text AS what_to_do,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) AS rows_ready,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NULL) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) AS bands_derived,
    'frozen_closed_world'::text AS blocker
   FROM derm.address_row_map arm
  WHERE
    -- (a) the folder fails the gate: at least one card has no stamp point
    EXISTS (SELECT 1 FROM derm.address_row_map g
             WHERE g.dump_folder = arm.dump_folder AND g.stamp_y_pct IS NULL)
    -- (b) and it is ALREADY SERVING documents, which is what makes it urgent rather than un-worked
    AND EXISTS (SELECT 1 FROM derm.address_row_map s
                  JOIN derm.redacted_manifest_docs d
                    ON d.manifest_id = s.matched_manifest_id AND d.client_id = s.matched_client_id
                 WHERE s.dump_folder = arm.dump_folder)
    -- (c) and arm A has not already reported it, so the view keeps ONE row per dump_folder.
    --     This is arm A's own membership predicate, negated.
    AND NOT EXISTS (SELECT 1 FROM derm.address_row_map a
                     WHERE a.dump_folder = arm.dump_folder
                       AND a.stamp_y_pct IS NOT NULL
                       AND NOT EXISTS (SELECT 1 FROM derm.page_block_extents e
                                        WHERE e.dump_folder = a.dump_folder
                                          AND e.effective_page = COALESCE(a.stamp_page, a.page)))
  GROUP BY arm.dump_folder
;

COMMENT ON VIEW derm.v_blackout_blocked_sheets IS
  'Blackout worklist. Empty is healthy. Arm A: stamped folders still missing a page_block_extents '
  'row. Arm B (2026-08-27): folders that fail fn_blackout_targets whole-folder closed-world gate '
  'while already serving documents, i.e. every document in them is a frozen snapshot. Arm A cannot '
  'see arm B cases because its WHERE is stamp_y_pct IS NOT NULL. See 2026-08-27_0356.';

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_n integer; v_txt text;
BEGIN
  -- 1. ARM A IS UNCHANGED. This is the control for the splice: if the copy lost anything, the
  --    folders arm A reported before this migration stop matching their exact blocker values.
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets
   WHERE blocker <> 'frozen_closed_world';
  IF v_n <> 4 THEN
    RAISE EXCEPTION 'VERIFY 1 failed: arm A now reports % folders, expected 4', v_n;
  END IF;

  SELECT blocker INTO v_txt FROM derm.v_blackout_blocked_sheets WHERE dump_folder='ticket-833049';
  IF v_txt IS DISTINCT FROM 'held_by_constraint' THEN
    RAISE EXCEPTION 'VERIFY 1 failed: ticket-833049 blocker is % not held_by_constraint', v_txt;
  END IF;
  SELECT blocker INTO v_txt FROM derm.v_blackout_blocked_sheets WHERE dump_folder='window5-sheet3';
  IF v_txt IS DISTINCT FROM 'no_stamp_timestamp' THEN
    RAISE EXCEPTION 'VERIFY 1 failed: window5-sheet3 blocker is % not no_stamp_timestamp', v_txt;
  END IF;
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets
   WHERE dump_folder IN ('ticket-833530','ticket-833813') AND blocker='needs_snap_then_extent';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'VERIFY 1 failed: the two target folders no longer read needs_snap_then_extent';
  END IF;

  -- 2. THE NEW ARM FIRES on exactly the two frozen-and-serving folders.
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets
   WHERE blocker = 'frozen_closed_world';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'VERIFY 2 failed: frozen_closed_world reports % folders, expected 2', v_n;
  END IF;
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets
   WHERE blocker = 'frozen_closed_world'
     AND dump_folder IN ('ticket-828604','ticket-830714');
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'VERIFY 2 failed: the frozen folders are not the two expected ones';
  END IF;

  -- 3. THE UN-WORKED FOLDERS ARE NOT REPORTED. Without this the arm would be noise.
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets
   WHERE dump_folder IN ('ticket-312024','window10-sheet6','window12-sheet1','window13-sheet8');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 failed: % un-worked folder(s) leaked onto the worklist', v_n;
  END IF;

  -- 4. ONE ROW PER FOLDER. The two arms must not double-report.
  SELECT count(*) INTO v_n FROM (
    SELECT dump_folder FROM derm.v_blackout_blocked_sheets
     GROUP BY dump_folder HAVING count(*) > 1) d;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 failed: % folder(s) reported by both arms', v_n;
  END IF;

  -- 5. POSITIVE CONTROL FOR THE GATE ITSELF. The two frozen folders must genuinely be excluded by
  --    fn_blackout_targets, or this arm is describing a problem that does not exist.
  --    A generous limit is passed because the argument DEFAULTS TO 3, and a bare call returns
  --    three rows and reads like an empty backlog (CLAUDE.md).
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(500) t
    JOIN derm.address_row_map r
      ON r.matched_manifest_id = t.manifest_id AND r.matched_client_id = t.client_id
   WHERE r.dump_folder IN ('ticket-828604','ticket-830714');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 5 failed: fn_blackout_targets returns % row(s) for folders this arm calls frozen', v_n;
  END IF;

  -- 6. And the only consumer still runs.
  PERFORM public.log_blackout_health();

  RAISE NOTICE 'VERIFY ok: arm A unchanged (4 folders, blockers intact), new arm reports 2 frozen-and-serving folders, 4 un-worked folders correctly silent, no double-reporting, fn_blackout_targets confirms the freeze.';
END $do$;

COMMIT;
