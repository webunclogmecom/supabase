# ADR 002 — `entity_source_links` replaces source-prefixed columns

- **Status:** Accepted (2026-04)
- **Deciders:** Fred Zerpa (guardrail), Viktor
- **Related:** [ADR 001](001-webhooks-over-cron.md)

## Context

Early schema drafts added source-prefixed columns per integration:

```
clients.jobber_client_id
clients.airtable_record_id
properties.jobber_property_id
visits.jobber_visit_id
visits.airtable_visit_id
invoices.jobber_invoice_id
employees.samsara_driver_id
employees.fillout_user_id
...
```

This pattern has two architectural problems:

1. **Business tables bleed integration history.** `clients.name` is a property of the client. `clients.jobber_client_id` is a property of *how Jobber happens to identify the same entity*. Mixing them in one table conflates domain and integration.
2. **Schema churn every time a source is added or removed.** The May 2026 Jobber/Airtable sunset would require dropping ~15 columns and dealing with orphaned FKs. Adding Odoo would require adding that many more.

## Decision

**Exactly one table tracks cross-system identity for every entity type:** `entity_source_links`.

```
entity_source_links
  id BIGSERIAL PK
  entity_type TEXT      — 'client', 'property', 'job', 'visit', 'invoice', ...
  entity_id BIGINT      — FK-in-spirit to the local entity's id (polymorphic)
  source_system TEXT    — 'jobber', 'airtable', 'samsara', 'fillout'
  source_id TEXT        — the ID in the source system
  source_name TEXT      — human-readable name for debugging
  match_method TEXT     — 'code_exact' | 'name_fuzzy' | 'manual' | 'api_webhook'
  match_confidence NUMERIC(3,2)
  synced_at TIMESTAMPTZ
  created_at TIMESTAMPTZ

  UNIQUE (entity_type, entity_id, source_system)
  UNIQUE (entity_type, source_system, source_id)
```

Business tables have **zero** `jobber_*` / `airtable_*` / `samsara_*` / `fillout_*` columns. If you find one, it's a bug.

## Consequences

**Positive:**
- Adding a source = inserting rows. No schema change.
- Sunsetting a source = deleting rows with `source_system = 'X'`. No business-table churn.
- One query pattern resolves inbound (`source_id` → `entity_id`) and outbound (`entity_id` → `source_id`) for any entity type.
- Match quality is explicit: `match_method` + `match_confidence` are auditable.

**Negative / accepted trade-offs:**
- Polymorphic FK — `entity_id` can't be a real FK constraint because it points at different tables depending on `entity_type`. Enforced by convention + application-layer checks.
- All lookups go through one table. At current scale (10k rows) this is free; at 100M rows we'd partition by `entity_type` or split per-type.
- No cascading deletes. If a business row is hard-deleted, its `entity_source_links` rows orphan. Mitigation: we don't hard-delete (use `status` instead).

**What this rules out:**
- **No `jobber_*`, `airtable_*`, `samsara_*`, `fillout_*`, or `odoo_*` columns on any business table.** Ever. Fred is the explicit guardrail on this — the rule appears in `CLAUDE.md` and in Fred's auto-memory. AI agents that propose such columns are blocked and must be told to use `entity_source_links` instead.
