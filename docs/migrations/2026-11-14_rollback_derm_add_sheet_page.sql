-- 2026-11-14_rollback_derm_add_sheet_page.sql
-- Undoes 2026-11-14_1315_derm_add_sheet_page.sql. Pages already added stay (they are ordinary manifest photos); remove
-- one in Edit manifest. Rehearsed in the migration's rolled-back rehearsal.
BEGIN;
DROP FUNCTION derm.add_sheet_page(text, text);
COMMIT;
