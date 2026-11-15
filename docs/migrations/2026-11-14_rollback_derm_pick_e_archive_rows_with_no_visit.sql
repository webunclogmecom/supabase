-- Rollback of 2026-11-14_2200_derm_pick_e_archive_rows_with_no_visit.sql: the eight client rows come back, their stamp
-- cards re-link (derm.fn_resolve_card_manifest), and their sheets are not reopened (the derm.card_link_only flag, as in
-- public.derm_restore_manifests). Only rows still archived with that migration's note are touched. Run it BEFORE the
-- rollback of 2026-11-14_2140 (which drops the archive columns). Backup of the rows before the archive:
-- backups/2026-11-14_pick_e_client_rows_with_no_visit.json. Rehearsed in rows2/rehearse_m3.mjs.

BEGIN;
SET LOCAL lock_timeout = '3s';
SELECT set_config('derm.card_link_only', 'on', true);
UPDATE public.derm_manifests
   SET deleted_at = NULL, archive_reason = NULL, archive_note = NULL, archived_by = NULL
 WHERE id IN (116, 501, 629, 685, 696, 913, 959, 1205)
   AND deleted_at IS NOT NULL
   AND archive_note LIKE 'No visit linked. Cleaned once (pick E%';
SELECT set_config('derm.card_link_only', '', true);
DO $v$
BEGIN
  IF (SELECT count(*) FROM public.derm_manifests WHERE id IN (116, 501, 629, 685, 696, 913, 959, 1205) AND deleted_at IS NULL) <> 8
    THEN RAISE EXCEPTION 'VERIFY: the eight rows are not all live again'; END IF;
END $v$;
COMMIT;
