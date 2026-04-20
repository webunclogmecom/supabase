# ADR 006 — No QuickBooks; Jobber is the payment source of truth

- **Status:** Accepted (2026-04)
- **Deciders:** Fred Zerpa (explicit)

## Context

Earlier planning treated QuickBooks as a data source to integrate. QuickBooks holds Unclogme's accounting: P&L, tax filings, reconciliations. It would be a candidate for a separate source system alongside Jobber / Airtable / Samsara / Fillout.

Two problems:

1. **Every invoice and payment already flows through Jobber.** Jobber writes to `invoices.paid_at` when payment is received. QuickBooks would be a second copy of the same data — reconciliation risk with no new information.
2. **Integration cost vs. value.** Building QuickBooks ingestion means another Edge Function, another `webhook_tokens` row, another rate-limit contract, and another source in `entity_source_links`. None of which unlocks any query we can't already answer from Jobber.

Accounting staff (Emily, the bookkeeper) read QuickBooks directly — outside this system. No downstream consumer of Supabase needs QuickBooks data.

## Decision

**QuickBooks is explicitly excluded from this database.**

- No `quickbooks` entry in `entity_source_links.source_system`.
- No `webhook-quickbooks` Edge Function.
- No QuickBooks columns, even "nullable for now."

Payment state for any invoice lives on the invoice:
- `invoices.paid_at IS NOT NULL` → paid in full.
- `invoices.outstanding_amount > 0` → partial or unpaid.
- `invoices.invoice_status = 'bad_debt'` → written off.

When Jobber sunsets in May 2026, Odoo.sh takes over invoicing. At that point, Odoo writes to the same `invoices` table (via its own Edge Function), with `entity_source_links.source_system = 'odoo'`. Still no QuickBooks.

## Consequences

**Positive:**
- One less integration to build and maintain.
- One less set of rate limits and tokens.
- Payment state queries are simple: one table, one timestamp column.

**Negative / accepted trade-offs:**
- If we ever need pre-Jobber payment history (2003–2017 era), it lives in QuickBooks and is not queryable from here. Accepted: that data is for tax/audit, not operations.
- If accounting reconciliation ever uncovers a drift between Jobber and QuickBooks, this database sides with Jobber by default. Accepted: Jobber is where the money event happens.

**If this is ever reversed**, the reversal must supersede this ADR explicitly, and the migration must write QuickBooks IDs into `entity_source_links` like any other source system (no `quickbooks_*` columns).
