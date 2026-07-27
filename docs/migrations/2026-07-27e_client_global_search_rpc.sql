-- ============================================================================
-- 2026-07-27f — client.global_search: one Jobber-style search RPC for the Client App
-- ============================================================================
-- Fred, 2026-07-27: "On the searchbar I want it to be like Jobber's … where it
-- shows all the data" (his image 3: typing 112-YA returns the client, its
-- addresses, its invoices, a payment — grouped, typed, counted, paginated).
--
-- WHY AN RPC AND NOT 5 PARALLEL SELECTS FROM THE APP: one round trip, one
-- consistent ranking across types, one honest total for "43 results", and the
-- ranking logic lives next to the data instead of being re-implemented in the
-- UI. Corpus is small (438 clients / 816 properties / 2,279 invoices / 1,782
-- jobs / 1,634 visits / 569 contacts ≈ 7.5k rows) so a plain ILIKE scan is
-- comfortably fast; pg_trgm is installed if this ever needs indexes.
--
-- CONTRACT (stable — the app renders straight off these columns):
--   entity_type  'client'|'property'|'invoice'|'job'|'contact'|'visit'
--   entity_id    the row id (route target)
--   title        primary line   e.g. '112-YA Yan''s Restaurant', 'Invoice #2093'
--   subtitle     secondary line e.g. the address, or the parent client
--   client_id/client_code/client_name  ALWAYS the owning client (Jobber shows
--                the parent client under every row) → also the route target
--   amount       invoices/jobs only, else null
--   occurred_on  invoice due date / visit date, else null
--   rank         0 = best. Exact client_code beats prefix beats name beats the
--                rest, so typing a code puts that client first, every time.
--   total_count  total matches across ALL types (window count) → "43 results"
--
-- ⚠ NO PAYMENTS: Jobber's search shows payments; we do not sync a payments
-- table (verified: no public.*payment* relation). Invoices carry
-- outstanding_amount/paid_at, so payment-ish intent is served by the invoice
-- rows. Do not fake a payments group.
--
-- SECURITY: SECURITY DEFINER + pinned search_path, READ-ONLY (a single SELECT).
-- REVOKE ALL then GRANT EXECUTE TO authenticated per the standing convention —
-- anon gets nothing. This is the phase-2 contract shape (RPC, never a writable
-- view) applied to a read path.
-- Soft-deletes filtered on visits. Requires >= 2 chars.
-- AUDIT (ADR 010): read-only function, no audit trigger applies.
-- ============================================================================

begin;

create or replace function client.global_search(
  p_q      text,
  p_limit  int default 20,
  p_offset int default 0
)
returns table (
  entity_type text,
  entity_id   bigint,
  title       text,
  subtitle    text,
  client_id   bigint,
  client_code text,
  client_name text,
  amount      numeric,
  occurred_on date,
  rank        int,
  total_count bigint
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with q as (
    select btrim(coalesce(p_q, '')) as raw
  ),
  params as (
    select raw,
           '%' || raw || '%' as contains,
           raw || '%'        as prefix
      from q
     where length(raw) >= 2
  ),
  hits as (
    -- CLIENTS ---------------------------------------------------------------
    select 'client'::text as entity_type, c.id as entity_id,
           coalesce(nullif(c.client_code,'') || ' ', '') || c.name as title,
           nullif(c.status,'') as subtitle,
           c.id as client_id, c.client_code, c.name as client_name,
           null::numeric as amount, null::date as occurred_on,
           case
             when upper(c.client_code) = upper(p.raw)      then 0
             when c.client_code ilike p.prefix             then 1
             when c.name        ilike p.prefix             then 2
             else 3
           end as rank
      from public.clients c cross join params p
     where c.client_code ilike p.contains or c.name ilike p.contains

    union all
    -- PROPERTIES ------------------------------------------------------------
    -- DISTINCT ON (client, address): a client routinely has TWO property rows at
    -- the same address — one service row and one Jobber BILLING row (372 of
    -- these exist; see 2026-07-27d). Showing both in search is the duplicate
    -- Fred reported, so keep the row that actually has work on it
    -- (job_count desc), then the primary, then the oldest id.
    select 'property', pr.id,
           pr.address,
           nullif(concat_ws(', ', pr.city, pr.state), ''),
           c.id, c.client_code, c.name,
           null::numeric, null::date,
           case when pr.address ilike p.prefix then 4 else 5 end
      from (
        select distinct on (pr0.client_id, lower(btrim(coalesce(pr0.address,''))))
               pr0.*
          from public.properties pr0
         order by pr0.client_id, lower(btrim(coalesce(pr0.address,''))),
                  (select count(*) from public.jobs j where j.property_id = pr0.id) desc,
                  pr0.is_primary desc, pr0.id
      ) pr
      join public.clients c on c.id = pr.client_id
      cross join params p
     -- also match via the PARENT CLIENT so searching a code/name returns that
     -- client's addresses, exactly as Jobber's search does (Fred's image 3
     -- shows 112-YA returning its properties).
     where pr.address ilike p.contains
        or pr.city ilike p.contains
        or c.name ilike p.contains
        or c.client_code ilike p.contains

    union all
    -- INVOICES --------------------------------------------------------------
    select 'invoice', i.id,
           'Invoice #' || coalesce(i.invoice_number::text, i.id::text),
           nullif(i.subject, ''),
           c.id, c.client_code, c.name,
           i.total, i.due_date,
           case when i.invoice_number::text = p.raw then 2 else 6 end
      from public.invoices i
      join public.clients c on c.id = i.client_id
      cross join params p
     where i.invoice_number::text ilike p.contains
        or i.subject ilike p.contains
        or c.name ilike p.contains
        or c.client_code ilike p.contains

    union all
    -- JOBS ------------------------------------------------------------------
    select 'job', j.id,
           'Job #' || coalesce(j.job_number::text, j.id::text),
           nullif(j.title, ''),
           c.id, c.client_code, c.name,
           j.total, null::date,
           case when j.job_number::text = p.raw then 2 else 7 end
      from public.jobs j
      join public.clients c on c.id = j.client_id
      cross join params p
     where j.job_number::text ilike p.contains
        or j.title ilike p.contains
        or c.name ilike p.contains
        or c.client_code ilike p.contains

    union all
    -- CONTACTS --------------------------------------------------------------
    select 'contact', ct.id,
           ct.name,
           nullif(concat_ws(' · ', ct.contact_role, ct.email, ct.phone), ''),
           c.id, c.client_code, c.name,
           null::numeric, null::date,
           8
      from public.client_contacts ct
      join public.clients c on c.id = ct.client_id
      cross join params p
     where ct.name ilike p.contains or ct.email ilike p.contains or ct.phone ilike p.contains

    union all
    -- VISITS ----------------------------------------------------------------
    select 'visit', v.id,
           coalesce(nullif(v.title,''), 'Visit'),
           to_char(v.visit_date, 'Mon DD, YYYY') || ' · ' || coalesce(v.visit_status,''),
           c.id, c.client_code, c.name,
           null::numeric, v.visit_date,
           9
      from public.visits v
      join public.clients c on c.id = v.client_id
      cross join params p
     where v.deleted_at is null
       and (v.title ilike p.contains or v.ticket_number ilike p.contains)
  )
  select h.entity_type, h.entity_id, h.title, h.subtitle,
         h.client_id, h.client_code, h.client_name,
         h.amount, h.occurred_on, h.rank,
         count(*) over ()::bigint as total_count
    from hits h
   order by h.rank, h.entity_type, h.title
   limit greatest(coalesce(p_limit, 20), 1)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

revoke all on function client.global_search(text, int, int) from public;
revoke all on function client.global_search(text, int, int) from anon;
grant execute on function client.global_search(text, int, int) to authenticated;
grant execute on function client.global_search(text, int, int) to service_role;

commit;
