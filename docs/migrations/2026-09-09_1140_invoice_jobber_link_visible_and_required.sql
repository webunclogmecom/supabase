-- ============================================================================
-- 2026-09-09_1140_invoice_jobber_link_visible_and_required.sql
--
-- Two of the three things Fred asked for. The third (the cron) is 2026-09-09_1200.
--
-- Fred, 2026-09-09: "you would need a plan for a good link between our DB invoice data to the
-- Jobber invoice. So we don't get dupes, we stay syncd (cron job), and if i need to double check
-- with Jobber is simple."
--
--   "simple to double check"  -> PART 1: client.invoices gains jobber_invoice_id + jobber_url
--   "we don't get dupes"      -> PART 2: an unlinked invoice becomes IMPOSSIBLE, not just detectable
--   "we stay syncd (cron)"    -> the next migration
--
-- ⚠ **BILLING SETTINGS UNTOUCHED**, per his instruction: `jobs.billing_type`,
--   `jobs.invoice_frequency`, `jobs.invoice_rrule` are not referenced anywhere in this file.
--
-- ============================================================================
-- PART 1 -- WHY THIS WAS MISSING AND WHY IT MATTERS
--
-- `client.clients`, `client.visits` and `client.jobs` all expose a `jobber_url`. **`client.invoices`
-- was the only major entity you could not click through to**, which is precisely the entity where
-- "let me check Jobber" is the most common question, because it is the money.
--
-- The identity itself has always been there -- `entity_source_links (entity_type='invoice',
-- source_system='jobber', source_id=<base64 GID>)` -- it was simply not surfaced anywhere a person
-- looks. This exposes it two ways: the numeric id (searchable, quotable in a message) and a URL.
--
-- ⚠ **THE CASE IS INLINED RATHER THAN FACTORED INTO A HELPER, ON PURPOSE.** Five views already
--   carry this exact expression. A shared SECURITY INVOKER function called from inside an
--   owner-rights view adds an invoker-side EXECUTE check to the view's read path, which has broken
--   a read for a low-privilege role **five separate times** in this repo (see CLAUDE.md, "Grants,
--   views and functions -- the asymmetry that has bitten three times", since updated to five).
--   Matching the existing five copies is the boring, safe choice here.
--
-- ⚠ **COLUMNS ARE APPENDED, NEVER INSERTED.** `create or replace view` can only ADD columns at the
--   end; renaming or reordering raises 42P16. The 16 existing columns are restated in their exact
--   current order and the two new ones go last.
--
-- ============================================================================
-- PART 2 -- MAKING A GHOST IMPOSSIBLE RATHER THAN DETECTABLE
--
-- 2026-09-08 fixed the RACE that created unlinked invoices (fn_jobber_resolve_invoice writes the
-- row and its link in ONE transaction). 2026-09-09_1045 removed the last of them, so the population
-- is **zero for the first time**, which is what makes a constraint possible at all.
--
-- But the race was only one way in. **Nothing stops a raw `INSERT INTO public.invoices`** from a
-- script, a migration, or a future edge function, and such a row is invisible to every sync path
-- while still being counted by `ops.v_ar_aging` and `client.v_client_billing`. That is exactly how
-- $35,801.90 of phantom receivable happened.
--
-- ⇒ **`trg_zz_invoice_requires_jobber_link`**: a DEFERRABLE INITIALLY DEFERRED constraint trigger.
--   Deferred is load-bearing -- `fn_jobber_resolve_invoice` inserts the invoice BEFORE its link, so
--   an immediate trigger would refuse the very function that does it correctly.
--
-- ⚠ Only `public.invoices` may originate from Jobber-and-nowhere-else, which is why this guard is
--   safe here and would NOT be safe on `public.visits`: **520 alive visits legitimately carry no
--   Jobber link** (SA generation creates them here and pushes them later). Do not copy this trigger
--   to visits without re-measuring. Invoices are the only entity where "no link" is always wrong.
--
-- ⚠ It guards INSERT only. Deleting a link out from under an existing invoice would also orphan it,
--   but that is a deliberate, rare act on a shared 15-entity-type table, and a trigger there would
--   be far broader than this problem. Left as a known gap, covered by the drift check.
--
-- Audit: no audit trigger on public.invoices (unchanged by this migration). No data rows are
-- modified here: this is one view replace, one function, one trigger.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- PART 1. the click-through
-- ---------------------------------------------------------------------------
create or replace view client.invoices as
 select id,
    client_id,
    job_id,
    invoice_number,
    subject,
    subtotal,
    tax_amount,
    total,
    outstanding_amount,
    deposit_amount,
    invoice_status,
    due_date,
    sent_at,
    paid_at,
    created_at,
    updated_at,
    -- ---- appended 2026-09-09 ------------------------------------------------------------
    ( select case
               when l.source_id ~ '^[0-9]+$' then l.source_id
               when length(l.source_id) % 4 = 0 and l.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'
                 then split_part(convert_from(decode(l.source_id, 'base64'), 'UTF8'), '/', -1)
               else null
             end
        from entity_source_links l
       where l.entity_type = 'invoice' and l.source_system = 'jobber' and l.entity_id = invoices.id
       limit 1) as jobber_invoice_id,
    ( select case
               when l.source_id ~ '^[0-9]+$'
                 then 'https://secure.getjobber.com/invoices/' || l.source_id
               when length(l.source_id) % 4 = 0 and l.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'
                 then 'https://secure.getjobber.com/invoices/'
                      || split_part(convert_from(decode(l.source_id, 'base64'), 'UTF8'), '/', -1)
               else null
             end
        from entity_source_links l
       where l.entity_type = 'invoice' and l.source_system = 'jobber' and l.entity_id = invoices.id
       limit 1) as jobber_url
   from invoices;

comment on view client.invoices is
  'Client App invoice surface. jobber_invoice_id and jobber_url were appended 2026-09-09 so an '
  'invoice can be checked against Jobber in one click; invoices were the only major entity without '
  'them. Both read public.entity_source_links, which is the ONLY thing tying one of our invoices to '
  'a Jobber invoice -- public.invoices has no jobber id column by design (workspace rule 1).';

-- ---------------------------------------------------------------------------
-- PART 2. the guard
-- ---------------------------------------------------------------------------
create or replace function public.fn_invoice_requires_jobber_link()
returns trigger
language plpgsql
security definer
set search_path to ''
as $fn$
begin
  if not exists (select 1 from public.entity_source_links e
                  where e.entity_type = 'invoice'
                    and e.source_system = 'jobber'
                    and e.entity_id = new.id) then
    raise exception
      using errcode = '23514',
            message = format('invoice %s was created with no Jobber link', new.id),
            hint    = 'Every invoice originates in Jobber. Create it through '
                   || 'public.fn_jobber_resolve_invoice(<base64 gid>), which writes the row and its '
                   || 'entity_source_links row in the SAME transaction. An unlinked invoice is '
                   || 'unreachable by every sync path -- it can never be updated or re-linked -- '
                   || 'while still being counted by ops.v_ar_aging and client.v_client_billing.';
  end if;
  return null;
end
$fn$;

comment on function public.fn_invoice_requires_jobber_link() is
  'Refuses an invoice that reaches COMMIT with no Jobber entity_source_links row. Deferred, because '
  'fn_jobber_resolve_invoice legitimately inserts the invoice before its link. Added 2026-09-09 '
  'after the create race produced 63 unlinked invoices carrying $35,801.90 of phantom receivable.';

drop trigger if exists trg_zz_invoice_requires_jobber_link on public.invoices;
create constraint trigger trg_zz_invoice_requires_jobber_link
  after insert on public.invoices
  deferrable initially deferred
  for each row execute function public.fn_invoice_requires_jobber_link();

commit;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_n bigint; v_url text; v_id text; v_raised boolean;
begin
  -- 1. the view exposes both columns and they resolve for a real invoice
  select jobber_invoice_id, jobber_url into v_id, v_url
    from client.invoices where id = 1617;
  if v_id is null or v_url is null then
    raise exception 'VERIFY 1 FAILED: invoice 1617 has no jobber id/url (%, %)', v_id, v_url;
  end if;
  if v_url <> 'https://secure.getjobber.com/invoices/153894341' then
    raise exception 'VERIFY 1b FAILED: unexpected url %', v_url;
  end if;

  -- 2. every invoice resolves one, since the population is fully linked
  select count(*) into v_n from client.invoices where jobber_url is null;
  if v_n <> 0 then
    raise exception 'VERIFY 2 FAILED: % invoice(s) produce a NULL jobber_url', v_n;
  end if;

  -- 3. the 16 original columns survived the replace, in order, with the 2 appended LAST
  select count(*) into v_n from information_schema.columns
   where table_schema='client' and table_name='invoices';
  if v_n <> 18 then
    raise exception 'VERIFY 3 FAILED: client.invoices has % columns, expected 18', v_n;
  end if;
  if (select column_name from information_schema.columns
       where table_schema='client' and table_name='invoices' and ordinal_position=17) <> 'jobber_invoice_id'
     or (select column_name from information_schema.columns
          where table_schema='client' and table_name='invoices' and ordinal_position=18) <> 'jobber_url' then
    raise exception 'VERIFY 3b FAILED: the new columns are not last';
  end if;

  -- 4. 🛑 THE GUARD ACTUALLY BITES. A constraint trigger is DEFERRED, so without
  --    SET CONSTRAINTS ALL IMMEDIATE the check never runs inside this savepoint and the probe
  --    returns a confident ACCEPTED. That exact mistake has produced a false all-clear in this
  --    repo before.
  v_raised := false;
  begin
    insert into public.invoices (invoice_number, total, invoice_status)
         values ('VERIFY_2026-09-09_no_link', 0, 'draft');
    set constraints all immediate;
    raise exception 'VERIFY 4 FAILED: an invoice with no Jobber link was ACCEPTED';
  exception
    when check_violation then v_raised := true;
    when others then
      if sqlerrm like '%VERIFY 4 FAILED%' then raise; end if;
      raise exception 'VERIFY 4b FAILED: wrong error from the guard: %', sqlerrm;
  end;
  if not v_raised then
    raise exception 'VERIFY 4c FAILED: the guard did not raise';
  end if;
  set constraints all deferred;

  -- 5. POSITIVE CONTROL: the sanctioned path still works end to end, and cleans up after itself.
  --    Without this, VERIFY 4 alone is satisfied by a trigger that refuses EVERYTHING.
  declare
    v_new bigint; v_created boolean;
    v_gid text := 'VERIFY_2026-09-09_1140_guard_probe_gid';
  begin
    select entity_id, was_created into v_new, v_created
      from public.fn_jobber_resolve_invoice(v_gid);
    if not v_created or v_new is null then
      raise exception 'VERIFY 5 FAILED: the resolve function did not create a row';
    end if;
    set constraints all immediate;   -- must NOT raise: this row has its link
    set constraints all deferred;
    delete from public.entity_source_links
     where entity_type='invoice' and source_system='jobber' and source_id = v_gid;
    delete from public.invoices where id = v_new;
    if exists (select 1 from public.invoices where id = v_new) then
      raise exception 'VERIFY 5b FAILED: probe invoice % survived cleanup', v_new;
    end if;
  end;

  -- 6. nothing was left behind by either probe
  select count(*) into v_n from public.invoices
   where invoice_number = 'VERIFY_2026-09-09_no_link'
      or (invoice_number is null and total is null and invoice_status is null and client_id is null);
  if v_n <> 0 then
    raise exception 'VERIFY 6 FAILED: % probe row(s) survive', v_n;
  end if;

  -- 7. the invariant still holds after all that
  select count(*) into v_n from public.invoices i
   where not exists (select 1 from public.entity_source_links e
                      where e.entity_type='invoice' and e.entity_id=i.id and e.source_system='jobber');
  if v_n <> 0 then
    raise exception 'VERIFY 7 FAILED: % unlinked invoice(s)', v_n;
  end if;

  raise notice 'VERIFY ok: client.invoices exposes jobber_invoice_id + jobber_url (18 cols, new ones last, 0 NULL), the guard REFUSES an unlinked insert and ACCEPTS one made through fn_jobber_resolve_invoice, no probe rows left, 0 unlinked invoices';
end
$verify$;
