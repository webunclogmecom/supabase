# ADR 011 — Source-of-truth canonicalization (2026-04-29)

- **Status:** Accepted (2026-04-29)
- **Supersedes:** Implicit source-of-truth conventions in CLAUDE.md Rule 4 (pre-2026-04-29 wording)
- **Authors:** Fred (decisions) · Claude (implementation)

## Context

Through April 2026 the warehouse accreted populate.js logic that pulled from every source it had access to (Jobber, Airtable, Samsara, Fillout) for every entity it could populate. This was deliberate during the schema-discovery phase but left several costs:

1. **Cross-source visit duplicates.** Airtable's "Visits" table and Jobber's `visits` were both ingested into `public.visits` with no coherent dedup. populate.js step 10 attempted to match Airtable to Jobber by reading a non-existent `Jobber Visit ID` field on Airtable records — match always failed, every Airtable visit became a separate row. Net: ~5,000 visits with rampant cross-source dups (Casa Neos went from 26 real visits to 51 rows).

2. **Stale Airtable data leaking in.** Airtable's `Drivers & Team` table held departed staff. Airtable's `Past due` table tracked receivables that Jobber was already authoritative on. Airtable's `Route Creation` table was abandoned in favor of Viktor's routing skill in Slack. Airtable's `Leads` table was being deprecated for Odoo's CRM module.

3. **Fillout dependency.** Pre-shift / post-shift inspections originally landed in Fillout, then were re-pointed at Airtable's `PRE-POST insptection` table for the live Edge Function (commit 2026-04-22), but populate.js step 12 was never updated — still read from Fillout.

4. **Trust hierarchy unclear.** CLAUDE.md Rule 4 said "Jobber wins on conflict" but didn't draw the line between *trust 100%* and *trust grudgingly because no alternative*. Engineers (and Viktor) defaulted to treating Airtable enrichment as authoritative for any field where Jobber didn't have a column.

Fred's directive on 2026-04-29:

> "The only thing we have to fully trust in Airtable will be for the DERM and PRE-POST Inspections, but the rest is from Jobber and Samsara which are 100% correct both of them and Airtable usually throws wrong data or error which have to fix, that's why we don't focus with it too much."

## Decision

### 1. Trust hierarchy (definitive)

| Tier | System | Trust |
|---|---|---|
| **100% canonical** | Jobber | Identity, addresses, contacts, jobs, visits, invoices, line_items, quotes, notes/photos, employees (office/admin via Jobber users) |
| **100% canonical** | Samsara | Vehicles, drivers (field staff), GPS/telemetry, geofences |
| **100% trusted** | Airtable | `derm_manifests` + `inspections` (PRE-POST) **only** |
| **Best-effort enrichment** (no alternative source) | Airtable | `service_configs` (frequencies, prices, GDO permits), `client_contacts` (multiple roles), `properties` enrichment (zone, access hours, days, county) |
| **Dropped** | Airtable | `Drivers & Team`, `Past due`, `Route Creation`, `Leads` |
| **Dropped** | Fillout | All inspection + expense ingestion |

When sources conflict on overlapping fields, **Jobber + Samsara win.** Airtable is never used to override an identity or money field.

### 2. Visits dedup logic (`populate.js step 10`)

- Iterate `cache.jobber.visits` first → canonical rows. Index by `(client_id, visit_date)`.
- For each `cache.airtable.visits` record, attempt strict match: same `client_id` + `visit_date == 0d`.
  - **Match found**: enrich the Jobber row with `service_type` only (where Jobber's is NULL). Add an `airtable` `entity_source_links` row to the same `visit_id`. **Do not insert a separate row.**
  - **No match**: insert as standalone "AT-only historical" row (pre-Jobber era, no Jobber visit exists for that day). These rows carry `truck` text + `completed_by` text as the only attribution available since Samsara coverage doesn't reach pre-Jobber days.
- Real twice-per-day visits (Goliath + David same client same day) are preserved when Jobber itself has two distinct visit rows. Airtable's first match merges into one; if Airtable has its own duplicate-twice it falls through to standalone — visible in audit.

### 3. Inspections (`populate.js step 12`)

Rewritten 2026-04-29 to read from `cache.airtable.inspections` (Airtable's `PRE-POST insptection` table). Field mapping mirrors `webhook-airtable`'s `handleInspectionRecord`:

```
Airtable column          → inspections column
─────────────────────────  ──────────────────────────
Date                     → shift_date + submitted_at
Pre/Post                 → inspection_type
Driver                   → employee_id (resolve via name)
Truck                    → vehicle_id (resolve via name)
SLUDGE Tank level        → sludge_gallons (rounded)
Water Tank level         → water_gallons (POST only)
Gas Level                → gas_level
Valve Closed             → is_valve_closed
Issue / Issue Note       → has_issue, issue_note
```

Photo attachments on the Airtable record are NOT processed by populate.js — that runs through `jobber_notes_photos.js` per ADR 009.

### 4. Employees (`populate.js step 2`)

Reordered: Jobber users iterate first → canonical office/admin roster. Samsara drivers match into existing rows by name (or add as new field-staff). **Airtable `Drivers & Team` source dropped entirely** — held departed staff and stale data.

### 5. Dropped sources + populate steps

| populate step | Status | Replacement |
|---|---|---|
| Step 13 (expenses from Fillout) | DROPPED | Ramp owns expenses |
| Step 16 (routes from Airtable Route Creation) | DROPPED | Viktor's routing skill in Slack |
| Step 17 (receivables from Airtable Past due) | DROPPED | Jobber `invoices` (filter by `invoice_status` or `due_date < now()`) |
| Step 18 (leads from Airtable Leads) | DROPPED | Odoo CRM module post-cutover |
| `pullFillout`, `cache.fillout`, `_fillout_name`, `employeeByFilloutName` | DROPPED | — |

Tables `routes`, `route_stops`, `receivables`, `leads`, `expenses` remain in the schema but are unpopulated. Drop tables at Odoo cutover.

### 6. `--from-step=N` flag added to populate.js

For surgical re-runs: `--from-step=N` skips steps 1..N-1 (whose tables are preserved) and runs only steps >= N. A `loadAllIdMaps()` helper preloads idmaps from existing `entity_source_links` + name columns so downstream steps can reference clients/properties/jobs without re-running their inserts. Used to recover from transient infra failures mid-repop.

## Consequences

**Positive**

- One canonical row per real visit (rather than 1.5–2× rows due to cross-source dups). Casa Neos: 51 → 42 rows; 9 cross-source merges + 5 legit twice-per-day pairs preserved.
- `populate.js step 12` now matches the live `webhook-airtable` handler. No drift between one-shot population and incremental sync.
- Drivers/employees roster reflects current staff, not Airtable's stale list.
- Zero ambiguity for future agents: Airtable is for DERM + PRE-POST inspections + service_configs, period.
- ESL bridge keeps cross-source IDs intact — Jobber and Airtable still both have their `source_id` rows, just pointing at the same `visit_id`.

**Negative / accepted trade-offs**

- Pre-Jobber AT-only historical visits (~2,081 rows) carry `truck` + `completed_by` as text and may have NULL `vehicle_id` / `visit_assignments` when fixupPass 3 / 5 can't resolve the names. Acceptable — these are pre-Samsara data, no telemetry exists to retrofit them.
- The `routes` / `receivables` / `leads` / `expenses` tables stay in the schema empty. Cosmetic clutter until Odoo cutover when they get DROP TABLE'd.
- If Airtable's PRE-POST table changes a field name (e.g. "Water Tank level" → "WATER level"), step 12 silently writes NULL instead of crashing. Mitigated by post-repop sanity checks.

**Implication for schema design**

- `entity_source_links` becomes the only place Airtable's `Visits` Record IDs live going forward. After the May 2026 sunset, those rows can be archived; the Jobber-canonical visit rows survive untouched.
- `service_configs` continues to be Airtable-sourced (no alternative). Anomalies in this table should be flagged for Yan to fix in Airtable, not patched in DB.
- Future Apps DB extensions per [docs/building-new-apps.md](../building-new-apps.md) — when they need to reference visits, store `external_visit_id BIGINT` (cross-DB loose FK), unaffected by this ADR.

**Migration record**

Wipe + repop executed 2026-04-29 via `node populate.js --execute --confirm --truncate`. Two transient Supabase 503s required `--from-step=8` and `--from-step=15` resumes. Final state:

```
clients         400 jobber + 190 AT links + 197 samsara geofences
properties      401
jobs            518
invoices       1665
line_items      565
quotes          166
visits         3888 (1807 jobber-canonical, 377 AT-merged, 2081 AT-only historical)
visit_assignments 1830
inspections     242 (AT PRE-POST)
derm_manifests  958
manifest_visits 819 (84% match rate)
employees        28 jobber + 6 samsara (AT drivers DROPPED)
vehicles          3 samsara + 1 manual (Goliath)
service_configs 204
```

Notes + photos full re-migration via `jobber_notes_photos.js --execute` initiated same day; runs in background for hours.

## Related ADRs

- [ADR 002 — Entity source links](002-entity-source-links.md) — the polymorphic bridge that makes this trust hierarchy enforceable without source-prefixed columns.
- [ADR 005 — 3NF standing check](005-3nf-standing-check.md) — why we don't store derived/duplicated values across sources.
- [ADR 007 — Samsara permanent](007-samsara-permanent.md) — establishes Samsara's role beyond the Jobber/Airtable sunset.
- [ADR 009 — Unified photos architecture](009-unified-photos-architecture.md) — why photos+photo_links handle inspection attachments outside of populate.js.
