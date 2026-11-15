-- 2026-11-15_rollback_derm_row_898_page_two_note.sql
-- Undoes 2026-11-15_0750_derm_row_898_page_two_note.sql: row 898's note back to NULL, only while it is exactly that note.
BEGIN;
SET LOCAL lock_timeout = '3s';
UPDATE public.derm_manifests SET notes = NULL WHERE id = 898 AND notes = '[2026-11-15 pick PP] Kept live with no visit on purpose: this row alone carries page 2 of the address sheet of #813222 (its photo is that page), so archiving it would take page 2 out of the stamping record. Fred, 2026-11-15: "go ahead with recomended".';
DO $v$
BEGIN
  IF (SELECT notes FROM public.derm_manifests WHERE id = 898) IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: the note is still there'; END IF;
END $v$;
COMMIT;
