# ADR 012 — `visits.vehicle_id` derived from Samsara telemetry

**Date:** 2026-05-04
**Status:** Accepted
**Supersedes:** —

## Context

The `visits` table has a `vehicle_id` column intended to record which truck
performed the work. But the upstream sources don't provide it:

- **Jobber** owns visit records but only tracks the assigned **employee**, not
  the truck. Drivers in Jobber's mobile app check off "I did this visit" with
  no truck dropdown.
- **Samsara** owns truck GPS / engine state / fuel telemetry but has no
  concept of "visits" or "clients."

Without truck attribution, downstream features become impossible:
- "Which truck visited which client when" (fleet utilization reporting)
- Per-truck KPIs (visits/day, dwell time, fuel/water consumption)
- Inspection truck attribution (PRE-POST shifts → which truck)
- Historical proof-of-work for customer disputes

## Decision

`visits.vehicle_id` is **derived** by cross-referencing Samsara GPS pings
against client property locations during each visit's time window. The
derivation runs as a scheduled job and writes back to the column.

### Algorithm

For each visit V where `vehicle_id IS NULL` and `start_at IS NOT NULL`:

1. Resolve V's location:
   - First try V's `property_id → properties.latitude/longitude`
   - Fallback: V's `client_id → primary property → latitude/longitude`
     (most clients have a single property; this fallback adds ~80% of candidates)
2. Query `vehicle_telemetry_readings` for any truck whose GPS landed within
   ~100 m of that location during `[V.start_at, COALESCE(V.completed_at, V.start_at + 4h)]`
3. If exactly **one** truck has matching pings → write that `vehicle_id`
4. If multiple → mark **ambiguous** (skip; defer to human review or future
   dwell-time tiebreaker)
5. If zero → leave NULL (visit happened off-route, telemetry gap, or
   incorrect property GPS)

Distance check uses simple squared-degree comparison (~111km/° lat in Miami,
acceptable accuracy for 100m radius).

### Operational cadence

- **Hourly cron** (`derive-visit-vehicle-id.yml`, runs at `:17` past each hour)
- Looks back 7 days from now
- Idempotent: only operates on `vehicle_id IS NULL` rows
- Offset from `samsara-poll.yml` at `:09` to give telemetry time to land

### Coverage achieved

After Jan 1 → May 3 telemetry backfill (4 months) and full property geocoding:

| Domain | Coverage |
|---|---|
| Completed 2026 visits | 269 → 326 (64% → 77%) |
| April 2026 specifically | 41% (some pre-Apr 3 visits fall outside backfill window) |
| Telemetry rows in DB | ~440K |
| Properties with GPS | 437 / 438 (99.8%) |

## Consequences

### Positive

- **Truck attribution for free** on every visit going forward, no driver UX changes required
- Unlocks `inspections_with_truck` (employee + shift_date → visit → vehicle)
- Unlocks fleet utilization, dwell-time, fuel-burn-per-visit analytics
- Self-correcting: future visits get attributed within 1 hour of completion
- Architecture survives the May 2026 Jobber sunset — works the same whether
  visits come from Jobber, Odoo, or any future CRM

### Negative

- **77% ceiling** on coverage:
  - 23% of visits have no telemetry overlap (cancellations, off-site work,
    catering events at venues different from the registered address, GPS
    dead zones)
  - ~6% land in "ambiguous" bucket when two trucks were at the same client
    in the same window
- **Property GPS quality matters**: a misaddressed property → matcher
  fails. We mitigated with full geocoding (ADR 013) but addresses can still
  be wrong upstream.
- 100m radius is a tuning constant — too small misses parking-behind-building
  cases, too large misattributes adjacent businesses. Validated empirically.
- **Storage cost** of telemetry: ~103 MB at current scale, growing ~14 MB/yr
  steady-state. Audit script flags >1 GB warn / >4 GB fail thresholds.

### Alternatives considered

- **Driver-facing truck dropdown in Jobber**: requires upstream UX change
  drivers won't reliably use, and Jobber sunsets May 2026 anyway.
- **Hardcode "employee X always drives truck Y"**: brittle, breaks when
  drivers swap trucks, falls apart with emergency truck David which Grecia
  drives only on emergency calls.
- **Store nothing; recompute at query time**: too expensive for hot queries,
  and forces every consumer to know the algorithm.

## References

- [scripts/sync/derive_visit_vehicle_id.js](../../scripts/sync/derive_visit_vehicle_id.js)
- [.github/workflows/derive-visit-vehicle-id.yml](../../.github/workflows/derive-visit-vehicle-id.yml)
- [scripts/sync/backfill_samsara_telemetry.js](../../scripts/sync/backfill_samsara_telemetry.js) — historical telemetry pull
- ADR 013 — tiered property geocoding (the dependency that unlocked client-fallback matching)
