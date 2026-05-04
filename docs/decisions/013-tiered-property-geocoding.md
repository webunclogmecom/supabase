# ADR 013 — Tiered geocoding for property latitude/longitude

**Date:** 2026-05-04
**Status:** Accepted
**Supersedes:** —

## Context

Without `properties.latitude` and `properties.longitude` populated, the
`derive_visit_vehicle_id` job (ADR 012) cannot match visits to truck GPS.
On 2026-05-04, only **199 of 438 properties (45%)** had coordinates.
The other 239 had street addresses but no resolved lat/lng.

We have multiple potential sources for coordinates:

- **Jobber GraphQL** — `client.billingAddress.coordinates` and
  `client.properties.address.coordinates` sometimes carry geocoded values
- **Airtable Clients table** — Yan-curated; *might* carry lat/lng on some rows
- **Samsara geofences** — customer geofence centers are explicit lat/lng
  per customer, exact precision
- **Google Maps Geocoding API** — universal fallback; ~$0.005/lookup

## Decision

Resolve missing coords in **strict tier order**, preferring cheaper /
more-authoritative sources first. The script attempts each tier and stops
at the first that returns a coordinate.

### Tier order

1. **Jobber** — Pull `client.billingAddress.coordinates` and
   `client.properties.address.coordinates` via GraphQL. Match the candidate
   whose `street` field best matches our DB `properties.address`. **$0.**
2. **Airtable Clients table** — Look up the client's record by
   `external_client_id` (via `entity_source_links`). Read fields named
   `Latitude`/`Longitude`/`Lat`/`Lng` (case variations). **$0.**
3. **Samsara geofences** — *Skipped in this pass.* Geofence names are
   arbitrary; would require pre-mapping geofence_id → property_id. Flagged
   for future work if needed.
4. **Google Maps Geocoding API** — Build full address (`address, city,
   state, zip, USA`), call `/maps/api/geocode/json`, take first match.
   **~$0.005/lookup.**

### Result tagging

Each write logs the **source tier** that resolved it:
- `jobber`, `airtable`, `samsara`, `google`

This enables future audits to find low-confidence rows (e.g. all `google`
rows in a chain that should be in Airtable might indicate Yan needs to
populate Airtable).

### Idempotency

Only operates on `properties.latitude IS NULL`. Safe to re-run.
Re-running adds new properties as they appear (e.g. a new Jobber client
created after the last run).

## Consequences

### Positive

- **From 199 → 437 of 438 properties (99.8%) with GPS** in one run on 2026-05-04
- **Cost: $1.45 total** for 289 lookups (well under Google's $200/month free tier)
- **Tier order favors free + authoritative**: only fell to Google when other
  sources had nothing — but in practice Jobber returned 0 (their
  `billingAddress.coordinates` was always empty in our dataset) and Airtable
  Clients table doesn't carry lat/lng for these clients, so Google did all
  the work this run. The tier order is still correct for future runs.
- **Source-tagged writes** let us audit accuracy or re-source if a tier
  improves later
- **Unlocked +57 visit truck attributions** by enabling matching for the
  44 clients whose only GPS-bearing primary property was previously NULL

### Negative

- **Google's geocoding is best-effort.** 3 properties were geocoded outside
  Miami because their address city/state explicitly said California (1) or
  Quebec (1) or Manhattan Beach CA (1). Those resolutions are *correct* but
  point to non-Miami clients (test data or out-of-area billing entities).
  They won't match Miami GPS but won't pollute either.
- **No automatic re-geocoding** if an address changes. If a property's
  address is updated later, our stored coordinates become stale. Not a
  problem at current scale; would be solved by a webhook-driven invalidation
  in the future CRM.
- **API key dependency**: requires `GOOGLE_API_KEY` in env. Currently shared
  with the Slack project's key. If the key gets rotated, geocoding stops
  working until updated.

### Alternatives considered

- **Hand-curate via Yan in Airtable.** Would take days; Yan has more
  important things to do. Google fills the gap in one pass.
- **Skip geocoding; only match visits where property already had GPS.**
  Coverage cap of 64% on completed 2026 visits. Geocoding pushes it to
  77% — worth the $1.45.
- **Use OSM Nominatim** (free) instead of Google. Lower accuracy in Miami
  per spot checks; not worth the savings.

## References

- [scripts/sync/geocode_missing_properties.js](../../scripts/sync/geocode_missing_properties.js)
- ADR 012 — visit-vehicle-id derivation (downstream consumer)
- `GOOGLE_API_KEY` in `.env` (also referenced by Slack project's `.env`)
