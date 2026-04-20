# Database Schema Reference

**Supabase project:** `wbasvhvvismukaqdnouk` · **Version:** v2 · **Last reviewed:** 2026-04-20

Full DDL lives in [`../schema/v2_schema.sql`](../schema/v2_schema.sql). Migrations that have shipped since the baseline live in [`../scripts/migrations/`](../scripts/migrations/). This doc is the human-readable column reference — authoritative for column names, types, and intent.

- **28 tables** — 22 business + 6 system/ops
- **7 views**
- **38 foreign keys**
- **Normalization:** 2NF baseline, 3NF for service_configs and telemetry
- **Cross-system ID tracking:** `entity_source_links` only. No source-prefixed columns anywhere.

---

## Relationship map

```
clients (PK)
  ├─ client_contacts          (client_id FK)
  ├─ properties               (client_id FK)
  ├─ service_configs          (client_id FK)         [3NF: one row per service type]
  ├─ jobs                     (client_id FK)
  │   ├─ visits               (job_id FK)
  │   │   ├─ visit_assignments (visit_id FK) → employees
  │   │   ├─ manifest_visits   (visit_id FK) → derm_manifests
  │   │   └─ visit_photos      (visit_id FK)
  │   ├─ invoices             (job_id FK)
  │   └─ line_items           (job_id FK)
  ├─ visits                   (client_id FK)          [also links to jobs, vehicles, invoices]
  ├─ quotes                   (client_id FK, property_id FK)
  │   └─ line_items           (quote_id FK)
  ├─ invoices                 (client_id FK)
  ├─ derm_manifests           (client_id FK)
  ├─ routes                   (client_id FK, vehicle_id FK, employee_id FK)
  │   └─ route_stops          (route_id FK, client_id FK, property_id FK)
  ├─ receivables              (client_id FK)
  └─ leads                    (converted_client_id FK)

vehicles (PK)
  ├─ visits                   (vehicle_id FK)
  ├─ inspections              (vehicle_id FK)
  ├─ expenses                 (vehicle_id FK)
  ├─ routes                   (vehicle_id FK)
  └─ vehicle_telemetry_readings (vehicle_id FK)

employees (PK)
  ├─ visit_assignments        (employee_id FK)
  ├─ inspections              (employee_id FK)
  ├─ expenses                 (employee_id FK)
  └─ routes                   (employee_id FK)

entity_source_links           — polymorphic bridge (any entity ↔ any source system)
sync_log, sync_cursors,
webhook_events_log,
webhook_tokens                — system/ops tables
```

---

## Business tables

### `clients` — 409 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| client_code | TEXT | 3-digit prefix, e.g. `"009"` |
| name | TEXT | Clean display name |
| status | TEXT | `ACTIVE`, `RECURRING`, `PAUSED`, `INACTIVE` |
| balance | NUMERIC(12,2) | Outstanding balance |
| notes | TEXT | |
| created_at | TIMESTAMPTZ | |
| updated_at | TIMESTAMPTZ | Trigger-managed |

### `client_contacts` — 519 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| client_id | BIGINT FK → clients | |
| contact_role | TEXT | `billing`, `operations`, `city`, `primary` |
| name / email / phone | TEXT | |
| created_at, updated_at | TIMESTAMPTZ | |

**Unique:** `(client_id, contact_role)`

### `properties` — 421 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| client_id | BIGINT FK → clients | |
| name | TEXT | |
| address / city / state / zip / country | TEXT | |
| is_billing / is_primary | BOOLEAN | |
| zone | TEXT | Service zone |
| county | TEXT | Miami-Dade / Broward / Palm Beach |
| latitude / longitude | NUMERIC | |
| geofence_radius_meters | NUMERIC | |
| geofence_type | TEXT | `circle`, `polygon` |
| access_hours_start / access_hours_end | TEXT | |
| access_days | TEXT[] | |
| location_photo_url | TEXT | |
| notes | TEXT | |
| created_at, updated_at | TIMESTAMPTZ | |

### `service_configs` — 202 rows · 3NF

One row per `(client_id, service_type)`. Replaces the flat `gt_*` / `cl_*` / `wd_*` column groups.

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| client_id | BIGINT FK → clients | |
| service_type | TEXT | `GT`, `CL`, `WD`, `AUX`, `SUMP`, `GREY_WATER`, `WARRANTY` |
| frequency_days | INTEGER | Always stored in DAYS (see note below) |
| first_visit / last_visit / next_visit / stop_date | DATE | |
| price_per_visit | NUMERIC(12,2) | |
| status | TEXT | `On Time`, `Late`, `Critical`, `Paused` |
| schedule_notes | TEXT | |
| equipment_size_gallons | NUMERIC | GT capacity |
| permit_number | TEXT | GDO permit number |
| permit_expiration | DATE | |
| created_at, updated_at | TIMESTAMPTZ | |

**Unique:** `(client_id, service_type)`

**Frequency normalization at sync time:**
- GT / CL frequency from Airtable (MONTHS) × 30 → days
- WD frequency from Airtable → already DAYS, pass through

### `employees` — 34 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| full_name | TEXT NOT NULL UNIQUE | |
| role | TEXT | `Owner`, `Manager`, `Technician`, … |
| status | TEXT | `ACTIVE`, `INACTIVE`, `DEACTIVATED` |
| shift | TEXT | `Day`, `Night`, `Both` |
| email / phone | TEXT | |
| hire_date | DATE | |
| access_level | TEXT | `dev`, `office`, `field` |
| notes | TEXT | |
| created_at, updated_at | TIMESTAMPTZ | |

### `vehicles` — 4 rows

Grease tank and fuel tank are independent physical tanks on vacuum trucks. Grease capacity drives route/dump scheduling; fuel capacity is used (via `v_vehicle_telemetry_latest`) to compute diesel gallons from Samsara's `fuelPercent`.

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| name | TEXT NOT NULL UNIQUE | `Moises`, `Cloggy`, `David`, `Goliath` |
| make / model | TEXT | |
| year | INTEGER | |
| vin | TEXT UNIQUE | |
| license_plate | TEXT | |
| grease_tank_capacity_gallons | NUMERIC | Waste/vacuum tank (126–9000) |
| fuel_tank_capacity_gallons | NUMERIC | Diesel/gas tank (26–90). NULL for inactive vehicles. |
| status | TEXT | `ACTIVE`, `INACTIVE`, `OUT_OF_SERVICE`, `RETIRED` |
| notes | TEXT | |
| created_at, updated_at | TIMESTAMPTZ | |

### `jobs` — 493 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| client_id | BIGINT FK → clients | |
| property_id | BIGINT FK → properties | |
| job_number | TEXT | |
| title | TEXT | |
| job_status | TEXT | `active`, `upcoming`, `completed`, `archived` |
| start_at / end_at | TIMESTAMPTZ | |
| total | NUMERIC(12,2) | |
| quote_id | BIGINT FK → quotes | |
| notes | TEXT | |
| created_at, updated_at | TIMESTAMPTZ | |

### `visits` — 4705 rows · central operations table

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| client_id | BIGINT FK → clients | |
| property_id | BIGINT FK → properties | |
| job_id | BIGINT FK → jobs | Nullable |
| vehicle_id | BIGINT FK → vehicles | Nullable; 1505 of 2208 visits resolved |
| visit_date | DATE | |
| start_at / end_at / completed_at | TIMESTAMPTZ | |
| duration_minutes | INTEGER | |
| title | TEXT | |
| service_type | TEXT | `GT`, `CL`, `AUX`, `HYDROJET`, `CAMERA`, `EMERGENCY` |
| visit_status | TEXT | `COMPLETED`, `UPCOMING`, `UNSCHEDULED`, `CANCELLED`, `LATE` |
| is_complete | BOOLEAN | |
| actual_arrival_at / actual_departure_at | TIMESTAMPTZ | GPS enrichment from Samsara |
| is_gps_confirmed | BOOLEAN | TRUE when GPS matches |
| invoice_id | BIGINT FK → invoices | |
| truck | TEXT | **Intentional denorm** — historical truck name (see ADR 004) |
| completed_by | TEXT | **Intentional denorm** — historical attribution |
| created_at, updated_at | TIMESTAMPTZ | |

### `visit_assignments` — 0 rows

**PK:** `(visit_id, employee_id)` composite — true M:N.

| Column | Type | Notes |
|---|---|---|
| visit_id | BIGINT FK → visits | |
| employee_id | BIGINT FK → employees | |

**Status:** Empty. Blocked by Jobber API rate limits on the visits re-pull that would populate `assignedUsers`. See [docs/migration-plan.md](migration-plan.md#outstanding-jobber-backfills).

### `invoices` — 1557 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| client_id | BIGINT FK → clients | |
| job_id | BIGINT FK → jobs | |
| invoice_number | TEXT | |
| subject | TEXT | |
| subtotal / tax_amount / total | NUMERIC(12,2) | |
| outstanding_amount / deposit_amount | NUMERIC(12,2) | |
| invoice_status | TEXT | `draft`, `sent`, `awaiting_payment`, `paid`, `void`, `overdue`, `bad_debt` |
| due_date | DATE | |
| sent_at / paid_at | TIMESTAMPTZ | `paid_at` = payment received |
| created_at, updated_at | TIMESTAMPTZ | |

### `quotes` — 151 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| client_id | BIGINT FK → clients | |
| property_id | BIGINT FK → properties | |
| quote_number | TEXT | |
| title | TEXT | |
| subtotal / tax_amount / total / deposit_amount | NUMERIC(12,2) | |
| quote_status | TEXT | `draft`, `awaiting_response`, `approved`, `rejected`, `converted` |
| sent_at / approved_at / converted_to_job_at | TIMESTAMPTZ | |
| created_at, updated_at | TIMESTAMPTZ | |

### `line_items` — 565 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| job_id | BIGINT FK → jobs | Mutually exclusive with quote_id |
| quote_id | BIGINT FK → quotes | |
| name / description | TEXT | |
| quantity | NUMERIC | |
| unit_price / total_price | NUMERIC(12,2) | |
| taxable | BOOLEAN | |
| created_at, updated_at | TIMESTAMPTZ | |

### `inspections` — 247 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| vehicle_id | BIGINT FK → vehicles | |
| employee_id | BIGINT FK → employees | |
| shift_date | DATE | Date the shift STARTED (handles overnight) |
| inspection_type | TEXT | `PRE`, `POST` |
| submitted_at | TIMESTAMPTZ | |
| sludge_gallons | INTEGER | |
| water_gallons | INTEGER | POST only |
| gas_level | TEXT | |
| is_valve_closed | BOOLEAN | |
| has_issue | BOOLEAN | |
| issue_note | TEXT | |
| created_at, updated_at | TIMESTAMPTZ | |

### `inspection_photos` — 0 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| inspection_id | BIGINT FK → inspections | |
| photo_type | TEXT | `dashboard`, `cabin`, `front`, `back`, … |
| url | TEXT | |
| created_at | TIMESTAMPTZ | |

### `visit_photos` — 0 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| visit_id | BIGINT FK → visits | |
| client_id | BIGINT FK → clients | |
| photo_type | TEXT | |
| url / thumbnail_url | TEXT | |
| file_name / content_type | TEXT | |
| caption | TEXT | |
| taken_at / created_at | TIMESTAMPTZ | |

### `expenses` — 111 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| expense_date | DATE | |
| amount | NUMERIC(12,2) | |
| description | TEXT | |
| category | TEXT | `Fuel`, `Maintenance`, `Dump Fee`, `Supplies`, `Tools`, `Other` |
| vendor_name | TEXT | |
| vehicle_id | BIGINT FK → vehicles | |
| employee_id | BIGINT FK → employees | |
| receipt_url | TEXT | |
| created_at, updated_at | TIMESTAMPTZ | |

### `derm_manifests` — 898 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| client_id | BIGINT FK → clients | |
| service_date | DATE | |
| dump_ticket_date | DATE | |
| white_manifest_number | TEXT | DADE = `481xxx`, BROWARD = `294xxx` |
| yellow_ticket_number | TEXT | |
| manifest_images | JSONB | |
| address_images | JSONB | |
| sent_to_client | BOOLEAN | |
| sent_to_city | BOOLEAN | |
| created_at, updated_at | TIMESTAMPTZ | |

### `manifest_visits` — 1079 rows

**PK:** `(manifest_id, visit_id)` composite — true M:N. One manifest can cover multiple stops on the same dump trip.

### `routes` — 135 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| client_id | BIGINT FK → clients | |
| status | TEXT | `Todo`, `In Progress`, `Done`, `Cancelled` |
| assignee | TEXT | Legacy — use `employee_id` for new reads |
| zone | TEXT | |
| route_date | DATE | |
| vehicle_id | BIGINT FK → vehicles | |
| employee_id | BIGINT FK → employees | |
| notes | TEXT | |
| created_at, updated_at | TIMESTAMPTZ | |

### `route_stops` — 134 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| route_id | BIGINT FK → routes | |
| client_id | BIGINT FK → clients | |
| property_id | BIGINT FK → properties | |
| service_type | TEXT | |
| stop_order | INTEGER | |
| wanted_date | DATE | |
| status | TEXT | |
| created_at | TIMESTAMPTZ | |

### `receivables` — 45 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| client_id | BIGINT FK → clients | |
| amount_due | NUMERIC(12,2) | |
| status | TEXT | `Open`, `Contacted`, `Payment Plan`, `Resolved` |
| assignee | TEXT | |
| notes | TEXT | |
| created_at, updated_at | TIMESTAMPTZ | |

### `leads` — 5 rows

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| converted_client_id | BIGINT FK → clients | NULL until converted |
| contact_name / company_name | TEXT | |
| phone / email | TEXT | |
| address / city / state / zip | TEXT | |
| lead_source | TEXT | `website`, `referral`, `jobber`, `cold_call`, `other` |
| lead_status | TEXT | `new`, `contacted`, `qualified`, `quoted`, `converted`, `lost` |
| notes | TEXT | |
| first_contact_at / converted_at | TIMESTAMPTZ | |
| created_at, updated_at | TIMESTAMPTZ | |

### `vehicle_telemetry_readings` — 0 rows · 3NF append-only

Every column is a direct observation of `(vehicle_id, recorded_at)`. No derived columns — `fuel_gallons` is computed on read in `v_vehicle_telemetry_latest` via JOIN to `vehicles.fuel_tank_capacity_gallons`, not stored.

Renamed from `vehicle_fuel_readings` on 2026-04-14 (table already stored odometer + engine state; name was lying). Dropped stored `fuel_gallons` at same time (was a 3NF violation: transitive dep via `fuel_tank_capacity_gallons`).

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| vehicle_id | BIGINT FK → vehicles | |
| fuel_percent | NUMERIC | Direct observation |
| odometer_meters | BIGINT | Direct observation |
| engine_state | TEXT | `On`, `Off`, `Idle` |
| engine_hours_seconds | BIGINT | Lifetime engine seconds; ÷ 3600 for hours |
| recorded_at | TIMESTAMPTZ | Samsara observation timestamp |
| created_at | TIMESTAMPTZ | |

### `entity_source_links` — 10,117 rows

THE cross-system ID tracking table. Replaces ALL source-prefixed columns. See [ADR 002](decisions/002-entity-source-links.md).

| Column | Type | Notes |
|---|---|---|
| id | BIGSERIAL PK | |
| entity_type | TEXT | `client`, `property`, `job`, `visit`, `invoice`, `quote`, `employee`, `vehicle`, … |
| entity_id | BIGINT | FK to the entity's id (not enforced — polymorphic) |
| source_system | TEXT | `jobber`, `airtable`, `samsara`, `fillout` |
| source_id | TEXT | The ID in the source system |
| source_name | TEXT | Human-readable name from source (debugging) |
| match_method | TEXT | `code_exact`, `name_fuzzy`, `manual`, `api_webhook` |
| match_confidence | NUMERIC(3,2) | 0.00 – 1.00 |
| synced_at | TIMESTAMPTZ | |
| created_at | TIMESTAMPTZ | |

**Unique:** `(entity_type, entity_id, source_system)` and `(entity_type, source_system, source_id)`

**Lookup patterns:**

```sql
-- Find Jobber ID for a client
SELECT source_id FROM entity_source_links
WHERE entity_type = 'client' AND entity_id = 42 AND source_system = 'jobber';

-- Resolve our client from a Jobber webhook
SELECT entity_id FROM entity_source_links
WHERE entity_type = 'client' AND source_system = 'jobber' AND source_id = 'JOB_123';
```

---

## System / ops tables

### `sync_log`
Execution history for batch operations. One row per sync run. `sync_source`, `started_at`, `finished_at`, `rows_inserted/updated/errored`, `duration_seconds`, `status`, `error_details` (JSONB).

### `sync_cursors`
Per-entity incremental cursors (e.g. `"visits"` → `last_synced_at`). PK is the entity name.

### `webhook_events_log`
Every webhook payload we receive, pass/fail/error. `source_system`, `event_type`, `event_id`, `payload` (JSONB), `entity_type`, `entity_id`, `status` (`received`/`processed`/`failed`), `error_message`, `processing_ms`, `processed_at`. Primary observability surface for webhook drift.

### `webhook_tokens`
OAuth credentials for each source system. PK is `source_system`. `access_token`, `refresh_token`, `client_id`, `client_secret`, `expires_at`. Refreshed automatically by the Edge Functions.

---

## Views

| View | Purpose |
|---|---|
| `client_services_flat` | Pivoted GT/CL/WD columns from 3NF `service_configs` back to flat layout for Diego/Aaron daily lookup. |
| `clients_due_service` | Overdue and due-soon clients for scheduling. **Most operationally critical view.** |
| `driver_inspection_status` | Daily PRE/POST compliance check. Handles overnight shifts (10pm–3am). |
| `manifest_detail` | DERM manifests with client info and linked visit count. |
| `v_vehicle_telemetry_latest` | Latest telemetry snapshot per vehicle. Computes `fuel_gallons_computed` on read from `vehicles.fuel_tank_capacity_gallons`; derives `odometer_miles`, `engine_hours`, `minutes_ago`. |
| `visits_recent` | Last 30 days of visits with client context. |
| `visits_with_status` | Visits enriched with derived status fields. |

---

## Unique & primary key constraints

| Table | Constraint | Type |
|---|---|---|
| `entity_source_links` | `(entity_type, entity_id, source_system)` | UNIQUE |
| `entity_source_links` | `(entity_type, source_system, source_id)` | UNIQUE |
| `client_contacts` | `(client_id, contact_role)` | UNIQUE |
| `service_configs` | `(client_id, service_type)` | UNIQUE |
| `vehicles` | `name` | UNIQUE |
| `vehicles` | `vin` | UNIQUE |
| `employees` | `full_name` | UNIQUE |
| `visit_assignments` | `(visit_id, employee_id)` | PK |
| `manifest_visits` | `(manifest_id, visit_id)` | PK |
| `sync_cursors` | `entity` | PK |
| `webhook_tokens` | `source_system` | PK |

---

## Row counts as of 2026-04-20

| Table | Rows | Source of truth |
|---|---|---|
| clients | 409 | Jobber (373) + Airtable-only (~36) |
| client_contacts | 519 | Normalized from clients |
| properties | 421 | Includes billing addresses |
| service_configs | 202 | Airtable (unpivoted) |
| employees | 34 | Merged across all sources |
| vehicles | 4 | Moises, Cloggy, David, Goliath |
| jobs | 493 | Jobber |
| quotes | 151 | Jobber |
| invoices | 1,557 | Jobber |
| line_items | 565 | Jobber |
| visits | 4,705 | 1,685 Jobber + 3,020 Airtable historical |
| visit_assignments | 0 | Blocked — see runbook |
| inspections | 247 | Fillout |
| expenses | 111 | Fillout |
| derm_manifests | 898 | Airtable |
| manifest_visits | 1,079 | Linked from 743/882 manifests |
| routes | 135 | Airtable |
| receivables | 45 | Airtable (past-due) |
| leads | 5 | Airtable |
| vehicle_telemetry_readings | 0 | Samsara (webhook blocked) |
| entity_source_links | 10,117 | Cross-system |

See [docs/runbook.md](runbook.md#outstanding-population-gaps) for what each `0`-row gap is blocked on.
