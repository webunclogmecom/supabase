-- ============================================================================
-- 2026-09-09_1045_remove_last_unlinked_invoices.sql
--
-- Remove the LAST 6 invoices in the database with no Jobber link. Takes the unlinked population
-- to ZERO, which is what makes the structural guard in the next migration possible at all.
--
-- Fred, 2026-09-09: "if it's in our DB you can manipulate the Invoices data, but not the Billing
-- settings. Then you can adopt from Jobber..."
-- ⚠ **BILLING SETTINGS ARE UNTOUCHED BY HIS EXPLICIT INSTRUCTION.** `jobs.billing_type`,
--   `jobs.invoice_frequency` and `jobs.invoice_rrule` are not read or written here. This is
--   `public.invoices` row data only, and `webhook-jobber` has zero Jobber mutations, so nothing
--   reaches Jobber.
--
-- ============================================================================
-- 🛑 WHY THESE SIX SURVIVED THE 2026-09-08 CLEANUP, AND IT IS A VERIFICATION LESSON
--
-- That migration bounded its work with `created_at >= '2026-08-21'` (the day real Jobber webhooks
-- were enabled, so a genuine regime change). Bounding the WORK was right. **It then repeated the
-- same floor inside its own VERIFY**, which asserted "no unlinked invoice appears in
-- ops.v_ar_aging" and could therefore only ever confirm the rows it had just deleted were deleted.
-- It passed while three unlinked invoices sat in the receivables report.
--
-- ⇒ **SCOPE THE CHANGE, NEVER THE ASSERTION.** This migration's VERIFY asserts over the WHOLE
--    table: `count(unlinked) = 0`, no date predicate anywhere. Its sibling assertion in the 1330
--    migration did it correctly (duplicate invoice-number pairs must equal exactly 6) and would
--    have caught a new one; the AR assertion did not, and did not.
--
-- ⚠ The health detector carries the same floor DELIBERATELY (to keep legacy off a daily worklist),
--   so `link_orphans = 0` also read clean. **Two instruments sharing a blind spot is one
--   instrument.** After this migration the floor stops mattering: the population is zero.
--
-- ============================================================================
-- THE SIX, AND JOBBER'S ANSWER FOR EACH (re-read 2026-09-09 10:3x ET, unchanged from 09-08)
--
--   ghost  keep   #      JOBBER says              our KEEP row said
--   1663   1691   2340   paid      362.35  bal 0  paid 0            agree
--   1664   1692   2339   paid      361.32  bal 0  paid 0            agree
--   1665   1660   2220   past_due  474.00  bal 474.00               agree
--   1666   1617   2320   paid      450.36  bal 0  awaiting 450.36   🛑 KEEP ROW IS WRONG
--   1669   1690   2341   paid     1400.00  bal 0  paid 0            agree
--   1670   1671   2342   paid     1004.24  bal 0  paid 0            agree
--
-- 🛑 **THE DIVERGENCE RUNS BOTH WAYS HERE, WHICH IT DID NOT FOR THE 57.**
--    For the 57 the unlinked copy was always the staler one. On **#2320 the LINKED row 1617 is the
--    wrong one.** So this could NOT have been done by re-running the previous cleanup with a wider
--    floor: that would have deleted the row that matches Jobber and kept the one that does not.
--    **Re-measure a population before extending a fix to it. Do not inherit the conclusion along
--    with the query.**
--
-- ⚠ **THIS MIGRATION DOES NOT FIX 1617, AND THAT IS DELIBERATE.** Deleting its duplicate removes a
--   double-count; the surviving row still claims $450.36 that Jobber says was paid. Hard-coding
--   Jobber's values into a migration would fix one row and teach the system nothing. It is fixed by
--   the drift reconciler (2026-09-09_1200), whose FIRST job is this known-answer case.
--
-- ============================================================================
-- WHAT IT IS WORTH, measured
--
--   ops.v_ar_aging          3 of these rows, **$2,739.68** of a $141,152.38 receivable
--   client.v_client_billing 6 clients reading high by **$3,913.71**
--
--   🛑 Two clients appear to owe money Jobber records as PAID:
--        009-CN Casa Neos     $1,400.00   (Jobber: paid)
--        206-CAC Cacio e Pepe $1,004.24   (Jobber: paid)
--      Yes Market shows BOTH rows, so it reads $809.44 against a true $474.00.
--
-- ============================================================================
-- 🛑 THE MATCH PREDICATE GAINED A `client_id` LEG, AND THE OLD ONE WAS A LATENT BUG
--
-- The 1330 cleanup matched ghost to twin on `invoice_number` ALONE. It was safe on that population
-- (0 cross-client matches, re-confirmed), but **`invoice_number` is NOT unique**: #1027 legitimately
-- exists on two LINKED invoices for different clients ($0.01 and $413.08). This migration adds
-- `and k.client_id is not distinct from g.client_id`. Any future reuse must keep it.
--
-- ⚠ `line_items.invoice_id` is ON DELETE SET NULL: an invoice WITH line items would be deleted
--   silently and orphan them. The FK will not stop it, so the block below counts them before and
--   after and refuses if the number moves.
-- ⚠ NO AUDIT TRIGGER on public.invoices. The backup is the only record:
--   backups/2026-09-09_last_six_unlinked_invoices.json (6 rows + the keep map + Jobber's answer).
--
-- Audit: no audit trigger on this table (see above). The backup file is the record.
-- ============================================================================

begin;

do $cleanup$
declare
  v_ids     bigint[];
  v_n       bigint;
  v_li_before bigint;
  v_li_after  bigint;
  v_deleted bigint;
  r_ent     record;
begin
  -- 1. DERIVE from the invariant, over the WHOLE table. No date floor: that is the defect this
  --    migration exists to close, and a floor here would reintroduce it.
  select array_agg(i.id order by i.id) into v_ids
    from public.invoices i
   where not exists (select 1 from public.entity_source_links e
                      where e.entity_type='invoice' and e.entity_id=i.id
                        and e.source_system='jobber');

  if coalesce(cardinality(v_ids), 0) <> 6 then
    raise exception 'REFUSING: found % unlinked invoices, audited exactly 6 against Jobber. Re-verify before deleting.',
      coalesce(cardinality(v_ids), 0);
  end if;

  -- 2. each must have EXACTLY ONE linked twin, SAME CLIENT, same number
  select count(*) into v_n from public.invoices g
   where g.id = any(v_ids)
     and (select count(*) from public.invoices k
            join public.entity_source_links e
              on e.entity_type='invoice' and e.source_system='jobber' and e.entity_id = k.id
           where k.invoice_number is not distinct from g.invoice_number
             and k.client_id     is not distinct from g.client_id
             and k.id <> g.id) <> 1;
  if v_n > 0 then
    raise exception 'REFUSING: % of the 6 no longer have exactly one linked same-client twin', v_n;
  end if;

  -- 3. none may have acquired a link between the derivation and the write
  if exists (select 1 from public.entity_source_links
              where entity_type='invoice' and entity_id = any(v_ids)) then
    raise exception 'REFUSING: one of the 6 acquired a source link mid-migration';
  end if;

  -- 4. dependent sweep over EVERY fk pointing at public.invoices, at apply time
  for r_ent in
    select con.conrelid::regclass::text as tbl, a.attname as col
      from pg_constraint con
      join pg_attribute a on a.attrelid = con.conrelid and a.attnum = con.conkey[1]
     where con.confrelid = 'public.invoices'::regclass and con.contype = 'f'
  loop
    execute format('select count(*) from %s where %I = any($1)', r_ent.tbl, r_ent.col)
      into v_n using v_ids;
    if v_n > 0 then
      raise exception 'REFUSING: % row(s) in %.% reference one of the 6 -- it is NOT debris',
        v_n, r_ent.tbl, r_ent.col;
    end if;
  end loop;

  select count(*) into v_li_before from public.line_items where invoice_id is null;

  delete from public.invoices where id = any(v_ids);
  get diagnostics v_deleted = row_count;
  if v_deleted <> 6 then
    raise exception 'REFUSING: deleted % rows, expected 6', v_deleted;
  end if;

  -- the ON DELETE SET NULL must not have fired
  select count(*) into v_li_after from public.line_items where invoice_id is null;
  if v_li_after <> v_li_before then
    raise exception 'REFUSING: line_items with NULL invoice_id went % -> %; the SET NULL fired',
      v_li_before, v_li_after;
  end if;

  raise notice 'removed the last 6 unlinked invoices; orphaned line_items unchanged at %', v_li_after;
end
$cleanup$;

commit;

-- ---------------------------------------------------------------------------
-- VERIFY. Every assertion is over the WHOLE table. No date predicate appears anywhere in this
-- block, on purpose: see the header.
-- ---------------------------------------------------------------------------
do $verify$
declare v_n bigint; v_sum numeric;
begin
  -- 1. THE INVARIANT, unscoped: there is no such thing as an unlinked invoice any more
  select count(*) into v_n from public.invoices i
   where not exists (select 1 from public.entity_source_links e
                      where e.entity_type='invoice' and e.entity_id=i.id and e.source_system='jobber');
  if v_n <> 0 then
    raise exception 'VERIFY 1 FAILED: % unlinked invoice(s) remain anywhere in the table', v_n;
  end if;

  -- 2. and the same statement on the RECEIVABLES VIEW, again unscoped. This is the assertion the
  --    previous migration got wrong by repeating the delete's own floor inside it.
  select count(*) into v_n
    from ops.v_ar_aging a
   where not exists (select 1 from public.entity_source_links e
                      where e.entity_type='invoice' and e.entity_id=a.invoice_id
                        and e.source_system='jobber');
  if v_n <> 0 then
    raise exception 'VERIFY 2 FAILED: % unlinked invoice(s) still appear in ops.v_ar_aging', v_n;
  end if;

  -- 3. we removed a double-count, not a receivable. The report must still be substantial.
  select coalesce(sum(a.balance_due), 0) into v_sum from ops.v_ar_aging a;
  if v_sum < 100000 then
    raise exception 'VERIFY 3 FAILED: AR balance due is now $%; something real was deleted', round(v_sum,2);
  end if;

  -- 4. the rows we KEPT are all still present and still resolve
  if exists (select 1 from public.entity_source_links e
              where e.entity_type='invoice' and e.source_system='jobber'
                and not exists (select 1 from public.invoices i where i.id = e.entity_id)) then
    raise exception 'VERIFY 4 FAILED: an invoice link now points at a row that does not exist';
  end if;
  foreach v_n in array array[1617,1660,1671,1690,1691,1692] loop
    if not exists (select 1 from public.invoices where id = v_n) then
      raise exception 'VERIFY 4b FAILED: kept invoice % was deleted', v_n;
    end if;
  end loop;

  -- 5. no client/invoice_number pair is duplicated any more, ANYWHERE. The previous migration had
  --    to assert a residue of 6; that residue was these rows, and it is now gone.
  select count(*) into v_n from (
    select i.client_id, i.invoice_number from public.invoices i
     where i.client_id is not null and i.invoice_number is not null
     group by 1,2 having count(*) > 1) d;
  if v_n <> 0 then
    raise exception 'VERIFY 5 FAILED: % duplicated client/invoice_number pair(s) remain', v_n;
  end if;

  -- 6. 🛑 THE KNOWN-REMAINING DEFECT IS ASSERTED TO STILL EXIST, so that nobody reads this
  --    migration as having fixed it. Invoice 1617 (Davinci #2320) still disagrees with Jobber.
  --    The drift reconciler fixes it. When that ships, THIS assertion is what must be inverted.
  if not exists (select 1 from public.invoices
                  where id = 1617 and coalesce(invoice_status,'') <> 'paid') then
    raise notice 'NOTE: invoice 1617 no longer reads unpaid -- the reconciler has already run. Update this assertion.';
  end if;

  raise notice 'VERIFY ok: ZERO unlinked invoices in the whole table and zero in ops.v_ar_aging, every link resolves, all 6 kept rows present, no duplicated client/invoice_number pair remains';
end
$verify$;
