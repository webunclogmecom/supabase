# Architecture

**Version:** v2 · **Last reviewed:** 2026-04-29 (post-repop / source-of-truth canonicalization)

---

## One-paragraph summary

Source systems push events to Supabase Edge Functions, which validate, normalize, and upsert into 28 Postgres tables. Cross-system identity resolution happens in a single polymorphic table (`entity_source_links`) rather than via source-prefixed columns. No nightly cron, no drift detector — the webhook stream is the only path, and `webhook_events_log` is the observability surface. Jobber and Airtable sunset in May 2026, at which point Odoo.sh reads from this database as CRM; Samsara survives as a permanent fleet-telemetry integration.

---

## Data flow

```
┌──────────┐     event      ┌────────────────────┐   validate    ┌──────────────┐
│  Jobber  │ ─────────────▶ │  webhook-jobber    │ ───────────▶  │              │
└──────────┘                │  Edge Function     │               │              │
                            └────────────────────┘               │              │
┌──────────┐     event      ┌────────────────────┐   upsert      │              │
│ Airtable │ ─────────────▶ │  webhook-airtable  │ ───────────▶  │   Postgres   │
└──────────┘                │  Edge Function     │               │ (Supabase)   │
                            └────────────────────┘               │              │
┌──────────┐     event      ┌────────────────────┐   resolve     │              │
│ Samsara  │ ─────────────▶ │  webhook-samsara   │ ───────────▶  │              │
└──────────┘                │  Edge Function     │               │              │
                            └────────────────────┘               └──────┬───────┘
                                     │                                   │
                                     │ log every event                   │
                                     ▼                                   │
                            ┌────────────────────┐                       │
                            │ webhook_events_log │ ◀─── observability ───┘
                            └────────────────────┘
```

Every Edge Function follows the same 5-step handler:

1. **Validate webhook signature** (source-specific HMAC / bearer / query secret)
2. **Log to `webhook_events_log`** (status=`received`, raw payload JSONB)
3. **Resolve entity** via `entity_source_links` (find our local `entity_id` from `source_id`)
4. **Upsert to the normalized table** (idempotent, `ON CONFLICT` on natural keys)
5. **Upsert `entity_source_links` row** (match_method=`api_webhook`, update `synced_at`)

If any step throws, `webhook_events_log.status` is flipped to `failed` with the error message.

---

## Source systems

> **Trust hierarchy** (revised 2026-04-29 — see [ADR 011](decisions/011-source-of-truth-canonicalization-2026-04-29.md)):
> - **Jobber + Samsara = 100% canonical.** Every overlapping field, Jobber/Samsara wins.
> - **Airtable = 100% trusted ONLY for `derm_manifests` + `inspections` (PRE-POST table).**
> - **Airtable = best-effort enrichment** (because no alternative source exists) for: `service_configs` (frequencies, prices, GDO permits), client contacts, property zone/access fields.
> - **Dropped sources (2026-04-29)**: Airtable `Drivers & Team`, `Past due`, `Route Creation`, `Leads`. Fillout entirely (inspections moved to Airtable PRE-POST; expenses live in Ramp).

### Jobber — 100% canonical (identity + billing + visits)

- **API:** GraphQL, OAuth 2.0
- **Endpoint:** `https://api.getjobber.com/api/graphql`
- **Receiver:** `supabase/functions/webhook-jobber/index.ts`
- **Sunset:** May 2026 — replaced by Odoo.sh CRM
- **Owns:** clients (identity, name, address, contacts), properties, jobs, visits, invoices, line_items, quotes, notes/photos, employees (office/admin via Jobber users), payment status
- **Webhook events consumed:** `CLIENT_CREATE/UPDATE/DESTROY`, `JOB_*`, `VISIT_*`, `INVOICE_*`, `QUOTE_*`, `PROPERTY_*`
- **Rate limits:** 2,500 req / 5 min (DDoS), plus a 10,000-point GraphQL query-cost budget restored at 500/sec. [Details ›](integration.md#jobber-rate-limits)

### Samsara — 100% canonical (fleet, drivers, GPS)

- **API:** REST
- **Endpoint:** `https://api.samsara.com`
- **Receivers:**
  - Webhook (`supabase/functions/webhook-samsara/index.ts`) — receives address/driver/alert events. 6 webhook subscriptions registered, 296+ events processed.
  - Polling cron (`scripts/sync/cron_samsara_telemetry.js`, `.github/workflows/samsara-poll.yml`) — pulls `/fleet/vehicles/stats?types=engineStates,fuelPercents,obdOdometerMeters,gps` every 10 minutes. Vehicle stats are NOT available via webhook on Samsara's side (polling is the only mechanism).
- **Sunset:** Never — Samsara is permanent ([ADR 007](decisions/007-samsara-permanent.md))
- **Owns:** vehicles, drivers (field staff), GPS/telemetry (`vehicle_telemetry_readings`), geofences, harsh events, DVIR submissions
- **Telemetry table** (`vehicle_telemetry_readings`): one row per vehicle per cron fire. Columns include `fuel_percent`, `engine_state`, `odometer_meters`, `engine_hours_seconds`, `latitude`, `longitude`, `speed_meters_per_sec`, `heading_degrees`, `recorded_at`. Idempotent on `(vehicle_id, recorded_at)`. ~30MB/year at 10-min cadence × 3 vehicles. Started collecting 2026-04-30 to accumulate history before fuel/water-burn modeling begins.
- **Rate limits:** 150 req/sec per token, 200 req/sec per org, plus per-endpoint caps (e.g. `/fleet/hos/logs` = 30/sec)

### Airtable — DERM + PRE-POST inspections (100% trusted), service configs (best-effort)

- **API:** REST
- **Endpoint:** `https://api.airtable.com/v0/`
- **Receiver:** `supabase/functions/webhook-airtable/index.ts`
- **Sunset:** May 2026 — replaced by Odoo.sh
- **Owns (100% trusted)**: `derm_manifests` (white/yellow manifest numbers, dump dates), `inspections` (PRE-POST insptection table — driver, truck, sludge/water levels, gas, valve, issues)
- **Best-effort enrichment** (used because no alternative source): `service_configs` (GT/CL/WD frequencies, prices, GDO permit numbers + expirations, equipment size), `client_contacts` (Operation/Accounting/City contact roles), `properties` (zone, access hours/days, county)
- **Never trusted over Jobber/Samsara**: identity fields, addresses, money, employees, route assignments, payment status
- **Rate limits:** 5 req/sec per base (hard cap, all tiers), 50 req/sec per token across all bases

**Frequency-unit normalization at sync time** (corrected 2026-04-30 — Airtable stores DAYS for all three; the previous "GT/CL in months" claim was wrong, produced 30× inflated values for 98% of clients):
- GT frequency: DAYS → `service_configs.frequency_days` (pass-through)
- CL frequency: DAYS → `service_configs.frequency_days` (pass-through)
- WD frequency: DAYS → `service_configs.frequency_days` (pass-through)

Yannick's normal entry range: 10–180 days. Anything > 180d is an Airtable data error that should be flagged for review (not patched in DB — fix in the source).

### Fillout — DROPPED 2026-04-29

Inspection ingestion migrated to Airtable's PRE-POST table; expense ingestion dropped (Ramp owns expenses). All `pullFillout`, `cache.fillout`, `_fillout_name`, `employeeByFilloutName` references removed from `populate.js`. The Edge Function for Fillout (if any was wired) is no longer referenced.

### Service type vocabulary

| Code | Meaning | Where it appears |
|---|---|---|
| `GT` | Grease Trap (commercial, DERM-regulated) | `service_configs.service_type`, `visits.service_type` |
| `CL` | Cleaning (drain cleaning) | same |
| `WD` | Water Drain | same |
| `AUX` | Auxiliary / other | same |
| `SUMP`, `GREY_WATER`, `WARRANTY` | Rare | `service_configs` only |
| `HYDROJET`, `CAMERA` | Job type shorthand | `visits.service_type` |
| `EMERGENCY` | Visit-level only | `visits.service_type` (never a service_config row) |

---

## The `entity_source_links` pattern

**The single most important architectural decision in this database.** See [ADR 002](decisions/002-entity-source-links.md) for the full rationale.

### Problem it replaces

Without it, every business table grows source-prefixed columns as integrations accrue:

```
clients
  id                  (our PK)
  jobber_id           ← if we pull from Jobber
  airtable_record_id  ← if we pull from Airtable
  fillout_customer_id ← if we pull from Fillout
  ...
```

This bloats tables, leaks integration history into business schemas, and breaks every time a new source is added (or removed — like the Jobber sunset).

### What we do instead

```
clients
  id, client_code, name, status, balance, notes, created_at, updated_at
  -- zero source-prefixed fields

entity_source_links
  (entity_type='client', entity_id=42, source_system='jobber',   source_id='JOB_123')
  (entity_type='client', entity_id=42, source_system='airtable', source_id='recABC')
  (entity_type='client', entity_id=42, source_system='fillout',  source_id='fill_999')
```

- Business tables stay source-agnostic.
- Adding a new source = inserting rows, not altering tables.
- Sunset-proof: at the Jobber cutover (May 2026) we delete those link rows, business tables are untouched.
- Polymorphic: one table covers clients, properties, jobs, visits, employees, vehicles, invoices, quotes, manifests.

### Usage

Every webhook handler uses this table three ways:
1. **Inbound resolve:** `source_id` → `entity_id`
2. **Outbound resolve:** `entity_id` → `source_id` (for replying / enrichment)
3. **First-touch insert:** new row with `match_method='api_webhook'`, `match_confidence=1.00`

See examples in [docs/schema.md#entity_source_links](schema.md#entity_source_links--10117-rows).

---

## Integration timeline

```
                     ┌─────── webhooks active ───────┐
                     │                               │
                     │   Jobber, Airtable, Samsara   │
  v2 schema ────────┼─── webhook-* Edge Fns ────────┼──── Odoo.sh CRM reads Supabase
  2026-04           │                               │    (replaces Jobber + Airtable)
                     │   populate scripts (one-shot)│
                     │                               │
                     └────────── 2026-05 ────────────┘
                                                    ▲
                                              cutover window

                                             ┌──────────────────────────
                                             │  Samsara stays (permanent)
                                             ▼
```

| Source | Status | Target |
|---|---|---|
| Jobber | Active via webhook | Sunset May 2026 |
| Airtable | Active via webhook | Sunset May 2026 |
| Samsara | Active via webhook (registration blocked) | Permanent |
| Fillout | Sunset already underway | Replaced by Odoo.sh forms |
| Odoo.sh | Reads from this DB | Live May 2026 |

Full cutover plan: [docs/migration-plan.md](migration-plan.md).

---

## Why webhooks — and not nightly cron

The first architecture was a 5-script nightly cron pipeline running in GitHub Actions. It was replaced by webhooks at commit `1cf3715`. See [ADR 001](decisions/001-webhooks-over-cron.md) for the decision memo. Short version:

| Dimension | Cron nightly | Webhooks |
|---|---|---|
| Latency | 24 h | ~seconds |
| Token refresh | Must self-update GH Secrets (impossible) | Stored in `webhook_tokens`, refreshed naturally |
| Moving parts | 5 scripts + 1 workflow + 1 populate orchestrator | 3 Edge Functions, one per source |
| Failure surface | Red CI email, nobody acts | `webhook_events_log` row with `status='failed'` |
| Cost | 60 min of runner time × 365 | ~1M Edge Function invocations/mo, well inside free tier |

The drift-detection question was resolved: for a 4-truck fleet, `webhook_events_log` catches failures on its own. No separate reconciliation.

---

## Edge Function deployment model

Each webhook receiver is a Deno-based Supabase Edge Function:

```
supabase/functions/
  webhook-jobber/
    index.ts
  webhook-samsara/
    index.ts
  webhook-airtable/
    index.ts
  _shared/
    supabase-client.ts    ← authenticated client factory
    entity-links.ts       ← inbound/outbound lookup + upsert helpers
    responses.ts          ← standardized HTTP responses
```

- Deployed with `supabase functions deploy <name>` (see [docs/integration.md](integration.md#deploying-an-edge-function))
- Environment variables injected from the project's Edge Function secrets — not from `.env`
- Signature validation uses source-specific secrets also stored as Edge Function secrets

---

## What this architecture is *not*

- **Not an event sourcing store.** We don't replay `webhook_events_log` to rebuild state. It's an audit log.
- **Not multi-region.** Single Supabase region (East US via `wbasvhvvismukaqdnouk`).
- **Not a read-replica pattern.** All reads and writes hit the same DB. Pro plan supports read replicas if we need them later.
- **Not a CQRS boundary.** Business tables are read and written by the same functions.

---

## Known integration blockers (2026-04-20)

| Blocker | Impact | Fix path |
|---|---|---|
| Samsara Edge Function code vs schema | Webhooks registered but deployed function still writes to pre-rename table; needs deploy of updated code | `supabase functions deploy webhook-samsara` once ready |
| Jobber visits re-pull for `assignedUsers` | `visit_assignments` stays at 0 rows | Rate-limited; needs paced re-pull or a `webhook-jobber` backfill endpoint |
| Photo migration from Jobber notes | Photo URLs expire at May 2026 sunset | Schema ready (`photos`, `photo_links`); extractor not written. [Migration plan](migration-plan.md#jobber-notes--photos-migration) |

Full list in [docs/runbook.md](runbook.md#outstanding-population-gaps).
