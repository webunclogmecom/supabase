# 2026-06-25 — Service-Call line-item prices + push to Jobber

Fred: the New Visit form had no way to price line items, and Service-Call line
items added in the Calendar never appeared in Jobber.

## What we found (evidence)
- **Form:** no price field — services are a multi-select by name; `create_calendar_visit`
  took service IDs only and stored every line item at `unit_price = 0`; `service_line_items`
  had no price column. (Confirmed live in the app + in the RPC.)
- **Push:** `jobber-push-visit` only sent `title/instructions/schedule(+driver)` — it never
  called any line-items mutation, so visit line items stayed DB-only. Jobber *does* support
  visit line items via the separate `visitCreateLineItems` mutation (requires `unitPrice`).
- **Pricing model (key):** **Service-Agreement** line items are priced **per client** and
  already live on the **Jobber SA job** (verified: 099-PV SA #99900735 = "02 – Pumping" $700;
  source = Airtable "Job Line Items", 287 rows, prices vary 8× across clients). **Service-Call**
  services (09–24) have **no price anywhere** and are ad-hoc/variable.

## Decision (Fred)
Service-Call line items get an **editable price on the form (default blank)** + an optional
**catalog default** per service (fill later). SA prices stay per-client on the Jobber job —
untouched.

## Built (backend — DONE + live-verified)
- `service_line_items.unit_price` (nullable) — optional catalog default per service.
  `2026-06-25_calendar_visit_line_item_prices.sql`.
- `create_calendar_visit` (public + ops) → optional `p_line_item_prices jsonb`
  (`{service_line_item_id: {unit_price, quantity}}`); per line item
  `price = COALESCE(form, catalog default, 0)`, `qty = COALESCE(form, 1)`, `total = price×qty`.
- `jobber-push-visit` (v15) → `syncVisitLineItems`: **Service-Call visits only** push their
  line items to the Jobber visit via `visitCreateLineItems` (idempotent — deletes + recreates
  on update); **SA visits skipped**. Verified: re-pushing visit 6804 put "22 – Service Call –
  Labor" on the Jobber visit ($0 until priced).

## Remaining
- **Form (Lovable):** editable price (+ qty) field per selected SC service → passes
  `p_line_item_prices` to `create_calendar_visit`.
- **Catalog defaults:** Fred fills `service_line_items.unit_price` for SC services that have a
  standard rate (optional, anytime).
- Until the form ships, SC line items push at the catalog default (or $0) and can be priced in Jobber.
