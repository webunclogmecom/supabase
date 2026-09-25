-- ============================================================================
-- 2026-09-25_1650 — public.invoices can hold 'voided'; the table is audited
-- ============================================================================
-- ASK (Fred, 2026-09-25): "yes, start the Client App dialog and fix the invoice sync".
--
-- WHY. Jobber API 2026-04-16 reads a VOIDED invoice as invoiceStatus "awaiting_payment" with a 0 balance;
-- only 2026-09-09 reads "voided" (measured on [TEST] invoice #3247, 112-YA, id 2835). Our invoice writers
-- (webhook-jobber handleInvoice, sync-jobber-invoice-drift) read at 2026-04-16, so every voided invoice
-- has been stored as 'awaiting_payment'. They move to 2026-09-09 right after this migration. This CHECK
-- did not admit 'voided', so the handler change alone would fail 23514 AFTER fn_jobber_resolve_invoice
-- ran, and the poll would retry that row for ever: the widening MUST ship first.
-- Census (all 2,674 Jobber invoices read at 2026-09-09 against all 2,681 rows): exactly ONE row differs,
-- id 2835, the test invoice. Nothing else is voided today.
--
-- RULE 8. public.invoices is a billing table and had NO audit trigger, although CLAUDE.md rule 8 says no
-- billing table may skip audit. Opted in here. audit.log_change skips updates that change nothing but
-- updated_at, so the sync's repeated identical writes do not flood audit.logs.
--
-- The widening is a single ALTER that only ADDS a value, so no existing row can fail it.
-- ROLLBACK:
--   drop trigger if exists audit_invoices on public.invoices;
--   -- only after the writers are back on 2026-04-16 AND no row holds 'voided':
--   alter table public.invoices drop constraint invoices_invoice_status_chk,
--     add constraint invoices_invoice_status_chk check (invoice_status = any (array['draft','awaiting_payment',
--     'paid','past_due','bad_debt','sent_not_due','destroyed']));
-- ============================================================================

alter table public.invoices
  drop constraint invoices_invoice_status_chk,
  add  constraint invoices_invoice_status_chk check (invoice_status = any (array[
    'draft', 'awaiting_payment', 'paid', 'past_due', 'bad_debt', 'sent_not_due', 'destroyed', 'voided']));

create trigger audit_invoices after insert or update or delete on public.invoices
  for each row execute function audit.log_change();

-- VERIFY
do $$
declare v_def text; v_trg int;
begin
  select pg_get_constraintdef(oid) into v_def from pg_constraint where conname = 'invoices_invoice_status_chk';
  if v_def not like '%''voided''%' then raise exception 'verify: constraint lacks voided: %', v_def; end if;
  if v_def not like '%''destroyed''%' or v_def not like '%''sent_not_due''%' then raise exception 'verify: constraint lost a value: %', v_def; end if;
  select count(*) into v_trg from pg_trigger where tgrelid = 'public.invoices'::regclass and tgname = 'audit_invoices' and not tgisinternal;
  if v_trg <> 1 then raise exception 'verify: audit trigger missing'; end if;
end $$;
