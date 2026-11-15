-- 2026-11-15_rollback_derm_blocked_list_skips_unlinked_unstamped_card.sql
--
-- Puts back derm.v_blackout_blocked_sheets and derm.fn_sheet_publishable exactly as they were before
-- 2026-11-15_1240_derm_blocked_list_skips_unlinked_unstamped_card.sql (the live bodies read 2026-11-15 12:22 ET, byte for
-- byte; md5 4bad4d024cfde5c56ba6ab7ef41197fc and a3b9424dcb06c25bb60b4cfe4b0824af). After it, window5-sheet3 is listed again as 'no_stamp_timestamp'.
-- Rehearsed in the same rolled-back run as the migration (see the migration's REHEARSED block).

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF md5(replace(pg_get_viewdef('derm.v_blackout_blocked_sheets'::regclass), chr(13), '')) <> '0abfa2a00d2743be620c795a305b9fb0'
    THEN RAISE EXCEPTION 'GUARD: derm.v_blackout_blocked_sheets changed since it was read (expected the body of 2026-11-15_1240)'; END IF;
  IF md5(replace(pg_get_functiondef('derm.fn_sheet_publishable(text)'::regprocedure), chr(13), '')) <> 'ad0a457efe70f9163cf3f20fd1325ea7'
    THEN RAISE EXCEPTION 'GUARD: derm.fn_sheet_publishable changed since it was read (expected the body of 2026-11-15_1240)'; END IF;
END $g$;

CREATE OR REPLACE VIEW derm.v_blackout_blocked_sheets AS
SELECT arm.dump_folder,
    count(*) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE (arm.matched_manifest_id IS NOT NULL)) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE (arm.matched_client_id IS NOT NULL)) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    (now() - max(arm.stamp_placed_at)) AS blocked_for,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM ((pg_constraint con
                 JOIN pg_class c ON ((c.oid = con.conrelid)))
                 JOIN pg_namespace n ON ((n.oid = c.relnamespace)))
              WHERE ((n.nspname = 'derm'::name) AND (c.relname = 'page_block_extents'::name) AND (con.contype = 'c'::"char") AND (pg_get_constraintdef(con.oid) ~~ (('%'::text || arm.dump_folder) || '%'::text))))) THEN 'DELIBERATELY FROZEN by a CHECK constraint on derm.page_block_extents. Do NOT drop it to "unblock" this folder. Read 2026-08-19_2355 PART 5 first: the page grouping is wrong, and opening the gate widens the exposure instead of fixing it.'::text
            WHEN (count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NOT NULL))) = 0) THEN 'NOT a measurement problem. Every stamped row here has a stamp POSITION but no stamp_placed_at, and derm.fn_blackout_targets requires stamp_placed_at. Measuring this folder will not produce a document. The stamp needs to be re-placed through the Studio.'::text
            WHEN (count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND ((arm.band_y0_pct IS NULL) OR (arm.band_y1_pct IS NULL)))) > 0) THEN 'SNAP THE BANDS FIRST, THEN add the extent, in ONE migration. Some rows here still have DERIVED bands (no band_y0_pct/band_y1_pct override). An extent does not redact anything: it opens the gate onto whatever bands exist, and a derived band is a stamp-midpoint heuristic that is not on the printed rules. Adding the extent alone is what leaked client data on 2026-08-19.'::text
            ELSE 'Bands are already snapped. Add the derm.page_block_extents row for this folder, bounded by the printed roster (first to last form rule, covering empty slots), and verify every band still falls inside it.'::text
        END AS what_to_do,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NOT NULL))) AS rows_ready,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NULL))) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND ((arm.band_y0_pct IS NULL) OR (arm.band_y1_pct IS NULL)))) AS bands_derived,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM ((pg_constraint con
                 JOIN pg_class c ON ((c.oid = con.conrelid)))
                 JOIN pg_namespace n ON ((n.oid = c.relnamespace)))
              WHERE ((n.nspname = 'derm'::name) AND (c.relname = 'page_block_extents'::name) AND (con.contype = 'c'::"char") AND (pg_get_constraintdef(con.oid) ~~ (('%'::text || arm.dump_folder) || '%'::text))))) THEN 'held_by_constraint'::text
            WHEN (count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NOT NULL))) = 0) THEN 'no_stamp_timestamp'::text
            WHEN (count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND ((arm.band_y0_pct IS NULL) OR (arm.band_y1_pct IS NULL)))) > 0) THEN 'needs_snap_then_extent'::text
            ELSE 'needs_extent'::text
        END AS blocker
   FROM derm.address_row_map arm
  WHERE ((arm.stamp_y_pct IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
           FROM derm.page_block_extents e
          WHERE ((e.dump_folder = arm.dump_folder) AND (e.effective_page = COALESCE(arm.stamp_page, arm.page)))))) AND (NOT derm.fn_card_page_missing(arm.white_manifest_number, COALESCE(arm.stamp_page, arm.page))))
  GROUP BY arm.dump_folder
UNION ALL
 SELECT arm.dump_folder,
    count(*) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE (arm.matched_manifest_id IS NOT NULL)) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE (arm.matched_client_id IS NOT NULL)) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    (now() - max(arm.stamp_placed_at)) AS blocked_for,
    'FROZEN, AND ALREADY SERVING. At least one card in this folder has no stamp POINT, which fails derm.fn_blackout_targets whole-folder closed-world gate, so NOTHING in this folder can regenerate - including the documents it is serving right now, which are frozen snapshots. Fix: place the missing stamp(s) in the Stamp Studio. Do NOT just clear the bands - that does not add a stamp and the folder stays frozen. Do NOT delete the cards without checking what the paper says.'::text AS what_to_do,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NOT NULL))) AS rows_ready,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NULL))) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND ((arm.band_y0_pct IS NULL) OR (arm.band_y1_pct IS NULL)))) AS bands_derived,
    'frozen_closed_world'::text AS blocker
   FROM derm.address_row_map arm
  WHERE ((EXISTS ( SELECT 1
           FROM derm.address_row_map g
          WHERE ((g.dump_folder = arm.dump_folder) AND (g.stamp_y_pct IS NULL)))) AND (EXISTS ( SELECT 1
           FROM derm.address_row_map h
          WHERE ((h.dump_folder = arm.dump_folder) AND (((h.stamp_y_pct IS NOT NULL) AND ((h.band_source IS DISTINCT FROM 'slot'::text) OR (h.band_y0_pct IS NULL) OR (h.band_y1_pct IS NULL))) OR ((h.stamp_y_pct IS NOT NULL) AND (h.matched_manifest_id IS NOT NULL) AND (EXISTS ( SELECT 1
                   FROM derm.page_slots ps
                  WHERE ((ps.dump_folder = h.dump_folder) AND (ps.effective_page = COALESCE(h.stamp_page, h.page)) AND (ps.y0_pct > (( SELECT min(o.band_y0_pct) AS min
                           FROM derm.address_row_map o
                          WHERE ((o.dump_folder = h.dump_folder) AND (COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)) AND (o.matched_manifest_id = h.matched_manifest_id) AND (o.stamp_y_pct IS NOT NULL))) - 0.001)) AND (ps.y1_pct < (( SELECT max(o.band_y1_pct) AS max
                           FROM derm.address_row_map o
                          WHERE ((o.dump_folder = h.dump_folder) AND (COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)) AND (o.matched_manifest_id = h.matched_manifest_id) AND (o.stamp_y_pct IS NOT NULL))) + 0.001)) AND (NOT (EXISTS ( SELECT 1
                           FROM derm.address_row_map o
                          WHERE ((o.dump_folder = h.dump_folder) AND (COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)) AND (o.matched_manifest_id = h.matched_manifest_id) AND (o.stamp_y_pct IS NOT NULL) AND (round(ps.y0_pct, 3) = o.band_y0_pct) AND (round(ps.y1_pct, 3) = o.band_y1_pct))))))))))))) AND (EXISTS ( SELECT 1
           FROM (derm.address_row_map s
             JOIN derm.redacted_manifest_docs d ON (((d.manifest_id = s.matched_manifest_id) AND (d.client_id = s.matched_client_id))))
          WHERE (s.dump_folder = arm.dump_folder))) AND (NOT (EXISTS ( SELECT 1
           FROM derm.address_row_map a
          WHERE ((a.dump_folder = arm.dump_folder) AND (a.stamp_y_pct IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
                   FROM derm.page_block_extents e
                  WHERE ((e.dump_folder = a.dump_folder) AND (e.effective_page = COALESCE(a.stamp_page, a.page)))))) AND (NOT derm.fn_card_page_missing(a.white_manifest_number, COALESCE(a.stamp_page, a.page))))))))
  GROUP BY arm.dump_folder
UNION ALL
 SELECT arm.dump_folder,
    count(*) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_rows,
    count(DISTINCT COALESCE(arm.stamp_page, arm.page)) FILTER (WHERE (arm.stamp_y_pct IS NOT NULL)) AS stamped_pages,
    count(DISTINCT arm.matched_manifest_id) FILTER (WHERE ((arm.matched_manifest_id IS NOT NULL) AND (arm.stamp_placed_at IS NULL))) AS manifests_blocked,
    count(DISTINCT arm.matched_client_id) FILTER (WHERE ((arm.matched_client_id IS NOT NULL) AND (arm.stamp_placed_at IS NULL))) AS clients_blocked,
    max(arm.stamp_placed_at) AS last_stamp_at,
    (now() - max(arm.stamp_placed_at)) AS blocked_for,
    'WITHHELD. One or more cards here have a stamp POSITION but no stamp_placed_at, so derm.fn_blackout_targets skips them and those clients are served NO FOG sheet. This is the state a card is left in when it is deliberately pulled from publication (see 2026-08-27_1015) and also what a half-finished placement looks like. Fix: re-place the stamp through the Studio once the underlying question is settled. Measuring or re-banding this folder will not publish these cards.'::text AS what_to_do,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NOT NULL))) AS rows_ready,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND (arm.stamp_placed_at IS NULL))) AS rows_no_stamp_ts,
    count(*) FILTER (WHERE ((arm.stamp_y_pct IS NOT NULL) AND ((arm.band_y0_pct IS NULL) OR (arm.band_y1_pct IS NULL)))) AS bands_derived,
    'cards_withheld'::text AS blocker
   FROM derm.address_row_map arm
  WHERE ((EXISTS ( SELECT 1
           FROM derm.address_row_map w
          WHERE ((w.dump_folder = arm.dump_folder) AND (w.stamp_y_pct IS NOT NULL) AND (w.stamp_placed_at IS NULL) AND (w.matched_client_id IS NOT NULL) AND (w.matched_manifest_id IS NOT NULL)))) AND (NOT (EXISTS ( SELECT 1
           FROM derm.address_row_map a
          WHERE ((a.dump_folder = arm.dump_folder) AND (a.stamp_y_pct IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
                   FROM derm.page_block_extents e
                  WHERE ((e.dump_folder = a.dump_folder) AND (e.effective_page = COALESCE(a.stamp_page, a.page)))))) AND (NOT derm.fn_card_page_missing(a.white_manifest_number, COALESCE(a.stamp_page, a.page))))))) AND (NOT ((EXISTS ( SELECT 1
           FROM derm.address_row_map g
          WHERE ((g.dump_folder = arm.dump_folder) AND (g.stamp_y_pct IS NULL)))) AND (EXISTS ( SELECT 1
           FROM derm.address_row_map h
          WHERE ((h.dump_folder = arm.dump_folder) AND (((h.stamp_y_pct IS NOT NULL) AND ((h.band_source IS DISTINCT FROM 'slot'::text) OR (h.band_y0_pct IS NULL) OR (h.band_y1_pct IS NULL))) OR ((h.stamp_y_pct IS NOT NULL) AND (h.matched_manifest_id IS NOT NULL) AND (EXISTS ( SELECT 1
                   FROM derm.page_slots ps
                  WHERE ((ps.dump_folder = h.dump_folder) AND (ps.effective_page = COALESCE(h.stamp_page, h.page)) AND (ps.y0_pct > (( SELECT min(o.band_y0_pct) AS min
                           FROM derm.address_row_map o
                          WHERE ((o.dump_folder = h.dump_folder) AND (COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)) AND (o.matched_manifest_id = h.matched_manifest_id) AND (o.stamp_y_pct IS NOT NULL))) - 0.001)) AND (ps.y1_pct < (( SELECT max(o.band_y1_pct) AS max
                           FROM derm.address_row_map o
                          WHERE ((o.dump_folder = h.dump_folder) AND (COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)) AND (o.matched_manifest_id = h.matched_manifest_id) AND (o.stamp_y_pct IS NOT NULL))) + 0.001)) AND (NOT (EXISTS ( SELECT 1
                           FROM derm.address_row_map o
                          WHERE ((o.dump_folder = h.dump_folder) AND (COALESCE(o.stamp_page, o.page) = COALESCE(h.stamp_page, h.page)) AND (o.matched_manifest_id = h.matched_manifest_id) AND (o.stamp_y_pct IS NOT NULL) AND (round(ps.y0_pct, 3) = o.band_y0_pct) AND (round(ps.y1_pct, 3) = o.band_y1_pct))))))))))))) AND (EXISTS ( SELECT 1
           FROM (derm.address_row_map s
             JOIN derm.redacted_manifest_docs d ON (((d.manifest_id = s.matched_manifest_id) AND (d.client_id = s.matched_client_id))))
          WHERE (s.dump_folder = arm.dump_folder))))))
  GROUP BY arm.dump_folder;

CREATE OR REPLACE FUNCTION derm.fn_sheet_publishable(p_dump_folder text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  -- NULL means publishable. Any other value is the REASON it is not, and is shown to the operator.
  SELECT COALESCE(
    -- 1. the estate's own detector. It already knows every way a sheet can be unpublishable
    --    (needs_extent, needs_snap_then_extent, cards_withheld, no_stamp_timestamp,
    --    held_by_constraint, frozen_closed_world) and carries the what_to_do text beside it.
    (SELECT b.blocker FROM derm.v_blackout_blocked_sheets b
      WHERE b.dump_folder = p_dump_folder LIMIT 1),
    CASE
      -- 2. nothing placed: there is no document to produce, so "complete" would be meaningless.
      WHEN NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                        WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL)
        THEN 'no_stamps'
      -- 3. a stamped page with no measured extent. This is the exact hard gate in
      --    fn_blackout_targets' geo CTE, restated so completion cannot outrun the measurement.
      WHEN EXISTS (
        SELECT 1
          FROM (SELECT DISTINCT COALESCE(r.stamp_page, r.page) AS pg
                  FROM derm.address_row_map r
                 WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL
                   -- 2026-10-01: a card on a page with no image cannot be blacked out; it does not block.
                   AND NOT derm.fn_card_page_missing(r.white_manifest_number, COALESCE(r.stamp_page, r.page))) sp
         WHERE NOT EXISTS (SELECT 1 FROM derm.page_block_extents e
                            WHERE e.dump_folder = p_dump_folder AND e.effective_page = sp.pg))
        THEN 'needs_extent'
      -- 4. (2026-09-14) a stamped card whose band is still the stamp-midpoint heuristic on a page
      --    that HAS an extent. An extent opens the gate onto whatever bands exist (2026-08-19), and
      --    a stamp cleared and placed again arrives with no band, so this is the one shape the
      --    blocked-sheets view cannot see: it reports derived bands only on pages WITHOUT an extent.
      --    Measured at install: 3 pages estate-wide (ticket-831102 p1+p2, ticket-831325 p1, the dark
      --    scans of 2026-08-20), all completed and serving; they stay completed and are refused only
      --    if re-completed unmeasured, which is the rule.
      WHEN EXISTS (SELECT 1 FROM derm.address_row_map r
                    WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL
                      AND (r.band_y0_pct IS NULL OR r.band_y1_pct IS NULL)
                      AND NOT derm.fn_card_page_missing(r.white_manifest_number, COALESCE(r.stamp_page, r.page)))
        THEN 'needs_snap_then_extent'
      ELSE NULL
    END);
$function$;

DO $v$
BEGIN
  IF md5(replace(pg_get_viewdef('derm.v_blackout_blocked_sheets'::regclass), chr(13), '')) <> '4bad4d024cfde5c56ba6ab7ef41197fc'
    THEN RAISE EXCEPTION 'VERIFY: the view is not the rehearsed one'; END IF;
  IF md5(replace(pg_get_functiondef('derm.fn_sheet_publishable(text)'::regprocedure), chr(13), '')) <> 'a3b9424dcb06c25bb60b4cfe4b0824af'
    THEN RAISE EXCEPTION 'VERIFY: derm.fn_sheet_publishable is not the rehearsed one'; END IF;
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'derm.v_blackout_blocked_sheets'::regclass) <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}'
    THEN RAISE EXCEPTION 'VERIFY: view grants moved'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'derm.fn_sheet_publishable(text)'::regprocedure) <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
    THEN RAISE EXCEPTION 'VERIFY: derm.fn_sheet_publishable grants moved'; END IF;

END $v$;

COMMIT;
