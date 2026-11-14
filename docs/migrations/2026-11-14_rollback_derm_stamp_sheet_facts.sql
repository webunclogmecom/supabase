-- 2026-11-14_rollback_derm_stamp_sheet_facts.sql
-- Undoes 2026-11-14_1305_derm_stamp_sheet_facts.sql (read only, nothing else depends on it). Rehearsed in its rolled-back rehearsal.
BEGIN;
DROP FUNCTION derm.stamp_sheet_facts(text);
COMMIT;
