-- 2026-07-06_derm_sibling_mislinks_norecord.sql
-- Fred confirmed the same-address sibling codes are TWO SEPARATE facilities (same
-- building maybe, but different manholes + different GDO permits) -> their
-- cross-client links are REAL mis-links to fix, not a merge.
-- Fixed the 2 that need NO new record:
--   #820615  v1567 (144-LTG) was on 139-LTG's m120 -> MOVE to 144-LTG's own empty
--            manifest m1245 (same client).
--   #821038  v1592 (193-FRK) was double-linked to 192-FRK's m441 (wrong) AND its
--            own 193-FRK m1133 -> DROP the spurious m441 link.
-- Backup: backups/2026-07-06_sibling_norecord_backup.json. Fleet cross-client
-- links 8 -> 6. The remaining 4 siblings' partners (815064 -> 144-LTG, 816562 ->
-- 193-FRK) plus 824713/825906/826661/827172 need a NEW manifest filed -> pending
-- Fred's ok (see project_derm_ocr_mislink_audit).

BEGIN;
DELETE FROM public.manifest_visits WHERE manifest_id=120 AND visit_id=1567;
INSERT INTO public.manifest_visits (manifest_id, visit_id) VALUES (1245,1567) ON CONFLICT DO NOTHING;
DELETE FROM public.manifest_visits WHERE manifest_id=441 AND visit_id=1592;
COMMIT;
