-- Rollback of 2026-11-05_0230_ops_portal_search.sql. The Ops Portal's search box then says it could not search.
BEGIN;
DROP FUNCTION IF EXISTS ops.portal_search(text);
NOTIFY pgrst, 'reload schema';
COMMIT;
