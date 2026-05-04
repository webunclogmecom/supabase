# ADR 014 — Source-prefixed columns ARE allowed in private state tables

**Date:** 2026-05-04
**Status:** Accepted
**Supersedes:** —
**Refines:** ADR 002 (entity-source-links)

## Context

ADR 002 says cross-system identity is tracked exclusively in
`entity_source_links` and **never as source-prefixed columns**
(`jobber_*_id`, `airtable_*_id`, etc.) on business tables. This rule was
written for **canonical business data** — tables like `clients`, `visits`,
`invoices` — where keeping the schema source-agnostic is essential because
multiple sources can produce the same entity and we want clean swap-out at
sunset.

When Viktor (or any future skill) wants to persist private operational
state in the DB — a check-processing dedup map, a Trello-nudge tracker, a
geocode cache — those tables reference **non-canonical external resources**:
- A Google Drive file ID
- A Trello card ID
- A Stripe charge ID
- An Airtable record ID for a non-canonical Airtable table

These external resources are NOT entities in our canonical schema. There's
no `clients` table for "Trello cards" — Trello cards are just IDs from a
remote system that Viktor's skill tracks.

## Decision

In **private state tables** (named `viktor_*`, `app_*`, or other
non-canonical prefix), source-prefixed column names ARE allowed for
references to external non-canonical resources.

### Allowed pattern

```sql
CREATE TABLE viktor_trello_nudges (
  trello_card_id        TEXT PRIMARY KEY,
  external_employee_id  BIGINT,                  -- canonical entity ref (BIGINT, loose FK)
  nudge_status          TEXT,
  escalation_threshold  TIMESTAMPTZ,
  nudged_at             TIMESTAMPTZ,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

- `trello_card_id TEXT` — Trello is non-canonical. Direct column is fine.
- `external_employee_id BIGINT` — `employees` IS canonical. Use the
  `external_<entity>_id BIGINT` loose-FK pattern from ADR 002.

### Disallowed (still)

```sql
-- ❌ never on canonical tables
ALTER TABLE clients ADD COLUMN jobber_client_id TEXT;
ALTER TABLE visits  ADD COLUMN airtable_visit_id TEXT;
```

These remain forbidden. Cross-system identity for canonical entities
goes through `entity_source_links` polymorphic.

### Discussed-and-rejected alternative

Use `entity_source_links` for non-canonical external refs too
(`entity_type='trello_card'`, etc.). Rejected because:
- Forces a 3-table JOIN to read what's effectively a single foreign ID
- The `entity_source_links` table is for **bridging multiple sources of
  the same canonical entity** (Jobber + Airtable + Samsara all knowing
  the same client). Trello cards aren't that — there's no canonical "card."
- Polluting `entity_source_links` with random external resource types
  conflates two different concerns

## Consequences

### Positive

- `viktor_*` tables can model their state naturally without indirection
- Read-time JOIN-hops are minimal (just to canonical entities, when needed)
- The validator (when built) can apply the right rule by namespace:
  - `<canonical_table>` → strict ADR 002 (no source prefixes)
  - `viktor_*` / `app_*` / non-canonical → ADR 014 (source prefixes OK
    for external refs, `external_<entity>_id BIGINT` for canonical refs)

### Negative

- Two rules to remember instead of one. Validator enforcement helps.
- A future skill that needs to merge with another source's identity for
  the same external resource (e.g. "this Trello card is also tracked in
  Linear") would need to add its own bridge table. Acceptable; rare.

### Naming convention reinforced

| Reference target | Column name pattern | Type |
|---|---|---|
| Canonical entity in our DB | `external_<entity>_id` | `BIGINT` (loose FK) |
| Non-canonical external resource | `<source>_<resource>_id` | `TEXT` usually |

Examples:
- `external_visit_id BIGINT` — references our `visits.id`
- `external_employee_id BIGINT` — references our `employees.id`
- `trello_card_id TEXT` — Trello card ID from Trello's API
- `drive_file_id TEXT` — Google Drive file ID
- `stripe_charge_id TEXT` — Stripe charge ID
- `airtable_record_id TEXT` — only when referencing a non-canonical
  Airtable table (DERM/PRE-POST stay in `entity_source_links` because
  they ARE canonical sources)

## References

- ADR 002 — entity_source_links (the rule this ADR refines, not overrides)
- Viktor's design notes 2026-05-04 in `#viktor-supabase` thread
  ts=1777918753.714489 — proposed schemas for `viktor_check_processing`,
  `viktor_trello_nudges`, `viktor_geocode_cache`
