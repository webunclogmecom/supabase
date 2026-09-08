-- ============================================================================
-- 2026-09-08_1300_jobber_invoice_quote_resolve_atomic.sql
--
-- STEP 1 of 2. Close the same create race on INVOICES and QUOTES that was closed for clients
-- this morning. This migration is PURELY PREVENTIVE: it creates two functions and changes no data.
-- The cleanup of the 57 existing ghost invoices and 10 ghost quotes is a SEPARATE migration and
-- must run AFTER this one, because cleaning before the source is fixed just makes room for more.
--
-- Fred, 2026-09-08, after seeing the numbers: "Go ahead, if it will affect only our DB invoice, go
-- ahead and fix it."
--
-- ⚠ HIS PRECONDITION, CHECKED BEFORE ANYTHING ELSE: `webhook-jobber` contains ZERO Jobber
--   mutations. It only ever QUERIES the Jobber GraphQL API and writes to our database. Both this
--   fix and the cleanup that follows are our-database-only. Nothing reaches Jobber.
--
-- ============================================================================
-- THE DEFECT, identical in shape to the client one (2026-09-08_1100)
--
--   handleInvoice (index.ts:1095) and handleQuote (index.ts:1312) each do:
--     findEntityBySourceId(...)   -- SELECT   "not found"
--     .insert(...)                -- INSERT   a row, committed on its own
--     upsertEntityLink(...)       -- INSERT   23505 on idx_esl_source_id
--   Three PostgREST requests are three transactions, so nothing spans them. Concurrent handlers
--   all read "not found", all insert, and the losers throw AFTER their row has committed.
--   upsertEntityLink's onConflict names (entity_type, entity_id, source_system); the index that
--   actually fires is idx_esl_source_id (entity_type, source_system, source_id). Different column
--   sets, so ON CONFLICT cannot absorb it.
--
--   Two drivers since 2026-08-21 (real Jobber webhooks + the */5 poll replay). Measured damage:
--     57 ghost invoices, every one a duplicate of a linked twin
--     10 ghost quotes (newest created 2026-09-08 11:21 ET, twenty minutes after the client fix)
--   client.v_client_billing sums public.invoices with NO link filter, so 10 clients read
--   $7,939.91 too high. Worst: Casa Neos #3071 for $1,400 exists FOUR times.
--
-- ============================================================================
-- WHY THE SHELL HERE IS EMPTIER THAN THE CLIENT ONE
--
-- On public.clients, `name` is NOT NULL, so fn_jobber_resolve_client has to be handed one.
-- On public.invoices and public.quotes the ONLY not-null column is `id`, and it is
-- GENERATED ALWAYS AS IDENTITY. So `insert ... default values` is sufficient and these functions
-- need nothing but the GID. The handler fills the whole payload in the UPDATE immediately after.
--
-- ⚠ Do NOT "improve" these by passing the payload in. The point of the shell is that it claims the
--   identity and nothing else; every column belongs to the handler, which already has the Jobber
--   response in hand and one code path for both the create and the update case.
--
-- ⚠ TWO EXPLICIT FUNCTIONS, NOT ONE GENERIC ONE WITH DYNAMIC SQL. A single
--   fn_jobber_resolve(entity_type, gid) would need `execute format(...)` against a table name.
--   These are billing tables; an explicit function per table has no injection surface at all and
--   reads plainly in `pg_get_functiondef`. The duplication is deliberate.
--
-- ⚠ THE FAST PATH TAKES NO LOCK. Measured over 30 days: 1,994 INVOICE_UPDATEs against 162 creates,
--   1,116 QUOTE_UPDATEs against 28 creates. Locking every update would serialise the poll for no
--   benefit; only the create path pays.
--
-- ⚠ THESE USE THE PLAIN `supabase` CLIENT IN THE HANDLER, NOT `supabaseJobber`. That is existing
--   behaviour and is left alone: invoices and quotes carry no audit trigger at all (only
--   trg_*_updated_at), so there is no app_source attribution to preserve here the way there was
--   for clients. See the cleanup migration for why that makes its JSON backup load-bearing.
--
-- Audit: N/A. This migration creates two functions and modifies no rows.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. INVOICES
-- ---------------------------------------------------------------------------
create or replace function public.fn_jobber_resolve_invoice(p_gid text)
returns table (entity_id bigint, was_created boolean)
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_id bigint;
begin
  if p_gid is null or pg_catalog.btrim(p_gid) = '' then
    raise exception 'fn_jobber_resolve_invoice: p_gid is required';
  end if;

  -- ---- FAST PATH: already linked. No lock. -------------------------------------------------
  -- The overwhelming majority of calls are updates to an invoice we already hold (1,994
  -- INVOICE_UPDATEs in 30 days against 162 creates). Locking those would serialise the poll for
  -- nothing. Only the create path pays.
  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'invoice' and l.source_system = 'jobber' and l.source_id = p_gid;
  if v_id is not null then
    return query select v_id, false;
    return;
  end if;

  -- ---- SLOW PATH: serialise every creator of THIS gid ---------------------------------------
  perform pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended('jobber:invoice:' || p_gid, 0));

  -- 🛑 THIS RE-READ IS THE FIX. The first read happened BEFORE the lock, so it saw the world as
  -- it was before the winner committed. This one happens after, and it is the only reason the
  -- loser stops instead of inserting a duplicate.
  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'invoice' and l.source_system = 'jobber' and l.source_id = p_gid;
  if v_id is not null then
    return query select v_id, false;
    return;
  end if;

  -- Only `id` is NOT NULL on public.invoices (GENERATED ALWAYS AS IDENTITY), so the shell needs
  -- no columns at all. handleInvoice fills the whole payload in the UPDATE immediately after.
  insert into public.invoices default values returning id into v_id;

  -- Same transaction as the row above: if this fails the invoice goes with it and the caller gets
  -- an error instead of a ghost. That is the entire point.
  insert into public.entity_source_links
         (entity_type, entity_id, source_system, source_id,
          match_method, match_confidence, synced_at)
       values ('invoice', v_id, 'jobber', p_gid, 'webhook', 1.0, pg_catalog.now());

  return query select v_id, true;
end
$fn$;

comment on function public.fn_jobber_resolve_invoice(text) is
  'Atomically resolve a Jobber invoice GID to our invoices.id, creating a shell row + its '
  'entity_source_links row together if new. Returns (entity_id, was_created). Serialised per GID '
  'by a transaction-scoped advisory lock, which makes a duplicate IMPOSSIBLE rather than merely '
  'detected. Before 2026-09-08 handleInvoice did SELECT then INSERT then link as three separate '
  'PostgREST requests and concurrent handlers produced 57 ghost invoices, every one a duplicate of '
  'a linked twin, overstating 10 clients billing totals by $7,939.91. Mirrors '
  'public.fn_jobber_resolve_client.';

revoke all on function public.fn_jobber_resolve_invoice(text) from public;
revoke all on function public.fn_jobber_resolve_invoice(text) from anon;
revoke all on function public.fn_jobber_resolve_invoice(text) from authenticated;
grant execute on function public.fn_jobber_resolve_invoice(text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. QUOTES
-- ---------------------------------------------------------------------------
create or replace function public.fn_jobber_resolve_quote(p_gid text)
returns table (entity_id bigint, was_created boolean)
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_id bigint;
begin
  if p_gid is null or pg_catalog.btrim(p_gid) = '' then
    raise exception 'fn_jobber_resolve_quote: p_gid is required';
  end if;

  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'quote' and l.source_system = 'jobber' and l.source_id = p_gid;
  if v_id is not null then
    return query select v_id, false;
    return;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended('jobber:quote:' || p_gid, 0));

  -- the re-read after the lock, same as above
  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'quote' and l.source_system = 'jobber' and l.source_id = p_gid;
  if v_id is not null then
    return query select v_id, false;
    return;
  end if;

  insert into public.quotes default values returning id into v_id;

  insert into public.entity_source_links
         (entity_type, entity_id, source_system, source_id,
          match_method, match_confidence, synced_at)
       values ('quote', v_id, 'jobber', p_gid, 'webhook', 1.0, pg_catalog.now());

  return query select v_id, true;
end
$fn$;

comment on function public.fn_jobber_resolve_quote(text) is
  'Atomically resolve a Jobber quote GID to our quotes.id, creating a shell row + its '
  'entity_source_links row together if new. Returns (entity_id, was_created). Same shape and same '
  'reason as public.fn_jobber_resolve_invoice; the quote race produced 10 ghost quotes, the newest '
  'at 2026-09-08 11:21 ET.';

revoke all on function public.fn_jobber_resolve_quote(text) from public;
revoke all on function public.fn_jobber_resolve_quote(text) from anon;
revoke all on function public.fn_jobber_resolve_quote(text) from authenticated;
grant execute on function public.fn_jobber_resolve_quote(text) to service_role;

commit;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_id1 bigint; v_id2 bigint; v_c1 boolean; v_c2 boolean;
  v_real_gid text; v_real_id bigint;
  v_fake  text := 'VERIFY_2026-09-08_1300_fake_invoice_gid';
  v_fakeq text := 'VERIFY_2026-09-08_1300_fake_quote_gid';
  v_body  text; v_before bigint; v_after bigint;
begin
  -- ---- INVOICES -----------------------------------------------------------------------------
  -- 1. fast path against a REAL linked invoice: resolves, and does NOT report itself as new
  select l.source_id, l.entity_id into v_real_gid, v_real_id
    from public.entity_source_links l
   where l.entity_type='invoice' and l.source_system='jobber'
   order by l.entity_id desc limit 1;
  if v_real_gid is null then
    raise exception 'VERIFY 0 FAILED: no linked invoice exists to test the fast path against';
  end if;

  select r.entity_id, r.was_created into v_id1, v_c1
    from public.fn_jobber_resolve_invoice(v_real_gid) r;
  if v_id1 <> v_real_id then
    raise exception 'VERIFY 1 FAILED: real invoice gid resolved to %, expected %', v_id1, v_real_id;
  end if;
  if v_c1 then
    raise exception 'VERIFY 1b FAILED: an EXISTING invoice was reported as was_created=true';
  end if;

  -- 2. create path: a fresh gid creates exactly ONE invoice, and a second call ADOPTS it.
  --    Scoped to the probe, never a whole-table count: the */5 poll inserts real invoices while
  --    this runs and a table delta would fail for a reason that has nothing to do with the fix.
  select count(*) into v_before from public.entity_source_links
   where entity_type='invoice' and source_id = v_fake;

  select r.entity_id, r.was_created into v_id1, v_c1
    from public.fn_jobber_resolve_invoice(v_fake) r;
  if not v_c1 then raise exception 'VERIFY 2 FAILED: a brand new invoice gid did not report was_created=true'; end if;

  select r.entity_id, r.was_created into v_id2, v_c2
    from public.fn_jobber_resolve_invoice(v_fake) r;
  if v_id2 <> v_id1 then
    raise exception 'VERIFY 2b FAILED: second call returned % but first returned % -- NOT idempotent', v_id2, v_id1;
  end if;
  if v_c2 then
    raise exception 'VERIFY 2c FAILED: second call reported was_created=true; it would have duplicated';
  end if;

  select count(*) into v_after from public.entity_source_links
   where entity_type='invoice' and source_id = v_fake;
  if v_after <> v_before + 1 then
    raise exception 'VERIFY 2d FAILED: two calls made % links, expected exactly 1', v_after - v_before;
  end if;

  -- 3. the link exists for the shell, written in the SAME transaction as the row
  if not exists (select 1 from public.entity_source_links
                  where entity_type='invoice' and source_system='jobber'
                    and source_id=v_fake and entity_id=v_id1) then
    raise exception 'VERIFY 3 FAILED: invoice % created with NO link -- the ghost bug is still live', v_id1;
  end if;

  -- 4. CLEAN UP. A positive control on a write path COMMITS; a probe left in public.invoices is a
  --    fake billing row. line_items.invoice_id is ON DELETE SET NULL, so assert none attached
  --    rather than trusting that a shell has none.
  if exists (select 1 from public.line_items where invoice_id = v_id1) then
    raise exception 'VERIFY 4 FAILED: probe invoice % somehow has line items; refusing to delete', v_id1;
  end if;
  delete from public.entity_source_links
   where entity_type='invoice' and source_system='jobber' and source_id=v_fake;
  delete from public.invoices where id = v_id1;
  if exists (select 1 from public.invoices where id = v_id1) then
    raise exception 'VERIFY 4b FAILED: probe invoice % survived cleanup', v_id1;
  end if;

  -- ---- QUOTES -------------------------------------------------------------------------------
  select r.entity_id, r.was_created into v_id1, v_c1 from public.fn_jobber_resolve_quote(v_fakeq) r;
  if not v_c1 then raise exception 'VERIFY 5 FAILED: a brand new quote gid did not report was_created=true'; end if;
  select r.entity_id, r.was_created into v_id2, v_c2 from public.fn_jobber_resolve_quote(v_fakeq) r;
  if v_id2 <> v_id1 or v_c2 then
    raise exception 'VERIFY 5b FAILED: quote resolve is not idempotent (% vs %, created=%)', v_id2, v_id1, v_c2;
  end if;
  if not exists (select 1 from public.entity_source_links
                  where entity_type='quote' and source_id=v_fakeq and entity_id=v_id1) then
    raise exception 'VERIFY 5c FAILED: quote % created with NO link', v_id1;
  end if;
  delete from public.entity_source_links where entity_type='quote' and source_id=v_fakeq;
  delete from public.quotes where id = v_id1;
  if exists (select 1 from public.quotes where id = v_id1) then
    raise exception 'VERIFY 5d FAILED: probe quote survived cleanup';
  end if;

  -- 6. NEGATIVE CONTROL: a blank gid is refused rather than silently creating a row
  begin
    perform * from public.fn_jobber_resolve_invoice('   ');
    raise exception 'VERIFY 6 FAILED: a blank gid was accepted';
  exception when others then
    if sqlerrm not like '%p_gid is required%' then
      raise exception 'VERIFY 6b FAILED: blank gid raised the wrong error: %', sqlerrm;
    end if;
  end;

  -- 7. THE LOCK IS IN BOTH SHIPPED BODIES. Comments are stripped first, because the comments
  --    above NAME the lock and would satisfy this assertion on their own.
  for v_body in
    select pg_get_functiondef(p.oid)
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'
       and p.proname in ('fn_jobber_resolve_invoice','fn_jobber_resolve_quote')
  loop
    if (select coalesce(string_agg(l, e'\n'), '')
          from unnest(string_to_array(v_body, e'\n')) l
         where btrim(l) not like '--%') not like '%pg_advisory_xact_lock%' then
      raise exception 'VERIFY 7 FAILED: a resolve function has no advisory lock in its body';
    end if;
  end loop;

  -- 8. not reachable by the browser roles
  if has_function_privilege('anon','public.fn_jobber_resolve_invoice(text)','EXECUTE')
     or has_function_privilege('authenticated','public.fn_jobber_resolve_invoice(text)','EXECUTE')
     or has_function_privilege('anon','public.fn_jobber_resolve_quote(text)','EXECUTE')
     or has_function_privilege('authenticated','public.fn_jobber_resolve_quote(text)','EXECUTE') then
    raise exception 'VERIFY 8 FAILED: anon or authenticated can execute a resolve function';
  end if;
  if not has_function_privilege('service_role','public.fn_jobber_resolve_invoice(text)','EXECUTE')
     or not has_function_privilege('service_role','public.fn_jobber_resolve_quote(text)','EXECUTE') then
    raise exception 'VERIFY 8b FAILED: service_role cannot execute one of them -- the webhook would break';
  end if;

  -- 9. NOTHING WAS LEFT BEHIND. Both tables are billing surfaces; a stray probe row is real damage.
  if exists (select 1 from public.entity_source_links where source_id in (v_fake, v_fakeq)) then
    raise exception 'VERIFY 9 FAILED: a probe link survived';
  end if;

  raise notice 'VERIFY ok: both resolve functions are idempotent, create exactly one row+link, refuse a blank gid, hold an xact advisory lock, are closed to anon/authenticated, and left no probe rows behind';
end
$verify$;
