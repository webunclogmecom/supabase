# The payments copy: Jobber payments and bank payouts in our database (2026-11-14)

*Fred, 2026-11-14 about 4:55 AM ET: "Build the copy now (Recommended) ... remember to have link a sync data to keep the
data up to the date. Because the finances is being handled in Jobber, so we need to have a way to get that data from
Jobber, see if there is a way to have a good way to have that realtime, like with the webhook but if we need to have
cronjob then decide the frequency of fetching that data", and "Client App setting" for who opens Finances. Plan:
`Building Apps/Ops Portal/docs/specs/2026-11-13-jobber-payments-and-people.md`, section C (section B, who did what, is
not part of this). Built by a helper of the session named Supabase.*

Migrations: `docs/migrations/2026-11-14_0620_payments_copy.sql` (tables, link CHECK, writers, reads) and
`2026-11-14_0720_payments_copy_schedule.sql` (two cron jobs, two targets, the health watch); undo beside each
(`2026-11-14_rollback_payments_copy_schedule.sql` FIRST, then `2026-11-14_rollback_payments_copy.sql`).
Edge functions: `webhook-jobber` v153 (six new topics, extra invoice and quote fields), `sync-jobber-payments` (new).
Shared: `supabase/functions/_shared/jobber-payments.ts` (the selections and the write loop, used by all three callers).
Backfill: `scripts/sync/backfill_jobber_payments.mjs`. Checks: `scripts/checks/jobber_payments_write_loop.mjs`
(the write loop on stubs, with a mutant that must fail) and the backfill's own count check (`--only` to narrow it).

## What is stored

| table | one row per | columns |
|---|---|---|
| `public.payments` | money event: payment, deposit, refund, failed payment, bad debt (not the issued-invoice ledger lines, which repeat `invoices`) | `client_id`, `kind`, `method`, `origin`, `amount`, `entered_at`, `reference`, `details`, `receipt_sent_at`, `fee_amount`, `processor_status`, `card_brand`, `card_funding`, `refunded_at`, `reverses_payment_id`, `deleted_at` |
| `public.payment_allocations` | payment and the invoice OR quote it pays | `payment_id`, `invoice_id` or `quote_id` (exactly one, CHECK), `amount` |
| `public.payouts` | bank payout | `status`, `method`, `arrival_date`, `issued_at`, `net_amount`, `failure_reason`, `deleted_at` |
| `public.payout_lines` | line of a payout | `payout_id`, `kind`, `payment_id` (when the line names a payment record: a payment, a refund, a dispute), `gross_amount`, `fee_amount`, `net_amount`, `occurred_at` |

- **Identity:** the Jobber id lives in `entity_source_links` (types `payment`, `payout`, added to the CHECK). A payment
  is its NUMBER: Jobber shows `OtherPaymentRecord/N` in the ledger and `PaymentRecord/N` under an invoice, so the
  stored id is always base64 `gid://Jobber/PaymentRecord/N` (`gid://Jobber/PayoutRecord/N` for payouts), built by
  `public.fn_jobber_gid(type, number)` from `public.fn_jobber_gid_number(any id)`.
- **`kind`** from Jobber's `adjustmentType`: PAYMENT `payment`, DEPOSIT `deposit`, REFUND `refund`,
  FAILED_ACH_PAYMENT `failed_payment`, BAD_DEBT `bad_debt`. INVOICE, VOIDED, CORRECTION, INITIAL_BALANCE are not
  money and are skipped.
- **`amount`** is Jobber's unsigned amount (Jobber's `rawAmount` is negative for money in); the kind gives the
  direction. `fee_amount` as Jobber states it (negative on a refund).
- **`method`** is the record's TYPE in snake case: `check`, `zelle`, `ach_bank_payment` (bank ACH outside Jobber),
  `credit_card` (card outside Jobber), `other`, `cash`, `cash_app`, `jobber_payments_credit_card`,
  `jobber_payments_ach`, `jobber_payments_refund`, `refund` (offline refund), and the rest of Jobber's types the same way.
  A bad debt is an `other` record.
- **`origin`** Jobber's `paymentOrigin` lowercased (`employee_online_origin` typed by staff, `client_online_origin`,
  `system_generated` automatic charge, `ewallet_origin`, `api_origin`, ...). **`processor_status`** Jobber Payments'
  `transactionStatus` lowercased (`succeeded`, `pending`, `failed`, `refunded`, `partially_refunded`), null otherwise.
- **`reference`**: the check number, or the confirmation number (Zelle, other, bank ACH ...), or a card-outside-Jobber
  transaction number. **Not stored, on purpose:** card last digits, name on card, expiry, bank name, transaction ids.
- **What it pays:** Jobber's allocation list; when that list is empty, the one invoice the payment names, else the one
  quote (30 deposits name both an invoice and a quote and list no allocation: they are linked to the invoice, where the
  money went). A list Jobber cuts (more than 25) is never stored cut: the payment is held and reported.
- **`reverses_payment_id`:** a refund's `refundedPaymentRecord`, a failed ACH's `negatedBalanceAdjustment`.
- **Payouts:** amounts arrive in cents and are stored in dollars; `arrival_date` is the UTC date Jobber gives.
  Which payout a payment landed in is read from `payout_lines` (third normal form), never stored on the payment.
- **The fee twice, on purpose (ADR 004 exception):** on the payment (what Jobber kept) and on its payout line (the
  bank statement). The totals differ by the payments not in a payout yet.
- **New columns on existing tables**, filled from now on by the invoice and quote handlers (and once by the backfill):
  `invoices.paid_at` (Jobber `receivedDate`), `subtotal`, `tax_amount`, `discount_amount`, `tax_label` (the tax rate's
  name: "CC Fees ..." is the card fee, not a sales tax), `viewed_at`, `voided_at`, `void_reason` (the code, lowercased);
  `quotes.sent_at` (the REAL sent date: it held the creation time until 2026-11-14), `approved_at`,
  `converted_to_job_at`, `subtotal`, `tax_amount`, `deposit_amount`, `viewed_at`, and the quote's lines
  (`line_items.quote_id`, through `public.rewrite_quote_line_items`). A quote's creation date is not stored any more
  (`created_at` is our row's date); the 345 old values are in `backups/2026-11-14_quotes_sent_at_before_payments_copy.json`.
- **Access:** RLS on (no policy) and no grant to anon, authenticated or service_role on the four tables and on
  `public.v_payment_rows`: nothing reads them directly. Audited (`audit_payments`, `audit_payment_allocations`,
  `audit_payouts`, `audit_payout_lines`; `audit_quotes` was added the same day). `client.entity_source_links` leaves
  the payment and payout links out, as it leaves out `source_record`.

## The writers (service_role only; never called by an app)

| function | does |
|---|---|
| `public.sync_jobber_payments(p_nodes jsonb, p_gone jsonb default '[]')` | raw Jobber payment nodes in, upserted by number; allocations replaced in the same transaction, under one advisory lock per payment, only when they differ; `p_gone` (ids Jobber answered null for when read by id) marked `deleted_at`, at most 20 per call. Returns counts, `held` and `missing` {invoices, quotes, payments} |
| `public.sync_jobber_payouts(p_nodes jsonb, p_gone jsonb default '[]')` | the same for payouts and their lines; a payout whose line names a payment not here yet is held |
| `public.fn_jobber_payments_unseen(p_from, p_to, p_seen jsonb)` | the held payments entered in the window that a COMPLETE read of it did not return; REFUSES an empty answer over a window we hold payments in, and more than 20 unseen that are also more than a quarter of the window |
| `public.sync_jobber_invoice_extras(p_nodes)`, `public.sync_jobber_quote_extras(p_nodes)` | the new invoice and quote fields; a node missing one of the keys is skipped (never read as "cleared"); compare before write |

The callers read Jobber and pass the nodes as read; a reply that is not JSON, has no `data` key, or carries an
`errors` array (or the singular `error` of an inactive account) throws before anything is written. The write loop
(`writePayments`, `writePayouts` in `_shared/jobber-payments.ts`) imports what a held payment waits for (an invoice
or quote through webhook-jobber's own handler, a refunded payment read by id) and writes it again, up to 3 rounds.

## How it stays current

1. **Webhooks, real time.** `webhook-jobber` v153 handles `PAYMENT_CREATE`, `PAYMENT_UPDATE`, `PAYMENT_DESTROY`,
   `PAYOUT_CREATE`, `PAYOUT_UPDATE`, `PAYOUT_DESTROY`: whatever the topic, it re-reads the object by id
   (`paymentRecord(id)` / `payoutRecord(id)`, API 2026-09-09) and writes what Jobber holds; a null re-read is a
   removal. A CREATE that lands after a DESTROY re-reads null and writes nothing. **They fire only after Fred adds the
   six topics in Jobber's Developer Center** (below). Until then a delivery would be acknowledged and dropped.
2. **The net, `sync-jobber-payments`, every 15 minutes** (pg_cron `jobber-payments-sync`, `13,28,43,58 * * * *`,
   `fn_request_jobber_sync('payments')`): the 50 payment records Jobber changed last (sort `UPDATED_AT`, newest first:
   a new entry, a status change, an edit or a back-dated entry surface there), every record entered in the last 2 days
   (in case more than 50 changed at once), and every payout updated in the last 2 days. Writes only; no removal.
3. **The nightly window** (pg_cron `jobber-payments-window`, `50 8 * * *` UTC = 03:50 ET in winter, 04:50 in summer,
   `?mode=window&days=35`): every record entered in the last 35 days, complete or nothing; held payments of the window
   Jobber did not return are re-read by id (a node: its entry date moved, written; null: removed), after
   `fn_jobber_payments_unseen` refused nothing; every payout updated in the window.
4. **Health:** both sources are in `log_jobber_sync_health`'s watched list (`jobber_payments` stale after 50 minutes,
   `jobber_payments_window` after 26 hours); a run that holds a payment it could not complete reads `partial`.
   `sync_log.details` carries the counts.

**Why these frequencies** (measured 2026-11-14 on the read app): a 15-minute run costs about 1,500 to 2,500 Jobber
points and 5 s (the bucket holds 10,000 and refills 500 a second, so about 1% of the read app's budget next to the
5-minute poll); payments are entered by people through the day, so 15 minutes is the most a payment typed in Jobber
waits before the webhooks are on. The 35-day window (measured 2026-11-14 by hand: 480 records of which 246 money, 23
payouts, 20 s, about 10,500 points, paced to keep 3,500 for the poll) is the only path that removes a payment Jobber
deleted, so it runs once a night. GitHub is never used
(its timed jobs run every 4 to 8 hours). Payments filter by entry date only, so they have no cursor; payouts filter by
`updatedAt`, and a 2-day look-back over a 15-minute cadence needs no stored cursor.

**How stale the copy can be:**

| | webhooks off (today) | webhooks on |
|---|---|---|
| a payment entered or changed in Jobber | 15 min (the next net run) | seconds |
| a payment back-dated more than 2 days and over 50 changes behind | until the 03:50 ET window (about 24 h), if within 35 days | seconds |
| a payment deleted in Jobber | until the 03:50 ET window (about 24 h), if entered within 35 days; older only by webhook or a backfill re-run | seconds |
| a payout created or paid | 15 min | seconds |
| an invoice's paid date, tax, void; a quote's dates and lines | as today's invoice and quote sync: their webhooks, the 5-minute poll | the same |

## The backfill and the standing check

`node --experimental-strip-types scripts/sync/backfill_jobber_payments.mjs [--from 2024-01-01]` reads every ledger
record entered since `--from`, every payout, every invoice and every quote on the WRITE app's token (its own points
bucket, so the 5-minute poll on the read app is not starved; the token is read, never refreshed), writes them through
the writers above, re-reads by id what a complete answer lacks, and ends with a count check against the totals Jobber
returned in the same run (exit 1 on a difference). A second run changes nothing. `--check-only` is the standing check:
it reads both sides and writes nothing, comparing money records by kind (count, amount), by month, method and kind
(amount), and payouts (count, net); its method is worked out from the record type on its own, not from the SQL writer.

**Run 2026-11-14, 06:17 to 06:23 ET** (the first run stopped at the payouts: a call of 184 payouts hit the API's
statement timeout; the write loop now sends 100 payments or 20 payouts per call): 5,882 ledger records read (Jobber's
own `totalCount`), 2,897 of them money and every one already in the copy (0 inserted, 0 updated, 0 held: the run is
idempotent), 384 payouts with 1,688 lines, 2,991 invoices and 271 quotes given their new fields, 0 imports needed.
The count check: payment 2,822 ($1,502,971.43), deposit 38 ($36,739.59), refund 24 ($7,000.28), bad debt 3 ($351.04),
failed payment 10 ($3,080.68), payouts 384 ($666,315.39 net): ours equal Jobber's, count and amount. Money received
without the test client 112-YA since 2024-08-26: 2,849 records, $1,538,708.02 (the plan's 2,838 / $1,519,538.27 was read
the morning before). Every paid invoice now has `paid_at` (2,828); 23 Jobber Payments payments are not at the bank yet
($10,402.76). One $0 entry (2026-04-07) has no client in our database (its Jobber client is not linked here).

## What Fred switches on (Jobber's Developer Center, his own login)

1. Sign in at https://developer.getjobber.com and open the app **Unclogme Supabase Sync** (the one whose webhooks point
   to `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-jobber`; the read app, not the write app).
2. In its Webhooks section add six topics, each with that same URL: `PAYMENT_CREATE`, `PAYMENT_UPDATE`,
   `PAYMENT_DESTROY`, `PAYOUT_CREATE`, `PAYOUT_UPDATE`, `PAYOUT_DESTROY`.
3. Save. No new permission and no re-authorization: the app already holds the payments read scope (the net reads
   payments and payouts with its token today).
4. Check: after the office records a payment, `webhook_events_log` shows a `PAYMENT_CREATE` row with status
   `processed` and a nested payload (`payload ? 'data'`).

## The reads for the Finances Payments page (authenticated only)

Each is STABLE SECURITY DEFINER, `search_path ''`, EXECUTE revoked from PUBLIC, anon and service_role by name, granted
to `authenticated`. Each starts with `hr.fn_require_app('client_app', 'view')` (the Client App setting, View), then the
sign-in and staff checks of `client.get_client_activity`. A person without the Client App gets 42501 "You do not have
access to do this in Client App. Ask Fred or Yannick to change it." Dates are Eastern. Removed payments are left out.

### `client.list_payments(...)` returns jsonb

Arguments, all optional: `p_from date`, `p_to date` (entered on, Eastern, inclusive), `p_methods text[]`,
`p_kinds text[]`, `p_statuses text[]` (processor status), `p_client_id bigint`, `p_at_bank boolean`,
`p_refunds_and_failed boolean default false` (refund and failed records, and payments failed, refunded, partly
refunded or disputed), `p_include_zero boolean default false` (the $0 "other" entries that close $0 invoices are
hidden by default), `p_limit int default 200` (1 to 1,000), `p_offset int default 0`.

```json
{ "total": 4, "money_in": 77.50, "money_out": 25.00, "fees": 0.75, "limit": 200, "offset": 0,
  "payments": [ { "id": 2, "client_id": 381, "client_code": "112-YA", "client_name": "...", "kind": "payment",
    "method": "check", "origin": "employee_online_origin", "amount": 12.50, "signed_amount": 12.50, "fee_amount": null,
    "entered_at": "2026-11-10T15:00:00+00:00", "entered_on": "2026-11-10", "reference": "777", "details": "...",
    "receipt_sent_at": null, "processor_status": null, "card_brand": null, "card_funding": null, "refunded_at": null,
    "reverses_payment_id": null, "via_jobber_payments": false, "payout_id": null, "payout_arrival_date": null,
    "payout_status": null, "at_bank": null,
    "pays": { "count": 1, "invoices": [ { "id": 2904, "number": "...", "amount": 12.50 } ], "quotes": [] } } ] }
```

`total`, `money_in` (payments and deposits), `money_out` (refunds and failed) and `fees` cover the whole filtered set,
not the page. Newest first. **`at_bank`**: for a Jobber Payments card or ACH payment or deposit, true once a line of
a PAID payout names it, false until then ("Not at the bank yet" = `p_at_bank => false`); null for every other method
(a check never goes through a payout). `signed_amount`: + for money in, - for refunds and failed, 0 for a bad debt.

### `client.payment_months(p_from date, p_to date, p_client_id bigint, p_methods text[])` returns jsonb

Every month of the range, zero months included (default: the 14 months up to the current one; at most ten years):

```json
{ "from": "2025-10-01", "to": "2026-11-14", "months": [ { "month": "2026-11", "received": 77.50, "count": 3,
  "refunds": 25.00, "failed": 0, "fees": 0.75, "by_method": { "check": 12.50, "zelle": 40.00, "jobber_payments_credit_card": 25.00 } } ] }
```

`received` and `by_method` are payments and deposits; `count` leaves out $0 entries.

### `client.get_payment(p_payment_id bigint)` returns jsonb or null

`{ "payment": <a list row>, "removed_at": null, "allocations": [ { "invoice_id", "invoice_number", "invoice_status",
"invoice_total", "invoice_outstanding", "invoice_paid_at", "quote_id", "quote_number", "quote_status", "amount" } ],
"payout": { "id", "arrival_date", "status", "net_amount", "failure_reason", "line": { "kind", "gross_amount",
"fee_amount", "net_amount" } } or null, "reversed_by": [ { "id", "kind", "method", "amount", "entered_at",
"processor_status" } ], "reverses": { ... } or null }`. A removed payment still opens, with `removed_at`.

### `client.get_invoice_payments(p_invoice_id bigint)` returns jsonb or null

`{ "invoice_id", "invoice_number", "invoice_status", "client_id", "total", "outstanding_amount", "paid_at", "due_date",
"sent_at", "viewed_at", "voided_at", "void_reason", "payments": [ { "payment_id", "entered_at", "entered_on", "kind",
"method", "origin", "reference", "allocated_amount" (what it puts on THIS invoice), "payment_amount", "split" (it pays
several invoices), "processor_status", "at_bank", "payout_arrival_date" } ] }`. `paid_at` is Jobber's received date and
is kept as its own fact: 7 invoices are paid with no payment, and $0 invoices are paid by $0 entries.

**Rehearsed 2026-11-14** (rolled back, `mockups/2026-11-14-payments/reh_m1.mjs`, 44 of 44): every read answers the
same for person 58 given the Client App alone as for Fred, and refuses person 58 with no app.

## Rules that must not regress

- Never write a value not just read from Jobber; never read a missing answer as "gone" (only a by-id `null` inside a
  well-formed reply is a removal, and the window refuses an empty or mass answer before any re-read).
- One writer per kind, one lock per object, allocations and lines in the same transaction, replaced only when they
  differ (webhooks arrive at least once, in pairs, in either order).
- The payment's identity is its number, never the typed id. A new reader of the links filters `entity_type`.
- No app reads the tables: a new page reads through a `client` function behind the Client App gate.
- The three callers share `_shared/jobber-payments.ts`; the mapping of fields lives only in the SQL writers.
