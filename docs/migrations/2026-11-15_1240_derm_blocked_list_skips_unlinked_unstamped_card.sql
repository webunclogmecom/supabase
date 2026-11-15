-- 2026-11-15_1240_derm_blocked_list_skips_unlinked_unstamped_card.sql
--
-- THE RULE NOW
-- ------------
-- A card with NO manifest link and NO stamp time, on a page with no measured extent, no longer counts as "stamped but
-- unmeasured": it has no copy to make, so it neither lists its sheet in derm.v_blackout_blocked_sheets nor makes
-- derm.fn_sheet_publishable answer 'needs_extent'. A LINKED card with no stamp time still counts (a withheld client), and
-- so does an unlinked card WITH a stamp time.
--
-- WHAT (four anchored edits, each asserted to match its count, from the LIVE bodies; nothing else moves)
-- ----
-- derm.v_blackout_blocked_sheets (body of 2026-11-14_1300, live md5 4bad4d024cfde5c56ba6ab7ef41197fc):
--   arm 1 ("stamped but unmeasured") WHERE gains  ((arm.matched_manifest_id IS NOT NULL) OR (arm.stamp_placed_at IS NOT NULL))
--   the same condition inside the two NOT EXISTS guards that keep arms 2 (frozen_closed_world) and 3 (cards_withheld) off a
--   folder arm 1 already lists (alias a), so the three arms still split the folders the same way.
-- derm.fn_sheet_publishable (live md5 a3b9424dcb06c25bb60b4cfe4b0824af): its step 3 (the 'needs_extent' restatement of
--   the extent gate) gains (r.matched_manifest_id IS NOT NULL OR r.stamp_placed_at IS NOT NULL), with a comment.
-- Grants, owner, language, volatility and SECURITY DEFINER unchanged (CREATE OR REPLACE). The view's columns are unchanged.
-- Audit (rule 8): no table changes, no column changes, no rows written: a view and a function only, nothing to opt in or out.
--
-- WHY
-- ---
-- Fred, 2026-11-15 about 11:30 AM ET, in a dialog after pick QQ (clear card 234's leftover stamp point on #822919) was held,
-- because clearing it reopened the completed sheet window5-sheet3 and blocked Mark completed. The recommended choice read:
-- "The blocked list stops counting a card that has no manifest, no stamp time, on a page never measured: it has no copy to
-- make. The sheet leaves the list by the rule, stays completed, and nothing on it changes. One database change, rehearsed with
-- a control first." He picked:
--     "Change the rule (Recommended)"
-- (Building Apps/Ops Portal/docs/00-fred-picks-2026-11-12-manifests-and-stamping.md, last section.)
-- Card 234 (ticket #822919, folder window5-sheet3) keeps a stamp point on page 1 with no stamp time and no manifest link (a
-- vision repair of 2026-07-14 placed it); page 1 has no row in derm.page_block_extents, so arm 1 listed the sheet as
-- 'no_stamp_timestamp' (1 client, 0 manifests) in the daily health email. The other unlinked cards with a point and no stamp
-- time (7 cards on 4 other sheets) sit on measured pages and were listed nowhere.
--
-- WHY THE GUARDS AND THE FUNCTION TOO (measured, not assumed)
-- --------------------------------------------------------------
--   * The guards: with the arm-1 edit alone, a folder whose only unmeasured card is such a card AND that holds a withheld
--     linked card is listed by NO arm (fixture D below: arm-1-only reads nothing; with the guards it reads 'cards_withheld').
--   * The function: with the view edits alone, fn_sheet_publishable('window5-sheet3') falls through to its step 3 and reads
--     'needs_extent' (card 234's page 1), so the sheet would reappear under another blocker.
--   * NOT changed, on purpose: arm 2's own "unsafe stamped card" condition (h) mirrors the closed-world gate in
--     derm.fn_blackout_targets, which counts every card with a point; it fires only with a card that has NO point, and
--     window5-sheet3 has none (7 of 7 pointed). derm.fn_blackout_targets (the only maker of client copies) reads neither object.
--     derm.fn_sheet_publishable_detail keeps listing page 1 in pages_needing_extent for window5-sheet3; that list is shown only
--     beside a blocker, and the blocker is now NULL.
--
-- WHAT ELSE MOVES (proved BEFORE writing, on copies, rolled back, one REPEATABLE READ snapshot each; 2026-11-15 ~12:25 ET)
-- ---------------
--   view rows, old (live) vs new (temp copy): 3 -> 2; only window5-sheet3 leaves (no_stamp_timestamp, 1 client, 0
--     manifests); ticket-315808 and window4-sheet1 identical, column for column. Nothing new appears.
--   fn_sheet_publishable for all 189 sheets, old vs new copy: ONE differs, window5-sheet3 'no_stamp_timestamp' -> NULL
--     (by code: NULL 165 -> 166, no_stamp_timestamp 1 -> 0; no_stamps 20, cards_withheld 1, needs_snap_then_extent 2 unchanged).
--   What NULL does for window5-sheet3: nothing is written. It is already completed (2026-07-13); the completion trigger gates
--     only false -> true; it is not in derm.v_blackout_completed_unpublished (all 6 of its client pairs have their copy) and
--     its Manifests row (Miami-Dade #822919) already reads completed, 6 of 6 placed, no copies fact, so
--     derm.fn_manifest_row_states_core never asks about it. The portal's stamping screen and the old Stamp host show the
--     publishable message only on a sheet that is not completed. fn_blackout_targets: 0 targets before and after.
--   Health email (public.log_blackout_health, run rolled back): blocked_sheets 3 -> 2, clients_blocked 12 -> 11,
--     manifests_blocked 11 -> 11; completed_unpublished 1 (ticket-836361) unchanged.
--
-- REHEARSED (BEGIN ... ROLLBACK on Prod, 2026-11-15 12:35 ET: this file's BEGIN..COMMIT body, then the rollback file's,
-- in one transaction; 2.6 s in all, the DDL and VERIFY 0.5 s). Fixtures in a folder that does not exist, cards on page 1 of
-- test ticket #111111, no extent (the standing check's own fixtures):
--                                                         NEW body              OLD body (control)
--   A unlinked, point, no stamp time                      not listed, NULL      no_stamp_timestamp   <- control FAILS
--   B LINKED (2017), point, no stamp time                 no_stamp_timestamp    no_stamp_timestamp
--   C unlinked, point, WITH a stamp time                  needs_extent          needs_extent
--   D A + a LINKED withheld card on a page never uploaded cards_withheld        no_stamp_timestamp   <- control FAILS
--   (D on a copy with the arm-1 edit ONLY: listed nowhere, publishable NULL: why the two guards carry the condition.)
--   md5 view 4bad4d02 -> 0abfa2a0 -> 4bad4d02 and function a3b9424d -> ad0a457e -> a3b9424d through migration and rollback;
--   window5-sheet3 no_stamp_timestamp -> NULL (not listed) -> no_stamp_timestamp; window4-sheet1 cards_withheld and
--   ticket-315808 needs_snap_then_extent throughout; window5-sheet3 completed throughout; net.http_request_queue 0 throughout
--   (no sweep kicked). The standing check on the OLD live bodies, before this file: A and D FAIL, B, C, CITY pass.
-- APPLIED 2026-11-15 12:36 ET (first attempt, 1.1 s; the name is earlier than the apply time). NOTHING ELSE MOVED, measured
-- read-only right before (12:35:50 ET) and right after (12:36:31 ET), the health email run rolled back both times:
--   view rows: window5-sheet3 gone, nothing else moved, nothing new; fn_sheet_publishable, 189 sheets: window5-sheet3
--   'no_stamp_timestamp' -> NULL, the other 188 identical; derm.fn_manifest_row_states_core(): 180 of 180 rows identical;
--   derm.v_blackout_completed_unpublished identical (ticket-836361); fn_blackout_targets(100000): 0 and 0;
--   derm.stamp_sheet_status (md5 of every row), derm.redacted_manifest_docs (md5 of every row), window5-sheet3's 7 cards
--   (md5) and card 234 itself: identical; health email: blocked_sheets 3 -> 2, clients_blocked 12 -> 11, manifests_blocked
--   11 -> 11, completed_unpublished 1 -> 1, customer impact identical, only window5-sheet3 left the sheet list; city email
--   2017 already_sent, 2020 awaiting_manual_send, before and after. fn_sheet_publishable_detail('window5-sheet3'): blocker
--   and message NULL (pages_needing_extent still [1], shown only beside a blocker); fn_stamp_sheet_wait_reason reads "ready:
--   press Mark completed" (read only for sheets still open, so it shows nowhere for this completed sheet).
--   Standing check after: ALL PASS; CONTROL=1: A and D FAIL, as they must.
-- Locks: CREATE OR REPLACE VIEW holds ACCESS EXCLUSIVE until COMMIT, so the transaction holds only the DDL, md5 and grant
-- checks and three one-sheet reads (about 0.1 s each); the full comparisons ran before on copies and run after as read-only
-- checks. A full read of the view takes about 7 s, so never put one inside this transaction.
-- Standing check: scripts/checks/stamp_blocked_list_unlinked_card.mjs (rolled back; CONTROL=1 puts the old bodies back
-- from the rollback file and must FAIL A and D).
-- Rollback: 2026-11-15_rollback_derm_blocked_list_skips_unlinked_unstamped_card.sql (the old bodies byte for byte).

BEGIN;
SET LOCAL lock_timeout = '3s';

-- GUARD: the live bodies this was generated from (md5 in the replace(..., chr(13), '') form, read 2026-11-15 12:22 ET)
DO $g$
BEGIN
  IF md5(replace(pg_get_viewdef('derm.v_blackout_blocked_sheets'::regclass), chr(13), '')) <> '4bad4d024cfde5c56ba6ab7ef41197fc'
    THEN RAISE EXCEPTION 'GUARD: derm.v_blackout_blocked_sheets changed since it was read (read 2026-11-15 12:22 ET)'; END IF;
  IF md5(replace(pg_get_functiondef('derm.fn_sheet_publishable(text)'::regprocedure), chr(13), '')) <> 'a3b9424dcb06c25bb60b4cfe4b0824af'
    THEN RAISE EXCEPTION 'GUARD: derm.fn_sheet_publishable changed since it was read (read 2026-11-15 12:22 ET)'; END IF;
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
  WHERE ((arm.stamp_y_pct IS NOT NULL) AND ((arm.matched_manifest_id IS NOT NULL) OR (arm.stamp_placed_at IS NOT NULL)) AND (NOT (EXISTS ( SELECT 1
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
          WHERE ((a.dump_folder = arm.dump_folder) AND (a.stamp_y_pct IS NOT NULL) AND ((a.matched_manifest_id IS NOT NULL) OR (a.stamp_placed_at IS NOT NULL)) AND (NOT (EXISTS ( SELECT 1
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
          WHERE ((a.dump_folder = arm.dump_folder) AND (a.stamp_y_pct IS NOT NULL) AND ((a.matched_manifest_id IS NOT NULL) OR (a.stamp_placed_at IS NOT NULL)) AND (NOT (EXISTS ( SELECT 1
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
                   AND NOT derm.fn_card_page_missing(r.white_manifest_number, COALESCE(r.stamp_page, r.page))
                   -- 2026-11-15 (pick QQ): a card with no manifest link and no stamp time has no copy to make, so a
                   -- page holding only such cards needs no extent (the rule of derm.v_blackout_blocked_sheets).
                   AND (r.matched_manifest_id IS NOT NULL OR r.stamp_placed_at IS NOT NULL)) sp
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

-- VERIFY: cheap only (md5, grants, three one-sheet reads of about 0.1 s each)
DO $v$
BEGIN
  IF md5(replace(pg_get_viewdef('derm.v_blackout_blocked_sheets'::regclass), chr(13), '')) <> '0abfa2a00d2743be620c795a305b9fb0'
    THEN RAISE EXCEPTION 'VERIFY: the view is not the rehearsed one'; END IF;
  IF md5(replace(pg_get_functiondef('derm.fn_sheet_publishable(text)'::regprocedure), chr(13), '')) <> 'ad0a457efe70f9163cf3f20fd1325ea7'
    THEN RAISE EXCEPTION 'VERIFY: derm.fn_sheet_publishable is not the rehearsed one'; END IF;
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'derm.v_blackout_blocked_sheets'::regclass) <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}'
    THEN RAISE EXCEPTION 'VERIFY: view grants moved'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'derm.fn_sheet_publishable(text)'::regprocedure) <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
    THEN RAISE EXCEPTION 'VERIFY: derm.fn_sheet_publishable grants moved'; END IF;
  IF derm.fn_sheet_publishable('window5-sheet3') IS NOT NULL
    THEN RAISE EXCEPTION 'VERIFY: window5-sheet3 is still not publishable: %', derm.fn_sheet_publishable('window5-sheet3'); END IF;
  IF derm.fn_sheet_publishable('window4-sheet1') IS DISTINCT FROM 'cards_withheld'
    THEN RAISE EXCEPTION 'VERIFY: window4-sheet1 moved'; END IF;
  IF derm.fn_sheet_publishable('ticket-315808') IS DISTINCT FROM 'needs_snap_then_extent'
    THEN RAISE EXCEPTION 'VERIFY: ticket-315808 moved'; END IF;
END $v$;

COMMIT;
