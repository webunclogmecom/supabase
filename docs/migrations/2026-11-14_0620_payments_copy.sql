-- =============================================================================
-- 2026-11-14_0620_payments_copy.sql
--
-- WHAT: the payments copy. Every Jobber payment and bank payout in our own database, and the reads the portal's
--       Finances pages use. Plan: Building Apps/Ops Portal/docs/specs/2026-11-13-jobber-payments-and-people.md,
--       section C (section B, who did what, is not part of this).
--   1. public.payments, public.payment_allocations, public.payouts, public.payout_lines (new). RLS on (the event
--      trigger rls_auto_enable), NO policy and NO grant to anon, authenticated or service_role: nothing reads them
--      directly. Writers are the SECURITY DEFINER functions below; readers are the client.* functions below.
--   2. public.entity_source_links: the entity_type CHECK gains 'payment' and 'payout' (18 values -> 20).
--      client.entity_source_links (the pass-through staff read) now also leaves those two out, so its answer does
--      not change: every other reader of the table names the types it reads (swept 2026-11-14, 55 objects).
--   3. public.invoices gains discount_amount, tax_label, viewed_at, voided_at, void_reason; public.quotes gains
--      viewed_at. Existing columns filled from now on: invoices.paid_at (Jobber receivedDate), subtotal, tax_amount;
--      quotes.sent_at (the real sentAt; it held the creation time), approved_at, converted_to_job_at, subtotal,
--      tax_amount, deposit_amount; quote lines (line_items.quote_id).
--   4. Writers (service_role only, called by webhook-jobber, sync-jobber-payments and the backfill script with the
--      RAW Jobber nodes, so the mapping from Jobber's fields to our columns lives here and nowhere else):
--        public.sync_jobber_payments(p_nodes, p_gone)   payments + allocations, one advisory lock per payment
--        public.sync_jobber_payouts(p_nodes, p_gone)    payouts + lines, one advisory lock per payout
--        public.fn_jobber_payments_unseen(from, to, seen)  which held payments a complete window answer lacks,
--                                                        refusing an empty or mass-removal answer
--        public.sync_jobber_invoice_extras(p_nodes), public.sync_jobber_quote_extras(p_nodes),
--        public.rewrite_quote_line_items(p_quote_id, p_lines)  (the sibling of rewrite_invoice_line_items)
--   5. Reads (authenticated only, gated on the Client App at View, then the staff check):
--        client.list_payments(...), client.payment_months(...), client.get_payment(id), client.get_invoice_payments(id)
--      over public.v_payment_rows (owner only). Contract: docs/reference/payments-copy.md.
--
-- WHY: Fred, 2026-11-14 about 4:55 AM ET: "Build the copy now (Recommended) ... remember to have link a sync data to
--      keep the data up to the date. Because the finances is being handled in Jobber, so we need to have a way to get
--      that data from Jobber, see if there is a way to have a good way to have that realtime, like with the webhook
--      but if we need to have cronjob then decide the frequency of fetching that data". "Who may open the Finances
--      pages ...? Client App setting (Recommended)".
--
-- RULES THAT MUST NOT REGRESS:
--   * Never trust an event and never write a value not just read from Jobber: the writers take Jobber's nodes as
--     read; a reply that is not JSON or has no data never reaches them (the callers throw first).
--   * A payment is identified by its NUMBER: Jobber shows OtherPaymentRecord/N in the ledger and PaymentRecord/N under
--     an invoice. The stored link is base64('gid://Jobber/PaymentRecord/N'); payouts 'gid://Jobber/PayoutRecord/N'.
--   * Allocations and payout lines are replaced in ONE transaction, under the per-object lock, and only when they
--     differ (webhooks arrive at least once, in pairs, in any order; the audit trail stays quiet on a re-read).
--   * A payment is never hard-deleted: deleted_at, and only on a by-id read that came back null (p_gone), at most
--     20 in one call. The timed net asks fn_jobber_payments_unseen first, which refuses an empty answer over a window
--     we hold payments in, and a removal of more than 20 that is also more than a quarter of the window.
--   * A payment is held (not written) while what it pays (an invoice, a quote) or reverses (a payment) is not in our
--     database yet; the reply lists what is missing so the caller imports it and calls again.
--   * Amount is Jobber's unsigned amount; the kind says the direction (rawAmount is negative for money in).
--   * Not stored, on purpose: card last digits, name on card, expiry, bank name, transaction ids.
--   * The fee is kept on the payment AND on its payout line, as Jobber states each (the payout line is the bank
--     statement; the two totals differ by the payments not in a payout yet): an intentional exception (ADR 004).
--
-- RULE 8, AUDIT: payments, payment_allocations, payouts, payout_lines get audit_<table> (money tables may not skip
--   audit). public.quotes gets audit_quotes in the same change (it had none). audit.log_change skips an UPDATE that
--   changes nothing; the writers also compare before they write.
-- RLS: on (rls_auto_enable), no policy on purpose. GRANTS: REVOKE ALL from anon, authenticated, service_role by
--   name; db_backup_reader keeps SELECT (the backup dumps every table). Compared in the VERIFY.
-- UNDO: 2026-11-14_rollback_payments_copy.sql.
-- =============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if to_regclass('public.payments') is not null or to_regclass('public.payouts') is not null then
    raise exception 'the payments copy exists already; stop';
  end if;
  if (select md5(pg_get_constraintdef(c.oid)) from pg_constraint c
       where c.conrelid = 'public.entity_source_links'::regclass and c.conname = 'entity_source_links_entity_type_chk')
     is distinct from '8c6bcc9d2249baa81e12ad038e7bfe80' then
    raise exception 'entity_source_links_entity_type_chk is not the 18-value list this was written against; stop';
  end if;
  if md5(pg_get_viewdef('client.entity_source_links'::regclass, true)) is distinct from '890b59ef635d3dd456b8993d03954829' then
    raise exception 'client.entity_source_links is not the view this was written against; stop';
  end if;
  if exists (select 1 from pg_trigger where tgrelid = 'public.quotes'::regclass and tgname = 'audit_quotes') then
    raise exception 'public.quotes already has audit_quotes; stop';
  end if;
end
$pin$;

-- ---------------------------------------------------------------------------------------------------------------
-- 1. the link CHECK, and the pass-through staff read
-- ---------------------------------------------------------------------------------------------------------------
alter table public.entity_source_links
  drop constraint entity_source_links_entity_type_chk,
  add constraint entity_source_links_entity_type_chk check (entity_type = any (array[
    'client', 'derm_manifest', 'employee', 'inspection', 'invoice', 'job', 'line_item', 'note', 'photo', 'property',
    'quote', 'vehicle', 'visit', 'calendar_day_marker', 'calendar_task', 'tank_sensor', 'time_entry', 'source_record',
    'payment', 'payout']));

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
  WHERE entity_type <> ALL (ARRAY['source_record'::text, 'payment'::text, 'payout'::text]);

-- ---------------------------------------------------------------------------------------------------------------
-- 2. the tables
-- ---------------------------------------------------------------------------------------------------------------
create table public.payments (
  id                  bigint generated always as identity primary key,
  client_id           bigint references public.clients(id),
  kind                text not null check (kind in ('payment', 'deposit', 'refund', 'failed_payment', 'bad_debt')),
  method              text check (method ~ '^[a-z][a-z0-9_]*$'),
  origin              text check (origin ~ '^[a-z][a-z0-9_]*$'),
  amount              numeric(12,2) not null check (amount >= 0),
  entered_at          timestamptz not null,
  reference           text,
  details             text,
  receipt_sent_at     timestamptz,
  fee_amount          numeric(12,2),
  processor_status    text check (processor_status ~ '^[a-z][a-z0-9_]*$'),
  card_brand          text,
  card_funding        text,
  refunded_at         timestamptz,
  reverses_payment_id bigint references public.payments(id),
  deleted_at          timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index idx_payments_entered_at on public.payments (entered_at);
create index idx_payments_client on public.payments (client_id);
create index idx_payments_reverses on public.payments (reverses_payment_id) where reverses_payment_id is not null;

create table public.payment_allocations (
  id         bigint generated always as identity primary key,
  payment_id bigint not null references public.payments(id),
  invoice_id bigint references public.invoices(id),
  quote_id   bigint references public.quotes(id),
  amount     numeric(12,2) not null,
  created_at timestamptz not null default now(),
  constraint payment_allocations_one_target_chk check (num_nonnulls(invoice_id, quote_id) = 1)
);
create index idx_payment_allocations_payment on public.payment_allocations (payment_id);
create index idx_payment_allocations_invoice on public.payment_allocations (invoice_id) where invoice_id is not null;
create index idx_payment_allocations_quote on public.payment_allocations (quote_id) where quote_id is not null;

create table public.payouts (
  id             bigint generated always as identity primary key,
  status         text not null check (status ~ '^[a-z][a-z0-9_]*$'),
  method         text check (method ~ '^[a-z][a-z0-9_]*$'),
  arrival_date   date not null,
  issued_at      timestamptz,
  net_amount     numeric(12,2) not null,
  failure_reason text,
  deleted_at     timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index idx_payouts_arrival on public.payouts (arrival_date);

create table public.payout_lines (
  id           bigint generated always as identity primary key,
  payout_id    bigint not null references public.payouts(id),
  kind         text not null check (kind ~ '^[a-z][a-z0-9_]*$'),
  payment_id   bigint references public.payments(id),
  gross_amount numeric(12,2) not null,
  fee_amount   numeric(12,2) not null,
  net_amount   numeric(12,2) not null,
  occurred_at  timestamptz,
  created_at   timestamptz not null default now()
);
create index idx_payout_lines_payout on public.payout_lines (payout_id);
create index idx_payout_lines_payment on public.payout_lines (payment_id) where payment_id is not null;

create trigger trg_payments_updated_at before update on public.payments for each row execute function public.set_updated_at();
create trigger trg_payouts_updated_at before update on public.payouts for each row execute function public.set_updated_at();
create trigger audit_payments after insert or update or delete on public.payments for each row execute function audit.log_change();
create trigger audit_payment_allocations after insert or update or delete on public.payment_allocations for each row execute function audit.log_change();
create trigger audit_payouts after insert or update or delete on public.payouts for each row execute function audit.log_change();
create trigger audit_payout_lines after insert or update or delete on public.payout_lines for each row execute function audit.log_change();
create trigger audit_quotes after insert or update or delete on public.quotes for each row execute function audit.log_change();

revoke all on table public.payments, public.payment_allocations, public.payouts, public.payout_lines from anon, authenticated, service_role;
revoke all on sequence public.payments_id_seq, public.payment_allocations_id_seq, public.payouts_id_seq, public.payout_lines_id_seq
  from anon, authenticated, service_role;

alter table public.invoices
  add column discount_amount numeric(12,2),
  add column tax_label text,
  add column viewed_at timestamptz,
  add column voided_at timestamptz,
  add column void_reason text;
alter table public.quotes add column viewed_at timestamptz;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. two pure helpers: the number behind any Jobber id, and the id we store for a number. Owner only.
-- ---------------------------------------------------------------------------------------------------------------
create function public.fn_jobber_gid_number(p_gid text)
 returns text
 language sql
 immutable
 set search_path to ''
as $fn$
  select case
           when p_gid ~ '^[0-9]+$' then p_gid
           when length(p_gid) % 4 = 0 and p_gid ~ '^[A-Za-z0-9+/]+={0,2}$'
             then (regexp_match(convert_from(decode(p_gid, 'base64'), 'UTF8'), '^gid://Jobber/[A-Za-z]+/([0-9]+)$'))[1]
         end
$fn$;

create function public.fn_jobber_gid(p_type text, p_num text)
 returns text
 language sql
 immutable
 set search_path to ''
as $fn$
  select case when p_num ~ '^[0-9]+$' and p_type ~ '^[A-Za-z]+$'
              then replace(encode(convert_to('gid://Jobber/' || p_type || '/' || p_num, 'UTF8'), 'base64'), E'\n', '') end
$fn$;

revoke all on function public.fn_jobber_gid_number(text), public.fn_jobber_gid(text, text) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. the writers
-- ---------------------------------------------------------------------------------------------------------------
create function public.sync_jobber_payments(p_nodes jsonb, p_gone jsonb default '[]'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $fn$
-- 2026-11-14: Jobber payment records (raw nodes, the selection PAYMENT_FIELDS in supabase/functions/_shared/
-- jobber-payments.ts) into public.payments and public.payment_allocations. Idempotent on the payment's number.
-- p_gone: ids Jobber answered null for when read by id (deleted there): marked deleted_at, 20 at most per call.
-- Ledger lines that are not money (an issued invoice, a voided invoice, a correction, an opening balance) are counted
-- and skipped. A payment whose invoice, quote or reversed payment is not here yet is held, and named in "missing".
declare
  v_gone jsonb := coalesce(p_gone, '[]'::jsonb);
  v_ins int := 0; v_upd int := 0; v_same int := 0; v_alloc int := 0; v_rem int := 0; v_notmoney int := 0;
  v_held jsonb := '[]'::jsonb;
  v_miss_inv jsonb := '[]'::jsonb; v_miss_quote jsonb := '[]'::jsonb; v_miss_pay jsonb := '[]'::jsonb;
  r record; a record;
  v_id bigint; v_client bigint; v_rev bigint; v_target bigint; v_num text; v_rev_num text;
  v_src jsonb; v_allocs jsonb; v_cur jsonb; v_new jsonb; v_missing boolean; v_method text; v_gid text;
begin
  if jsonb_typeof(p_nodes) is distinct from 'array' or jsonb_typeof(v_gone) is distinct from 'array' then
    raise exception 'p_nodes and p_gone must be JSON arrays' using errcode = '22023';
  end if;
  if jsonb_array_length(v_gone) > 20 then
    raise exception 'refusing to mark % payments removed in one call (20 at most)', jsonb_array_length(v_gone) using errcode = 'P0001';
  end if;
  if exists (select 1 from jsonb_array_elements(p_nodes) e(v) where public.fn_jobber_gid_number(e.v ->> 'id') is null) then
    raise exception 'a payment node has no readable Jobber id' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(v_gone) g(v)
              where public.fn_jobber_gid_number(g.v #>> '{}') in
                    (select public.fn_jobber_gid_number(e.v ->> 'id') from jsonb_array_elements(p_nodes) e(v))) then
    raise exception 'a payment is both returned and gone in one call' using errcode = '22023';
  end if;

  for r in
    select x.node, x.num, public.fn_jobber_gid('PaymentRecord', x.num) as gid,
           case x.node ->> 'adjustmentType'
             when 'PAYMENT' then 'payment' when 'DEPOSIT' then 'deposit' when 'REFUND' then 'refund'
             when 'FAILED_ACH_PAYMENT' then 'failed_payment' when 'BAD_DEBT' then 'bad_debt' end as kind
      from (select e.v as node, public.fn_jobber_gid_number(e.v ->> 'id') as num from jsonb_array_elements(p_nodes) e(v)) x
     order by (x.node ->> 'entryDate')::timestamptz nulls first, x.num::numeric
  loop
    if r.kind is null then
      v_notmoney := v_notmoney + 1;
      continue;
    end if;
    if r.node ->> 'entryDate' is null or r.node ->> 'amount' is null then
      raise exception 'payment % has no entry date or amount', r.num using errcode = '22023';
    end if;
    if coalesce((r.node #>> '{allocations,pageInfo,hasNextPage}')::boolean, false) then
      v_held := v_held || jsonb_build_object('gid', r.gid, 'reason', 'more than 25 allocations; not stored cut');
      continue;
    end if;

    -- What it pays: Jobber's allocation list; when that is empty, the one invoice, else the one quote it names (30
    -- deposits name both an invoice and a quote and list no allocation: the invoice is where the money went).
    v_src := coalesce(r.node #> '{allocations,nodes}', '[]'::jsonb);
    if jsonb_array_length(v_src) = 0 then
      if r.node #>> '{invoice,id}' is not null then
        v_src := jsonb_build_array(jsonb_build_object('amount', r.node -> 'amount', 'invoice', r.node -> 'invoice'));
      elsif r.node #>> '{quote,id}' is not null then
        v_src := jsonb_build_array(jsonb_build_object('amount', r.node -> 'amount', 'quote', r.node -> 'quote'));
      end if;
    end if;

    v_missing := false;
    v_allocs := '[]'::jsonb;
    for a in select e.v as al from jsonb_array_elements(v_src) e(v) loop
      if a.al #>> '{invoice,id}' is not null then
        v_num := public.fn_jobber_gid_number(a.al #>> '{invoice,id}');
        select l.entity_id into v_target from public.entity_source_links l
         where l.entity_type = 'invoice' and l.source_system = 'jobber'
           and l.source_id in (a.al #>> '{invoice,id}', public.fn_jobber_gid('Invoice', v_num));
        if v_target is null then
          v_miss_inv := v_miss_inv || to_jsonb(public.fn_jobber_gid('Invoice', v_num));
          v_missing := true;
        else
          v_allocs := v_allocs || jsonb_build_object('i', v_target, 'q', null, 'a', (a.al ->> 'amount')::numeric(12,2));
        end if;
      elsif a.al #>> '{quote,id}' is not null then
        v_num := public.fn_jobber_gid_number(a.al #>> '{quote,id}');
        select l.entity_id into v_target from public.entity_source_links l
         where l.entity_type = 'quote' and l.source_system = 'jobber'
           and l.source_id in (a.al #>> '{quote,id}', public.fn_jobber_gid('Quote', v_num), v_num)
         order by l.id limit 1;
        if v_target is null then
          v_miss_quote := v_miss_quote || to_jsonb(public.fn_jobber_gid('Quote', v_num));
          v_missing := true;
        else
          v_allocs := v_allocs || jsonb_build_object('i', null, 'q', v_target, 'a', (a.al ->> 'amount')::numeric(12,2));
        end if;
      else
        raise exception 'an allocation of payment % names neither an invoice nor a quote', r.num using errcode = '22023';
      end if;
    end loop;

    v_rev := null;
    v_rev_num := public.fn_jobber_gid_number(coalesce(r.node #>> '{refundedPaymentRecord,id}', r.node #>> '{negatedBalanceAdjustment,id}'));
    if v_rev_num is not null then
      select l.entity_id into v_rev from public.entity_source_links l
       where l.entity_type = 'payment' and l.source_system = 'jobber' and l.source_id = public.fn_jobber_gid('PaymentRecord', v_rev_num);
      if v_rev is null then
        v_miss_pay := v_miss_pay || to_jsonb(public.fn_jobber_gid('PaymentRecord', v_rev_num));
        v_missing := true;
      end if;
    end if;

    if v_missing then
      v_held := v_held || jsonb_build_object('gid', r.gid, 'reason', 'waits for what it pays or reverses');
      continue;
    end if;

    v_client := null;
    if r.node #>> '{client,id}' is not null then
      select l.entity_id into v_client from public.entity_source_links l
       where l.entity_type = 'client' and l.source_system = 'jobber'
         and l.source_id in (r.node #>> '{client,id}', public.fn_jobber_gid('Client', public.fn_jobber_gid_number(r.node #>> '{client,id}')));
    end if;

    -- the method is the record's type: CheckPaymentRecord -> check, JobberPaymentsACHPaymentRecord -> jobber_payments_ach
    v_method := case when r.node ->> '__typename' ~ '^[A-Za-z]+PaymentRecord$' then
                  lower(regexp_replace(regexp_replace(left(r.node ->> '__typename', -13), '([A-Z]+)([A-Z][a-z])', '\1_\2', 'g'),
                                       '([a-z0-9])([A-Z])', '\1_\2', 'g')) end;

    perform pg_advisory_xact_lock(hashtextextended('jobber:payment:' || r.gid, 0));
    select l.entity_id into v_id from public.entity_source_links l
     where l.entity_type = 'payment' and l.source_system = 'jobber' and l.source_id = r.gid;

    if v_id is null then
      insert into public.payments (client_id, kind, method, origin, amount, entered_at, reference, details, receipt_sent_at,
                                   fee_amount, processor_status, card_brand, card_funding, refunded_at, reverses_payment_id)
      values (v_client, r.kind, v_method, lower(r.node ->> 'paymentOrigin'), (r.node ->> 'amount')::numeric(12,2),
              (r.node ->> 'entryDate')::timestamptz,
              nullif(btrim(coalesce(r.node ->> 'checkNumber', r.node ->> 'confirmationNumber', r.node ->> 'ccTransactionNumber')), ''),
              nullif(btrim(r.node ->> 'details'), ''), (r.node ->> 'sentAt')::timestamptz, (r.node ->> 'feeAmount')::numeric(12,2),
              lower(r.node ->> 'transactionStatus'), nullif(btrim(r.node ->> 'brand'), ''), lower(nullif(btrim(r.node ->> 'paymentMethodFunding'), '')),
              (r.node ->> 'refundedAt')::timestamptz, v_rev)
      returning id into v_id;
      insert into public.entity_source_links (entity_type, entity_id, source_system, source_id, match_method, match_confidence, synced_at)
      values ('payment', v_id, 'jobber', r.gid, 'jobber-sync', 1.0, now());
      v_ins := v_ins + 1;
    else
      update public.payments p
         set client_id = v_client, kind = r.kind, method = v_method, origin = lower(r.node ->> 'paymentOrigin'),
             amount = (r.node ->> 'amount')::numeric(12,2), entered_at = (r.node ->> 'entryDate')::timestamptz,
             reference = nullif(btrim(coalesce(r.node ->> 'checkNumber', r.node ->> 'confirmationNumber', r.node ->> 'ccTransactionNumber')), ''),
             details = nullif(btrim(r.node ->> 'details'), ''), receipt_sent_at = (r.node ->> 'sentAt')::timestamptz,
             fee_amount = (r.node ->> 'feeAmount')::numeric(12,2), processor_status = lower(r.node ->> 'transactionStatus'),
             card_brand = nullif(btrim(r.node ->> 'brand'), ''), card_funding = lower(nullif(btrim(r.node ->> 'paymentMethodFunding'), '')),
             refunded_at = (r.node ->> 'refundedAt')::timestamptz, reverses_payment_id = v_rev, deleted_at = null
       where p.id = v_id
         and (p.client_id, p.kind, p.method, p.origin, p.amount, p.entered_at, p.reference, p.details, p.receipt_sent_at,
              p.fee_amount, p.processor_status, p.card_brand, p.card_funding, p.refunded_at, p.reverses_payment_id, p.deleted_at)
             is distinct from
             (v_client, r.kind, v_method, lower(r.node ->> 'paymentOrigin'), (r.node ->> 'amount')::numeric(12,2),
              (r.node ->> 'entryDate')::timestamptz,
              nullif(btrim(coalesce(r.node ->> 'checkNumber', r.node ->> 'confirmationNumber', r.node ->> 'ccTransactionNumber')), ''),
              nullif(btrim(r.node ->> 'details'), ''), (r.node ->> 'sentAt')::timestamptz, (r.node ->> 'feeAmount')::numeric(12,2),
              lower(r.node ->> 'transactionStatus'), nullif(btrim(r.node ->> 'brand'), ''), lower(nullif(btrim(r.node ->> 'paymentMethodFunding'), '')),
              (r.node ->> 'refundedAt')::timestamptz, v_rev, null::timestamptz);
      if found then v_upd := v_upd + 1; else v_same := v_same + 1; end if;
    end if;

    -- the allocations: replaced only when they differ, inside this transaction and under this payment's lock
    select coalesce(jsonb_agg(jsonb_build_object('i', pa.invoice_id, 'q', pa.quote_id, 'a', pa.amount)
                              order by pa.invoice_id nulls last, pa.quote_id nulls last, pa.amount), '[]'::jsonb)
      into v_cur from public.payment_allocations pa where pa.payment_id = v_id;
    select coalesce(jsonb_agg(x.v order by (x.v ->> 'i')::bigint nulls last, (x.v ->> 'q')::bigint nulls last, (x.v ->> 'a')::numeric), '[]'::jsonb)
      into v_new from jsonb_array_elements(v_allocs) x(v);
    if v_cur is distinct from v_new then
      delete from public.payment_allocations where payment_id = v_id;
      insert into public.payment_allocations (payment_id, invoice_id, quote_id, amount)
      select v_id, (x.v ->> 'i')::bigint, (x.v ->> 'q')::bigint, (x.v ->> 'a')::numeric(12,2)
        from jsonb_array_elements(v_new) with ordinality x(v, ord) order by x.ord;
      v_alloc := v_alloc + 1;
    end if;
  end loop;

  for v_gid in select public.fn_jobber_gid('PaymentRecord', public.fn_jobber_gid_number(g.v #>> '{}')) from jsonb_array_elements(v_gone) g(v) loop
    update public.payments p set deleted_at = now()
     where p.deleted_at is null
       and p.id = (select l.entity_id from public.entity_source_links l
                    where l.entity_type = 'payment' and l.source_system = 'jobber' and l.source_id = v_gid);
    if found then v_rem := v_rem + 1; end if;
  end loop;

  return jsonb_build_object(
    'received', jsonb_array_length(p_nodes), 'not_money', v_notmoney, 'inserted', v_ins, 'updated', v_upd,
    'unchanged', v_same, 'allocations_rewritten', v_alloc, 'removed', v_rem, 'held', v_held,
    'missing', jsonb_build_object(
      'invoices', (select coalesce(jsonb_agg(distinct x.v), '[]'::jsonb) from jsonb_array_elements(v_miss_inv) x(v)),
      'quotes', (select coalesce(jsonb_agg(distinct x.v), '[]'::jsonb) from jsonb_array_elements(v_miss_quote) x(v)),
      'payments', (select coalesce(jsonb_agg(distinct x.v), '[]'::jsonb) from jsonb_array_elements(v_miss_pay) x(v))));
end
$fn$;

create function public.sync_jobber_payouts(p_nodes jsonb, p_gone jsonb default '[]'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $fn$
-- 2026-11-14: Jobber bank payouts (raw nodes, PAYOUT_FIELDS in _shared/jobber-payments.ts) into public.payouts and
-- public.payout_lines (amounts arrive in cents). A payout whose lines name a payment not here yet is held, and the
-- payment named in "missing". p_gone: payouts Jobber answered null for when read by id, marked deleted_at.
declare
  v_gone jsonb := coalesce(p_gone, '[]'::jsonb);
  v_ins int := 0; v_upd int := 0; v_same int := 0; v_lines int := 0; v_rem int := 0;
  v_held jsonb := '[]'::jsonb; v_miss_pay jsonb := '[]'::jsonb;
  r record; l record;
  v_id bigint; v_pid bigint; v_pnum text; v_new jsonb; v_cur jsonb; v_missing boolean; v_gid text;
begin
  if jsonb_typeof(p_nodes) is distinct from 'array' or jsonb_typeof(v_gone) is distinct from 'array' then
    raise exception 'p_nodes and p_gone must be JSON arrays' using errcode = '22023';
  end if;
  if jsonb_array_length(v_gone) > 20 then
    raise exception 'refusing to mark % payouts removed in one call (20 at most)', jsonb_array_length(v_gone) using errcode = 'P0001';
  end if;
  if exists (select 1 from jsonb_array_elements(p_nodes) e(v)
              where public.fn_jobber_gid_number(e.v ->> 'id') is null or e.v ->> 'status' is null
                 or e.v ->> 'arrivalDate' is null or e.v ->> 'netAmount' is null) then
    raise exception 'a payout node has no readable id, status, arrival date or net amount' using errcode = '22023';
  end if;

  for r in
    select e.v as node, public.fn_jobber_gid('PayoutRecord', public.fn_jobber_gid_number(e.v ->> 'id')) as gid
      from jsonb_array_elements(p_nodes) e(v)
     order by (e.v ->> 'arrivalDate')::timestamptz, public.fn_jobber_gid_number(e.v ->> 'id')::numeric
  loop
    if coalesce((r.node #>> '{balanceTransactions,pageInfo,hasNextPage}')::boolean, false) then
      v_held := v_held || jsonb_build_object('gid', r.gid, 'reason', 'more than 50 lines; not stored cut');
      continue;
    end if;
    v_missing := false;
    v_new := '[]'::jsonb;
    for l in select e.v as t, e.ord from jsonb_array_elements(coalesce(r.node #> '{balanceTransactions,nodes}', '[]'::jsonb)) with ordinality e(v, ord)
             order by e.ord loop
      v_pid := null;
      v_pnum := public.fn_jobber_gid_number(l.t #>> '{paymentRecord,id}');
      if v_pnum is not null then
        select s.entity_id into v_pid from public.entity_source_links s
         where s.entity_type = 'payment' and s.source_system = 'jobber' and s.source_id = public.fn_jobber_gid('PaymentRecord', v_pnum);
        if v_pid is null then
          v_miss_pay := v_miss_pay || to_jsonb(public.fn_jobber_gid('PaymentRecord', v_pnum));
          v_missing := true;
        end if;
      end if;
      v_new := v_new || jsonb_build_object(
        'k', coalesce(lower(l.t ->> 'type'), lower(regexp_replace(regexp_replace(regexp_replace(l.t ->> '__typename', 'BalanceTransaction$', ''),
                                                   '([A-Z]+)([A-Z][a-z])', '\1_\2', 'g'), '([a-z0-9])([A-Z])', '\1_\2', 'g'))),
        'p', v_pid,
        'g', ((l.t ->> 'grossAmount')::numeric / 100)::numeric(12,2),
        'f', ((l.t ->> 'feeAmount')::numeric / 100)::numeric(12,2),
        'n', ((l.t ->> 'netAmount')::numeric / 100)::numeric(12,2),
        't', to_jsonb((l.t ->> 'created')::timestamptz));
    end loop;
    if v_missing then
      v_held := v_held || jsonb_build_object('gid', r.gid, 'reason', 'waits for a payment it pays out');
      continue;
    end if;

    perform pg_advisory_xact_lock(hashtextextended('jobber:payout:' || r.gid, 0));
    select s.entity_id into v_id from public.entity_source_links s
     where s.entity_type = 'payout' and s.source_system = 'jobber' and s.source_id = r.gid;
    if v_id is null then
      insert into public.payouts (status, method, arrival_date, issued_at, net_amount, failure_reason)
      values (lower(r.node ->> 'status'), lower(r.node ->> 'payoutMethod'),
              ((r.node ->> 'arrivalDate')::timestamptz at time zone 'UTC')::date, (r.node ->> 'created')::timestamptz,
              ((r.node ->> 'netAmount')::numeric / 100)::numeric(12,2), nullif(btrim(r.node ->> 'failureReason'), ''))
      returning id into v_id;
      insert into public.entity_source_links (entity_type, entity_id, source_system, source_id, match_method, match_confidence, synced_at)
      values ('payout', v_id, 'jobber', r.gid, 'jobber-sync', 1.0, now());
      v_ins := v_ins + 1;
    else
      update public.payouts p
         set status = lower(r.node ->> 'status'), method = lower(r.node ->> 'payoutMethod'),
             arrival_date = ((r.node ->> 'arrivalDate')::timestamptz at time zone 'UTC')::date,
             issued_at = (r.node ->> 'created')::timestamptz, net_amount = ((r.node ->> 'netAmount')::numeric / 100)::numeric(12,2),
             failure_reason = nullif(btrim(r.node ->> 'failureReason'), ''), deleted_at = null
       where p.id = v_id
         and (p.status, p.method, p.arrival_date, p.issued_at, p.net_amount, p.failure_reason, p.deleted_at)
             is distinct from
             (lower(r.node ->> 'status'), lower(r.node ->> 'payoutMethod'),
              ((r.node ->> 'arrivalDate')::timestamptz at time zone 'UTC')::date, (r.node ->> 'created')::timestamptz,
              ((r.node ->> 'netAmount')::numeric / 100)::numeric(12,2), nullif(btrim(r.node ->> 'failureReason'), ''), null::timestamptz);
      if found then v_upd := v_upd + 1; else v_same := v_same + 1; end if;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object('k', pl.kind, 'p', pl.payment_id, 'g', pl.gross_amount, 'f', pl.fee_amount,
                                                 'n', pl.net_amount, 't', to_jsonb(pl.occurred_at)) order by pl.id), '[]'::jsonb)
      into v_cur from public.payout_lines pl where pl.payout_id = v_id;
    if v_cur is distinct from v_new then
      delete from public.payout_lines where payout_id = v_id;
      insert into public.payout_lines (payout_id, kind, payment_id, gross_amount, fee_amount, net_amount, occurred_at)
      select v_id, x.v ->> 'k', (x.v ->> 'p')::bigint, (x.v ->> 'g')::numeric(12,2), (x.v ->> 'f')::numeric(12,2),
             (x.v ->> 'n')::numeric(12,2), (x.v ->> 't')::timestamptz
        from jsonb_array_elements(v_new) with ordinality x(v, ord) order by x.ord;
      v_lines := v_lines + 1;
    end if;
  end loop;

  for v_gid in select public.fn_jobber_gid('PayoutRecord', public.fn_jobber_gid_number(g.v #>> '{}')) from jsonb_array_elements(v_gone) g(v) loop
    update public.payouts p set deleted_at = now()
     where p.deleted_at is null
       and p.id = (select s.entity_id from public.entity_source_links s
                    where s.entity_type = 'payout' and s.source_system = 'jobber' and s.source_id = v_gid);
    if found then v_rem := v_rem + 1; end if;
  end loop;

  return jsonb_build_object(
    'received', jsonb_array_length(p_nodes), 'inserted', v_ins, 'updated', v_upd, 'unchanged', v_same,
    'lines_rewritten', v_lines, 'removed', v_rem, 'held', v_held,
    'missing', jsonb_build_object('payments', (select coalesce(jsonb_agg(distinct x.v), '[]'::jsonb) from jsonb_array_elements(v_miss_pay) x(v))));
end
$fn$;

create function public.fn_jobber_payments_unseen(p_from timestamptz, p_to timestamptz, p_seen jsonb)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $fn$
-- 2026-11-14: the held payments entered in [p_from, p_to) that a COMPLETE read of that window (p_seen: the ids of
-- every money record Jobber returned for it, any id form) does not hold. The caller re-reads each by id: a node is
-- written (its entry date may have moved), a null is passed to sync_jobber_payments as gone. A missing answer is not
-- an empty one: an empty answer over a window we hold payments in, or more than 20 unseen that are also more than a
-- quarter of the window, is refused (the rule of hr.sync_time_entries).
declare
  v_held int; v_seen int; v_unseen jsonb;
begin
  if p_from is null or p_to is null or p_from >= p_to or jsonb_typeof(p_seen) is distinct from 'array' then
    raise exception 'give a window (from before to) and the array of ids Jobber returned' using errcode = '22023';
  end if;
  with seen as (
    select distinct public.fn_jobber_gid('PaymentRecord', public.fn_jobber_gid_number(e.v #>> '{}')) as gid
      from jsonb_array_elements(p_seen) e(v)
  ), held as (
    select l.source_id as gid
      from public.payments p
      join public.entity_source_links l on l.entity_type = 'payment' and l.source_system = 'jobber' and l.entity_id = p.id
     where p.deleted_at is null and p.entered_at >= p_from and p.entered_at < p_to
  )
  select (select count(*) from held), (select count(*) from seen where gid is not null),
         (select coalesce(jsonb_agg(h.gid order by h.gid), '[]'::jsonb) from held h where not exists (select 1 from seen s where s.gid = h.gid))
    into v_held, v_seen, v_unseen;
  if v_seen = 0 and v_held > 0 then
    raise exception 'Jobber returned no payment for a window that holds % here; refusing to treat them as removed', v_held
      using errcode = 'P0001';
  end if;
  if jsonb_array_length(v_unseen) > 20 and jsonb_array_length(v_unseen) * 4 > v_held then
    raise exception 'refusing: % of the % payments held in the window are missing from Jobber''s answer', jsonb_array_length(v_unseen), v_held
      using errcode = 'P0001';
  end if;
  return jsonb_build_object('held', v_held, 'seen', v_seen, 'unseen', v_unseen);
end
$fn$;

create function public.rewrite_quote_line_items(p_quote_id bigint, p_lines jsonb)
 returns void
 language plpgsql
 security definer
 set search_path to ''
as $fn$
-- 2026-11-14: the sibling of rewrite_invoice_line_items for a quote's lines. One transaction, one lock per quote.
begin
  if p_quote_id is null then
    raise exception 'rewrite_quote_line_items: p_quote_id is required' using errcode = '22023';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'rewrite_quote_line_items: p_lines must be a JSON array (got %)', coalesce(jsonb_typeof(p_lines), 'null') using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('public.rewrite_quote_line_items', p_quote_id));
  delete from public.line_items where quote_id = p_quote_id;
  insert into public.line_items (quote_id, name, description, quantity, unit_price, total_price, taxable)
  select p_quote_id, x.name, x.description, x.quantity, x.unit_price, x.total_price, x.taxable
    from jsonb_array_elements(p_lines) with ordinality as e(v, ord)
    cross join lateral jsonb_to_record(e.v)
      as x(name text, description text, quantity numeric, unit_price numeric, total_price numeric, taxable boolean)
   order by e.ord;
end
$fn$;

create function public.sync_jobber_invoice_extras(p_nodes jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $fn$
-- 2026-11-14: the invoice fields the payments plan adds, from raw Jobber invoice nodes read at API 2026-09-09
-- (handleInvoice's own query, or the backfill): paid date (receivedDate), subtotal, tax, discount, the tax rate's
-- name (it tells the card fee from a sales tax), viewed in the client hub, void date and reason code. A node missing
-- one of those keys is skipped (never read as "cleared"); an invoice not linked here is counted, never created.
declare
  v_upd int := 0; v_same int := 0; v_incomplete int := 0; v_unknown jsonb := '[]'::jsonb; r record; v_id bigint;
begin
  if jsonb_typeof(p_nodes) is distinct from 'array' then
    raise exception 'p_nodes must be a JSON array' using errcode = '22023';
  end if;
  for r in select e.v as n from jsonb_array_elements(p_nodes) e(v) loop
    if not (r.n ? 'receivedDate' and r.n ? 'dateViewedInClientHub' and r.n ? 'taxRate' and r.n ? 'voidDetails'
            and r.n -> 'amounts' ? 'subtotal' and r.n -> 'amounts' ? 'taxAmount' and r.n -> 'amounts' ? 'discountAmount') then
      v_incomplete := v_incomplete + 1;
      continue;
    end if;
    select l.entity_id into v_id from public.entity_source_links l
     where l.entity_type = 'invoice' and l.source_system = 'jobber'
       and l.source_id in (r.n ->> 'id', public.fn_jobber_gid('Invoice', public.fn_jobber_gid_number(r.n ->> 'id')));
    if v_id is null then
      v_unknown := v_unknown || to_jsonb(r.n ->> 'id');
      continue;
    end if;
    update public.invoices i
       set paid_at = (r.n ->> 'receivedDate')::timestamptz,
           subtotal = (r.n #>> '{amounts,subtotal}')::numeric(12,2),
           tax_amount = (r.n #>> '{amounts,taxAmount}')::numeric(12,2),
           discount_amount = (r.n #>> '{amounts,discountAmount}')::numeric(12,2),
           tax_label = nullif(btrim(r.n #>> '{taxRate,name}'), ''),
           viewed_at = (r.n ->> 'dateViewedInClientHub')::timestamptz,
           voided_at = (r.n #>> '{voidDetails,voidedAt}')::timestamptz,
           void_reason = lower(r.n #>> '{voidDetails,voidReasonCode}')
     where i.id = v_id
       and (i.paid_at, i.subtotal, i.tax_amount, i.discount_amount, i.tax_label, i.viewed_at, i.voided_at, i.void_reason)
           is distinct from
           ((r.n ->> 'receivedDate')::timestamptz, (r.n #>> '{amounts,subtotal}')::numeric(12,2),
            (r.n #>> '{amounts,taxAmount}')::numeric(12,2), (r.n #>> '{amounts,discountAmount}')::numeric(12,2),
            nullif(btrim(r.n #>> '{taxRate,name}'), ''), (r.n ->> 'dateViewedInClientHub')::timestamptz,
            (r.n #>> '{voidDetails,voidedAt}')::timestamptz, lower(r.n #>> '{voidDetails,voidReasonCode}'));
    if found then v_upd := v_upd + 1; else v_same := v_same + 1; end if;
  end loop;
  return jsonb_build_object('received', jsonb_array_length(p_nodes), 'updated', v_upd, 'unchanged', v_same,
                            'incomplete', v_incomplete, 'not_linked', v_unknown);
end
$fn$;

create function public.sync_jobber_quote_extras(p_nodes jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to ''
as $fn$
-- 2026-11-14: the quote fields the payments plan adds, from raw Jobber quote nodes read at API 2026-04-16 (handleQuote's
-- version): the real sent date (sent_at held the creation time until now), approved and converted dates, subtotal,
-- tax, required deposit, viewed in the client hub, and the quote's lines (replaced through rewrite_quote_line_items
-- only when they differ; a list with more pages is left alone and counted). A node missing a key is skipped.
declare
  v_upd int := 0; v_same int := 0; v_incomplete int := 0; v_lines int := 0; v_cut int := 0;
  v_unknown jsonb := '[]'::jsonb; r record; v_id bigint; v_num text; v_cur jsonb; v_new jsonb;
begin
  if jsonb_typeof(p_nodes) is distinct from 'array' then
    raise exception 'p_nodes must be a JSON array' using errcode = '22023';
  end if;
  for r in select e.v as n from jsonb_array_elements(p_nodes) e(v) loop
    if not (r.n ? 'sentAt' and r.n ? 'clientHubViewedAt' and r.n -> 'lastTransitioned' ? 'approvedAt'
            and r.n -> 'lastTransitioned' ? 'convertedAt' and r.n -> 'amounts' ? 'subtotal' and r.n -> 'amounts' ? 'taxAmount'
            and r.n -> 'amounts' ? 'depositAmount' and r.n -> 'lineItems' ? 'nodes') then
      v_incomplete := v_incomplete + 1;
      continue;
    end if;
    v_num := public.fn_jobber_gid_number(r.n ->> 'id');
    select l.entity_id into v_id from public.entity_source_links l
     where l.entity_type = 'quote' and l.source_system = 'jobber'
       and l.source_id in (r.n ->> 'id', public.fn_jobber_gid('Quote', v_num), v_num)
     order by l.id limit 1;
    if v_id is null then
      v_unknown := v_unknown || to_jsonb(r.n ->> 'id');
      continue;
    end if;
    update public.quotes q
       set sent_at = (r.n ->> 'sentAt')::timestamptz,
           approved_at = (r.n #>> '{lastTransitioned,approvedAt}')::timestamptz,
           converted_to_job_at = (r.n #>> '{lastTransitioned,convertedAt}')::timestamptz,
           subtotal = (r.n #>> '{amounts,subtotal}')::numeric(12,2),
           tax_amount = (r.n #>> '{amounts,taxAmount}')::numeric(12,2),
           deposit_amount = (r.n #>> '{amounts,depositAmount}')::numeric(12,2),
           viewed_at = (r.n ->> 'clientHubViewedAt')::timestamptz
     where q.id = v_id
       and (q.sent_at, q.approved_at, q.converted_to_job_at, q.subtotal, q.tax_amount, q.deposit_amount, q.viewed_at)
           is distinct from
           ((r.n ->> 'sentAt')::timestamptz, (r.n #>> '{lastTransitioned,approvedAt}')::timestamptz,
            (r.n #>> '{lastTransitioned,convertedAt}')::timestamptz, (r.n #>> '{amounts,subtotal}')::numeric(12,2),
            (r.n #>> '{amounts,taxAmount}')::numeric(12,2), (r.n #>> '{amounts,depositAmount}')::numeric(12,2),
            (r.n ->> 'clientHubViewedAt')::timestamptz);
    if found then v_upd := v_upd + 1; else v_same := v_same + 1; end if;

    if coalesce((r.n #>> '{lineItems,pageInfo,hasNextPage}')::boolean, false) then
      v_cut := v_cut + 1;
      continue;
    end if;
    select coalesce(jsonb_agg(jsonb_build_object('name', li.name, 'description', li.description, 'quantity', li.quantity,
                                                 'unit_price', li.unit_price, 'total_price', li.total_price, 'taxable', li.taxable)
                              order by li.id), '[]'::jsonb)
      into v_cur from public.line_items li where li.quote_id = v_id;
    select coalesce(jsonb_agg(jsonb_build_object('name', btrim(x.v ->> 'name'), 'description', x.v ->> 'description',
                                                 'quantity', (x.v ->> 'quantity')::numeric(10,2),
                                                 'unit_price', (x.v ->> 'unitPrice')::numeric(12,2),
                                                 'total_price', (x.v ->> 'totalPrice')::numeric(12,2),
                                                 'taxable', coalesce((x.v ->> 'taxable')::boolean, false))
                              order by x.ord), '[]'::jsonb)
      into v_new from jsonb_array_elements(r.n #> '{lineItems,nodes}') with ordinality x(v, ord);
    if v_cur is distinct from v_new then
      perform public.rewrite_quote_line_items(v_id, v_new);
      v_lines := v_lines + 1;
    end if;
  end loop;
  return jsonb_build_object('received', jsonb_array_length(p_nodes), 'updated', v_upd, 'unchanged', v_same,
                            'lines_rewritten', v_lines, 'lines_cut', v_cut, 'incomplete', v_incomplete, 'not_linked', v_unknown);
end
$fn$;

revoke all on function public.sync_jobber_payments(jsonb, jsonb), public.sync_jobber_payouts(jsonb, jsonb),
  public.fn_jobber_payments_unseen(timestamptz, timestamptz, jsonb), public.rewrite_quote_line_items(bigint, jsonb),
  public.sync_jobber_invoice_extras(jsonb), public.sync_jobber_quote_extras(jsonb)
  from public, anon, authenticated;
grant execute on function public.sync_jobber_payments(jsonb, jsonb), public.sync_jobber_payouts(jsonb, jsonb),
  public.fn_jobber_payments_unseen(timestamptz, timestamptz, jsonb), public.rewrite_quote_line_items(bigint, jsonb),
  public.sync_jobber_invoice_extras(jsonb), public.sync_jobber_quote_extras(jsonb)
  to service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- 5. the reads: one row shape (the view, owner only) and four gated functions
-- ---------------------------------------------------------------------------------------------------------------
create view public.v_payment_rows as
select p.id,
       p.client_id,
       c.client_code,
       c.name as client_name,
       p.kind,
       p.method,
       p.origin,
       p.amount,
       case when p.kind in ('payment', 'deposit') then p.amount
            when p.kind in ('refund', 'failed_payment') then -p.amount
            else 0::numeric end as signed_amount,
       p.fee_amount,
       p.entered_at,
       (p.entered_at at time zone 'America/New_York')::date as entered_on,
       p.reference,
       p.details,
       p.receipt_sent_at,
       p.processor_status,
       p.card_brand,
       p.card_funding,
       p.refunded_at,
       p.reverses_payment_id,
       (p.method like 'jobber\_payments%') as via_jobber_payments,
       po.id as payout_id,
       po.arrival_date as payout_arrival_date,
       po.status as payout_status,
       case when p.method in ('jobber_payments_credit_card', 'jobber_payments_ach') and p.kind in ('payment', 'deposit')
            then coalesce(po.status = 'paid', false) end as at_bank,
       al.pays,
       p.deleted_at
  from public.payments p
  left join public.clients c on c.id = p.client_id
  left join lateral (
    select x.id, x.arrival_date, x.status
      from public.payout_lines pl
      join public.payouts x on x.id = pl.payout_id and x.deleted_at is null
     where pl.payment_id = p.id
     order by (pl.kind = 'payment') desc, x.arrival_date, x.id
     limit 1) po on true
  left join lateral (
    select jsonb_build_object(
             'count', count(*),
             'invoices', coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.invoice_number, 'amount', pa.amount)
                                            order by i.invoice_number, i.id) filter (where pa.invoice_id is not null), '[]'::jsonb),
             'quotes', coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'number', q.quote_number, 'amount', pa.amount)
                                          order by q.quote_number, q.id) filter (where pa.quote_id is not null), '[]'::jsonb)) as pays
      from public.payment_allocations pa
      left join public.invoices i on i.id = pa.invoice_id
      left join public.quotes q on q.id = pa.quote_id
     where pa.payment_id = p.id) al on true;

revoke all on table public.v_payment_rows from anon, authenticated, service_role;

create function client.list_payments(
  p_from date default null,
  p_to date default null,
  p_methods text[] default null,
  p_kinds text[] default null,
  p_statuses text[] default null,
  p_client_id bigint default null,
  p_at_bank boolean default null,
  p_refunds_and_failed boolean default false,
  p_include_zero boolean default false,
  p_limit integer default 200,
  p_offset integer default 0)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $fn$
-- 2026-11-14: the Finances Payments list across all clients (contract: docs/reference/payments-copy.md).
declare
  v_out jsonb;
begin
  perform hr.fn_require_app('client_app', 'view');
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.list_payments';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.list_payments';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 1000 or p_offset is null or p_offset < 0 then
    raise exception 'Show between 1 and 1,000 payments at a time.' using errcode = '22023', detail = 'blocker=bad_page in client.list_payments';
  end if;
  if p_from is not null and p_to is not null and p_from > p_to then
    raise exception 'The start date is after the end date.' using errcode = '22023', detail = 'blocker=bad_range in client.list_payments';
  end if;

  with f as materialized (
    select r.*
      from public.v_payment_rows r
     where r.deleted_at is null
       and (p_from is null or r.entered_on >= p_from)
       and (p_to is null or r.entered_on <= p_to)
       and (p_methods is null or r.method = any (p_methods))
       and (p_kinds is null or r.kind = any (p_kinds))
       and (p_statuses is null or r.processor_status = any (p_statuses))
       and (p_client_id is null or r.client_id = p_client_id)
       and (p_at_bank is null or r.at_bank = p_at_bank)
       and (not coalesce(p_refunds_and_failed, false)
            or r.kind in ('refund', 'failed_payment')
            or r.processor_status in ('failed', 'refunded', 'partially_refunded', 'disputed', 'in_dispute'))
       and (coalesce(p_include_zero, false) or r.amount <> 0)
  )
  select jsonb_build_object(
           'total', (select count(*) from f),
           'money_in', (select coalesce(sum(f.amount), 0) from f where f.kind in ('payment', 'deposit')),
           'money_out', (select coalesce(sum(f.amount), 0) from f where f.kind in ('refund', 'failed_payment')),
           'fees', (select coalesce(sum(f.fee_amount), 0) from f),
           'limit', p_limit,
           'offset', p_offset,
           'payments', coalesce((select jsonb_agg(to_jsonb(x) - 'deleted_at' order by x.entered_at desc, x.id desc)
                                   from (select * from f order by f.entered_at desc, f.id desc limit p_limit offset p_offset) x), '[]'::jsonb))
    into v_out;
  return v_out;
end
$fn$;

create function client.payment_months(
  p_from date default null,
  p_to date default null,
  p_client_id bigint default null,
  p_methods text[] default null)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $fn$
-- 2026-11-14: money received per month (Eastern), by method, for the Payments line graph. Every month of the range
-- is present, zero included. Default: the 14 months up to this one.
declare
  v_to date := coalesce(p_to, (now() at time zone 'America/New_York')::date);
  v_from date := coalesce(p_from, (date_trunc('month', coalesce(p_to, (now() at time zone 'America/New_York')::date)) - interval '13 months')::date);
  v_out jsonb;
begin
  perform hr.fn_require_app('client_app', 'view');
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.payment_months';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.payment_months';
  end if;
  if v_from > v_to or v_to - v_from > 3700 then
    raise exception 'Pick a range of at most ten years, start before end.' using errcode = '22023', detail = 'blocker=bad_range in client.payment_months';
  end if;

  with m as (
    select g::date as month from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') g
  ), r as (
    select date_trunc('month', x.entered_on)::date as month, x.kind, x.method, x.amount, x.fee_amount
      from public.v_payment_rows x
     where x.deleted_at is null and x.entered_on between v_from and v_to
       and (p_client_id is null or x.client_id = p_client_id)
       and (p_methods is null or x.method = any (p_methods))
  )
  select jsonb_build_object('from', v_from, 'to', v_to, 'months', coalesce(jsonb_agg(jsonb_build_object(
           'month', to_char(m.month, 'YYYY-MM'),
           'received', (select coalesce(sum(r.amount), 0) from r where r.month = m.month and r.kind in ('payment', 'deposit')),
           'count', (select count(*) from r where r.month = m.month and r.kind in ('payment', 'deposit') and r.amount <> 0),
           'refunds', (select coalesce(sum(r.amount), 0) from r where r.month = m.month and r.kind = 'refund'),
           'failed', (select coalesce(sum(r.amount), 0) from r where r.month = m.month and r.kind = 'failed_payment'),
           'fees', (select coalesce(sum(r.fee_amount), 0) from r where r.month = m.month and r.kind in ('payment', 'deposit')),
           'by_method', (select coalesce(jsonb_object_agg(s.method, s.amount), '{}'::jsonb)
                           from (select coalesce(r.method, 'unknown') as method, sum(r.amount) as amount
                                   from r where r.month = m.month and r.kind in ('payment', 'deposit')
                                  group by 1 having sum(r.amount) <> 0) s))
         order by m.month), '[]'::jsonb))
    into v_out
    from m;
  return v_out;
end
$fn$;

create function client.get_payment(p_payment_id bigint)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $fn$
-- 2026-11-14: one payment opened: its row, what it pays (invoices, quotes), the payout it landed in, what reverses it
-- (refunds, a failed ACH) and what it reverses. Null when no such payment. A removed one comes with removed_at.
declare
  v_out jsonb;
begin
  perform hr.fn_require_app('client_app', 'view');
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_payment';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_payment';
  end if;

  select jsonb_build_object(
           'payment', to_jsonb(r) - 'deleted_at',
           'removed_at', r.deleted_at,
           'allocations', (select coalesce(jsonb_agg(jsonb_build_object(
                                     'invoice_id', i.id, 'invoice_number', i.invoice_number, 'invoice_status', i.invoice_status,
                                     'invoice_total', i.total, 'invoice_outstanding', i.outstanding_amount, 'invoice_paid_at', i.paid_at,
                                     'quote_id', q.id, 'quote_number', q.quote_number, 'quote_status', q.quote_status,
                                     'amount', pa.amount) order by pa.id), '[]'::jsonb)
                             from public.payment_allocations pa
                             left join public.invoices i on i.id = pa.invoice_id
                             left join public.quotes q on q.id = pa.quote_id
                            where pa.payment_id = r.id),
           'payout', (select jsonb_build_object('id', po.id, 'arrival_date', po.arrival_date, 'status', po.status,
                                                'net_amount', po.net_amount, 'failure_reason', po.failure_reason,
                                                'line', jsonb_build_object('kind', pl.kind, 'gross_amount', pl.gross_amount,
                                                                           'fee_amount', pl.fee_amount, 'net_amount', pl.net_amount))
                        from public.payout_lines pl
                        join public.payouts po on po.id = pl.payout_id and po.deleted_at is null
                       where pl.payment_id = r.id
                       order by (pl.kind = 'payment') desc, po.arrival_date, po.id limit 1),
           'reversed_by', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'method', x.method,
                                                                        'amount', x.amount, 'entered_at', x.entered_at,
                                                                        'processor_status', x.processor_status) order by x.entered_at), '[]'::jsonb)
                             from public.payments x where x.reverses_payment_id = r.id and x.deleted_at is null),
           'reverses', (select jsonb_build_object('id', x.id, 'kind', x.kind, 'method', x.method, 'amount', x.amount,
                                                  'entered_at', x.entered_at, 'processor_status', x.processor_status)
                          from public.payments x where x.id = r.reverses_payment_id))
    into v_out
    from public.v_payment_rows r
   where r.id = p_payment_id;
  return v_out;
end
$fn$;

create function client.get_invoice_payments(p_invoice_id bigint)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to ''
as $fn$
-- 2026-11-14: an invoice's paid date and the payments that pay it (the amount each puts on this invoice, and the
-- payment's own amount when it is split over several invoices). Null when no such invoice.
declare
  v_out jsonb;
begin
  perform hr.fn_require_app('client_app', 'view');
  if auth.uid() is null then
    raise exception 'Please sign in again.' using errcode = '28000', detail = 'blocker=not_signed_in in client.get_invoice_payments';
  end if;
  if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
    raise exception 'This page is for UnclogMe staff only.' using errcode = '42501', detail = 'blocker=not_staff in client.get_invoice_payments';
  end if;

  select jsonb_build_object(
           'invoice_id', i.id, 'invoice_number', i.invoice_number, 'invoice_status', i.invoice_status, 'client_id', i.client_id,
           'total', i.total, 'outstanding_amount', i.outstanding_amount, 'paid_at', i.paid_at, 'due_date', i.due_date,
           'sent_at', i.sent_at, 'viewed_at', i.viewed_at, 'voided_at', i.voided_at, 'void_reason', i.void_reason,
           'payments', (select coalesce(jsonb_agg(jsonb_build_object(
                                  'payment_id', r.id, 'entered_at', r.entered_at, 'entered_on', r.entered_on, 'kind', r.kind,
                                  'method', r.method, 'origin', r.origin, 'reference', r.reference, 'allocated_amount', pa.amount,
                                  'payment_amount', r.amount, 'split', (r.pays ->> 'count')::int > 1,
                                  'processor_status', r.processor_status, 'at_bank', r.at_bank,
                                  'payout_arrival_date', r.payout_arrival_date) order by r.entered_at, r.id), '[]'::jsonb)
                          from public.payment_allocations pa
                          join public.v_payment_rows r on r.id = pa.payment_id and r.deleted_at is null
                         where pa.invoice_id = i.id))
    into v_out
    from public.invoices i
   where i.id = p_invoice_id;
  return v_out;
end
$fn$;

revoke all on function client.list_payments(date, date, text[], text[], text[], bigint, boolean, boolean, boolean, integer, integer),
  client.payment_months(date, date, bigint, text[]), client.get_payment(bigint), client.get_invoice_payments(bigint)
  from public, anon, service_role;
grant execute on function client.list_payments(date, date, text[], text[], text[], bigint, boolean, boolean, boolean, integer, integer),
  client.payment_months(date, date, bigint, text[]), client.get_payment(bigint), client.get_invoice_payments(bigint)
  to authenticated;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------------------------------------------------
-- VERIFY (cheap: catalogue reads and one writer pass on throwaway rows that are undone before the end)
-- ---------------------------------------------------------------------------------------------------------------
do $verify$
declare
  v_t text; v_role text; v_acl text; v_res jsonb; v_res2 jsonb; v_pay bigint; v_inv bigint; v_inv_gid text; v_client_gid text;
  v_ok text;
begin
  -- 1. the four tables: RLS on, no policy, only the owner and the backup reader hold anything
  foreach v_t in array array['public.payments', 'public.payment_allocations', 'public.payouts', 'public.payout_lines'] loop
    if not (select c.relrowsecurity from pg_class c where c.oid = v_t::regclass) then
      raise exception 'verify_fail: % has RLS off', v_t;
    end if;
    if exists (select 1 from pg_policy where polrelid = v_t::regclass) then
      raise exception 'verify_fail: % has a policy', v_t;
    end if;
    select string_agg(a.grantee::regrole::text || ':' || a.privilege_type, ',' order by a.grantee::regrole::text, a.privilege_type) into v_acl
      from aclexplode((select relacl from pg_class where oid = v_t::regclass)) a where a.grantee <> 0;
    if v_acl is distinct from 'db_backup_reader:SELECT,postgres:DELETE,postgres:INSERT,postgres:MAINTAIN,postgres:REFERENCES,postgres:SELECT,postgres:TRIGGER,postgres:TRUNCATE,postgres:UPDATE' then
      raise exception 'verify_fail: % grants are %', v_t, v_acl;
    end if;
    foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
      if has_table_privilege(v_role, v_t, 'SELECT') or has_table_privilege(v_role, v_t, 'INSERT') then
        raise exception 'verify_fail: % can read or write %', v_role, v_t;
      end if;
    end loop;
    if not exists (select 1 from pg_trigger where tgrelid = v_t::regclass and tgname = 'audit_' || split_part(v_t, '.', 2)) then
      raise exception 'verify_fail: % has no audit trigger', v_t;
    end if;
  end loop;
  foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
    if has_table_privilege(v_role, 'public.v_payment_rows', 'SELECT') then raise exception 'verify_fail: % reads v_payment_rows', v_role; end if;
    if has_sequence_privilege(v_role, 'public.payments_id_seq', 'USAGE') then raise exception 'verify_fail: % uses payments_id_seq', v_role; end if;
  end loop;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.quotes'::regclass and tgname = 'audit_quotes') then
    raise exception 'verify_fail: quotes has no audit trigger';
  end if;

  -- 2. the CHECK and the pass-through read
  if (select pg_get_constraintdef(c.oid) from pg_constraint c where c.conname = 'entity_source_links_entity_type_chk') !~ '''payment''::text, ''payout''::text\]'
     or (select pg_get_constraintdef(c.oid) from pg_constraint c where c.conname = 'entity_source_links_entity_type_chk') !~ '''time_entry''::text, ''source_record''::text' then
    raise exception 'verify_fail: the link CHECK is not the old 18 values plus payment and payout';
  end if;
  if (select relacl::text from pg_class where oid = 'client.entity_source_links'::regclass)
     is distinct from '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres,db_backup_reader=r/postgres}' then
    raise exception 'verify_fail: client.entity_source_links grants changed';
  end if;
  if (select count(*) from public.entity_source_links where entity_type <> 'source_record')
     is distinct from (select count(*) from client.entity_source_links) then
    raise exception 'verify_fail: client.entity_source_links no longer returns every link but source_record (no payment link exists yet)';
  end if;

  -- 3. functions: definer, empty search path, who may run them
  foreach v_t in array array['public.sync_jobber_payments(jsonb,jsonb)', 'public.sync_jobber_payouts(jsonb,jsonb)',
                             'public.fn_jobber_payments_unseen(timestamptz,timestamptz,jsonb)', 'public.rewrite_quote_line_items(bigint,jsonb)',
                             'public.sync_jobber_invoice_extras(jsonb)', 'public.sync_jobber_quote_extras(jsonb)'] loop
    if not (select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = v_t::regprocedure) then
      raise exception 'verify_fail: % is not SECURITY DEFINER with an empty search_path', v_t;
    end if;
    if not has_function_privilege('service_role', v_t, 'execute') or has_function_privilege('authenticated', v_t, 'execute')
       or has_function_privilege('anon', v_t, 'execute') then
      raise exception 'verify_fail: % is not service_role only', v_t;
    end if;
  end loop;
  foreach v_t in array array['client.list_payments(date,date,text[],text[],text[],bigint,boolean,boolean,boolean,integer,integer)',
                             'client.payment_months(date,date,bigint,text[])', 'client.get_payment(bigint)', 'client.get_invoice_payments(bigint)'] loop
    if not (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""'] from pg_proc p where p.oid = v_t::regprocedure) then
      raise exception 'verify_fail: % is not STABLE SECURITY DEFINER with an empty search_path', v_t;
    end if;
    if not has_function_privilege('authenticated', v_t, 'execute') or has_function_privilege('anon', v_t, 'execute')
       or has_function_privilege('service_role', v_t, 'execute') then
      raise exception 'verify_fail: % is not authenticated only', v_t;
    end if;
  end loop;
  foreach v_t in array array['public.fn_jobber_gid_number(text)', 'public.fn_jobber_gid(text,text)'] loop
    foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(v_role, v_t, 'execute') then raise exception 'verify_fail: % can run %', v_role, v_t; end if;
    end loop;
  end loop;

  -- 4. one writer pass on throwaway rows (undone below): a payment on an invoice of the test client 112-YA, the same
  --    node again (nothing moves), a payout of it, then gone. Numbers 9000000000001+ are not Jobber's.
  select i.id, l.source_id into v_inv, v_inv_gid
    from public.invoices i join public.entity_source_links l on l.entity_type = 'invoice' and l.source_system = 'jobber' and l.entity_id = i.id
   where i.client_id = 381 order by i.id limit 1;
  select l.source_id into v_client_gid from public.entity_source_links l
   where l.entity_type = 'client' and l.source_system = 'jobber' and l.entity_id = 381;
  if v_inv is null or v_client_gid is null then raise exception 'verify_fail: no linked invoice of 112-YA to test with'; end if;
  begin
    v_res := public.sync_jobber_payments(jsonb_build_array(jsonb_build_object(
      '__typename', 'CheckPaymentRecord', 'id', public.fn_jobber_gid('CheckPaymentRecord', '9000000000001'),
      'adjustmentType', 'PAYMENT', 'paymentOrigin', 'EMPLOYEE_ONLINE_ORIGIN', 'amount', 12.5, 'entryDate', '2026-11-14T10:00:00Z',
      'checkNumber', ' 101 ', 'client', jsonb_build_object('id', v_client_gid), 'invoice', jsonb_build_object('id', v_inv_gid),
      'allocations', jsonb_build_object('pageInfo', jsonb_build_object('hasNextPage', false), 'nodes', '[]'::jsonb))));
    v_res2 := public.sync_jobber_payments(jsonb_build_array(jsonb_build_object(
      '__typename', 'CheckPaymentRecord', 'id', public.fn_jobber_gid('PaymentRecord', '9000000000001'),
      'adjustmentType', 'PAYMENT', 'paymentOrigin', 'EMPLOYEE_ONLINE_ORIGIN', 'amount', 12.5, 'entryDate', '2026-11-14T10:00:00Z',
      'checkNumber', '101', 'client', jsonb_build_object('id', v_client_gid), 'invoice', jsonb_build_object('id', v_inv_gid),
      'allocations', jsonb_build_object('pageInfo', jsonb_build_object('hasNextPage', false), 'nodes', '[]'::jsonb))));
    select p.id into v_pay from public.payments p join public.entity_source_links l on l.entity_type = 'payment' and l.entity_id = p.id
     where l.source_id = public.fn_jobber_gid('PaymentRecord', '9000000000001');
    if (v_res ->> 'inserted')::int <> 1 or (v_res ->> 'allocations_rewritten')::int <> 1
       or (v_res2 ->> 'unchanged')::int <> 1 or (v_res2 ->> 'allocations_rewritten')::int <> 0 or v_pay is null
       or (select method || '|' || reference || '|' || client_id from public.payments where id = v_pay) <> 'check|101|381'
       or (select count(*) from public.payment_allocations where payment_id = v_pay and invoice_id = v_inv and amount = 12.50) <> 1 then
      raise exception 'verify_fail: writer pass 1: % / %', v_res, v_res2;
    end if;
    v_res := public.sync_jobber_payouts(jsonb_build_array(jsonb_build_object(
      'id', public.fn_jobber_gid('PayoutRecord', '9000000000002'), 'status', 'PAID', 'payoutMethod', 'STANDARD', 'netAmount', 1213,
      'arrivalDate', '2026-11-16T00:00:00Z', 'created', '2026-11-15T01:00:00Z',
      'balanceTransactions', jsonb_build_object('pageInfo', jsonb_build_object('hasNextPage', false), 'nodes', jsonb_build_array(
        jsonb_build_object('__typename', 'PaymentBalanceTransaction', 'type', 'PAYMENT', 'grossAmount', 1250, 'feeAmount', 37,
                           'netAmount', 1213, 'created', '2026-11-14T10:00:00Z',
                           'paymentRecord', jsonb_build_object('id', public.fn_jobber_gid('JobberPaymentsCreditCardPaymentRecord', '9000000000001'))))))));
    if (v_res ->> 'inserted')::int <> 1 or (v_res ->> 'lines_rewritten')::int <> 1
       or (select count(*) from public.payout_lines pl join public.payouts po on po.id = pl.payout_id
            where pl.payment_id = v_pay and po.arrival_date = date '2026-11-16' and po.net_amount = 12.13 and pl.fee_amount = 0.37) <> 1 then
      raise exception 'verify_fail: payout pass: %', v_res;
    end if;
    v_res := public.sync_jobber_payments('[]'::jsonb, jsonb_build_array(public.fn_jobber_gid('OtherPaymentRecord', '9000000000001')));
    if (v_res ->> 'removed')::int <> 1 or (select deleted_at from public.payments where id = v_pay) is null then
      raise exception 'verify_fail: gone pass: %', v_res;
    end if;
    raise exception 'verify_undo';
  exception when others then
    if sqlerrm <> 'verify_undo' then raise; end if;
  end;
  if exists (select 1 from public.payments) or exists (select 1 from public.entity_source_links where entity_type in ('payment', 'payout')) then
    raise exception 'verify_fail: the throwaway rows were not undone';
  end if;

  raise notice 'verify ok';
end $verify$;

COMMIT;
