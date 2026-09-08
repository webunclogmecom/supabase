-- ============================================================================
-- 2026-09-08_1330_remove_jobber_invoice_quote_ghosts.sql
--
-- STEP 2 of 2. Remove the 57 ghost invoices and 10 ghost quotes, now that the race that made
-- them is closed. MUST run AFTER 2026-09-08_1300, which is what stops new ones appearing.
--
-- Fred: "Go ahead, if it will affect only our DB invoice, go ahead and fix it."
-- ⚠ His precondition holds: webhook-jobber has ZERO Jobber mutations, so nothing here or in the
--   migration before it reaches Jobber. Jobber's own invoices are untouched and remain the truth.
--
-- ============================================================================
-- WHAT A GHOST IS, AND WHY IT IS SAFE TO REMOVE
--
-- A row in public.invoices / public.quotes with NO entity_source_links row for Jobber. Every sync
-- path resolves a Jobber object through that table, so a ghost can never be found again: it cannot
-- receive an update, cannot be re-linked, and is frozen at the moment it was orphaned.
--
-- Verified before writing this, against JOBBER ITSELF and not just our own database:
--   * 57 ghost invoices, each paired with the LINKED row we keep. For all 57 the row we KEEP was
--     fetched from Jobber by its GID and its total MATCHES Jobber exactly. 57/57.
--   * 51 distinct Jobber invoices behind those 57 ghosts (some invoices were duplicated more than
--     once: Casa Neos #3071 for $1,400 exists FOUR times, ids 2570-2573).
--   * 38 of the ghosts are STALE relative to their twin (an older status or total). That is the
--     expected signature of a ghost, not a fault: it stopped receiving updates the moment it was
--     orphaned. An earlier version of the check scored staleness as a problem and manufactured 18
--     false positives; the rule being tested is "the row we KEEP equals Jobber", not "the ghost does".
--   * NEGATIVE CONTROL: a fabricated invoice GID comes back missing from Jobber, so the check can
--     actually detect absence rather than passing on everything.
--   * 0 ghosts have a NULL invoice_number, 0 have a NULL client_id, 0 match more than one linked
--     row, and 0 match none. Same for the 10 ghost quotes.
--
-- 🛑 IN 4 OF THE 57 THE GHOST WAS CREATED **BEFORE** THE ROW WE KEEP.
--    So "keep the oldest" would have deleted the RIGHT row four times. Creation order does not
--    identify the good row. THE LINK DOES, and that is the only thing this migration keys on.
--
-- ============================================================================
-- 🛑 THE DELETE HAZARD THAT DOES NOT ANNOUNCE ITSELF
--
-- `line_items.invoice_id` is **ON DELETE SET NULL**. Deleting an invoice that HAS line items would
-- neither block nor cascade: it would silently NULL them and leave orphaned line items behind, and
-- nothing would report it. Measured on this exact set, with a positive control:
--     line_items on the 57 ghosts .................. 0
--     visits    on the 57 ghosts .................. 0
--     jobs / line_items on the 10 ghost quotes .... 0 / 0
--     CONTROL: line_items on the LINKED twins ..... 97   <- so the probe can see line items
-- The VERIFY below counts orphaned line items before and after and refuses if the number moves.
-- ⚠ ANYONE REUSING THIS CLEANUP ON A DIFFERENT SET MUST RE-RUN THAT CHECK. The FK will not stop them.
--
-- ⚠ THERE IS NO AUDIT TRIGGER ON public.invoices OR public.quotes. Unlike public.clients, which
--   carries audit_clients and therefore logged every DELETE with its full old_row, these two tables
--   have only trg_*_updated_at. **The JSON backup is the ONLY record of what was removed.**
--   Taken first, to backups/2026-09-08_jobber_invoice_quote_ghosts.json, full column dumps with
--   explicit ids so the rows can be re-inserted verbatim.
--
-- ⚠ NEITHER TABLE HAS A deleted_at COLUMN, so soft-delete is not available here. The house rule
--   protects customer records; these are duplicate rows that no sync can reach, carrying nothing.
--
-- ============================================================================
-- WHAT CHANGES ON SCREEN
--
-- client.v_client_billing sums public.invoices with no link filter, so today it counts ghosts.
-- After this migration 10 clients read correctly for the first time since 2026-08-21:
--   009-CN  Casa Neos ............................ -$4,200.00
--   062-TCE The carrot express Aventura Mall ..... -$1,136.25
--   186-PV  Pura Vida Coconut Grove .............. -$975.00
--   051-PV  Pura Vida Delray ..................... -$700.00
--   139-LTG Lettuce and Tomato ................... -$515.58
--   137-BB  Bagel Boss Aventura .................. -$413.08
--   plus 315-CAP, 222-SPE, 242-WYN, 249-LOU at $0.00 (duplicate rows with a zero total)
-- Total overstatement removed: $7,939.91. The other 42 ghosts are drafts, which that view already
-- excludes, so they were invisible on screen and are removed for correctness rather than for money.
-- client.v_client_past_due is NOT affected: it keys on Jobber's invoice_status, not on our sums.
--
-- 🛑 AND THE LARGER SURFACE, FOUND LAST AND NOT IN THE FIRST REPORT: ops.v_ar_aging.
--    The accounts-receivable aging report also sums public.invoices with no link filter, and it
--    reads `balance_due`, which the billing view does not. Measured:
--        AR balance due, today .................... $157,643.63   (228 rows)
--        of which ghosts .......................... $ 35,801.90   ( 48 rows, 38 clients)
--        AR balance due after this migration ...... $121,841.73
--        worst single client: 021-GRA Granada Condo, overstated by $6,187.00
--    That is 23% of the reported receivable, and it is a bigger and more consequential number
--    than the $7,939.91 of billed totals: it is money the business thinks it is owed.
--    ops.v_revenue_summary sums invoices without a link filter too.
--    ⚠ THE FIRST REPORT OF THIS DEFECT QUOTED ONLY THE $7,939.91. That was the billed-total
--      figure from client.v_client_billing and it was correct for that view, but it was not the
--      whole exposure, because only one consumer had been checked. Enumerate the consumers before
--      quantifying the damage, not after.
--
-- Audit: no audit trigger on these tables (see above). The backup file is the record.
-- ============================================================================

begin;

do $cleanup$
declare
  v_inv         bigint[];
  v_qt          bigint[];
  v_n           bigint;
  v_orphan_li_before bigint;
  v_orphan_li_after  bigint;
  v_deleted     bigint;
  v_bill_before numeric;
  v_bill_after  numeric;
  v_expected_drop numeric;
  v_affected    bigint[];
  r_ent         record;
begin
  -- ---- 1. DERIVE both sets from the invariant. Never a hardcoded id list. ------------------
  select array_agg(i.id order by i.id) into v_inv
    from public.invoices i
   where not exists (select 1 from public.entity_source_links e
                      where e.entity_type='invoice' and e.entity_id=i.id and e.source_system='jobber')
     and i.created_at >= timestamptz '2026-08-21 00:00:00+00';

  select array_agg(q.id order by q.id) into v_qt
    from public.quotes q
   where not exists (select 1 from public.entity_source_links e
                      where e.entity_type='quote' and e.entity_id=q.id and e.source_system='jobber')
     and q.created_at >= timestamptz '2026-08-21 00:00:00+00';

  -- ---- 2. REFUSE IF THE WORLD MOVED SINCE THE AUDIT ----------------------------------------
  -- The audited set was 57 invoices and 10 quotes, verified against Jobber row by row. If the
  -- counts differ, something changed between the audit and this run and the Jobber verification
  -- no longer covers the whole set. Stop rather than delete a row nobody checked.
  if coalesce(cardinality(v_inv), 0) <> 57 then
    raise exception 'REFUSING: found % ghost invoices, audited 57. Re-run the Jobber verification before deleting.',
      coalesce(cardinality(v_inv), 0);
  end if;
  if coalesce(cardinality(v_qt), 0) <> 10 then
    raise exception 'REFUSING: found % ghost quotes, audited 10.', coalesce(cardinality(v_qt), 0);
  end if;

  -- ---- 3. EVERY GHOST MUST STILL HAVE EXACTLY ONE LINKED TWIN -------------------------------
  -- This is the claim the whole delete rests on. Re-checked at apply time, not taken on trust.
  select count(*) into v_n from public.invoices g
   where g.id = any(v_inv)
     and (select count(*) from public.invoices k
            join public.entity_source_links e
              on e.entity_type='invoice' and e.source_system='jobber' and e.entity_id=k.id
           where k.invoice_number is not distinct from g.invoice_number and k.id <> g.id) <> 1;
  if v_n > 0 then
    raise exception 'REFUSING: % ghost invoice(s) no longer have exactly one linked twin', v_n;
  end if;

  select count(*) into v_n from public.quotes g
   where g.id = any(v_qt)
     and (select count(*) from public.quotes k
            join public.entity_source_links e
              on e.entity_type='quote' and e.source_system='jobber' and e.entity_id=k.id
           where k.quote_number is not distinct from g.quote_number and k.id <> g.id) <> 1;
  if v_n > 0 then
    raise exception 'REFUSING: % ghost quote(s) no longer have exactly one linked twin', v_n;
  end if;

  -- ---- 4. NO GHOST MAY HAVE ACQUIRED A LINK ------------------------------------------------
  -- Belt and braces: the derivation already excludes linked rows, but a concurrent poll could
  -- link one between the derivation and the delete. Re-assert immediately before writing.
  if exists (select 1 from public.entity_source_links
              where entity_type='invoice' and entity_id = any(v_inv))
     or exists (select 1 from public.entity_source_links
                 where entity_type='quote' and entity_id = any(v_qt)) then
    raise exception 'REFUSING: a ghost acquired a source link mid-migration';
  end if;

  -- ---- 5. DEPENDENT SWEEP ACROSS EVERY FK, at apply time -----------------------------------
  -- 🛑 line_items.invoice_id is ON DELETE SET NULL: an invoice WITH line items would be deleted
  --    silently and leave them orphaned. The FK will not stop it, so this check must.
  for r_ent in
    select con.conrelid::regclass::text as tbl, a.attname as col, 'invoice' as kind
      from pg_constraint con
      join pg_attribute a on a.attrelid=con.conrelid and a.attnum=con.conkey[1]
     where con.confrelid='public.invoices'::regclass and con.contype='f'
    union all
    select con.conrelid::regclass::text, a.attname, 'quote'
      from pg_constraint con
      join pg_attribute a on a.attrelid=con.conrelid and a.attnum=con.conkey[1]
     where con.confrelid='public.quotes'::regclass and con.contype='f'
  loop
    execute format('select count(*) from %s where %I = any($1)', r_ent.tbl, r_ent.col)
      into v_n using (case when r_ent.kind='invoice' then v_inv else v_qt end);
    if v_n > 0 then
      raise exception 'REFUSING: % row(s) in %.% reference a ghost -- it is NOT debris',
        v_n, r_ent.tbl, r_ent.col;
    end if;
  end loop;

  -- ---- 6. BASELINE THE SET-NULL HAZARD, so the VERIFY can prove it did not fire -------------
  select count(*) into v_orphan_li_before from public.line_items where invoice_id is null;

  -- ---- 6b. BASELINE THE THING A PERSON ACTUALLY SEES ---------------------------------------
  -- The whole point of this migration is that 10 clients read too high. Measure the view itself
  -- before and after, and assert the drop equals exactly the money we are removing. Asserting on
  -- the invoices table alone would prove the rows went, not that the screen got better.
  select array_agg(distinct i.client_id) into v_affected
    from public.invoices i
   where i.id = any(v_inv) and i.client_id is not null
     and coalesce(i.invoice_status,'') <> 'draft';

  select coalesce(sum(i.total), 0) into v_expected_drop
    from public.invoices i
   where i.id = any(v_inv) and i.client_id is not null
     and coalesce(i.invoice_status,'') <> 'draft';

  select coalesce(sum(b.life_total), 0) into v_bill_before
    from client.v_client_billing b where b.client_id = any(v_affected);

  -- ---- 7. delete ---------------------------------------------------------------------------
  delete from public.invoices where id = any(v_inv);
  get diagnostics v_deleted = row_count;
  if v_deleted <> 57 then
    raise exception 'REFUSING: deleted % invoice rows, expected 57', v_deleted;
  end if;

  delete from public.quotes where id = any(v_qt);
  get diagnostics v_deleted = row_count;
  if v_deleted <> 10 then
    raise exception 'REFUSING: deleted % quote rows, expected 10', v_deleted;
  end if;

  -- ---- 8. and prove the SET NULL did not silently orphan anything ---------------------------
  select count(*) into v_orphan_li_after from public.line_items where invoice_id is null;
  if v_orphan_li_after <> v_orphan_li_before then
    raise exception 'REFUSING: line_items with a NULL invoice_id went % -> % -- the ON DELETE SET NULL fired',
      v_orphan_li_before, v_orphan_li_after;
  end if;

  -- ---- 9. the billed totals must fall by exactly the money we removed, no more and no less --
  select coalesce(sum(b.life_total), 0) into v_bill_after
    from client.v_client_billing b where b.client_id = any(v_affected);

  if round(v_bill_before - v_bill_after, 2) <> round(v_expected_drop, 2) then
    raise exception 'REFUSING: billed totals fell by % but the ghosts we removed were worth % -- something else moved',
      round(v_bill_before - v_bill_after, 2), round(v_expected_drop, 2);
  end if;

  raise notice 'removed 57 ghost invoices and 10 ghost quotes; % client(s) corrected by $%; orphaned line_items unchanged at %',
    coalesce(cardinality(v_affected),0), round(v_expected_drop,2), v_orphan_li_after;
end
$cleanup$;

commit;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare v_n bigint; v_sum numeric;
begin
  -- 1. both ghost sets are gone
  select count(*) into v_n from public.invoices i
   where not exists (select 1 from public.entity_source_links e
                      where e.entity_type='invoice' and e.entity_id=i.id and e.source_system='jobber')
     and i.created_at >= timestamptz '2026-08-21 00:00:00+00';
  if v_n <> 0 then raise exception 'VERIFY 1 FAILED: % ghost invoice(s) survive', v_n; end if;

  select count(*) into v_n from public.quotes q
   where not exists (select 1 from public.entity_source_links e
                      where e.entity_type='quote' and e.entity_id=q.id and e.source_system='jobber')
     and q.created_at >= timestamptz '2026-08-21 00:00:00+00';
  if v_n <> 0 then raise exception 'VERIFY 2 FAILED: % ghost quote(s) survive', v_n; end if;

  -- 3. 🛑 THE ROWS WE KEEP ARE STILL THERE. Deleting the wrong half of a duplicate pair is the
  --    entire risk of this migration, so assert the survivors explicitly rather than inferring it
  --    from the count of what went.
  select count(*) into v_n
    from public.entity_source_links e
    join public.invoices i on i.id = e.entity_id
   where e.entity_type='invoice' and e.source_system='jobber';
  -- A floor, not an equality: the */5 poll legitimately adds linked invoices while this runs.
  -- Measured 2558 immediately before applying; only unlinked rows are deleted, so it cannot fall.
  if v_n < 2550 then
    raise exception 'VERIFY 3 FAILED: only % linked invoices remain (was 2558); the keep rows may have been deleted', v_n;
  end if;

  -- and every remaining linked invoice still resolves to a row (no dangling link)
  select count(*) into v_n from public.entity_source_links e
   where e.entity_type='invoice' and e.source_system='jobber'
     and not exists (select 1 from public.invoices i where i.id = e.entity_id);
  if v_n <> 0 then
    raise exception 'VERIFY 3b FAILED: % invoice link(s) now point at a row that does not exist', v_n;
  end if;
  select count(*) into v_n from public.entity_source_links e
   where e.entity_type='quote' and e.source_system='jobber'
     and not exists (select 1 from public.quotes q where q.id = e.entity_id);
  if v_n <> 0 then
    raise exception 'VERIFY 3c FAILED: % quote link(s) now point at a row that does not exist', v_n;
  end if;

  -- 4. THE SPECIFIC CLIENT FRED WAS SHOWN. Casa Neos held invoice #3071 four times at $1,400.
  --    It must now hold it exactly once.
  select count(*) into v_n from public.invoices i
    join public.clients c on c.id = i.client_id
   where c.client_code = '009-CN' and i.invoice_number = '3071';
  if v_n <> 1 then
    raise exception 'VERIFY 4 FAILED: Casa Neos holds % copies of invoice 3071, expected exactly 1', v_n;
  end if;

  -- 5. no NULL-everything shell survived anywhere (the shape my own probe leaked twice)
  select count(*) into v_n from public.invoices
   where invoice_number is null and total is null and invoice_status is null and client_id is null;
  if v_n <> 0 then raise exception 'VERIFY 5 FAILED: % empty invoice shell(s) present', v_n; end if;
  select count(*) into v_n from public.quotes
   where quote_number is null and title is null and total is null and client_id is null;
  if v_n <> 0 then raise exception 'VERIFY 5b FAILED: % empty quote shell(s) present', v_n; end if;

  -- 6. duplicate client/invoice_number pairs must fall from 57 to exactly 6.
  --    ⚠ NOT to zero, and asserting zero would have failed this migration for a reason that has
  --    nothing to do with it. Six pairs pre-date the 2026-08-21 floor: they are the older unlinked
  --    invoices, a different and closed cause, deliberately out of scope here. Assert the exact
  --    residue so that a NEW duplicate appearing later still trips this.
  select count(*) into v_n from (
    select i.client_id, i.invoice_number
      from public.invoices i
     where i.client_id is not null and i.invoice_number is not null
     group by 1,2 having count(*) > 1) d;
  if v_n <> 6 then
    raise exception 'VERIFY 6 FAILED: % duplicated client/invoice_number pair(s), expected exactly the 6 pre-2026-08-21 ones', v_n;
  end if;

  -- and every one of those 6 must genuinely be pre-floor, not a new duplicate hiding in the count
  select count(*) into v_n from (
    select i.client_id, i.invoice_number, max(i.created_at) as newest
      from public.invoices i
     where i.client_id is not null and i.invoice_number is not null
     group by 1,2 having count(*) > 1) d
   where d.newest >= timestamptz '2026-08-21 00:00:00+00';
  if v_n <> 0 then
    raise exception 'VERIFY 6b FAILED: % duplicated pair(s) involve a row created after the floor', v_n;
  end if;

  -- 6c. THE RECEIVABLES REPORT IS CLEAN. This is the biggest surface and it is checked on the
  --     VIEW, not on the table: ops.v_ar_aging sums public.invoices with no link filter, and it
  --     was carrying 48 ghost rows worth $35,801.90 of the $157,643.63 it reported owed.
  select count(*) into v_n
    from ops.v_ar_aging a
    join public.invoices i on i.id = a.invoice_id
   where i.created_at >= timestamptz '2026-08-21 00:00:00+00'
     and not exists (select 1 from public.entity_source_links e
                      where e.entity_type='invoice' and e.entity_id=i.id and e.source_system='jobber');
  if v_n <> 0 then
    raise exception 'VERIFY 6c FAILED: % unlinked invoice(s) still appear in ops.v_ar_aging', v_n;
  end if;

  -- and the report is not EMPTY, which would mean we broke it rather than cleaned it
  select coalesce(sum(a.balance_due), 0) into v_sum from ops.v_ar_aging a;
  if v_sum < 100000 then
    raise exception 'VERIFY 6d FAILED: AR balance due is now $% (was $157,643.63, expected about $121,841.73) -- too low, something real was deleted', round(v_sum,2);
  end if;

  -- 7. the source is fixed, so this cannot refill: both resolve functions must exist and be
  --    wired. A cleanup shipped without the fix would just recreate the ghosts.
  if to_regprocedure('public.fn_jobber_resolve_invoice(text)') is null
     or to_regprocedure('public.fn_jobber_resolve_quote(text)') is null then
    raise exception 'VERIFY 7 FAILED: the resolve functions are missing -- 2026-09-08_1300 has not been applied';
  end if;

  raise notice 'VERIFY ok: 0 ghost invoices, 0 ghost quotes, every link still resolves, Casa Neos holds invoice 3071 exactly once, no empty shells, duplicated invoice-number pairs down to the 6 pre-floor legacy ones, no unlinked invoice left in ops.v_ar_aging while the report still totals over $100k, and both resolve functions are in place';
end
$verify$;
