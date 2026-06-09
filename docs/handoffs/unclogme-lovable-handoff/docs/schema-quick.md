# Schema quick reference

Compact table-by-table reference. For each table: rough row count, what it represents, the columns most relevant to app-building.

When you need to see the actual schema, prompt Lovable: *"Show me the columns of the X table"* — it can introspect Supabase directly.

---

## clients (~445 rows)

| Column | Type | Notes |
|---|---|---|
| `id` | BIGINT PK | |
| `client_code` | TEXT | 3-letter prefix code, e.g. `"009-CN"` |
| `name` | TEXT | Display name (Jobber-canonical) |
| `status` | TEXT | `'ACTIVE'`, `'INACTIVE'`, `'Recuring'` (yes, sic) |
| `balance` | NUMERIC(12,2) | Outstanding balance |
| `notes` | TEXT | |
| `created_at`, `updated_at` | TIMESTAMPTZ | |

Add your own `client_type` column here for prospect classification (see **04-EXAMPLE-PROMPTS.md C**).

---

## client_contacts (~548 rows)

| Column | Notes |
|---|---|
| `id`, `client_id`, `created_at`, `updated_at` | standard |
| `contact_role` | `'primary'`, `'accounting'`, `'city'` |
| `name`, `email`, `phone` | |

---

## properties (~457 rows)

| Column | Notes |
|---|---|
| `id`, `client_id` (FK) | |
| `address`, `city`, `state`, `zip`, `country`, `county` | |
| `is_billing`, `is_primary` | BOOLEAN |
| `zone` | TEXT — Airtable-sourced grouping for routing |
| `latitude`, `longitude` | NUMERIC — from Samsara |
| `geofence_radius_meters`, `geofence_type` | |
| `access_hours_start`, `access_hours_end`, `access_days` | TEXT — Airtable-sourced |
| `grease_trap_manhole_count` | INTEGER NOT NULL DEFAULT 1 — number of trap covers at this property |

---

## jobs (~518 rows) and visits (~3,888 rows)

```
clients
  → jobs (one job has many visits)
       → visits
```

`visits` is the most-used operational table. Key columns:

| Column | Notes |
|---|---|
| `id`, `client_id`, `property_id`, `job_id`, `vehicle_id`, `invoice_id` (FKs) | |
| `visit_date` | DATE — the LOGICAL operating date (overnight visits use the start day) |
| `start_at`, `end_at`, `completed_at` | TIMESTAMPTZ UTC |
| `visit_status` | `'COMPLETED'`, `'scheduled'`, `'destroyed'` |
| `title` | from Jobber |
| `service_type` | `'GT'`, `'CL'`, `'WD'`, etc. — see service codes below |
| `truck`, `completed_by` | TEXT — only set on pre-Jobber AT-historical visits; NULL on Jobber-canonical (use vehicle_id + visit_assignments instead) |
| `actual_arrival_at`, `actual_departure_at`, `is_gps_confirmed` | currently empty; future Samsara enrichment |

---

## visit_assignments (~1,830 rows)

| Column | Notes |
|---|---|
| `visit_id` (FK), `employee_id` (FK) | composite PK |

Use this to answer "who worked this visit".

---

## invoices (~1,670 rows) + line_items (~565)

| Column | Notes |
|---|---|
| `id`, `client_id`, `job_id`, `created_at`, `updated_at` | |
| `invoice_number`, `subject` | |
| `invoice_status` | `'draft'`, `'sent'`, `'paid'`, `'past_due'`, `'overdue'` |
| `issued_date`, `sent_at`, `due_date` | |
| `total`, `outstanding_amount`, `deposit_amount`, `amount_paid` | NUMERIC(12,2) |

---

## quotes (~167 rows)

Same shape as invoices but for quotes. Status: `'draft'`, `'awaiting_response'`, `'approved'`, `'archived'`.

---

## service_configs (~204 rows)

| Column | Notes |
|---|---|
| `client_id` (FK) | |
| `service_type` | `'GT'`, `'CL'`, `'WD'`, `'SUMP'`, `'GREY_WATER'`, `'WARRANTY'` |
| `frequency_days` | INTEGER — how often the service repeats |
| `last_visit` | DATE |
| `price_per_visit` | NUMERIC(12,2) |
| `equipment_size_gallons` | for GT — tank capacity |
| `permit_number`, `permit_expiration` | GDO permit info |

`UNIQUE(client_id, service_type)` — one config per (client, service) pair.

**Frequency note:** stored in DAYS. Most clients are 30/60/90/120. Anything > 180 is suspect data.

---

## vehicles (4 rows)

| Column | Notes |
|---|---|
| `id`, `name` | `'Cloggy'`, `'David'`, `'Moises'`, `'Goliath'` |
| `make`, `model`, `year`, `vin`, `license_plate` | |
| `grease_tank_capacity_gallons` | the vacuum tank — drives route capacity |
| `fuel_tank_capacity_gallons` | diesel/gas tank — different from grease tank! |
| `status` | `'ACTIVE'`, `'INACTIVE'` (Goliath is inactive) |

---

## vehicle_telemetry_readings (growing, every 10 min × 3 vehicles)

| Column | Notes |
|---|---|
| `id`, `vehicle_id` (FK), `recorded_at`, `created_at` | UNIQUE on (vehicle_id, recorded_at) |
| `fuel_percent` | NUMERIC(5,2) — 0–100 |
| `odometer_meters` | BIGINT |
| `engine_state` | `'On'`, `'Off'`, `'Idle'` |
| `engine_hours_seconds` | BIGINT — lifetime engine seconds |
| `latitude`, `longitude` | NUMERIC(9,6) — GPS at sample time |
| `speed_meters_per_sec`, `heading_degrees` | NUMERIC |

Convenience view: `v_vehicle_telemetry_latest` joins vehicles for the latest sample per truck with `fuel_gallons_computed`, `speed_mph`, `minutes_ago`.

---

## employees (~32 rows)

| Column | Notes |
|---|---|
| `id`, `full_name`, `created_at`, `updated_at` | |
| `role` | `'Owner'`, `'Admin'`, `'Office'`, `'Technician'` |
| `status` | `'ACTIVE'`, `'INACTIVE'` |
| `shift`, `phone`, `email`, `hire_date`, `notes` | |
| `access_level` | `'office'`, `'field'`, `'dev'` |

---

## inspections (~242 rows)

PRE / POST shift inspections from Airtable.

| Column | Notes |
|---|---|
| `vehicle_id`, `employee_id` (FKs) | |
| `shift_date`, `submitted_at` | |
| `inspection_type` | `'PRE'` or `'POST'` |
| `sludge_gallons`, `water_gallons` | INTEGER |
| `gas_level` | TEXT (`'1/4'`, `'FULL'`, etc.) |
| `is_valve_closed`, `has_issue` | BOOLEAN |
| `issue_note` | TEXT |

---

## derm_manifests (~963 rows)

DERM (Miami-Dade Environmental Resources Management) compliance — grease disposal manifests.

| Column | Notes |
|---|---|
| `client_id` (FK) | |
| `service_date`, `dump_ticket_date` | DATE |
| `white_manifest_number` | TEXT — the receipt number from the city. Multiple rows can share one number (one physical dump = many client contributions). |
| `yellow_ticket_number` | TEXT |
| `sent_to_client`, `sent_to_city` | BOOLEAN |

Photos linked via `photo_links` (entity_type='derm_manifest', role='manifest' or 'address').

---

## manifest_visits (~819 rows)

Junction: which visits contributed grease to which manifest. Composite PK on (manifest_id, visit_id).

---

## photos (~9,544 rows) + photo_links (~10,700 rows)

```
photos                                   ← the file
  ↑ photo_id
photo_links                               ← polymorphic link
  - entity_type: 'visit' | 'note' | 'derm_manifest' | 'inspection' | ...
  - entity_id:    integer
  - role:         'manifest' | 'address' | 'before' | 'during' | 'after' | etc.
```

| photos column | Notes |
|---|---|
| `id`, `created_at` | |
| `storage_path` | path inside the bucket — UNIQUE |
| `file_name`, `content_type`, `size_bytes` | |
| `source` | `'jobber_migration'`, `'airtable_migration'`, etc. |
| `uploaded_at`, `exif_taken_at` | |
| `uploaded_by_employee_id` | optional FK |

Photo file URL pattern:
```
https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/{storage_path}
```

---

## notes (~1,902 rows)

Jobber's notes. Multiple FKs (visit_id, property_id, job_id) optional — note can hang off a client without a visit.

| Column | Notes |
|---|---|
| `id`, `client_id` (FK, NOT NULL) | |
| `visit_id`, `property_id`, `job_id` | nullable FKs |
| `body` | the note text |
| `author_employee_id`, `author_name` | |
| `note_date`, `created_at`, `updated_at` | |
| `source`, `tags` | metadata |

---

## entity_source_links (~20,500 rows)

THE polymorphic table. Maps any (entity_type, entity_id) to its source-system origin.

You probably don't query this from your apps — it's plumbing for cross-system reconciliation. Useful only if you need to look up "what's the Jobber GID of this client".

---

## jobber_oversized_attachments (~45 rows)

Tracking table for files >50 MB that exceeded our migration's bucket cap. Contains `attachment_jobber_id`, `client_id`, `note_jobber_id`, `file_name`, etc. Local backups exist; not in production storage.

---

## System tables (don't touch from your apps)

- `webhook_events_log` — webhook deliveries, 30-day retention
- `webhook_tokens` — OAuth credentials. NEVER read or expose.
- `sync_cursors` — cron job state
- `sync_log` — sync run audit

---

## Useful pre-built views

- `v_vehicle_telemetry_latest` — latest fuel/engine/GPS per truck + computed fields
- `clients_due_service` — who's due based on `service_configs.frequency_days + last_visit`
- `visits_with_status` — visits with derived `is_complete` boolean
- (more in `ops.*` schema — Fred can list if needed)

---

## Service type codes

| Code | Means |
|---|---|
| `GT` | Grease Trap (commercial, DERM-regulated) |
| `CL` | Cleaning (drain cleaning, hydrojetting) |
| `WD` | Water Drain |
| `SUMP` | Sump pumping |
| `GREY_WATER` | Grey water service |
| `WARRANTY` | Warranty / follow-up call |
| `HYDROJET`, `CAMERA`, `EMERGENCY` | Visit-only types — never appear in `service_configs`, only in `visits.service_type` |

---

## Status enums (cheat sheet)

- `clients.status`: `'ACTIVE'` / `'INACTIVE'` / `'Recuring'`
- `visits.visit_status`: `'COMPLETED'` / `'scheduled'` / `'destroyed'`
- `invoices.invoice_status`: `'draft'` / `'sent'` / `'paid'` / `'past_due'` / `'overdue'`
- `quotes.quote_status`: `'draft'` / `'awaiting_response'` / `'approved'` / `'archived'`
- `jobs.job_status`: `'active'` / `'closed'` / `'destroyed'`
- `vehicles.status`: `'ACTIVE'` / `'INACTIVE'`
- `employees.status`: `'ACTIVE'` / `'INACTIVE'`
- `inspections.inspection_type`: `'PRE'` / `'POST'`
