-- 2026-11-15_0750_derm_row_898_page_two_note.sql
--
-- WHAT
-- ----
-- A ONE-TIME data change (no object changes): public.derm_manifests row 898 (#813222, the one live client row with no
-- visit, held back by pick E) gets a note saying why it stays live with no visit: it alone carries page 2 of that
-- ticket's address sheet. Written where the row-completeness check reads an accepted gap: public.derm_manifests.notes,
-- read through derm.manifest_health.notes, which ops.v_derm_row_completeness_gaps turns into accepted_gap_note
-- (notes IS NOT NULL) and derm.fn_manifest_row_states_core into its "noted" grey. The same path every note on a
-- manifest row was written by so far: a SQL update with a dated bracket prefix (82 changes in audit.logs, all
-- app_source 'sql'; no app writes this column). The row is untouched otherwise; the UPDATE re-asserts "no note yet,
-- live, no visit linked".
--
-- WHY
-- ---
-- Fred, 2026-11-15 ~2:45 AM ET, answering the page of the built stamping screen: "go ahead with recomended". Pick PP:
-- "Keep the row and add a note on it that says it holds page 2 of the sheet, so the row stops asking for a visit"
-- (Building Apps/Ops Portal/docs/00-fred-picks-2026-11-12-manifests-and-stamping.md). Pick E (2026-11-14_2200)
-- archived the other 8 client rows with no visit; this one was held because derm.ticket_page_images keeps a page only
-- while a live row carries its photo, so archiving it would drop page 2 of a regulator-facing sheet and raise
-- STAMP_PAGE_PAST_END for its stamped client.
--
-- REACH, measured (2026-11-15 ~07:45 ET)
-- -----
-- Before the note the row already read as nobody's work: the Manifests row of #813222 is "ok" with needs false
-- (derm.fn_manifest_row_states_core has no "no visit" place since pick E) and no health email read names #813222 or
-- row 898 (blackout-health, the blocked and unpublished lists, placement health, the 11 AM list). Its papers are
-- complete, so it is not in ops.v_derm_row_completeness_gaps (that view keeps rows that are not fully_complete) and
-- the core's "noted" grey does not apply to it. What the note changes: the reason is now ON the row, read by
-- derm.manifest_health.notes, so the next person who finds it with no visit (derm.v_orphan_manifests, a diagnostic
-- view no app or health read uses, keeps listing it by design) reads why instead of linking or archiving it.
-- 🛑 Do not archive row 898 while page 2 of #813222 lives only in its photo.
--
-- REHEARSED (rolled back, 2026-11-15 ~07:49 ET, one statement ending in P0099), with the 27-key snapshot used for
-- the three items: CONTROL before the note, derm.manifest_health reads no note for 898; after it, 1 row updated, the
-- note read through derm.manifest_health; of the 27 keys only row898_notes and mh898_notes_set changed (every other
-- manifest row, every card, every sheet status, every copy, both tickets' page lists, the Manifests rows of every
-- ticket (md5 of the core), the blocked / unpublished / placement health / 11 AM lists, the gaps view counts 20 / 1 /
-- 19, the city email rows of manifests 2017 and 2020: identical). audit.logs: one UPDATE, column notes, label sql.
-- Applied 2026-11-15 07:50 ET; after it the same snapshot differs only in the note (row898_notes, mh898_notes_set).
-- Rollback (rehearsed after apply, inside a rolled-back statement): 2026-11-15_rollback_derm_row_898_page_two_note.sql (notes back to NULL, only while it is this note).

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF (SELECT notes FROM public.derm_manifests WHERE id = 898) IS NOT NULL
    THEN RAISE EXCEPTION 'GUARD: row 898 already has a note'; END IF;
  IF (SELECT deleted_at FROM public.derm_manifests WHERE id = 898) IS NOT NULL
    THEN RAISE EXCEPTION 'GUARD: row 898 is archived'; END IF;
  IF EXISTS (SELECT 1 FROM public.manifest_visits WHERE manifest_id = 898)
    THEN RAISE EXCEPTION 'GUARD: row 898 has a visit now'; END IF;
END $g$;

UPDATE public.derm_manifests SET notes = '[2026-11-15 pick PP] Kept live with no visit on purpose: this row alone carries page 2 of the address sheet of #813222 (its photo is that page), so archiving it would take page 2 out of the stamping record. Fred, 2026-11-15: "go ahead with recomended".'
 WHERE id = 898 AND notes IS NULL AND deleted_at IS NULL
   AND NOT EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = 898);

DO $v$
BEGIN
  IF (SELECT notes FROM derm.manifest_health WHERE id = 898) IS DISTINCT FROM '[2026-11-15 pick PP] Kept live with no visit on purpose: this row alone carries page 2 of the address sheet of #813222 (its photo is that page), so archiving it would take page 2 out of the stamping record. Fred, 2026-11-15: "go ahead with recomended".'
    THEN RAISE EXCEPTION 'VERIFY: derm.manifest_health does not read the note'; END IF;
  IF (derm.fn_manifest_row_states_core()->'Miami-Dade #813222'->>'needs')::boolean
    THEN RAISE EXCEPTION 'VERIFY: the Manifests row of #813222 needs someone'; END IF;
  IF cardinality(derm.ticket_page_images('813222')) <> 2
    THEN RAISE EXCEPTION 'VERIFY: #813222 does not have its two pages'; END IF;
END $v$;

COMMIT;
