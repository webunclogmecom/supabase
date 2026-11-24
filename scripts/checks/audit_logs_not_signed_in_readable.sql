-- The change log (audit.logs) is readable only through owner-rights readers, never directly by a browser role.
-- Migration 2026-11-23_1950_audit_logs_no_signed_in_read. audit.logs keeps whole old/new rows (gate and lock box
-- codes inside property_pages.content, the #244 survey_no reasons), and audit.redacted_columns can only redact
-- whole columns. Healthy = one row, status 'ok'. Anything else names what drifted. Read-only.
with readers_fn as (
  select p.oid::regprocedure::text as fn, p.prosecdef
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname not in ('pg_catalog', 'information_schema')
     and p.prosrc ~* 'audit[.]logs'
     and (has_function_privilege('authenticated', p.oid, 'EXECUTE') or has_function_privilege('anon', p.oid, 'EXECUTE'))
),
readers_view as (
  select distinct r.ev_class::regclass::text as v, c.reloptions
    from pg_depend d join pg_rewrite r on r.oid = d.objid join pg_class c on c.oid = r.ev_class
   where d.refobjid = 'audit.logs'::regclass and r.ev_class <> 'audit.logs'::regclass
)
select case
         -- control: the instrument sees the readers it must see (11 callable functions, 4 views on 2026-11-23)
         when (select count(*) from readers_fn) < 8 or (select count(*) from readers_view) < 4
           then 'CONTROL FAILED: ' || (select count(*) from readers_fn) || ' functions, '
                || (select count(*) from readers_view) || ' views seen'
         when has_table_privilege('authenticated', 'audit.logs', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
           or has_table_privilege('anon', 'audit.logs', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
           then 'GRANT BACK: a browser role holds a privilege on audit.logs'
         when has_schema_privilege('authenticated', 'audit', 'USAGE') or has_schema_privilege('anon', 'audit', 'USAGE')
           then 'GRANT BACK: a browser role holds USAGE on schema audit'
         when exists (select 1 from pg_policy where polrelid = 'audit.logs'::regclass)
           then 'POLICY BACK: audit.logs has a policy again: ' || (select string_agg(polname, ', ') from pg_policy where polrelid = 'audit.logs'::regclass)
         when exists (select 1 from readers_fn where not prosecdef)
           then 'INVOKER READER: a browser-callable function reads audit.logs with the caller''s rights (it fails now): '
                || (select string_agg(fn, ', ') from readers_fn where not prosecdef)
         when exists (select 1 from readers_view where array_to_string(reloptions, ',') ~* 'security_invoker=(true|on|1)')
           then 'INVOKER VIEW: a view reads audit.logs with the caller''s rights (it fails now): '
                || (select string_agg(v, ', ') from readers_view where array_to_string(reloptions, ',') ~* 'security_invoker=(true|on|1)')
         else 'ok'
       end as status,
       (select count(*) from readers_fn) as callable_reader_functions,
       (select count(*) from readers_view) as reader_views;
