# ADR 003 — `service_configs` is 3NF (one row per service type)

- **Status:** Accepted (2026-04)
- **Related:** [ADR 005](005-3nf-standing-check.md), [ADR 002](002-entity-source-links.md)

## Context

The Airtable CRM stored per-client service configuration as a flat row with dozens of repeating columns:

```
clients (Airtable):
  gt_frequency, gt_last_visit, gt_next_visit, gt_price, gt_permit, gt_size, …
  cl_frequency, cl_last_visit, cl_next_visit, cl_price, …
  wd_frequency, wd_last_visit, wd_next_visit, …
  aux_frequency, …
  sump_frequency, …
  grey_water_frequency, …
  warranty_frequency, …
```

Pulled into Supabase 1:1, this would be ~30+ nullable columns per client and would balloon every time Unclogme adds a service type. Every service type also has the same *shape* (frequency, pricing, permit, status), so the repetition is a classic 3NF violation.

## Decision

One row per `(client_id, service_type)` in a dedicated `service_configs` table:

```
service_configs
  id BIGSERIAL PK
  client_id BIGINT FK → clients
  service_type TEXT       — 'GT' | 'CL' | 'WD' | 'AUX' | 'SUMP' | 'GREY_WATER' | 'WARRANTY'
  frequency_days INTEGER
  first_visit DATE
  last_visit DATE
  next_visit DATE
  stop_date DATE
  price_per_visit NUMERIC(12,2)
  status TEXT             — 'On Time' | 'Late' | 'Critical' | 'Paused'
  schedule_notes TEXT
  equipment_size_gallons NUMERIC
  permit_number TEXT
  permit_expiration DATE
  created_at, updated_at TIMESTAMPTZ

  UNIQUE (client_id, service_type)
```

The legacy flat layout is exposed for humans via the `client_services_flat` view (pivot-back).

## Consequences

**Positive:**
- Adding a new service type = one row, zero schema change.
- Null-reduction: a client with only GT service has one row instead of 30 empty `cl_*`/`wd_*` columns.
- Aggregate queries work naturally (`GROUP BY service_type`).
- Permit expiration tracking is per-service, which matches DERM's real model.

**Negative / accepted trade-offs:**
- Operational staff (Aaron, Diego) prefer the flat layout. Solved via the `client_services_flat` view — one source of truth, two presentations.
- Queries that touch multiple services per client need a JOIN/aggregate instead of a wide row. Acceptable.

**Frequency unit convention:**
- Airtable stores GT and CL frequencies in *months*, WD in *days*.
- `service_configs.frequency_days` is **always days**. Conversion happens at webhook/sync time, not on read. Preserves the one-source-of-truth rule.
