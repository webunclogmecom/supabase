# ADR 007 — Samsara integration is permanent

- **Status:** Accepted (2026-04)

## Context

Jobber and Airtable sunset in May 2026 when Odoo.sh takes over as CRM. The question arose: does Samsara go with them?

Samsara provides GPS fleet telemetry (`vehicle_telemetry_readings`), driver events (harsh braking, speeding), DVIR inspections, and geofence enter/exit events. It is independent of CRM and billing concerns.

## Decision

**Samsara survives the May 2026 cutover.** It is a permanent integration.

The `webhook-samsara` Edge Function, the `vehicle_telemetry_readings` table, and the `entity_source_links` rows with `source_system='samsara'` all continue to exist indefinitely.

## Consequences

**Positive:**
- Fleet telemetry keeps flowing without interruption at the Jobber/Airtable cutover.
- `v_vehicle_telemetry_latest` stays meaningful forever.
- GPS enrichment of visits (matching Samsara trips to `visits.actual_arrival_at` / `actual_departure_at`) continues to work.

**Negative / accepted trade-offs:**
- One ongoing vendor relationship (Samsara) where the others are being deprecated. Acceptable — fleet telemetry is a distinct domain.

**Implication for schema design:**
- When the Jobber/Airtable rows in `entity_source_links` are deleted at cutover, Samsara rows remain.
- `vehicles` table is authoritative for fleet identity. Samsara is a *source of readings about* vehicles; it is not the vehicles table itself.
