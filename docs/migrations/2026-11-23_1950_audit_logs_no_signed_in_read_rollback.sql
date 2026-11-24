-- 2026-11-23_1950_audit_logs_no_signed_in_read_rollback.sql
-- Puts back what 2026-11-23_1950 took away: SELECT on audit.logs and USAGE on schema audit for
-- `authenticated`, and the policy authenticated_read_all (SELECT, USING true). This REOPENS the whole change
-- log (gate and lock box codes inside property_pages rows) to any signed-in role if `audit` is ever exposed.
-- Guarded: refuses unless the state is exactly the one 2026-11-23_1950 left.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $guard$
BEGIN
  IF has_table_privilege('authenticated', 'audit.logs', 'SELECT')
     OR has_schema_privilege('authenticated', 'audit', 'USAGE')
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'audit.logs'::regclass) THEN
    RAISE EXCEPTION 'audit.logs is not in the 2026-11-23_1950 state: rollback refused';
  END IF;
END
$guard$;

GRANT USAGE ON SCHEMA audit TO authenticated;
GRANT SELECT ON TABLE audit.logs TO authenticated;
CREATE POLICY authenticated_read_all ON audit.logs FOR SELECT TO authenticated USING (true);

DO $verify$
BEGIN
  IF NOT has_table_privilege('authenticated', 'audit.logs', 'SELECT')
     OR has_table_privilege('authenticated', 'audit.logs', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
     OR NOT has_schema_privilege('authenticated', 'audit', 'USAGE')
     OR has_schema_privilege('authenticated', 'audit', 'CREATE')
     OR (SELECT count(*) FROM pg_policy WHERE polrelid = 'audit.logs'::regclass AND polname = 'authenticated_read_all'
          AND polcmd = 'r' AND polroles = ARRAY['authenticated'::regrole::oid] AND pg_get_expr(polqual, polrelid) = 'true') <> 1 THEN
    RAISE EXCEPTION 'VERIFY: the pre-2026-11-23_1950 state was not restored exactly';
  END IF;
END
$verify$;

COMMIT;
