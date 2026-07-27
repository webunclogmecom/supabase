-- ============================================================================
-- 2026-07-28b — client.global_search v2: grouped JSONB contract
-- ============================================================================
-- Supersedes the v1 flat-array RPC from 2026-07-27e. The BA session pushed back
-- on the shape and was RIGHT: a flat ranked array cannot produce per-group counts
-- without over-fetching, and cannot paginate ONE group independently ("See all
-- properties"). Both are things Fred explicitly asked for (count per group +
-- pagination, per his Jobber screenshot). So the contract is now an
-- object-of-groups and p_limit/p_offset are PER GROUP.
--
-- ⚠ PAYMENTS: Fred's 4th group CANNOT be served, and is deliberately NOT faked.
-- Independently verified: zero payment relations in any non-catalog schema, and
-- entity_source_links (every object type ever synced from Jobber: client,
-- derm_manifest, employee, inspection, invoice, job, line_item, note, photo,
-- property, quote, vehicle, visit) has NO payment entity — payments have never
-- been ingested. invoices.paid_at is NULL on all 2,279 rows, so it is not even a
-- usable proxy: a "payment" derived from invoice_status would carry no real date
-- and would show the invoice total rather than what was actually received. A
-- plausible-looking wrong number on a money surface is worse than an honest gap.
-- → returned in `unavailable_groups` so the app renders a disabled group that
-- lights up later with no app change. Real payments = a public.payments table +
-- a Jobber poll job + a client.payments view; its own project.
-- QUOTES ships as the 4th group instead (216 rows, invoice-shaped, free here).
--
-- DATA FACTS BAKED IN (all verified on live Prod before building):
--   * 167 of 438 clients have NO client_code (161 of them ACTIVE/RECURRING) →
--     NAME matching is first-class, never a fallback.
--   * properties.name is blank on 814 of 816 rows → never searched, never a
--     title; the ADDRESS is the title.
--   * invoice_number is NOT unique (7 duplicated) → never used as a key; the row
--     id is the identity and the parent client always accompanies it.
--   * invoices.paid_at is NULL on 100% of rows → never surfaced; date is
--     due_date falling back to sent_at. outstanding_amount > 0 on 172 rows →
--     surfaced as the secondary.
--   * properties repeat addresses (683 rows in same-client duplicate groups,
--     mostly the Jobber billing row) → deduped per (client, address), keeping the
--     row that actually has jobs.
--
-- RANKING: exact client_code, then code prefix, then name prefix, then substring.
-- A PURELY NUMERIC query is ambiguous between an invoice/quote number and the
-- numeric part of a client_code — client_code is weighted higher because that is
-- how staff refer to clients.
--
-- SECURITY: STABLE, SECURITY DEFINER, pinned search_path, read-only.
-- REVOKE from public/anon; GRANT EXECUTE to authenticated + service_role.
-- AUDIT (ADR 010): read-only function; no audit trigger applies.
-- ============================================================================

begin;

drop function if exists client.global_search(text, int, int);

create or replace function client.global_search(
  q                  text,
  p_limit            int     default 5,
  p_offset           int     default 0,
  p_groups           text[]  default null,
  p_include_inactive boolean default false
)
returns jsonb
language sql
stable
security definer
set search_path = client, public, pg_temp
as $$
with params as (
  select btrim(coalesce(q, ''))              as raw,
         '%' || btrim(coalesce(q, '')) || '%' as contains,
         btrim(coalesce(q, '')) || '%'        as prefix,
         greatest(coalesce(p_limit, 5), 1)    as lim,
         greatest(coalesce(p_offset, 0), 0)   as off,
         (btrim(coalesce(q, '')) ~ '^[0-9]+$') as is_numeric
    from (select 1) _
   where length(btrim(coalesce(q, ''))) >= 2
),
want as (
  select p_groups is null or 'clients'    = any(p_groups) as g_clients,
         p_groups is null or 'properties' = any(p_groups) as g_properties,
         p_groups is null or 'invoices'   = any(p_groups) as g_invoices,
         p_groups is null or 'quotes'     = any(p_groups) as g_quotes
),
-- CLIENTS ---------------------------------------------------------------------
c_all as (
  select c.id, c.name as title,
         nullif(concat_ws(' · ', c.client_code, c.status), '') as subtitle,
         c.status as badge,
         (case when c.balance > 0 then c.balance end) as amount,
         null::date as occurred_on,
         c.id as client_id, c.name as client_name, c.client_code,
         case
           when upper(coalesce(c.client_code,'')) = upper(p.raw)        then 0
           when c.client_code ilike p.prefix                            then 1
           when p.is_numeric and split_part(coalesce(c.client_code,''),'-',1) = p.raw then 1
           when c.name ilike p.prefix                                   then 2
           else 3
         end as rank
    from public.clients c cross join params p cross join want w
   where w.g_clients
     and (p_include_inactive or c.status <> 'INACTIVE')
     and (c.name ilike p.contains or c.client_code ilike p.contains)
),
-- PROPERTIES (deduped per client+address, keeping the row that has jobs) -------
p_dedup as (
  select distinct on (pr.client_id, lower(btrim(coalesce(pr.address,''))))
         pr.id, pr.client_id, pr.address, pr.city, pr.state, pr.zip, pr.county,
         pr.is_billing, pr.zone_id,
         (select count(*) from public.jobs j where j.property_id = pr.id) as job_count
    from public.properties pr cross join want w
   where w.g_properties
   order by pr.client_id, lower(btrim(coalesce(pr.address,''))),
            (select count(*) from public.jobs j where j.property_id = pr.id) desc,
            pr.is_primary desc, pr.id
),
p_all as (
  select d.id, d.address as title,
         nullif(concat_ws(', ', d.city, d.state, d.zip), '') as subtitle,
         case when d.is_billing and d.job_count = 0 then 'Billing address'
              else (select z.code from public.zones z where z.id = d.zone_id) end as badge,
         null::numeric as amount, null::date as occurred_on,
         c.id as client_id, c.name as client_name, c.client_code,
         case when d.address ilike p.prefix then 4 else 5 end as rank
    from p_dedup d
    join public.clients c on c.id = d.client_id
    cross join params p
   where d.address ilike p.contains or d.city ilike p.contains
      or d.zip ilike p.contains or d.county ilike p.contains
      or c.name ilike p.contains or c.client_code ilike p.contains
),
-- INVOICES --------------------------------------------------------------------
i_all as (
  select i.id,
         'Invoice #' || coalesce(i.invoice_number::text, i.id::text) as title,
         nullif(i.subject, '') as subtitle,
         i.invoice_status as badge,
         i.total as amount,
         coalesce(i.due_date, i.sent_at::date) as occurred_on,
         c.id as client_id, c.name as client_name, c.client_code,
         case when p.is_numeric and i.invoice_number::text = p.raw then 2 else 6 end as rank
    from public.invoices i
    join public.clients c on c.id = i.client_id
    cross join params p cross join want w
   where w.g_invoices
     and (i.invoice_number::text ilike p.contains or i.subject ilike p.contains
          or c.name ilike p.contains or c.client_code ilike p.contains)
),
-- QUOTES ----------------------------------------------------------------------
qt_all as (
  select qt.id,
         'Quote #' || coalesce(qt.quote_number::text, qt.id::text) as title,
         nullif(qt.title, '') as subtitle,
         qt.quote_status as badge,
         qt.total as amount,
         qt.sent_at::date as occurred_on,
         c.id as client_id, c.name as client_name, c.client_code,
         case when p.is_numeric and qt.quote_number::text = p.raw then 2 else 7 end as rank
    from public.quotes qt
    join public.clients c on c.id = qt.client_id
    cross join params p cross join want w
   where w.g_quotes
     and (p_include_inactive or coalesce(qt.quote_status,'') <> 'archived')
     and (qt.quote_number::text ilike p.contains or qt.title ilike p.contains
          or c.name ilike p.contains or c.client_code ilike p.contains)
),
grp as (
  select 'clients'    as k, (select count(*) from c_all)  as total,
         (select coalesce(jsonb_agg(x order by x_rank, x_title), '[]'::jsonb) from (
            select jsonb_build_object('id',id,'title',title,'subtitle',subtitle,'badge',badge,
                     'amount',amount,'occurred_on',occurred_on,'rank',rank,
                     'client',jsonb_build_object('id',client_id,'name',client_name,'client_code',client_code)) as x,
                   rank as x_rank, title as x_title
              from c_all order by rank, title
             limit (select lim from params) offset (select off from params)) s) as rows
  union all
  select 'properties', (select count(*) from p_all),
         (select coalesce(jsonb_agg(x order by x_rank, x_title), '[]'::jsonb) from (
            select jsonb_build_object('id',id,'title',title,'subtitle',subtitle,'badge',badge,
                     'amount',amount,'occurred_on',occurred_on,'rank',rank,
                     'client',jsonb_build_object('id',client_id,'name',client_name,'client_code',client_code)) as x,
                   rank as x_rank, title as x_title
              from p_all order by rank, title
             limit (select lim from params) offset (select off from params)) s)
  union all
  select 'invoices', (select count(*) from i_all),
         (select coalesce(jsonb_agg(x order by x_rank, x_title), '[]'::jsonb) from (
            select jsonb_build_object('id',id,'title',title,'subtitle',subtitle,'badge',badge,
                     'amount',amount,'occurred_on',occurred_on,'rank',rank,
                     'client',jsonb_build_object('id',client_id,'name',client_name,'client_code',client_code)) as x,
                   rank as x_rank, title as x_title
              from i_all order by rank, title
             limit (select lim from params) offset (select off from params)) s)
  union all
  select 'quotes', (select count(*) from qt_all),
         (select coalesce(jsonb_agg(x order by x_rank, x_title), '[]'::jsonb) from (
            select jsonb_build_object('id',id,'title',title,'subtitle',subtitle,'badge',badge,
                     'amount',amount,'occurred_on',occurred_on,'rank',rank,
                     'client',jsonb_build_object('id',client_id,'name',client_name,'client_code',client_code)) as x,
                   rank as x_rank, title as x_title
              from qt_all order by rank, title
             limit (select lim from params) offset (select off from params)) s)
)
select jsonb_build_object(
  'query', coalesce((select raw from params), btrim(coalesce(q,''))),
  'total_count', coalesce((select sum(total) from grp), 0),
  'groups', coalesce((select jsonb_object_agg(k, jsonb_build_object(
              'total_count', total,
              'has_more', (total > (select off from params) + jsonb_array_length(rows)),
              'rows', rows)) from grp), '{}'::jsonb),
  'unavailable_groups', jsonb_build_array(
     jsonb_build_object('key','payments','label','Payments',
                        'reason','Payments are not synced from Jobber yet'))
);
$$;

revoke all on function client.global_search(text, int, int, text[], boolean) from public;
revoke all on function client.global_search(text, int, int, text[], boolean) from anon;
grant execute on function client.global_search(text, int, int, text[], boolean) to authenticated;
grant execute on function client.global_search(text, int, int, text[], boolean) to service_role;

commit;
