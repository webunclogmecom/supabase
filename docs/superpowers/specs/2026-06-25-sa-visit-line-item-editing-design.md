# Per-visit Service-Agreement line-item editing — design spec

*2026-06-25. Status: DESIGN — awaiting Fred's review before implementation.*

## Goal

When creating (form) or opening (drawer) a **Service-Agreement (SA)** visit, show the
agreement's line items **pre-selected** with their **per-client price + quantity**, let the
office **change** them (services *and* fees/custom lines), save the per-visit override in our
DB, and **reflect it on that visit's Jobber bill**. Maintain 3NF; build on the existing
Service-Call line-item path without breaking it.

## Verified facts (live, 2026-06-25)

- **SA line items are already in our DB** — `public.line_items`, job-scoped (`job_id` set,
  `visit_id/invoice_id/quote_id` NULL), with `name`/`unit_price`/`quantity`/`total_price`,
  synced from Jobber by `webhook-jobber.handleJob` (SA jobs only). Match Jobber exactly.
  Coverage: 167/169 active SA jobs (2 stragglers: jobs 645, 815).
- **SA jobs are `billingType: VISIT_BASED`** (recurring). Each **visit inherits the job's
  line items**; the **invoice pulls the visit's lines** (job lines = visit lines = invoice
  lines, verified on job 567 / invoice 2605). A payment-fee line ("ACH fee" / "CC Fees") is
  sometimes added at invoice time.
- **No double-bill risk**: a visit carries one line set; our `syncVisitLineItems` already
  does delete-then-recreate, so edited lines **replace** the inherited ones (not add). Real
  SA invoices show a single line set, never doubled.
- The drawer **already displays** an SA visit's agreement lines (via the job-scoped fallback
  in `ops.v_calendar_visit_detail.line_items`, shipped earlier 2026-06-25). What's missing is
  making them editable + savable + pushable per visit.
- SA line items include **non-catalog** lines (e.g. "26 - ACH Fee (1%)", "25 - Credit card
  fee (3.53%)", "Drain Line Replacement") that are NOT in the `service_line_items` catalog.

## Data model (3NF — verdict: clean)

| Scope | Meaning |
|---|---|
| `line_items` row with `job_id` set | the **agreement template** (per-client agreed services + price) |
| `line_items` row with `visit_id` set | this **visit's instance** (what this visit bills) |

`line_items` stores `name`/`unit_price`/`quantity`/`taxable` **directly** (no
`service_line_item_id` FK column), so arbitrary lines already fit. Price/qty on a visit row
are point-in-time instance facts (same class as Service-Call visit lines and invoice lines) —
not a normalization anomaly. **No `scope` column** (derivable from which FK is set). An
**untouched** SA visit gets **no** visit-scoped rows — it keeps inheriting the agreement
(Jobber-side inheritance + our view's job fallback). Visit rows are written **only when the
office edits**.

## Changes

### A. Backend — extend the line-item editor to accept arbitrary lines
`edit_calendar_visit` / `create_calendar_visit` today take `p_service_line_item_ids` (catalog
ids) + `p_line_item_prices`. Add a path that accepts a **full line list**
(`[{name, unit_price, quantity, taxable, service_line_item_id?}]`) so fee/custom lines are
representable. Keep the existing catalog path working unchanged (Service Calls keep using it).
Still: DELETE+re-INSERT visit-scoped `line_items`, re-derive `service_type`/`derm_required`
(monotonic), bump `line_items_rev`. SECURITY DEFINER preserved.

### B. Pre-fill source
Form/drawer pre-fill defaults from the **job's** synced lines (`job_id = visit.job_id`) — the
per-client agreed prices — not the generic $0 catalog. (`ops.v_calendar_visit_detail.line_items`
already returns these; expose price+qty for all lines.)

### C. Jobber push — lift the SA skip
Remove the `^service agreement` early-return in `syncVisitLineItems` so an **edited** SA visit
pushes its lines onto the Jobber **visit** (delete-then-recreate replaces inherited; the
dedupe keeps it idempotent). Because SA billing is VISIT_BASED, the invoice reflects the
override. Invariants kept: push fires only on `line_items_rev` bump; source-gate
(`visit-calendar`/`supabase_cron`) keeps Jobber-born visits Jobber-mastered; never demote a
known-TRUE `derm_required`.

### D. Coverage
Backfill the 2 active SA jobs missing DB lines (645, 815) from Jobber; keep the SA job
line-item sync **Jobber-native** (Airtable sunsets May 2026).

### E. UX — form + drawer
- **Field order: quantity first, then price** — everywhere line items are edited (New Visit
  form + drawer), including the existing Service-Call editor (for consistency). (Fred's
  preference, 2026-06-25.) **STATUS: built + published standalone 2026-06-25** (Lovable
  "Reordered qty/price fields"); live visual confirm pending (browser renderer was unstable).
- **Drawer line-item display (polish phase, after A–D):** evaluate the best way to present a
  priced, multi-line agreement in the drawer — alignment, `$`/qty placement, per-line total,
  agreement subtotal, read vs edit states — and present **2 mockup options** for Fred to pick,
  rather than defaulting to the current `☑ name … $ … qty` checkbox row.

## Phases

1. **Backend** — extend RPCs (arbitrary lines) + lift SA push skip + backfill 2 jobs. Verify
   on a 112-YA-style SA test: edit SA visit lines/prices/qty → DB visit-scoped + Jobber visit
   override + (per-visit) invoice reflects it; no double-bill.
2. **Form/drawer wiring (Lovable)** — SA pre-fill (all lines incl. fees), editable qty+price,
   **qty-before-price** order, save via the extended RPC. Live-verify on an SA visit.
3. **Drawer UX polish** — mockup options for the line-item display → Fred picks → implement.

## Risks / watch-items

- **Untouched-visit default**: keep inheriting (no copy) — **CONFIRMED by Fred 2026-06-25**.
- **Jobber per-visit override reaching the invoice**: confirmed VISIT_BASED + invoice reads
  visit lines; re-verify end-to-end with a real edit before declaring done.
- **Don't break the Service-Call path** (the existing `service_line_item_ids` flow, the view
  fix, the push dedupe) — all must keep working.
- **Sync coverage**: only active SA jobs need pre-fill; ensure handleJob keeps them current.
