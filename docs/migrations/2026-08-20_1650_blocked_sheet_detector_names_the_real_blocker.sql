-- ============================================================================
-- 2026-08-20_1650  derm.v_blackout_blocked_sheets: name the REAL blocker, and
--                  stop advising the act that caused the 2026-08-19 leak
-- ============================================================================
--
-- 🛑 THE DETECTOR I SHIPPED YESTERDAY ADVISES AN UNSAFE ACT. Its `what_to_do` is a
-- constant string ending "Run a measurement pass for this folder." A measurement pass
-- means adding a derm.page_block_extents row. 2026-08-19_2355 PART 0 is explicit that
--
--     an extent does not redact anything, it OPENS THE GATE onto whatever bands
--     already exist, and adding one to a sheet whose bands are still DERIVED is
--     the unsafe act
--
-- which is how 30 documents were published in 90 seconds and three clients had a
-- neighbour's data served to them. So the detector names a real problem and then
-- recommends the exact move that turns it into an incident. Fixed here.
--
-- 🛑 IT ALSO SENDS PEOPLE TO WORK THAT CANNOT HELP. The view keys on
-- `stamp_y_pct IS NOT NULL`, but derm.fn_blackout_targets requires
-- `stamp_placed_at IS NOT NULL`. A row with a stamp POSITION but no stamp TIMESTAMP is
-- reported as blocked-for-want-of-measurement and will not generate however carefully
-- it is measured. Measured today: `window5-sheet3` is exactly that, one row, one client.
-- I followed the advice before noticing.
--
-- WHAT CHANGES: same rows, same grain, four new columns and advice derived from the
-- data rather than hard-coded. No column is removed, so existing readers keep working.
--
--   rows_ready         rows that WOULD generate once an extent exists
--   rows_no_stamp_ts   rows that will not, whatever you measure
--   bands_derived      rows with no band override; if > 0, snapping is a PREREQUISITE
--   blocker            one of: needs_snap_then_extent / needs_extent /
--                      no_stamp_timestamp / held_by_constraint
--
-- ⚠ `held_by_constraint` is detected by looking for a CHECK on page_block_extents that
--   names the folder. That is how ticket-833049 is deliberately frozen
--   (page_block_extents_no_ticket_833049): its rows disagree about `page`, so
--   ticket_page_images emits [address_1, address_1, address_2] and effective_page 1
--   resolves to the wrong physical page. Telling someone to "measure" it would invite
--   them to drop the constraint, which DOUBLES the exposure from 5 clients to 10.
--   See 2026-08-19_2355 PART 5 before touching it.
--
-- ⚠ The new columns are APPENDED after what_to_do, not grouped with the counts they
--   belong with. CREATE OR REPLACE VIEW can only add columns at the END: inserting them
--   mid-list raises 42P16 "cannot change name of view column". Dropping and recreating
--   would reorder them nicely and would also drop any dependent object without warning,
--   which is not worth a tidier column order on a detector view.
--
-- Audit opt-out: this is a view. Rule 8 does not apply.

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
      WHEN EXISTS (SELECT 1 FROM pg_constraint con
                    JOIN pg_class c ON c.oid = con.conrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname = 'derm' AND c.relname = 'page_block_extents'
                     AND con.contype = 'c'
                     AND pg_get_constraintdef(con.oid) LIKE '%' || arm.dump_folder || '%')
        THEN 'DELIBERATELY FROZEN by a CHECK constraint on derm.page_block_extents. Do NOT drop it to "unblock" this folder. Read 2026-08-19_2355 PART 5 first: the page grouping is wrong, and opening the gate widens the exposure instead of fixing it.'
      WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) = 0
        THEN 'NOT a measurement problem. Every stamped row here has a stamp POSITION but no stamp_placed_at, and derm.fn_blackout_targets requires stamp_placed_at. Measuring this folder will not produce a document. The stamp needs to be re-placed through the Studio.'
      WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL
                              AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) > 0
        THEN 'SNAP THE BANDS FIRST, THEN add the extent, in ONE migration. Some rows here still have DERIVED bands (no band_y0_pct/band_y1_pct override). An extent does not redact anything: it opens the gate onto whatever bands exist, and a derived band is a stamp-midpoint heuristic that is not on the printed rules. Adding the extent alone is what leaked client data on 2026-08-19.'
      ELSE 'Bands are already snapped. Add the derm.page_block_extents row for this folder, bounded by the printed roster (first to last form rule, covering empty slots), and verify every band still falls inside it.'
    END AS what_to_do,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) AS rows_ready,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NULL)     AS rows_no_stamp_ts,
    count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL
                       AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL))            AS bands_derived,
    CASE
      WHEN EXISTS (SELECT 1 FROM pg_constraint con
                    JOIN pg_class c ON c.oid = con.conrelid
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname = 'derm' AND c.relname = 'page_block_extents'
                     AND con.contype = 'c'
                     AND pg_get_constraintdef(con.oid) LIKE '%' || arm.dump_folder || '%')
        THEN 'held_by_constraint'
      WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL AND arm.stamp_placed_at IS NOT NULL) = 0
        THEN 'no_stamp_timestamp'
      WHEN count(*) FILTER (WHERE arm.stamp_y_pct IS NOT NULL
                              AND (arm.band_y0_pct IS NULL OR arm.band_y1_pct IS NULL)) > 0
        THEN 'needs_snap_then_extent'
      ELSE 'needs_extent'
    END AS blocker
   FROM derm.address_row_map arm
  WHERE arm.stamp_y_pct IS NOT NULL
    AND NOT (EXISTS ( SELECT 1
           FROM derm.page_block_extents e
          WHERE e.dump_folder = arm.dump_folder
            AND e.effective_page = COALESCE(arm.stamp_page, arm.page)))
  GROUP BY arm.dump_folder;

DO $$
DECLARE r record; v_seen int := 0;
BEGIN
  FOR r IN SELECT dump_folder, blocker, rows_ready, rows_no_stamp_ts, bands_derived
             FROM derm.v_blackout_blocked_sheets ORDER BY dump_folder LOOP
    v_seen := v_seen + 1;
    RAISE NOTICE 'blocked: % -> % (ready=%, no_stamp_ts=%, derived=%)',
      r.dump_folder, r.blocker, r.rows_ready, r.rows_no_stamp_ts, r.bands_derived;
  END LOOP;

  -- the two known cases must classify correctly, or the new advice is not trustworthy
  IF NOT EXISTS (SELECT 1 FROM derm.v_blackout_blocked_sheets
                  WHERE dump_folder='ticket-833049' AND blocker='held_by_constraint') THEN
    RAISE EXCEPTION 'ticket-833049 should classify as held_by_constraint';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.v_blackout_blocked_sheets
                  WHERE dump_folder='window5-sheet3' AND blocker='no_stamp_timestamp') THEN
    RAISE EXCEPTION 'window5-sheet3 should classify as no_stamp_timestamp';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.v_blackout_blocked_sheets WHERE dump_folder='ticket-832996') THEN
    RAISE EXCEPTION 'ticket-832996 was unblocked by 2026-08-20_1635 and must not reappear';
  END IF;

  RAISE NOTICE 'OK: % blocked folders, all classified', v_seen;
END $$;

COMMIT;
