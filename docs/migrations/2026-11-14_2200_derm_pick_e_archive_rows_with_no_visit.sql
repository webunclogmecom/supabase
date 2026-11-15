-- 2026-11-14_2200_derm_pick_e_archive_rows_with_no_visit.sql
--
-- WHAT
-- ----
-- A ONE-TIME data change (no object changes): 8 of the 9 live client rows of public.derm_manifests that have no visit
-- linked (no public.manifest_visits row) are archived WITH A REASON, the same soft delete as the portal's "Archive
-- manifest" (2026-11-14_2140): deleted_at = now(), archive_reason = 'other', archive_note = the words below, archived_by
-- NULL (no person clicked it). The transaction setting derm.card_link_only is on for the UPDATE, as in
-- public.derm_archive_manifests, so their stamp cards only lose their manifest link and no completed sheet is reopened.
-- The nine, measured again on the day (2026-11-14 ~21:20 ET), exactly the ones of the plan, 9 on 5 tickets:
--   #294999 (Broward): 116, 501, 629, 685, 696 (every row of the ticket)   #813222: 898   #813912: 913
--   #822919: 959   #306859 (Broward): 1205
-- The guard stops unless the live rows with no visit are exactly these nine, and the UPDATE re-asserts "no visit linked".
-- (ops.v_derm_row_completeness_gaps, named in the plan, no longer lists them: its WHERE keeps rows whose health is not
-- fully_complete, and these nine now are. Its column visit_linked is the rule used here.)
--
-- 🛑 HELD BACK: 898 (#813222). Found in the rehearsal: row 898 alone carries page 2 of #813222's address sheet
-- (derm/898/address.jpg; the five other rows carry page 1), and its client's stamp sits on that page. Archiving the row
-- drops page 2 from the sheet (derm.ticket_page_images keeps a page only while a live row carries its picture), and
-- derm.v_stamp_placement_health then reports window13-sheet1 "STAMP_PAGE_PAST_END" (ATTENTION): a new alarm, and a page
-- of a regulator-facing paper gone from the stamping record. Left live for Fred: move the picture to a sibling row first,
-- or keep the row. The rule this leaves: a one-time archive never takes a row whose picture is a page no other live row of
-- its ticket carries. (The portal's Archive and the old host's Delete act on a whole ticket, whose sheet goes away with
-- it, so they cannot meet this case.)
--
-- WHY
-- ---
-- Fred, 2026-11-12, "go ahead with all the recommendations", pick E: "Clean them once: archive each of the nine client
-- rows with a reason (nothing is deleted), and make 'Unlink from manifest' warn before it leaves a row with no visit."
-- The page's reason: none of the nine can be given a visit (six clients have no completed visit on or before the dump
-- date, three have an older one already on another ticket or marked not required); on #822919 the row with no visit is
-- also the card with no stamp, "the stamp to place of your health email of November 11": cleaning the row ends that
-- to-do (the plan's fixed case #822919).
--
-- BACKUP, taken first: backups/2026-11-14_pick_e_client_rows_with_no_visit.json (all nine rows, their 9 cards, 0 per-visit
-- forms, the 5 sheet status rows), written by mockups/2026-11-14-stamping-build/rows2/backup_pick_e.mjs.
-- UNDO: as a DERM Tracker editor, public.derm_restore_manifests(array[116,501,629,685,696,913,959,1205]), or the
-- portal's Restore on each of the four entries of the Archived list. Rollback file:
-- 2026-11-14_rollback_derm_pick_e_archive_rows_with_no_visit.sql (the same restore, by id, with the flag).
--
-- REACH, measured in the rehearsal (rows2/rehearse_m3.mjs, rolled back): live rows 967 -> 959. The list loses #294999
-- (its sheet window13-sheet8 leaves the sheet list with it) and three rows change (#306859, #813912, #822919). #822919's
-- sheet counts 6 of 6 stamps where it counted 6 of 7 and its row needs nobody: the plan's fixed case reads as designed.
-- No sheet reopens; the 11 AM post / bell list (one open sheet, #841609), the health email's unpublished list, the
-- placement health list, the city email candidates (1, row 898's, status no_property) and customer.work_orders (0 rows)
-- are unchanged.
-- ⚠ NOT ended, unlike the page said: the health email's blocked list keeps #822919's sheet (window5-sheet3,
-- "no_stamp_timestamp"), now with 0 manifests blocked where it had 1, still 1 client: card 234 keeps its stamp POSITION
-- with no stamp time and its client (the no-visit client). Ending it means clearing that card's position
-- (derm.clear_stamp_position), a change on a real client's sheet: Fred's call, not done here.
-- Old host: the DERM Tracker's list stops showing #294999 and the three client rows, as for any deleted row.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
DECLARE v_ids bigint[];
BEGIN
  IF to_regprocedure('public.derm_archive_manifests(bigint[], text, text)') IS NULL
    THEN RAISE EXCEPTION 'GUARD: 2026-11-14_2140 (the archive columns and functions) is not applied'; END IF;
  IF strpos(pg_get_functiondef('derm.fn_dirty_on_card_change()'::regprocedure), 'derm.card_link_only') = 0
    THEN RAISE EXCEPTION 'GUARD: derm.fn_dirty_on_card_change does not know derm.card_link_only (2026-11-14_2140)'; END IF;
  SELECT array_agg(m.id ORDER BY m.id) INTO v_ids
    FROM public.derm_manifests m
   WHERE m.deleted_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = m.id);
  IF v_ids IS DISTINCT FROM ARRAY[116, 501, 629, 685, 696, 898, 913, 959, 1205]::bigint[]
    THEN RAISE EXCEPTION 'GUARD: the live client rows with no visit are not the measured nine: %', v_ids; END IF;
END $g$;

SELECT set_config('derm.card_link_only', 'on', true);
UPDATE public.derm_manifests m
   SET deleted_at = now(),
       archive_reason = 'other',
       archive_note = 'No visit linked. Cleaned once (pick E, Fred: "go ahead with all the recommendations", 2026-11-12).',
       archived_by = NULL
 WHERE m.id IN (116, 501, 629, 685, 696, 913, 959, 1205)
   AND m.deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = m.id);
SELECT set_config('derm.card_link_only', '', true);

DO $v$
BEGIN
  IF (SELECT count(*) FROM public.derm_manifests WHERE id IN (116, 501, 629, 685, 696, 913, 959, 1205)
        AND deleted_at IS NOT NULL AND archive_reason = 'other') <> 8
    THEN RAISE EXCEPTION 'VERIFY: not exactly eight rows archived'; END IF;
  IF (SELECT array_agg(m.id) FROM public.derm_manifests m WHERE m.deleted_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = m.id)) IS DISTINCT FROM ARRAY[898]::bigint[]
    THEN RAISE EXCEPTION 'VERIFY: the live client rows with no visit are not exactly the held one (898)'; END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map WHERE matched_manifest_id IN (116, 501, 629, 685, 696, 913, 959, 1205))
    THEN RAISE EXCEPTION 'VERIFY: a stamp card still points at an archived row'; END IF;
  IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status
              WHERE dump_folder IN ('derm/1194', 'window12-sheet11', 'window13-sheet1', 'window13-sheet8', 'window5-sheet3') AND NOT completed)
    THEN RAISE EXCEPTION 'VERIFY: a sheet of the nine was reopened'; END IF;
  IF EXISTS (SELECT 1 FROM derm.v_stamp_placement_health WHERE dump_folder IN ('derm/1194', 'window12-sheet11', 'window13-sheet1', 'window5-sheet3'))
    THEN RAISE EXCEPTION 'VERIFY: a sheet of the eight now has a placement problem'; END IF;
END $v$;

COMMIT;
