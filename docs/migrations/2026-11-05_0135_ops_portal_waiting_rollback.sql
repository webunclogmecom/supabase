-- Rollback of 2026-11-05_0135_ops_portal_waiting.sql. The Ops Portal's bell then shows that it could not load.
BEGIN;
DROP FUNCTION IF EXISTS ops.portal_waiting();
NOTIFY pgrst, 'reload schema';
COMMIT;
