-- 2026-08-27_1040_detect_withheld_stamp_cards.sql
--
-- WHY
-- ---
-- Closing a gap that `2026-08-27_1015` walked straight into, and that turned out to be older and
-- wider than that migration.
--
-- `derm.fn_blackout_targets` requires `r.stamp_placed_at IS NOT NULL` per card. So a card with a
-- stamp POINT but no timestamp publishes NOTHING: that client's FOG card is a permanent
-- placeholder. `2026-08-27_1015` deliberately put two cards into exactly that state to stop a live
-- cross-client leak republishing.
--
-- 🛑 AND THEN NOTHING REPORTED THEM. Arm A of derm.v_blackout_blocked_sheets only fires when the
-- folder is MISSING a page_block_extents row. `window4-sheet1` HAS one, so the two withheld cards
-- landed on no worklist anywhere. A deliberate, invisible withhold is precisely the silent state
-- this estate keeps paying for, and the containment created one.
--
-- ⚠ SIX folders hold a card with a stamp point and no timestamp, but only TWO of them actually
-- deny a client anything. The discriminator is `matched_manifest_id`: fn_blackout_targets also
-- requires it, so a withheld card with no manifest was never going to publish and is not a
-- withhold at all. Measured 2026-08-27:
--
--   folder            withheld cards  REAL withholds  clients denied  on worklist
--   window4-sheet1          2               2               2             NO    <- by 2026-08-27_1015
--   window5-sheet3          1               1               1             yes   <- by luck, see below
--   window12-sheet9         1               0               0             NO
--   window3-sheet3          1               0               0             NO
--   window3-sheet5          2               0               0             NO
--   window4-sheet4          3               0               0             NO
--
-- 🛑 I GOT THIS WRONG FIRST TIME AND THE VERIFY CAUGHT IT. An earlier draft counted
-- `count(DISTINCT matched_client_id)` without requiring a manifest, concluded window3-sheet5 was
-- denying a real client, and asserted arm C would report 2 folders. It reports 1. window3-sheet5's
-- withheld cards (160, 167) have `matched_manifest_id IS NULL`, so there is nothing to serve for
-- them and nothing is being denied. A card counts as withheld only when it has BOTH a client and
-- a manifest.
--
-- window5-sheet3 is reported only because it ALSO lacks an extent, i.e. arm A catches it for an
-- unrelated reason. That is luck, not a detector, which is why arm C exists.
--
-- WHAT THIS DOES
-- --------------
-- Adds ARM C, `blocker = 'cards_withheld'`. Arms A and B are spliced in VERBATIM from the live
-- pg_get_viewdef output, never retyped, and VERIFY 1 is the control for that splice.
--
-- 🛑 CARDS WITH NO MATCHED CLIENT ARE EXCLUDED ON PURPOSE. Four of the six folders above hold only
-- unmatched cards (`clients = 0`); those can never publish to anyone, so reporting them would put
-- four permanent rows on a worklist whose entire value is that empty means healthy. That is the
-- same reasoning arm B used to exclude un-worked folders. Expected result: 1 folder, not 6.
--
-- ⚠ ARM C'S BLIND SPOT: it says a client is being served nothing. It does NOT say whether that is
-- correct. For window4-sheet1 it is deliberate and documented; for window3-sheet5 nobody has
-- looked. The worklist is the prompt to look, never the verdict.
--
-- RULE 8 (audit trail): N/A. Replaces one view; creates no table and changes no data.

BEGIN;

CREATE OR REPLACE VIEW derm.v_blackout_blocked_sheets AS
SELECT arm.dump_folder,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE arm.matched_manifest_id IS NOT NULL) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE arm.matched_client_id IS NOT NULL) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    now() - max(arm.stamp_placed_at) AS blocked_for,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM pg_constraint con
                 JOIN pg_class c ON c.oid = con.conrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'derm'::name AND c.relname = 'page_block_extents'::name AND con.contype = 'c'::"char" AND pg_get_constraintdef(con.oid) ~~ (('%'::text || arm.dump_folder) || '%'::text))) THEN 'DELIBERATELY FROZEN by a CHECK constraint on derm.page_block_extents. Do NOT drop it to "unblock" this folder. Read 2026-08-19_2355 PART 5 first: the page grouping is wrong, and opening the gate widens the exposure instead of fixing it.'::text
            WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) = 0 THEN 'NOT a measurement problem. Every stamped row here has a stamp POSITION but no stamp_placed_at, and derm.fn_blackout_targets requires stamp_placed_at. Measuring this folder will not produce a document. The stamp needs to be re-placed through the Studio.'::text
            WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) > 0 THEN 'SNAP THE BANDS FIRST, THEN add the extent, in ONE migration. Some rows here still have DERIVED bands (no band_y0_pct/band_y1_pct override). An extent does not redact anything: it opens the gate onto whatever bands exist, and a derived band is a stamp-midpoint heuristic that is not on the printed rules. Adding the extent alone is what leaked client data on 2026-08-19.'::text
            ELSE 'Bands are already snapped. Add the derm.page_block_extents row for this folder, bounded by the printed roster (first to last form rule, covering empty slots), and verify every band still falls inside it.'::text
        END AS what_to_do,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) AS rows_ready,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NULL) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) AS bands_derived,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM pg_constraint con
                 JOIN pg_class c ON c.oid = con.conrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'derm'::name AND c.relname = 'page_block_extents'::name AND con.contype = 'c'::"char" AND pg_get_constraintdef(con.oid) ~~ (('%'::text || arm.dump_folder) || '%'::text))) THEN 'held_by_constraint'::text
            WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) = 0 THEN 'no_stamp_timestamp'::text
            WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) > 0 THEN 'needs_snap_then_extent'::text
            ELSE 'needs_extent'::text
        END AS blocker
   FROM derm.address_row_map arm
  WHERE arm.stamp_y_pct IS NOT NULL AND NOT (EXISTS ( SELECT 1
           FROM derm.page_block_extents e
          WHERE e.dump_folder = arm.dump_folder AND e.effective_page = COALESCE(arm.stamp_page, arm.page)))
  GROUP BY arm.dump_folder
UNION ALL
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
  WHERE (EXISTS ( SELECT 1
           FROM derm.address_row_map g
          WHERE g.dump_folder = arm.dump_folder AND g.stamp_y_pct IS NULL)) AND (EXISTS ( SELECT 1
           FROM derm.address_row_map s
             JOIN derm.redacted_manifest_docs d ON d.manifest_id = s.matched_manifest_id AND d.client_id = s.matched_client_id
          WHERE s.dump_folder = arm.dump_folder)) AND NOT (EXISTS ( SELECT 1
           FROM derm.address_row_map a
          WHERE a.dump_folder = arm.dump_folder AND a.stamp_y_pct IS NOT NULL AND NOT (EXISTS ( SELECT 1
                   FROM derm.page_block_extents e
                  WHERE e.dump_folder = a.dump_folder AND e.effective_page = COALESCE(a.stamp_page, a.page)))))
  GROUP BY arm.dump_folder
UNION ALL
-- ARM C (NEW 2026-08-27_1040). Cards deliberately WITHHELD: they carry a stamp POINT but no
-- stamp_placed_at, so derm.fn_blackout_targets skips them (it requires stamp_placed_at IS NOT
-- NULL) and the client is served nothing.
--
-- Arm A only fires when the folder is MISSING an extent, so a withheld card on a folder that HAS
-- an extent was reported by nothing at all. Measured 2026-08-27: 6 folders hold such a card and
-- FIVE of them were on no worklist. window5-sheet3 was visible only by the accident of also
-- lacking an extent.
--
-- Cards with no matched client are excluded: they cannot publish to anyone, so reporting them
-- would be noise on a worklist whose whole value is that empty means healthy.
 SELECT arm.dump_folder,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE arm.stamp_y_pct IS NOT NULL) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE arm.matched_manifest_id IS NOT NULL AND arm.stamp_placed_at IS NULL) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE arm.matched_client_id IS NOT NULL AND arm.stamp_placed_at IS NULL) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    now() - max(arm.stamp_placed_at) AS blocked_for,
    'WITHHELD. One or more cards here have a stamp POSITION but no stamp_placed_at, so derm.fn_blackout_targets skips them and those clients are served NO FOG sheet. This is the state a card is left in when it is deliberately pulled from publication (see 2026-08-27_1015) and also what a half-finished placement looks like. Fix: re-place the stamp through the Studio once the underlying question is settled. Measuring or re-banding this folder will not publish these cards.'::text AS what_to_do,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) AS rows_ready,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NULL) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) AS bands_derived,
    'cards_withheld'::text AS blocker
   FROM derm.address_row_map arm
  WHERE
    -- (a) the folder holds a withheld card that WOULD have served a real client
    EXISTS (SELECT 1 FROM derm.address_row_map w
             WHERE w.dump_folder = arm.dump_folder
               AND w.stamp_y_pct IS NOT NULL
               AND w.stamp_placed_at IS NULL
               AND w.matched_client_id IS NOT NULL
               AND w.matched_manifest_id IS NOT NULL)
    -- (b) not already reported by ARM A (a stamped row whose page has no extent)
    AND NOT EXISTS (SELECT 1 FROM derm.address_row_map a
                     WHERE a.dump_folder = arm.dump_folder
                       AND a.stamp_y_pct IS NOT NULL
                       AND NOT EXISTS (SELECT 1 FROM derm.page_block_extents e
                                        WHERE e.dump_folder = a.dump_folder
                                          AND e.effective_page = COALESCE(a.stamp_page, a.page)))
    -- (c) not already reported by ARM B (fails the closed-world gate AND already serving)
    AND NOT (
      EXISTS (SELECT 1 FROM derm.address_row_map g
               WHERE g.dump_folder = arm.dump_folder AND g.stamp_y_pct IS NULL)
      AND EXISTS (SELECT 1 FROM derm.address_row_map s
                    JOIN derm.redacted_manifest_docs d
                      ON d.manifest_id = s.matched_manifest_id AND d.client_id = s.matched_client_id
                   WHERE s.dump_folder = arm.dump_folder)
    )
  GROUP BY arm.dump_folder
;

COMMENT ON VIEW derm.v_blackout_blocked_sheets IS
  'Blackout worklist. Empty is healthy. Arm A: stamped folders missing a page_block_extents row. '
  'Arm B (2026-08-27_0356): folders failing fn_blackout_targets whole-folder closed-world gate '
  'while already serving, i.e. serving frozen snapshots. Arm C (2026-08-27_1040): folders holding '
  'a card with a stamp point but no stamp_placed_at, so that client is served nothing. Arms B and '
  'C exist because arm A only fires on a MISSING extent and is blind to both states.';

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_n integer; v_txt text;
BEGIN
  -- 1. ARMS A AND B SURVIVED THE SPLICE, with their exact blocker values.
  SELECT blocker INTO v_txt FROM derm.v_blackout_blocked_sheets WHERE dump_folder='ticket-833049';
  IF v_txt IS DISTINCT FROM 'held_by_constraint' THEN
    RAISE EXCEPTION 'VERIFY 1 failed: ticket-833049 reads % not held_by_constraint', v_txt;
  END IF;
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets WHERE blocker='frozen_closed_world';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'VERIFY 1 failed: arm B reports % folders, expected 2', v_n;
  END IF;
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets WHERE blocker='needs_snap_then_extent';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'VERIFY 1 failed: arm A no longer reports the 2 needs_snap_then_extent folders';
  END IF;

  -- 2. ARM C FIRES on exactly the two folders that withhold a REAL client.
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets WHERE blocker='cards_withheld';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 2 failed: cards_withheld reports % folders, expected 1', v_n;
  END IF;
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets
   WHERE blocker='cards_withheld' AND dump_folder = 'window4-sheet1';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 2 failed: the withheld folder is not window4-sheet1';
  END IF;
  -- CONTROL: window3-sheet5 must NOT be here. Its withheld cards have no manifest, so nothing is
  -- denied. This is the assertion an earlier draft got backwards.
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets
   WHERE blocker='cards_withheld' AND dump_folder = 'window3-sheet5';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 failed: window3-sheet5 reported as withheld, but it has no manifest to serve';
  END IF;

  -- 3. THE UNMATCHED-CARD FOLDERS STAY SILENT. Without this arm C is noise.
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets
   WHERE dump_folder IN ('window12-sheet9','window3-sheet3','window3-sheet5','window4-sheet4');
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 failed: % no-manifest folder(s) leaked onto the worklist', v_n;
  END IF;

  -- 4. window5-sheet3 is still reported ONCE, by arm A, not twice. It qualifies for arm C's
  --    symptom too, so this is the real test of arm C's exclusion clauses.
  SELECT count(*) INTO v_n FROM derm.v_blackout_blocked_sheets WHERE dump_folder='window5-sheet3';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'VERIFY 4 failed: window5-sheet3 reported % times, expected exactly 1', v_n;
  END IF;
  SELECT blocker INTO v_txt FROM derm.v_blackout_blocked_sheets WHERE dump_folder='window5-sheet3';
  IF v_txt IS DISTINCT FROM 'no_stamp_timestamp' THEN
    RAISE EXCEPTION 'VERIFY 4 failed: window5-sheet3 now reads % (arm C stole it from arm A)', v_txt;
  END IF;

  -- 5. ONE ROW PER FOLDER across all three arms.
  SELECT count(*) INTO v_n FROM (
    SELECT dump_folder FROM derm.v_blackout_blocked_sheets
     GROUP BY dump_folder HAVING count(*) > 1) d;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 5 failed: % folder(s) reported by more than one arm', v_n;
  END IF;

  -- 6. The withheld cards really do publish nothing, which is what arm C claims.
  SELECT count(*) INTO v_n FROM derm.fn_blackout_targets(500) t
    JOIN derm.address_row_map r
      ON r.matched_manifest_id = t.manifest_id AND r.matched_client_id = t.client_id
   WHERE r.stamp_placed_at IS NULL;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'VERIFY 6 failed: % withheld card(s) are still blackout targets', v_n;
  END IF;

  -- 7. The only consumer still runs.
  PERFORM public.log_blackout_health();

  RAISE NOTICE 'VERIFY ok: arms A and B intact, arm C reports 1 folder (window4-sheet1) withholding a real client, the four no-manifest folders silent, window5-sheet3 still reported once by arm A, no folder double-reported.';
END $do$;

COMMIT;
