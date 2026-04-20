# ADR 005 — Every schema proposal must pass a 3NF audit; reference all data

- **Status:** Accepted (2026-04)
- **Deciders:** Fred Zerpa (standing rule)
- **Related:** [ADR 002](002-entity-source-links.md), [ADR 003](003-service-configs-3nf.md)

## Context

Without a standing rule, 3NF violations creep in one column at a time. Examples observed before the rule was made explicit:

- `vehicle_fuel_readings.fuel_gallons` was stored, computed as `fuel_percent × tank_capacity_gallons / 100`. This is a **transitive dependency**: `fuel_gallons` depends on the `(vehicle_id, recorded_at)` PK via `fuel_percent`, but also via `tank_capacity_gallons` from another table. Storing it creates drift when `tank_capacity_gallons` is updated.
- The table name `vehicle_fuel_readings` was lying: it also stored `odometer_meters` and `engine_state`. Those are 3NF-clean observations, but the name made it look like a single-metric table.

These showed up despite otherwise careful design. The fix is procedural: audit 3NF *every time*, not once.

## Decision

Two standing rules, applied to every schema proposal (new table, new column, migration, or Edge Function that writes):

### Rule 1 — 3NF check

For each column, explicitly state:

> "Does this depend on the whole key, and nothing else?"

If the column depends on another column in the same table (2NF violation), or on a column in a different table reachable by FK (3NF violation — transitive dep), **it does not get stored**. It gets computed on read, via a view or query.

### Rule 2 — Reference all data

Related data is referenced via FK, not copied. No snapshotting of related values. When the referenced value changes, all consumers see the new value.

Exceptions: intentional denormalization (see [ADR 004](004-intentional-denormalization.md)) — which must be explicit, documented, and justified.

## Consequences

**Positive:**
- Forces the computed-on-read pattern. Views (`v_vehicle_telemetry_latest`, `clients_due_service`, `client_services_flat`) do the work instead of triggers or snapshot columns.
- Catches drift-prone columns at design time instead of after they've drifted.
- The rule is explicit enough that AI agents can apply it mechanically: "state the 3NF justification per column."

**Negative / accepted trade-offs:**
- Slower design: every schema proposal has an extra review step.
- Occasional read-time compute cost. Mitigation: views are cheap at current scale; materialize if it ever matters.

## Enforcement

- Every new migration file in `scripts/migrations/` has a header comment listing each column and its 3NF justification. Example: `scripts/migrations/3nf_telemetry_readings.sql`.
- Code review (or AI-agent self-review) checks the header before applying.
- Fred is the final guardrail — if a proposal lacks the 3NF justification, it's rejected.
