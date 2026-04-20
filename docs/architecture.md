# Architecture

**Version:** v2 · **Last reviewed:** 2026-04-20

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

### Jobber — source of truth for contact + billing

- **API:** GraphQL, OAuth 2.0
- **Endpoint:** `https://api.getjobber.com/api/graphql`
- **Receiver:** `supabase/functions/webhook-jobber/index.ts`
- **Sunset:** May 2026 — replaced by Odoo.sh CRM
- **Wins on:** name, address, phone, email, billing, payment status, job/visit dates, financial fields, invoice data
- **Webhook events consumed:** `CLIENT_CREATE/UPDATE/DESTROY`, `JOB_*`, `VISIT_*`, `INVOICE_*`, `QUOTE_*`, `PROPERTY_*`
- **Rate limits:** 2,500 req / 5 min (DDoS), plus a 10,000-point GraphQL query-cost budget restored at 500/sec. [Details ›](integration.md#jobber-rate-limits)

### Airtable — CRM master for service details + compliance

- **API:** REST
- **Endpoint:** `https://api.airtable.com/v0/`
- **Receiver:** `supabase/functions/webhook-airtable/index.ts`
- **Sunset:** May 2026 — replaced by Odoo.sh
- **Wins on:** GDO compliance fields, service frequencies, zone, scheduling notes, `service_type` on visits, `client_code`
- **Rate limits:** 5 req/sec per base (hard cap, all tiers), 50 req/sec per token across all bases

**Frequency-unit normalization at sync time:**
- GT frequency from Airtable: MONTHS × 30 → `service_configs.frequency_days`
- CL frequency from Airtable: MONTHS × 30 → `service_configs.frequency_days`
- WD frequency from Airtable: already DAYS → pass through

### Samsara — fleet telemetry (permanent)

- **API:** REST
- **Endpoint:** `https://api.samsara.com`
- **Receiver:** `supabase/functions/webhook-samsara/index.ts`
- **Sunset:** Never. Samsara survives Jobber and Airtable.
- **Provides:** Vehicle telemetry (fuel %, odometer, engine state, engine hours), GPS geofence enter/exit events, harsh events, DVIR submissions
- **Known integration blocker:** Samsara webhook registration requires "Webhooks write" scope on the API token. Current token only has read scope. [Recovery ›](runbook.md#samsara-webhook-registration)
- **Rate limits:** 150 req/sec per token, 200 req/sec per org, plus per-endpoint caps (e.g. `/fleet/hos/logs` = 30/sec)

### Fillout — digital inspection forms (sunset)

- **API:** REST
- **Sunset:** May 2026 — replaced by Odoo.sh forms
- **Provides:** Pre/post-shift inspections, expense reports, manifest submissions
- **Rate limits:** 5 req/sec per account (~300 req/min)

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
| Samsara webhook registration denied | `vehicle_telemetry_readings` stays at 0 rows | Token needs "Webhooks write" scope → update in Samsara dashboard |
| Jobber visits re-pull for `assignedUsers` | `visit_assignments` stays at 0 rows | Rate-limited; needs paced re-pull or a `webhook-jobber` backfill endpoint |
| Photo migration from Jobber notes | Photo URLs expire at May 2026 sunset | [Migration plan](migration-plan.md#jobber-notes--photos-migration) |

Full list in [docs/runbook.md](runbook.md#outstanding-population-gaps).
