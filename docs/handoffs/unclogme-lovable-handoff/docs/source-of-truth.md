# Source-of-truth map

Where data in your Sandbox originally came from. Helpful for understanding *why* a value is what it is, and *how trustworthy* a given column is.

---

## The 3 source systems (production-side, before being cloned to your Sandbox)

| Source | Trust level | What it owns |
|---|---|---|
| **Jobber** | 100% canonical | Identity (clients, contacts), addresses, billing data, jobs, visits, invoices, line_items, quotes, notes, photos, employee roster (office) |
| **Samsara** | 100% canonical | Vehicles, drivers (field staff), GPS/telemetry, geofences (per-property lat/lng + radius) |
| **Airtable** | trusted ONLY for: DERM manifests + PRE-POST inspections | + best-effort enrichment for service_configs (frequencies, prices, GDO permits) and a few `properties` fields (zone, access_hours, days_of_week) |

**Critical:** Airtable is treated as best-effort outside of DERM and inspections. The data has known quality issues (Diego enters values manually; some clients have wrong frequencies, missing emails, etc.). Don't auto-correct or override Jobber/Samsara from Airtable values in your apps.

---

## Per-table source map

| Table | Source(s) | Trust |
|---|---|---|
| `clients` | Jobber (canonical name/balance/status) + Airtable (client_code, contacts) | Identity = Jobber. Other fields = best-effort. |
| `client_contacts` | Jobber emails/phones + Airtable Operation/Accounting/City contacts | Mixed. Jobber primary tends to be more reliable. |
| `properties` | Jobber addresses (canonical) + Airtable (zone, access hours/days, county) + Samsara (lat/lng, geofence) | Address from Jobber is authoritative. Access info from Airtable is best-effort. |
| `service_configs` | Airtable only — UNPIVOTed from Airtable Clients | Best-effort. Yannick maintains in Airtable; ~6 records have known bad values today. |
| `jobs` | Jobber | 100% |
| `visits` | Jobber canonical (1,807 rows) + Airtable enriches `service_type` on matched visits + ~2,081 pre-Jobber AT-historical visits with `truck` text | Jobber-era: 100%. AT-only historical: best-effort. |
| `visit_assignments` | Jobber (`v.assignedUsers`) + fixup-pass text matching for AT-historical | Jobber-era: 100%. Historical: 90%. |
| `invoices`, `line_items`, `quotes` | Jobber | 100% |
| `vehicles` | Samsara + manual capacity overrides (Goliath is manual-only) | 100% |
| `vehicle_telemetry_readings` | Samsara polling cron, every 10 min | 100% |
| `employees` | Jobber users (office/admin) + Samsara drivers (field) | 100% |
| `derm_manifests` | Airtable | **100% trusted** for DERM specifically |
| `manifest_visits` | derived (joined by client_id + service_date ±1 day) | depends on input quality |
| `inspections` | Airtable PRE-POST insptection table | **100% trusted** for inspections specifically |
| `notes` | Jobber's notes API (one-shot migration 2026-04-29) | 100% (one-shot) |
| `photos`, `photo_links` | Jobber notes attachments + Airtable DERM attachments | 100% |
| `entity_source_links` | derived | system table — plumbing |

---

## Sources that have been DROPPED

These ARE in the schema (some still — others were physically dropped 2026-04-30) but no longer populated:

| Was sourcing what | Replacement |
|---|---|
| Airtable `Drivers & Team` (driver roster) | Jobber + Samsara only — Airtable list had departed staff |
| Airtable `Past due` table → `receivables` | `invoices` filtered by `invoice_status` IN ('PAST_DUE','OVERDUE') |
| Airtable `Route Creation` → `routes`, `route_stops` | Viktor's routing skill (in Slack) |
| Airtable `Leads` | Will live in your app's `sales_leads` table going forward (Apps DB / Sandbox) |
| Fillout (forms) — entire integration | Inspections moved to Airtable PRE-POST. Expense reports moved to Ramp. |

The actual physical tables `routes`, `route_stops`, `receivables`, `leads`, `expenses` were `DROP TABLE`'d 2026-04-30. Don't expect to find them in your Sandbox.

---

## When data conflicts

If your app finds two values for the same field (e.g. `clients.name` differs from Airtable's "Client Name"), trust this hierarchy:

1. **Jobber + Samsara win** for everything they own (above table)
2. **Airtable wins** for DERM manifests + inspections only
3. For service_configs: Airtable wins by necessity (no other source) — but flag the data as suspect if it looks weird

Don't let your apps override Jobber/Samsara from Airtable values — that's a one-way street into data corruption.

---

## What lives ONLY in production, not in your Sandbox

- **Storage bucket** `GT - Visits Images` — ~12 GB of photos, public-read. Your Sandbox apps fetch from these URLs directly:
  ```
  https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/{storage_path}
  ```
- **Live webhooks** from Jobber/Airtable/Samsara — they hit production, not your Sandbox. Your Sandbox is a snapshot.
- **OAuth tokens** in `webhook_tokens` — your Sandbox has NULLs / placeholders here. Tokens are production-only secrets.
- **Edge Functions** (`webhook-jobber`, `webhook-airtable`, `webhook-samsara`) — these run on production. Your Sandbox has the schema but the functions aren't deployed there.

When your Sandbox is refreshed (Fred re-clones Main), the *data* tables sync but the operational fixtures above stay production-side.
