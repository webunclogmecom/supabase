-- 2026-06-02 — Hard-delete ALL soft-deleted derm_manifests (Fred-requested, explicit).
-- Applied via Mgmt API from the Building Apps session (Fred-authorized; Supabase session busy).
-- Overrides the standing "never hard-delete a manifest" rule for this purge of already-soft-deleted (trash) rows,
-- same pattern as the 2026-06-01 pre-2026 DERM purge: BACK UP FIRST, then hard-delete.
--
-- BACKUP (full rows + dependencies, reversible): docs/backups/derm_softdelete_hard_delete_backup_2026-06-02.json
--   8 manifests, 7 manifest_visits links, 2 entity_source_links, 0 derm_manifest_number_proposals.
--
-- The 8 soft-deleted manifests (all legitimately trash):
--   1135 053-PV wm 488184 (0 links, partial save)      1136 087-BB wm 825560 (0 links, superseded by live re-file)
--   1140 112-YA wm 0001  (0 links, junk test number)    1141 209-TRUE wm 825560 (1 link, superseded by live 1159)
--   1142 212-TRUE wm 825560 (1 link, live 1158)          1143 176-SOU wm 825560 (3 links, live 1161)
--   1147 053-PV wm 9999999 (1 link, session test)        1148 226-JER wm 9999999 (1 link, session test)
-- Safety: of the 7 linked visits, 5 (5028,3903,5131,5092,5043) are ALSO on a LIVE manifest (stay documented);
-- the other 2 (5528,5644) were only on the 9999999 TEST manifests -> correctly revert to "Missing Docs".
-- manifest_visits_manifest_id_fkey is ON DELETE CASCADE, so the 7 links auto-clear; the 2 entity_source_links
-- are polymorphic (no FK) so are deleted explicitly to avoid dangling refs.
--
-- Verified: derm_manifests 384 -> 376; soft-deleted remaining 0; leftover links 0; leftover esl 0.
-- Audit: deletes ran via Mgmt API -> audit.logs app_source='sql'.

DELETE FROM public.entity_source_links
 WHERE entity_type LIKE '%manifest%'
   AND entity_id IN (1135,1136,1140,1141,1142,1143,1147,1148);   -- 2 rows (ids 40459, 40504)

DELETE FROM public.derm_manifests
 WHERE id IN (1135,1136,1140,1141,1142,1143,1147,1148)
   AND deleted_at IS NOT NULL;                                   -- 8 rows; CASCADE clears 7 manifest_visits links
