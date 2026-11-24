-- 2026-11-23_1950_audit_logs_no_signed_in_read.sql
--
-- WHAT: a signed-in browser role can no longer read the change log directly.
--   REVOKE ALL on audit.logs and on schema audit from authenticated, anon and PUBLIC (REVOKE ALL, never a
--   list: on PG17 a list misses MAINTAIN), and DROP POLICY audit.logs.authenticated_read_all (USING true),
--   so a grant that comes back by accident still shows 0 rows (RLS stays on, no policy).
--   service_role, postgres and db_backup_reader keep what they had. No trigger, function or view changes.
--
-- WHY: found in the Trello #244 verification (2026-11-23 ~7:30 PM ET, reproduced by two agents). audit.logs
--   keeps WHOLE old/new rows. 28 public.property_pages rows hold the full page content, whose facts include
--   the gate and lock box codes, and since #244 survey_no (the builder's No reasons, staff only by design).
--   audit.redacted_columns (5 rows) can only redact whole columns, so it cannot cover a code inside a jsonb.
--   `authenticated` held SELECT + schema USAGE and the policy was USING (true): the only thing keeping the
--   log from any signed-in browser was that PostgREST's db_schema (public, graphql_public, customer, derm,
--   ops, client, hr, read from the Management API /postgrest the same evening) does not list `audit`.
--   pg_graphql is not installed (graphql_public.graphql is the stub), so GraphQL was not a second door.
--   Fred, asked with the measurement below: "Remove it + its rule (Recommended)".
--
-- WHO READS audit.logs (measured 2026-11-23 7:42 PM ET, pg_depend + prosrc, a positive control on
--   audit.log_change), and why none of them needs the caller's grant:
--   views (all owned by postgres, reloptions NULL = owner rights): client.job_activity,
--     derm.gdo_report_activity, derm.manifest_activity, derm.v_orphan_manifests. No view calls an audit.*
--     function (EXECUTE would be checked as the caller).
--   functions authenticated may EXECUTE, all SECURITY DEFINER owned by postgres: client.fn_intake_who,
--     client.get_client_activity, client.get_property_activity, derm.audit_pack,
--     public.detach_manifest_document, public.get_record_history, public.get_review_history,
--     hr.get_access_overview, hr.get_employee_record, public.include_visits_in_review,
--     public.visit_last_schedule_edit.
--   the one SECURITY INVOKER reader, derm.fn_manifest_row_states_core(), is EXECUTE for its owner only and
--     is called only from SECURITY DEFINER functions (derm.manifest_row_states, _for_client,
--     get_manifest_dialog, stamp_sheet_facts, archived_manifest_rows, ops.portal_waiting), so it runs as
--     postgres. No view calls it.
--   writers: audit.log_change and audit.fn_log_derm_required_shadow are SECURITY DEFINER, so an app's
--     write still logs without any grant on audit.logs.
--   no edge function or app reads audit.logs as the user: supabase/functions has only comments naming it,
--     and the Building Apps sources (every app, the Ops Portal app repo included) have no .schema('audit'),
--     no db.schema 'audit' and no from('logs').
--
-- APPLIED 2026-11-23 7:50 PM ET (DB clock). REHEARSAL (rolled back, ~7:45 PM ET): as `authenticated` with an admin employee's real JWT
--   claims, 19 readers (the 4 views, the 9 read functions above and the 6 core callers; the 2 writers
--   detach_manifest_document / include_visits_in_review not called) were run before and after the change
--   in one transaction, each reduced to row count + md5 of the rows: 19 of 19 identical, every one
--   returning at least one row. Control: the direct read `select count(*) from audit.logs where
--   table_name = 'property_pages'` returned 28 BEFORE (the old state really was readable) and 42501 AFTER;
--   a partition (audit.logs_p20261101) 42501.
--
-- RULE 8: no table added or changed; audit triggers untouched.
-- CHECK: scripts/checks/audit_logs_not_signed_in_readable.sql (one row, 'ok').
-- ROLLBACK: 2026-11-23_1950_audit_logs_no_signed_in_read_rollback.sql (puts the grant, USAGE and policy back).

BEGIN;
SET LOCAL lock_timeout = '3s';

-- Guard: the state this file was measured against.
DO $guard$
BEGIN
  IF NOT has_table_privilege('authenticated', 'audit.logs', 'SELECT')
     OR NOT has_schema_privilege('authenticated', 'audit', 'USAGE')
     OR NOT EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'audit.logs'::regclass AND polname = 'authenticated_read_all') THEN
    RAISE EXCEPTION 'audit.logs is not in the measured state (grant, USAGE and policy expected): re-measure';
  END IF;
END
$guard$;

REVOKE ALL ON TABLE audit.logs FROM authenticated, anon, PUBLIC;
REVOKE ALL ON SCHEMA audit FROM authenticated, anon, PUBLIC;
DROP POLICY authenticated_read_all ON audit.logs;

-- VERIFY
DO $verify$
DECLARE
  v_uid uuid; v_email text; n bigint; r text;
BEGIN
  -- nothing for a browser role, on the table, any partition, or the schema
  IF EXISTS (
       SELECT 1 FROM pg_class c
        WHERE (c.oid = 'audit.logs'::regclass OR c.oid IN (SELECT inhrelid FROM pg_inherits WHERE inhparent = 'audit.logs'::regclass))
          AND (has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN')
            OR has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN'))) THEN
    RAISE EXCEPTION 'VERIFY: a browser role still holds a privilege on audit.logs or a partition';
  END IF;
  IF has_schema_privilege('authenticated', 'audit', 'USAGE') OR has_schema_privilege('anon', 'audit', 'USAGE') THEN
    RAISE EXCEPTION 'VERIFY: a browser role still holds USAGE on schema audit';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'audit.logs'::regclass) THEN
    RAISE EXCEPTION 'VERIFY: audit.logs still has a policy';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'audit.logs'::regclass) THEN
    RAISE EXCEPTION 'VERIFY: RLS is off on audit.logs';
  END IF;
  -- what must keep working: the server key and the backup reader
  IF NOT has_table_privilege('service_role', 'audit.logs', 'SELECT') OR NOT has_schema_privilege('service_role', 'audit', 'USAGE')
     OR NOT has_table_privilege('db_backup_reader', 'audit.logs', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY: service_role or db_backup_reader lost its read';
  END IF;

  -- as a signed-in admin: an owner-rights view and a definer function still read, the direct read fails
  SELECT u.id, u.email INTO v_uid, v_email
    FROM public.employees e JOIN auth.users u ON lower(btrim(u.email)) = lower(btrim(e.email))
   WHERE e.status = 'ACTIVE' AND e.access_level = 'admin' AND u.email_confirmed_at IS NOT NULL
   ORDER BY e.id LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO n FROM (SELECT 1 FROM client.job_activity LIMIT 5) s;
  IF n = 0 THEN RAISE EXCEPTION 'VERIFY: client.job_activity returned nothing as authenticated'; END IF;
  SELECT count(*) INTO n FROM public.get_record_history('visits', '9245', NULL, false, 5);
  IF n = 0 THEN RAISE EXCEPTION 'VERIFY: get_record_history(visits, 9245) returned nothing as authenticated'; END IF;
  r := client.get_property_activity(1164)::text;
  IF r IS NULL THEN RAISE EXCEPTION 'VERIFY: client.get_property_activity(1164) returned NULL as authenticated'; END IF;
  BEGIN
    PERFORM 1 FROM audit.logs LIMIT 1;
    RAISE EXCEPTION 'VERIFY: authenticated can still read audit.logs directly';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  EXECUTE 'RESET ROLE';
END
$verify$;

COMMIT;
