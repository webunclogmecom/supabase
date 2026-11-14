-- ROLLBACK of 2026-11-14_0721_client_quotes_jobber_url.sql
--
-- Puts client.quotes back to the view it was (verbatim, md5 da19a8daf8aa5f8a912b89985bb38a0f as printed with an empty
-- search_path): no jobber_url, so the Ops Portal greys a quote's "Open in Jobber" and "Send it in Jobber" again ("No Jobber
-- address on file"). A view cannot lose a column by CREATE OR REPLACE, so this DROPs it and creates it again, then sets
-- its grants back exactly (a new view in client gets authenticated and db_backup_reader by default privileges, and no
-- service_role). Nothing depends on client.quotes (measured 2026-11-14: no view, rule or function names it).
-- Guarded: refuses unless the live view is exactly the one that migration made (md5 f1e63cb78185fb4839ab459076eb72bc).

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path = '';

do $pin$
begin
  if pg_catalog.md5(pg_catalog.pg_get_viewdef('client.quotes'::regclass, false)) <> 'f1e63cb78185fb4839ab459076eb72bc' then
    raise exception 'client.quotes is not the view of 2026-11-14_0721_client_quotes_jobber_url; do not undo blindly';
  end if;
end
$pin$;

DROP VIEW client.quotes;

CREATE VIEW client.quotes AS
 SELECT id,
    client_id,
    property_id,
    quote_number,
    title,
    subtotal,
    tax_amount,
    total,
    deposit_amount,
    quote_status,
    sent_at,
    approved_at,
    converted_to_job_at,
    created_at,
    updated_at
   FROM public.quotes;

REVOKE ALL ON client.quotes FROM PUBLIC, anon, authenticated, service_role, db_backup_reader;
GRANT SELECT ON client.quotes TO authenticated, service_role, db_backup_reader;

do $verify$
begin
  if pg_catalog.md5(pg_catalog.pg_get_viewdef('client.quotes'::regclass, false)) <> 'da19a8daf8aa5f8a912b89985bb38a0f' then
    raise exception 'verify_fail: client.quotes is not the old text';
  end if;
  if (select c.relacl::text from pg_catalog.pg_class c where c.oid = 'client.quotes'::regclass)
       is distinct from '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}'
     or (select c.reloptions from pg_catalog.pg_class c where c.oid = 'client.quotes'::regclass) is not null
     or (select pg_catalog.pg_get_userbyid(c.relowner) from pg_catalog.pg_class c where c.oid = 'client.quotes'::regclass) <> 'postgres'
     or pg_catalog.has_table_privilege('anon', 'client.quotes', 'SELECT') then
    raise exception 'verify_fail: the grants, owner or options of client.quotes are not the old ones';
  end if;
  raise notice 'verify ok: client.quotes is the old view again, with its old grants';
end $verify$;

COMMIT;
