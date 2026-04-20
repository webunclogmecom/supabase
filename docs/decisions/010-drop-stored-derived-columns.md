# ADR 010 — Drop stored derived columns; compute on read

- **Status:** Accepted (2026-04-20)
- **Related:** [ADR 005](005-3nf-standing-check.md) (the standing rule this enforces)
- **Deciders:** Fred Zerpa

## Context

A 3NF audit on 2026-04-20 (prompted by Fred's standing instruction to double-check every design) surfaced three columns that stored values derivable from other columns. All three were live in prod.

| Column | Derivation | Drift risk |
|---|---|---|
| `visits.is_complete` | `= (visit_status = 'COMPLETED')` | Pure duplication. Zero drift today (verified against 4,705 rows), but nothing enforces it. |
| `service_configs.next_visit` | `= last_visit + (frequency_days) days` | Stale if `last_visit` updates without recomputing. All 202 rows were NULL — unused column. |
| `service_configs.status` | `= CASE based on next_visit vs CURRENT_DATE (and stop_date)` | Triple violation — derived from a derived column, from a scalar `CURRENT_DATE` not in the DB, AND from `stop_date` in the same row. All 202 rows were NULL. |

Five views (`public.clients_due_service`, `public.client_services_flat`, `public.visits_with_status`, `ops.v_route_today`, `ops.v_service_due`) read these columns. Each had to be rebuilt with the derivations inline.

This is the first concrete enforcement of [ADR 005](005-3nf-standing-check.md) on existing (not just newly-proposed) schema.

## Decision

**Drop the three columns. Compute on read via view.**

- `visits.is_complete` → `(visit_status = 'COMPLETED')` in `visits_with_status` and `ops.v_route_today`.
- `service_configs.next_visit` → `(last_visit + (frequency_days || ' days')::interval)::date` in all views that reference it.
- `service_configs.status` → inline CASE against the computed next_visit and CURRENT_DATE in all views that reference it.

Also:
- `populate.js` updated to stop inserting into these columns.
- `webhook-jobber` already didn't insert them (verified).
- Ancillary cleanup: normalized `clients.status = 'Recuring'` (typo, 132 rows) → `'RECURRING'` (documented migration `normalize_client_status_recuring.sql`).

## Consequences

**Positive:**
- No drift possible. Every read computes against live base data.
- Makes the derivation *visible* — the view SQL is now the canonical definition of "when is a service due." Previously it was split between populate.js and occasional manual UPDATEs.
- Forces consumer clarity: views are now the contract, not columns.

**Negative / accepted trade-offs:**
- Per-query compute cost. At 202 service_configs rows, imperceptible. If volume grows 100x we can materialize.
- Consumers that read the dropped columns directly break. In practice: only the 5 views did, and they were rewritten in the same migration.
- Writers that insert/update those columns silently succeed at column-not-found (`populate.js`). Updated to match.

## What this enforces going forward

Any future proposal to add a column whose value can be computed from other columns triggers one question: *can this be a view instead?* If yes, it's a view. Stored-derived columns are rejected unless there's a concrete performance reason documented in the ADR that introduces them.

## Migration

- `scripts/migrations/3nf_drop_derived_columns.sql` (applied 2026-04-20) — drops columns + rebuilds views.
- `scripts/migrations/normalize_client_status_recuring.sql` (applied 2026-04-20) — data normalization to make the rebuilt views actually match rows.
