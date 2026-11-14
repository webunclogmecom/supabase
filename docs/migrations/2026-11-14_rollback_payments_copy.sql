-- ROLLBACK of 2026-11-14_0620_payments_copy.sql (the payments copy).
--
-- Run 2026-11-14_rollback_payments_copy_schedule.sql FIRST if it was applied (it removes the two cron jobs and the
-- health watch; a cron left calling sync-jobber-payments after this would only log errors). Redeploy webhook-jobber
-- at the version before the payment handlers (152) first too, or its PAYMENT_* / PAYOUT_* and invoice / quote
-- handlers fail on the missing functions; the rest of the topics are unaffected either way.
--
-- What it removes: the four reads, the writers and helpers, public.v_payment_rows, the four tables and their rows,
-- the payment and payout links (entity_source_links has no audit trigger: those link rows are gone for good, which is
-- fine, they only point at Jobber and a re-run of the backfill rebuilds them), the two new CHECK values, the new
-- invoice and quote columns, every quote line (line_items.quote_id; there were 0 before the change) and audit_quotes.
-- The payments copy is a copy of Jobber: everything dropped here can be read again from Jobber.
-- What it does NOT restore: quotes.sent_at and the other existing columns the change filled (invoices.paid_at,
-- subtotal, tax_amount; quotes.sent_at, approved_at, converted_to_job_at, subtotal, tax_amount, deposit_amount) keep
-- Jobber's values. quotes.sent_at held the creation time before; the previous values of the 345 quotes are in the
-- workspace backup backups/2026-11-14_quotes_sent_at_before_payments_copy.json (id, sent_at) if they are ever wanted.

BEGIN;
SET LOCAL lock_timeout = '3s';

drop function client.list_payments(date, date, text[], text[], text[], bigint, boolean, boolean, boolean, integer, integer);
drop function client.payment_months(date, date, bigint, text[]);
drop function client.get_payment(bigint);
drop function client.get_invoice_payments(bigint);
drop view public.v_payment_rows;
drop function public.sync_jobber_payments(jsonb, jsonb);
drop function public.sync_jobber_payouts(jsonb, jsonb);
drop function public.fn_jobber_payments_unseen(timestamptz, timestamptz, jsonb);
drop function public.sync_jobber_invoice_extras(jsonb);
drop function public.sync_jobber_quote_extras(jsonb);
drop function public.rewrite_quote_line_items(bigint, jsonb);
drop function public.fn_jobber_gid_number(text);
drop function public.fn_jobber_gid(text, text);

delete from public.entity_source_links where entity_type in ('payment', 'payout');

alter table public.entity_source_links
  drop constraint entity_source_links_entity_type_chk,
  add constraint entity_source_links_entity_type_chk check (entity_type = any (array[
    'client', 'derm_manifest', 'employee', 'inspection', 'invoice', 'job', 'line_item', 'note', 'photo', 'property',
    'quote', 'vehicle', 'visit', 'calendar_day_marker', 'calendar_task', 'tank_sensor', 'time_entry', 'source_record']));

create or replace view client.entity_source_links as
 SELECT id,
    entity_type,
    entity_id,
    source_system,
    source_id,
    source_name,
    match_method,
    match_confidence,
    synced_at,
    created_at
   FROM public.entity_source_links
  WHERE entity_type <> 'source_record'::text;

drop table public.payout_lines;
drop table public.payouts;
drop table public.payment_allocations;
drop table public.payments;

delete from public.line_items where quote_id is not null;
alter table public.invoices
  drop column discount_amount,
  drop column tax_label,
  drop column viewed_at,
  drop column voided_at,
  drop column void_reason;
alter table public.quotes drop column viewed_at;
drop trigger audit_quotes on public.quotes;

notify pgrst, 'reload schema';

do $verify$
begin
  if to_regclass('public.payments') is not null or to_regclass('public.payouts') is not null
     or to_regprocedure('client.list_payments(date,date,text[],text[],text[],bigint,boolean,boolean,boolean,integer,integer)') is not null then
    raise exception 'verify_fail: the payments copy is still there';
  end if;
  if md5(pg_get_constraintdef((select oid from pg_constraint where conname = 'entity_source_links_entity_type_chk')))
     is distinct from '8c6bcc9d2249baa81e12ad038e7bfe80' then
    raise exception 'verify_fail: the link CHECK is not back to the 18-value list';
  end if;
  if md5(pg_get_viewdef('client.entity_source_links'::regclass, true)) is distinct from '890b59ef635d3dd456b8993d03954829' then
    raise exception 'verify_fail: client.entity_source_links is not back to its old text';
  end if;
  if exists (select 1 from pg_trigger where tgrelid = 'public.quotes'::regclass and tgname = 'audit_quotes') then
    raise exception 'verify_fail: audit_quotes is still there';
  end if;
  raise notice 'verify ok: the payments copy is gone';
end $verify$;

COMMIT;
