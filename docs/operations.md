# Operations Guide

Column-name gotchas, query patterns, and operational realities of the Unclogme database. If you're writing a query or a report and something looks off, read this first.

---

## Overnight shift handling

Trucks work through midnight. 10pm–3am is **standard** for commercial trucks (David, Goliath, Moises). Only Cloggy is daytime-only.

**Consequence for queries:**
- A visit that starts at 10pm on the 14th may complete at 3am on the 15th.
- `visit_date` is the *logical* operating date (usually the day the shift started), not the clock date of `start_at`.
- For date-range filters, either:
  - Use `visit_date` when you want "which shift was this on"
  - Use a ±12h window on `start_at`/`end_at` when you want "which clock day did activity happen"
  - Check both `start_at::date` AND `end_at::date` when either could matter

The `driver_inspection_status` view already handles this — it matches POST inspections submitted the morning after the PRE.

### Shift week convention

- **Sunday evening through Friday morning** is the standard shift week.
- Saturday is Shabbat; Aaron and Yan are unavailable. Diego runs weekend emergency coverage by SOP.

---

## Column name gotchas

Common query errors (all caught in agent conversations before):

| Wrong | Right | Table |
|---|---|---|
| `c.active = true` | `c.status = 'ACTIVE'` | `clients` |
| `e.active = true` | `e.status = 'ACTIVE'` | `employees` |
| `e.name` | `e.full_name` | `employees` |
| `v.status` | `v.visit_status` | `visits` |
| `v.is_complete` | `(v.visit_status = 'COMPLETED')` or use the `visits_with_status` view | `visits` (dropped 2026-04-20) |
| `v.gps_confirmed` | `v.is_gps_confirmed` | `visits` |
| `sc.next_visit` | `(sc.last_visit + (sc.frequency_days \|\| ' days')::interval)::date` or use `clients_due_service` | `service_configs` (dropped 2026-04-20) |
| `sc.status` | `clients_due_service.due_status` (view column, computed on read) | `service_configs` (dropped 2026-04-20) |
| `m.manifest_number` | `m.white_manifest_number` | `derm_manifests` |
| `m.manifest_date` | `m.service_date` | `derm_manifests` |
| `i.outstanding` | `i.outstanding_amount` | `invoices` |
| `v.tank_capacity_gallons` | `v.fuel_tank_capacity_gallons` OR `v.grease_tank_capacity_gallons` | `vehicles` |

The `v_vehicle_telemetry_latest` view exposes `fuel_gallons_computed` (not `fuel_gallons` — that column was dropped in the 3NF migration). See [ADR 005](decisions/005-3nf-standing-check.md) and [ADR 010](decisions/010-drop-stored-derived-columns.md).

**Photos:** `visit_photos` and `inspection_photos` tables were dropped on 2026-04-20. Use `photos` + `photo_links` instead — see [ADR 009](decisions/009-unified-photos-architecture.md) and [schema.md](schema.md#photos--0-rows--intrinsic-photo-metadata).

---

## Truck name ≠ person name

Three trucks are named after people. **They are not people.**

| Name | What it actually is |
|---|---|
| **Moises** | Kenworth T880 2023, 9,000 gal grease tank. NOT a person. |
| **David** | International MA025 2017, 1,800 gal grease tank. NOT a person. |
| **Goliath** | Vacuum truck, 4,800 gal grease tank. Currently INACTIVE — no Samsara data. NOT a person. |
| **Cloggy** | Toyota Tundra 2020, 126 gal grease tank. Only daytime truck. |

In historical Airtable visits, references like "Big One" / "the big one" / lowercase "david" / "moise" all map to one of these trucks. `scripts/populate/populate.js` does fuzzy name resolution; 1505 of 2208 legacy visits resolved to a `vehicle_id`, the rest fell through.

---

## Common operational views

### `clients_due_service` — the most important view

> Overdue and due-soon clients. Most operationally critical view.

Used daily by Aaron and Diego for scheduling. Driven by `service_configs.next_visit` and `frequency_days`.

Typical call:
```sql
SELECT * FROM clients_due_service
WHERE status IN ('Late','Critical')
ORDER BY days_overdue DESC
LIMIT 50;
```

### `client_services_flat`

3NF `service_configs` pivoted back into flat `gt_*` / `cl_*` / `wd_*` columns for humans. Use this when building reports for Aaron/Diego, not for engineering work.

### `driver_inspection_status`

Daily PRE/POST compliance check. Handles overnight shifts (matches a POST submitted at 3am the next morning with the PRE from the previous evening).

### `manifest_detail`

DERM manifests joined with client info and a count of linked visits. Use when tracking compliance or preparing client reports.

### `v_vehicle_telemetry_latest`

Latest telemetry snapshot per vehicle from `vehicle_telemetry_readings`. Computes `fuel_gallons_computed` on read — never stored.

### `visits_recent` and `visits_with_status`

`visits_recent` — last 30 days with client context. `visits_with_status` — derived status fields (e.g., whether a visit is late relative to its service_config).

---

## DERM compliance — daily queries

**90-day max cleaning interval** for food-service establishments in Miami-Dade. Fines: $500–$3,000.

Useful query:
```sql
SELECT c.name, sc.service_type, sc.last_visit, sc.frequency_days,
       CURRENT_DATE - sc.next_visit AS days_overdue
FROM service_configs sc
JOIN clients c ON c.id = sc.client_id
WHERE sc.service_type = 'Pumping'   -- was 'GT' until 2026-08-03
  AND sc.next_visit < CURRENT_DATE
  AND sc.status IN ('Late','Critical')
ORDER BY days_overdue DESC;
```

Manifest number series: **DADE = `481xxx`**, **BROWARD = `294xxx`**. The view `manifest_detail` exposes both.

---

## Hierarchical data: clients → properties → visits

- A client has N properties. One is `is_billing=true`, often one is `is_primary=true`.
- A visit ties to both `client_id` and `property_id` — not all visits share a client's primary property (chains like La Granja have 5+ locations under one client).
- When in doubt: filter by `property_id`, not `client_id`, for location-specific data.

Multi-location clients documented:
- La Granja (5+ locations)
- Carrot / Carrot Express (4+ locations)
- Grove Kosher (4 locations)
- Pura Vida (4+ locations)

---

## GDO permits — bound to LOCATION, not client (per Fred 2026-05-25)

A **GDO** (Grease Disposal Operator permit) is issued by Miami-Dade DERM to a **physical
location**, not to the business operating there. The GDO number stays with the address
across client turnover.

### Concrete example

If `Yan's Restaurant` operates at 123 Main St and the GDO is `GDO-103595`:
- When `Yan's Restaurant` closes and `Fred's Restaurant` takes over the same address, the
  GDO is still `GDO-103595` — the new client inherits the permit.
- The `clients` row may change (new owner, new client_code, new contract dates) but the
  `properties` row stays the same and the GDO stays bound to it.

### What the GDO carries

Beyond the permit number itself:
- **Maximum service frequency** — the city-mandated upper bound for how long between
  Grease Trap cleanings (e.g. "must be pumped at least every 90 days"). The negotiated
  contract `frequency_days` must be ≤ this max.
- **Permit document** (PDF) — the actual signed permit, customer-facing in FP.
- **Expiration date** — GDOs are renewed annually; expired GDO = compliance risk.

### Schema implication

Currently `service_configs` carries `permit_number` and `permit_document_path` on a per
(client, service_type) basis. This is **misaligned with reality**:

- If a property changes client, all the new client's `service_configs` rows lose the GDO
  data until someone manually re-enters it.
- The same GDO ends up duplicated across multiple `service_configs` rows for the same
  property (one per service type Pumping/Cleaning/Warranty of Drainage — GT/CL/WD/LS before 2026-08-03 — fixed today by the 2026-05-25 backfill,
  but the schema still has the data at the wrong level of abstraction).

**Forward design (not yet implemented):** GDO data belongs on `properties`, not
`service_configs`. Either:
- New columns: `properties.gdo_number`, `properties.gdo_max_frequency_days`,
  `properties.gdo_permit_document_path`, `properties.gdo_expiration_date`, OR
- A separate `property_permits` table FK'd to properties (one-to-many if a property has
  multiple compliance permits over its lifetime).

When this migration happens, `service_configs.permit_*` columns get dropped, and the
`customer.permits` view recomposes from `properties` joined to `service_configs` (for the
per-service `frequency_days`).

### Until that migration lands

The webhook-airtable sync currently writes GDO Number to ALL the client's
`service_configs` rows (not just GT) — that's the workaround. Backfill script
`scripts/sync/backfill_permit_numbers_from_at.js` (TBD) re-runs the AT Clients.GDO
Number alignment if drift appears.

---

## Payments: `invoices.paid_at` is the truth

There is **no QuickBooks**, no separate payments table. See [ADR 006](decisions/006-no-quickbooks.md).

- `invoices.paid_at IS NOT NULL` → paid in full.
- `invoices.outstanding_amount > 0` → partial or unpaid.
- `invoices.invoice_status = 'bad_debt'` → written off.

A/R reporting:
```sql
SELECT SUM(outstanding_amount) AS total_ar
FROM invoices
WHERE invoice_status IN ('sent','awaiting_payment','overdue');
```

---

## Money + time conventions

| Convention | Rule |
|---|---|
| Money columns | `NUMERIC(12,2)` |
| Timestamps | `TIMESTAMPTZ`, always UTC in storage |
| Display | Convert to EDT (America/New_York) in the presentation layer |
| `updated_at` | Trigger-managed; **never set manually** |
| Service frequency | Always `days` in `service_configs.frequency_days`; converters happen at sync time |
| Odometer | `vehicle_telemetry_readings.odometer_meters` (Samsara reports meters); divide by 1609.34 for miles |
| Engine hours | `vehicle_telemetry_readings.engine_hours_seconds` (Samsara reports seconds); divide by 3600 |

---

## Upserts: always idempotent

All sync/population code uses `ON CONFLICT` upserts on natural keys. Scripts must be re-runnable with zero data corruption. If you write a script that isn't idempotent, don't merge it.

Example pattern (from `scripts/populate/populate.js`):
```sql
INSERT INTO clients (client_code, name, status, ...)
VALUES (...)
ON CONFLICT (client_code) DO UPDATE SET
  name = EXCLUDED.name,
  status = EXCLUDED.status,
  updated_at = NOW();
```

---

## "Live" vs "historical" cohorts

The database is a merge of two eras:

- **Post-webhook (2026-04 onward):** Every visit, invoice, client has complete `visit_assignments`, `actual_arrival_at`, `is_gps_confirmed`, and full `entity_source_links` coverage.
- **Pre-webhook historical (pre-2026-04):** 3,020 Airtable-sourced visits, ~1,400 of which predate the `vehicles` and `visit_assignments` tables. `visits.truck` (TEXT) and `visits.completed_by` (TEXT) are kept as intentional denorms to preserve attribution for this cohort. See [ADR 004](decisions/004-intentional-denormalization.md).

When writing analytics queries, decide which cohort you want. For "what happened in the last 12 months" both are valid. For "what did truck X do" you may need to union on `vehicle_id IS NULL` and fuzzy-match `truck` text.

---

## What you should NOT do

- **Don't hardcode credentials.** Ever. Read `docs/security.md`.
- **Don't delete data.** Use `status = 'INACTIVE'` or equivalent. Hard deletes break `entity_source_links` and historical joins.
- **Don't add source-prefixed columns.** Use `entity_source_links`. See [ADR 002](decisions/002-entity-source-links.md). Fred is the guardrail on this — if you're tempted to add `jobber_*`, stop.
- **Don't store derived values** that can be computed from other columns. Use a view. See [ADR 005](decisions/005-3nf-standing-check.md).
- **Don't set `updated_at` manually.** The trigger handles it.
- **Don't skip webhook signature validation.** Even in dev.
