-- =============================================================================
-- 2026-11-14_0721_client_quotes_jobber_url.sql
--
-- WHAT: client.quotes gains ONE column, at its END: jobber_url, the quote's page in Jobber's web app,
--       https://secure.getjobber.com/quotes/<Jobber id>. It is built exactly as client.invoices builds its own jobber_url:
--       from the quote's stored Jobber id in public.entity_source_links (entity_type 'quote', source_system 'jobber'; a
--       bare number is the id itself, base64 is gid://Jobber/Quote/<id>), never from the quote number. A quote with no
--       stored id gets NULL, so the app shows no button. No column is renamed, moved or removed (the old Client App reads
--       this view), and CREATE OR REPLACE keeps the grants, the owner and the options.
--
-- WHY: the Ops Portal's Clients and Finances pages. A quote's "Open in Jobber", and a draft's "Send it in Jobber", read
--      client.quotes.jobber_url and showed greyed "No Jobber address on file", because client.invoices carried an
--      address and client.quotes did not.
--      The address pattern is Jobber's own: read live 2026-11-14 (read only, GraphQL version 2026-04-16), the
--      jobberWebUri of quotes #3131, #243 and #3158 is https://secure.getjobber.com/quotes/<stored id>, for a base64 link
--      and for a bare-number link alike (the same pattern archive-client has used since it was checked in the browser on
--      2026-09-22). Nothing stores a web address (entity_source_links has no URL column, public.quotes none), so it is
--      built from the stored id, like the invoices' address.
--
-- MEASURED 2026-11-14: 345 quotes, each with exactly one Jobber link (343 base64 gid://Jobber/Quote/<n>, 2 bare
--   numbers that Jobber answers as the same quote numbers), so 345 get an address and 0 get NULL. 73 of them are
--   destroyed (deleted in Jobber): they get an address too, as the 13 destroyed invoices do in client.invoices, and
--   Jobber answers null for such an id (2 of 2 read), so that page no longer opens.
--
-- Applied 2026-11-14 at 07:00 ET; named _0721 so it sorts after 2026-11-14_0720, which went in before it.
--
-- READ ONLY. A view, no row is written. RULE 8, AUDIT: no table.
-- LOCK: CREATE OR REPLACE VIEW takes an ACCESS EXCLUSIVE lock until the end of this transaction, so it holds only the
--   guard, a snapshot of the 345 rows, the statement and cheap checks (lock_timeout 3 s); proven first in a
--   rolled-back rehearsal, with the old view as the control that must fail.
-- search_path is '' inside this transaction, so the view text is the schema-qualified text pg_get_viewdef prints.
-- UNDO: 2026-11-14_rollback_client_quotes_jobber_url.sql (a view cannot lose a column by CREATE OR REPLACE, so it drops
--   and re-creates the old view with its grants; nothing depends on client.quotes, measured).
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path = '';

do $pin$
begin
  if pg_catalog.md5(pg_catalog.pg_get_viewdef('client.quotes'::regclass, false)) <> 'da19a8daf8aa5f8a912b89985bb38a0f' then
    raise exception 'client.quotes is not the view this migration was written from; stop';
  end if;
end
$pin$;

-- Every row of the 15 columns before the change, kept for the VERIFY (for this transaction only).
select pg_catalog.set_config('unclogme.quotes_before', (
  select pg_catalog.count(*)::text || ' rows ' || coalesce(pg_catalog.md5(pg_catalog.string_agg(
           ROW(q.id, q.client_id, q.property_id, q.quote_number, q.title, q.subtotal, q.tax_amount, q.total, q.deposit_amount,
               q.quote_status, q.sent_at, q.approved_at, q.converted_to_job_at, q.created_at, q.updated_at)::text, '|' ORDER BY q.id)), 'none')
    from client.quotes q), true);

CREATE OR REPLACE VIEW client.quotes AS
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
    updated_at,
    ( SELECT
                CASE
                    WHEN (l.source_id ~ '^[0-9]+$'::text) THEN ('https://secure.getjobber.com/quotes/'::text || l.source_id)
                    WHEN (((length(l.source_id) % 4) = 0) AND (l.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'::text)) THEN ('https://secure.getjobber.com/quotes/'::text || split_part(convert_from(decode(l.source_id, 'base64'::text), 'UTF8'::name), '/'::text, '-1'::integer))
                    ELSE NULL::text
                END AS "case"
           FROM public.entity_source_links l
          WHERE ((l.entity_type = 'quote'::text) AND (l.source_system = 'jobber'::text) AND (l.entity_id = quotes.id))
         LIMIT 1) AS jobber_url
   FROM public.quotes;

do $verify$
declare
  v_def text := pg_catalog.pg_get_viewdef('client.quotes'::regclass, false);
  v_total bigint; v_with bigint; v_without bigint; v_bad bigint; v_numbered bigint; v_links bigint;
begin
  -- 1. The text: the old view plus the new column, nothing else.
  if pg_catalog.md5(v_def) <> 'f1e63cb78185fb4839ab459076eb72bc' then
    raise exception 'verify_fail: the view is not the old one plus jobber_url';
  end if;
  if pg_catalog.md5(pg_catalog.left(v_def, pg_catalog.strpos(v_def, 'updated_at,') + 9)
                    || pg_catalog.substr(v_def, pg_catalog.strpos(v_def, ' AS jobber_url') + 14)) <> 'da19a8daf8aa5f8a912b89985bb38a0f' then
    raise exception 'verify_fail: the view is not the old one plus jobber_url';
  end if;
  -- 2. The columns: the 15 old ones, same names, types and order, then jobber_url text.
  if (select pg_catalog.string_agg(a.attname || ' ' || pg_catalog.format_type(a.atttypid, a.atttypmod), ', ' ORDER BY a.attnum)
        from pg_catalog.pg_attribute a where a.attrelid = 'client.quotes'::regclass and a.attnum > 0 and not a.attisdropped)
     is distinct from 'id bigint, client_id bigint, property_id bigint, quote_number text, title text, subtotal numeric(12,2), tax_amount numeric(12,2), total numeric(12,2), deposit_amount numeric(12,2), quote_status text, sent_at timestamp with time zone, approved_at timestamp with time zone, converted_to_job_at timestamp with time zone, created_at timestamp with time zone, updated_at timestamp with time zone, jobber_url text' then
    raise exception 'verify_fail: the columns are not the old 15 then jobber_url';
  end if;
  -- 3. Grants, owner and options unchanged; anon reads nothing.
  if (select c.relacl::text from pg_catalog.pg_class c where c.oid = 'client.quotes'::regclass)
       is distinct from '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}'
     or (select c.reloptions from pg_catalog.pg_class c where c.oid = 'client.quotes'::regclass) is not null
     or (select pg_catalog.pg_get_userbyid(c.relowner) from pg_catalog.pg_class c where c.oid = 'client.quotes'::regclass) <> 'postgres'
     or pg_catalog.has_table_privilege('anon', 'client.quotes', 'SELECT') then
    raise exception 'verify_fail: the grants, owner or options of the view changed';
  end if;
  -- 4. Every row, every old column: the same as before the change.
  if (select pg_catalog.count(*)::text || ' rows ' || coalesce(pg_catalog.md5(pg_catalog.string_agg(
            ROW(q.id, q.client_id, q.property_id, q.quote_number, q.title, q.subtotal, q.tax_amount, q.total, q.deposit_amount,
                q.quote_status, q.sent_at, q.approved_at, q.converted_to_job_at, q.created_at, q.updated_at)::text, '|' ORDER BY q.id)), 'none')
        from client.quotes q) is distinct from pg_catalog.current_setting('unclogme.quotes_before', true) then
    raise exception 'verify_fail: a row of the old columns changed';
  end if;
  -- 5. The addresses. Worked out again a second way (a strict gid://Jobber/Quote/<n>, cut by position), every quote must
  --    get exactly that: Jobber's page of its stored id, or NULL when it has none. None may be built from its number.
  select pg_catalog.count(*), pg_catalog.count(q.jobber_url), pg_catalog.count(*) filter (where q.jobber_url is null),
         pg_catalog.count(*) filter (where q.jobber_url is distinct from (
           case when l.source_id ~ '^[0-9]+$' then 'https://secure.getjobber.com/quotes/' || l.source_id
                when pg_catalog.length(l.source_id) % 4 = 0 and l.source_id ~ '^[A-Za-z0-9+/]+={0,2}$' then
                  case when pg_catalog.convert_from(pg_catalog.decode(l.source_id, 'base64'), 'UTF8') ~ '^gid://Jobber/Quote/[0-9]+$'
                       then 'https://secure.getjobber.com/quotes/' || pg_catalog.substr(pg_catalog.convert_from(pg_catalog.decode(l.source_id, 'base64'), 'UTF8'), 20) end
           end)),
         pg_catalog.count(*) filter (where q.jobber_url = 'https://secure.getjobber.com/quotes/' || q.quote_number),
         pg_catalog.count(l.source_id)
    into v_total, v_with, v_without, v_bad, v_numbered, v_links
    from client.quotes q
    left join public.entity_source_links l on l.entity_type = 'quote' and l.source_system = 'jobber' and l.entity_id = q.id;
  if v_bad <> 0 or v_numbered <> 0 or v_with = 0 or v_with <> v_links then
    raise exception 'verify_fail: an address is not Jobber''s page of the stored id (% wrong, % from a number, % with, % links)', v_bad, v_numbered, v_with, v_links;
  end if;
  raise notice 'verify ok: client.quotes carries jobber_url; % quotes, % with an address, % without', v_total, v_with, v_without;
end $verify$;

COMMIT;
