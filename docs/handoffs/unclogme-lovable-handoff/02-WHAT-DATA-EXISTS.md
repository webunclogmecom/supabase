# 02 — What data exists in the Main DB

The Main DB has **25 tables** organized into a few logical groups. This is a tour — for the exact column list per table, see [`docs/schema-quick.md`](docs/schema-quick.md).

---

## The spine: clients → properties → jobs → visits

Every operational entity hangs off this chain.

| Table | Rows | What's in it |
|---|---|---|
| `clients` | 445 | The companies/people we serve. Identity, status (`ACTIVE`/`INACTIVE`/`Recuring`), client_code (e.g. "009-CN"), balance |
| `client_contacts` | 548 | Multiple contacts per client (primary, accounting, city/DERM) — name, email, phone, role |
| `properties` | 457 | Locations served. One client can have many. Address, geofence (lat/lng + radius), access hours, `grease_trap_manhole_count` (how many traps to service per visit) |
| `jobs` | 518 | A unit of work for a client. Job has many visits. From Jobber. |
| `visits` | 3,888 | The actual on-site service. Date, start/end times, status, vehicle, completed_by. The most important table for operational reporting. |
| `visit_assignments` | 1,830 | Who worked which visit. Polymorphic team→visit join. |

---

## Money

| Table | Rows | What's in it |
|---|---|---|
| `invoices` | 1,670 | Issued invoices. From Jobber. Includes `invoice_status` so you can compute past-due. |
| `quotes` | 167 | Sent quotes. From Jobber. |
| `line_items` | 565 | Per-line invoice/quote items: description, qty, price |

**Past-due query** (replaces what used to be a separate `receivables` table):
```sql
SELECT * FROM invoices
WHERE invoice_status IN ('PAST_DUE', 'OVERDUE')
   OR (due_date < now() AND amount_paid < total_amount);
```

---

## Service operations

| Table | Rows | What's in it |
|---|---|---|
| `service_configs` | 204 | Per-client service definitions: type (GT/CL/WD/SUMP/GREY_WATER/WARRANTY), `frequency_days` (every N days), `price_per_visit`, GDO permit info. One client can have multiple service configs. |
| `vehicles` | 4 | The trucks: Cloggy, David, Moises, Goliath. Tank capacities (grease + fuel separately). |
| `vehicle_telemetry_readings` | growing | Samsara-pulled fuel %, engine state, GPS lat/lng, odometer. Updated every 10 min via cron. |
| `employees` | 32 | Office + field staff. Office: Yannick, Diego, Fred, Aaron. Field drivers from Samsara. |

**Important:** Truck names (David, Moises, Goliath) are TRUCKS, not people. The `vehicles.name` and `employees.full_name` are different concepts.

---

## DERM compliance (Miami-Dade grease disposal regulation)

| Table | Rows | What's in it |
|---|---|---|
| `derm_manifests` | 963 | One row per "client contributed to a dump" event. Has `white_manifest_number`, `dump_ticket_date`, `sent_to_client` / `sent_to_city` flags. Multiple rows can share the same manifest # (one physical dump = many client contributions). |
| `manifest_visits` | 819 | Junction: which visits contributed grease to which manifest |

---

## Photos & notes

| Table | Rows | What's in it |
|---|---|---|
| `photos` | 9,544 | All file metadata: storage path, file name, content type, source ('jobber_migration' or 'airtable_migration'). The actual files live in Supabase Storage bucket `GT - Visits Images`. |
| `photo_links` | ~10,700 | Polymorphic: links a `photo_id` to ANY entity via `(entity_type, entity_id, role)`. e.g. `entity_type='visit', role='during'`, or `entity_type='derm_manifest', role='manifest'`. |
| `notes` | 1,902 | Jobber's note attachments — text content, with optional FK to visit/property/job |
| `jobber_oversized_attachments` | 45 | Tracking table for files >50 MB that exceeded our migration's bucket cap. Local backups exist. |

**Reading photos for a visit:**
```sql
SELECT p.storage_path, p.file_name, pl.role
FROM photo_links pl
JOIN photos p ON p.id = pl.photo_id
WHERE pl.entity_type = 'visit' AND pl.entity_id = $visitId;
```

To display in your app: `https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/{storage_path}` (the bucket is public).

---

## Inspections (PRE/POST shift checks)

| Table | Rows | What's in it |
|---|---|---|
| `inspections` | 242 | One row per PRE or POST shift check. Driver, truck, sludge tank level, water tank level, gas level, valve state, issues. Source: Airtable's "PRE-POST insptection" table. |

---

## Cross-system bridge

| Table | Rows | Purpose |
|---|---|---|
| `entity_source_links` | 20,500 | THE polymorphic table. For any entity, says "this row in our DB came from THIS source system with THIS source ID". Lets us trace any client/visit/photo back to its Jobber/Airtable/Samsara origin. **You probably don't need to query this from your apps** — it's plumbing. |

---

## System / observability (you can ignore these for app-building)

| Table | Purpose |
|---|---|
| `webhook_events_log` | Every webhook delivery, last 30 days. Debugging only. |
| `webhook_tokens` | OAuth credentials. **NEVER read or expose.** |
| `sync_cursors` | Cron job state. |
| `sync_log` | Sync run audit. |

---

## Quick numbers (as of 2026-04-30)

| Metric | Value |
|---|---|
| Clients | 445 (190 with Airtable enrichment) |
| Properties | 457 |
| Visits this year (2026 so far) | ~700 |
| Active vehicles | 3 (Cloggy, Moises, David) + Goliath (inactive) |
| DERM manifests | 963 |
| Photos in storage | 9,544 (~12 GB) |
| Notes | 1,902 |

---

## Useful pre-built views (read-only convenience)

These are PostgreSQL views that compute things for you. Use them like tables:

| View | What it gives you |
|---|---|
| `v_vehicle_telemetry_latest` | Latest telemetry snapshot per truck — fuel %, gallons, miles, GPS, "minutes ago since last update" |
| `clients_due_service` | Clients whose next service is due (computed from service_configs.frequency_days + last_visit) |
| `visits_with_status` | Visits with derived `is_complete` boolean from `visit_status` |
| `ops.*` | Operational reporting views — Fred can give you specifics if needed |

---

## Where to find more detail

- [`docs/schema-quick.md`](docs/schema-quick.md) — column-by-column reference
- [`docs/source-of-truth.md`](docs/source-of-truth.md) — which source system owns what
- Or just ask Lovable: *"Show me the schema for the visits table"* — Lovable can query Supabase's metadata directly.

Next: read **03-BUILDING-YOUR-APP.md** for the two-database write pattern.
