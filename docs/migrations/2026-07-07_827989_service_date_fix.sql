-- 2026-07-07_827989_service_date_fix.sql
-- Found by the end-of-day adversarial fleet hunt (2-lens workflow, read-only):
-- #827989's 14 reconstruction-batch rows (ids 1218-1231, all created 2026-06-23)
-- carried service_date 2026-06-23 = the DATA-ENTRY date, which is AFTER the
-- ticket's dump 2026-06-21 (impossible: dump follows service). The 4 other live
-- siblings correctly had service=dump=2026-06-21. This was the ENTIRE fleet
-- class of dump-before-service violations (verified 0 remain after fix).
-- Backup: backups/2026-07-07_827989_service_date_fix_backup.json
-- Follow-up candidate (noted, not shipped): CHECK/BEFORE-guard enforcing
-- service_date <= dump_ticket_date on derm_manifests would catch this at entry.

UPDATE public.derm_manifests
   SET service_date = '2026-06-21'
 WHERE id BETWEEN 1218 AND 1231
   AND white_manifest_number = '827989'
   AND service_date = '2026-06-23'
   AND dump_ticket_date = '2026-06-21';
