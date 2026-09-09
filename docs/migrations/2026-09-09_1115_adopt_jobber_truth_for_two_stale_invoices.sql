-- ============================================================================
-- 2026-09-09_1115_adopt_jobber_truth_for_two_stale_invoices.sql
--
-- Adopt Jobber's answer for the TWO invoices whose rows claim money Jobber says was paid.
-- $863.44 of false receivable, on two real customers.
--
-- Fred, 2026-09-09: "if it's in our DB you can manipulate the Invoices data, but not the Billing
-- settings. Then you can adopt from Jobber..."
-- ⚠ **BILLING SETTINGS UNTOUCHED.** `jobs.billing_type`, `jobs.invoice_frequency` and
--   `jobs.invoice_rrule` are not read or written here. This is `public.invoices` row data only,
--   and nothing in this migration reaches Jobber.
--
-- ============================================================================
-- READ FROM JOBBER 2026-09-09 ~11:0x ET, one live GraphQL call per invoice
--
--   our 1617  #2320  152-DAV Davinci
--       ours    awaiting_payment  total 450.36  balance 450.36
--       JOBBER  paid              total 450.36  balance   0.00
--
--   our 1653  #2333  270-T4A Tower 41 Association
--       ours    awaiting_payment  total 413.08  balance 413.08
--       JOBBER  paid              total   0.00  balance   0.00
--       ⚠ Jobber's TOTAL is 0.00, not 413.08 -- the invoice was zeroed on their side, so this is
--         not merely a payment. Adopting the status without the total would leave a paid invoice
--         still claiming $413.08 of revenue in client.v_client_billing.
--
-- Both are IN ops.v_ar_aging today for their full balance, so this is $863.44 the business
-- believes it is owed and is not.
--
-- ============================================================================
-- 🛑 WHY THE OBVIOUS CHEAP FIX WAS REJECTED, AND IT WOULD HAVE RESURRECTED THREE INVOICES
--
-- `raw.jobber_pull_invoices` already holds a Jobber payload for **2,470 of our 2,470 linked
-- invoices**, so comparing raw against live looks like a free reconciler with no API cost. It finds
-- exactly these divergences:
--     status differs   5      balance differs  3      total differs  2
--
-- **But raw is a STAGING BUFFER, not a mirror, and on 3 of those 5 rows OUR ROW IS THE CORRECT
-- ONE.** Invoices 2335 (#2894), 2659 (#3109) and 2719 (#3134) read `destroyed` here while raw still
-- holds a pre-deletion snapshot saying `past_due` / `draft` / `awaiting_payment`. Asked directly,
-- **Jobber returns NULL for all three: they are gone.** A destroy never restages, because the poll
-- cannot pull an object that no longer exists, so raw is frozen at the last successful pull.
--
-- ⇒ A raw-based reconciler would have **resurrected three deleted invoices**, one of them
--    (#3134 Chaiky Katz) adding **$361.32** of phantom receivable. The divergence runs BOTH ways
--    and raw cannot tell you which way. **The reconciler must read Jobber.**
--
-- ⇒ This is the second time today that "the staler-looking copy is the wrong one" has been false.
--    It was also false for #2320 against its deleted duplicate. Re-measure direction per row.
--
-- ============================================================================
-- WHY THESE TWO WERE NEVER HEALED, which is a fixed bug and not an ongoing one
--
-- Both were staged 2026-04-30 with `needs_populate = FALSE`, i.e. the poll considered them
-- delivered. `sync-jobber-poll`'s replay loop clears `needs_populate` on `wr.ok`, and until
-- 2026-08-20 `webhook-jobber` acknowledged immediately and processed in the background, so **`ok`
-- meant "accepted", never "applied"**. A row could be acknowledged and silently never populated.
-- That is fixed at source: the replay now sends `x-sync-wait`, and the poll's own comment calls this
-- out as *"the needs_populate=0 hiding rows it had given up on"* failure.
--
-- ⇒ So these two are RESIDUE from before that fix, not evidence the poll is broken today.
-- ⚠ **But nothing would ever have found them.** A cursor poll cannot heal a row it has already
--   passed: once `sync_cursors.invoices` moves beyond an invoice's `updatedAt`, that invoice is
--   never looked at again. That is the gap the drift reconciler closes (2026-09-09_1200), and it is
--   why jobs and visits already have one and invoices did not.
--
-- ⚠ **"92 of 185 AR rows have not been updated in 30 days" is NOT a defect count**, and an earlier
--   report of mine implied it was. An unpaid invoice that nobody has touched is SUPPOSED to sit
--   still. Measured against Jobber's own staged payloads, the real divergence is these 5 rows, of
--   which 2 are wrong here. Staleness of `updated_at` is not evidence of wrongness.
--
-- Audit: no audit trigger on public.invoices, so this migration's own before/after values in the
-- VERIFY block and this header are the record. Two rows, both hand-verified against Jobber.
-- ============================================================================

begin;

do $adopt$
declare
  v_n bigint;
begin
  -- Refuse unless both rows are still exactly as measured. If either has moved, the Jobber read
  -- above is stale and a blind UPDATE would overwrite something newer.
  select count(*) into v_n from public.invoices
   where (id = 1617 and invoice_status = 'awaiting_payment' and total = 450.36 and outstanding_amount = 450.36)
      or (id = 1653 and invoice_status = 'awaiting_payment' and total = 413.08 and outstanding_amount = 413.08);
  if v_n <> 2 then
    raise exception 'REFUSING: expected both 1617 and 1653 in their measured pre-state, found % of 2. Re-read Jobber.', v_n;
  end if;

  -- both must still be linked; an unlinked row here would mean the world changed underneath us
  if (select count(*) from public.entity_source_links
       where entity_type='invoice' and source_system='jobber' and entity_id in (1617,1653)) <> 2 then
    raise exception 'REFUSING: 1617 and 1653 are not both still linked to Jobber';
  end if;

  -- 1617 Davinci: paid, total unchanged at 450.36, balance to zero
  update public.invoices
     set invoice_status = 'paid', total = 450.36, outstanding_amount = 0.00
   where id = 1617;

  -- 1653 Tower 41: paid, and Jobber ZEROED the total as well as the balance
  update public.invoices
     set invoice_status = 'paid', total = 0.00, outstanding_amount = 0.00
   where id = 1653;
end
$adopt$;

commit;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
do $verify$
declare v_n bigint; v_sum numeric;
begin
  -- 1. both rows now match what Jobber returned
  if not exists (select 1 from public.invoices
                  where id=1617 and invoice_status='paid' and total=450.36 and outstanding_amount=0.00) then
    raise exception 'VERIFY 1 FAILED: 1617 does not match Jobber';
  end if;
  if not exists (select 1 from public.invoices
                  where id=1653 and invoice_status='paid' and total=0.00 and outstanding_amount=0.00) then
    raise exception 'VERIFY 2 FAILED: 1653 does not match Jobber';
  end if;

  -- 2. neither appears in the receivables report any more
  select count(*) into v_n from ops.v_ar_aging where invoice_id in (1617,1653);
  if v_n <> 0 then
    raise exception 'VERIFY 3 FAILED: % of the two still appear in ops.v_ar_aging', v_n;
  end if;

  -- 3. and the report is still substantial: we removed a false claim, not a real one
  select coalesce(sum(balance_due),0) into v_sum from ops.v_ar_aging;
  if v_sum < 100000 then
    raise exception 'VERIFY 4 FAILED: AR balance due is now $%; too low', round(v_sum,2);
  end if;

  -- 4. 🛑 THE THREE `destroyed` ROWS ARE ASSERTED **UNCHANGED**. They are the rows a raw-based
  --    reconciler would have resurrected, and Jobber returns NULL for all three. If a later change
  --    ever flips one of these back to a live status, that is the bug this assertion exists to
  --    catch, not a repair.
  select count(*) into v_n from public.invoices
   where id in (2335,2659,2719) and invoice_status = 'destroyed';
  if v_n <> 3 then
    raise exception 'VERIFY 5 FAILED: only % of the 3 deleted-in-Jobber invoices still read destroyed', v_n;
  end if;

  -- 5. the invariant from the previous migration still holds
  select count(*) into v_n from public.invoices i
   where not exists (select 1 from public.entity_source_links e
                      where e.entity_type='invoice' and e.entity_id=i.id and e.source_system='jobber');
  if v_n <> 0 then
    raise exception 'VERIFY 6 FAILED: % unlinked invoice(s) appeared', v_n;
  end if;

  raise notice 'VERIFY ok: 1617 and 1653 now match Jobber (paid, zero balance), neither is in ops.v_ar_aging, the three deleted-in-Jobber rows still read destroyed, and no unlinked invoice exists';
end
$verify$;
