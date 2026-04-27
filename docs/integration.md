# Integration Contracts

Per-source integration details: webhook endpoints, signatures, payloads, registration, and rate limits. Pair this with [architecture.md](architecture.md) for the system-level view.

---

## Edge Function inventory

| Function | Endpoint (public) | Source | Target tables | Status |
|---|---|---|---|---|
| `webhook-jobber` | `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-jobber` | Jobber | clients, client_contacts, jobs, visits, visit_assignments, invoices, quotes, properties, photo_links | Deployed; live delivery intermittent |
| `webhook-airtable` | `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-airtable` | Airtable | service_configs (via Clients), derm_manifests, routes, receivables, inspections | Live (10 automations) |
| `webhook-samsara` | `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-samsara` | Samsara | properties (geofence on clients), employees (drivers), vehicle_telemetry_readings | Deployed; HMAC failing on real events (see runbook §5) |

Every function:
- Accepts `POST` with JSON body
- Validates signature (see per-source below)
- Logs to `webhook_events_log` before any business logic
- Returns `200 OK` on success, `401` on signature failure, `500` on internal error
- Source retries on non-2xx for the source's retry window

---

## Webhook signature validation

Shared principle: **never trust a webhook payload without verifying the signature.** The public endpoint is discoverable; anyone could POST to it.

### Jobber — HMAC-SHA256

1. Source sends `X-Jobber-Hmac-Sha256: <base64(hmac_sha256(body, SHARED_SECRET))>`
2. Edge Function reads `JOBBER_WEBHOOK_SECRET` from secrets.
3. Compute HMAC of raw request body with that secret.
4. Constant-time compare to the header value.
5. Mismatch → 401 + `webhook_events_log.error_message = 'signature_invalid'`.

### Airtable — static bearer

1. Source sends `Authorization: Bearer <AIRTABLE_WEBHOOK_TOKEN>` (static shared token).
2. Edge Function reads `AIRTABLE_WEBHOOK_TOKEN` from secrets.
3. Exact-match compare.
4. Mismatch → 401.

Airtable also signs webhooks with HMAC in newer API versions — this project uses the static-bearer pattern because it's simpler and sufficient at current risk level.

### Samsara — HMAC-SHA256

1. Source sends `X-Samsara-Signature: <hex(hmac_sha256(timestamp + '.' + body, SHARED_SECRET))>`
2. Source also sends `X-Samsara-Timestamp: <unix-ts>`.
3. Edge Function verifies `abs(now - timestamp) < 5 minutes` (replay protection).
4. Computes HMAC of `timestamp + '.' + body` with `SAMSARA_WEBHOOK_SECRET`.
5. Constant-time compare.

---

## Payload shapes

Minimal shapes — source systems send more fields, but these are what we consume. Full schemas in the source's API docs.

### Jobber — `CLIENT_UPDATE` example

```json
{
  "data": {
    "webHookEvent": {
      "itemId": "gid://Jobber/Client/12345",
      "appId": "uuid",
      "accountId": "uuid",
      "occuredAt": "2026-04-20T12:00:00Z",
      "topic": "CLIENT_UPDATE"
    }
  }
}
```

Handler then calls Jobber GraphQL with the `itemId` to fetch the full client record. Topic-specific handling:

| Topic | Handler action |
|---|---|
| `CLIENT_CREATE` / `CLIENT_UPDATE` | Fetch full client; upsert `clients`, `client_contacts`, `properties`; upsert `entity_source_links` |
| `CLIENT_DESTROY` | Set `clients.status = 'INACTIVE'` (never hard-delete — rule #6) |
| `JOB_CREATE` / `JOB_UPDATE` | Fetch job; upsert `jobs`; link via `entity_source_links` |
| `JOB_CLOSED` / `JOB_DESTROY` | Flip `jobs.job_status` to `closed` / `destroyed` — no hard-delete |
| `VISIT_CREATE` / `VISIT_UPDATE` / `VISIT_COMPLETE` | Fetch visit with `assignedUsers`; upsert `visits` + `visit_assignments` |
| `VISIT_DESTROY` | Flip `visits.visit_status = 'destroyed'` |
| `INVOICE_CREATE` / `INVOICE_UPDATE` | Upsert `invoices` from Jobber amounts |
| `INVOICE_DESTROY` | Flip `invoices.invoice_status = 'destroyed'` |
| `QUOTE_CREATE` / `QUOTE_UPDATE` / `QUOTE_SENT` / `QUOTE_APPROVED` | Upsert `quotes` (status reflects Jobber `quoteStatus`) |
| `QUOTE_DESTROY` | Flip `quotes.quote_status = 'destroyed'` |
| `PROPERTY_CREATE` / `PROPERTY_UPDATE` | Upsert `properties` (client_id, address, city, state, zip) |
| `PROPERTY_DESTROY` | Hard delete (properties are leaf nodes; FK children handled via ON DELETE) |

GraphQL contract notes (critical — all bugs discovered via replay 2026-04-22):
- IDs are the canonical `gid://Jobber/<Type>/<numericId>` form, base64-encoded; `decodeGid` must match that exact shape.
- `X-JOBBER-GRAPHQL-VERSION: 2026-04-16` is required on every GraphQL request.
- Status fields are **typed**: `Job.jobStatus`, `Visit.visitStatus`, `Invoice.invoiceStatus`, `Quote.quoteStatus`. There is no generic `status` field on any of them.
- `Client.isActive` does not exist — use `isArchived` only.
- `Visit.assignedTo` → `assignedUsers`. `Invoice.job` → `jobs.nodes[0]`. `InvoiceAmounts.outstanding` → `invoiceBalance`.

### Airtable — record change

```json
{
  "base": {"id": "appXXXX"},
  "webhook": {"id": "achXXXX"},
  "timestamp": "2026-04-20T12:00:00Z",
  "changedTablesById": {
    "tblABC": {
      "changedRecordsById": {
        "recDEF": {
          "current": {"fields": {"Name": "Casa Neos", "GT_Frequency": 1, ...}}
        }
      }
    }
  }
}
```

Handler maps `tblABC` to a target table (configured constant) and upserts.

### Samsara — vehicle stats snapshot

```json
{
  "eventId": "evt_...",
  "eventType": "VehicleStatsSnapshot",
  "data": {
    "id": "2811...",
    "name": "Moises",
    "fuelPercent": {"time": "2026-04-20T12:00:00Z", "value": 78.5},
    "obdOdometerMeters": {"time": "...", "value": 412340123},
    "engineStates": [{"time": "...", "value": "On"}],
    "obdEngineSeconds": {"time": "...", "value": 4382100}
  }
}
```

Handler appends one row to `vehicle_telemetry_readings`.

---

## Deploying an Edge Function

Prerequisites:
- Supabase CLI installed (`npm install -g supabase` or Homebrew)
- `supabase login` done once (uses `SUPABASE_PAT`)

```bash
# From project root
cd C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase

# Deploy a single function
supabase functions deploy webhook-jobber --project-ref wbasvhvvismukaqdnouk

# Deploy all three
for f in webhook-jobber webhook-samsara webhook-airtable; do
  supabase functions deploy $f --project-ref wbasvhvvismukaqdnouk
done
```

Each deploy:
- Bundles TypeScript with Deno
- Uploads to Supabase Edge runtime
- Atomically swaps the new version in
- Zero downtime

Logs stream with `supabase functions logs webhook-jobber --project-ref wbasvhvvismukaqdnouk --tail`.

---

## Registering webhooks

Registration is what tells the source system "deliver events to this URL". It's a one-time setup per source (plus re-registration after URL/secret changes).

### Jobber

Webhooks are managed in the Jobber Developer Center → your app → Webhooks. Register:

- **Webhook URL:** `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-jobber`
- **Secret:** the OAuth app's `client_secret` (Jobber signs every webhook with HMAC-SHA256 using the client_secret as the key — there is **no** separate "webhook signing secret"). Set as `JOBBER_WEBHOOK_SECRET` in the Edge Function secrets.
- **22 topics subscribed** (configured in Jobber Developer Center, not via script):
  - CLIENT_CREATE, CLIENT_UPDATE, CLIENT_DESTROY
  - JOB_CREATE, JOB_UPDATE, JOB_CLOSED, JOB_DESTROY
  - VISIT_CREATE, VISIT_UPDATE, VISIT_COMPLETE, VISIT_DESTROY
  - INVOICE_CREATE, INVOICE_UPDATE, INVOICE_DESTROY
  - QUOTE_CREATE, QUOTE_UPDATE, QUOTE_SENT, QUOTE_APPROVED, QUOTE_DESTROY
  - PROPERTY_CREATE, PROPERTY_UPDATE, PROPERTY_DESTROY
- **GraphQL contract notes** (all bugs found via 2026-04-22 replay):
  - IDs are canonical `gid://Jobber/<Type>/<numericId>` form, base64-encoded
  - `X-JOBBER-GRAPHQL-VERSION` header required (currently `2026-04-16`)
  - Status fields are typed: `Job.jobStatus`, `Visit.visitStatus`, `Invoice.invoiceStatus`, `Quote.quoteStatus` — no generic `status`
  - `Client.isActive` does not exist; use `isArchived` only
  - `Visit.assignedTo` → `assignedUsers`; `Invoice.job` → `jobs.nodes[0]`; `InvoiceAmounts.outstanding` → `invoiceBalance`

### Airtable

Airtable webhooks are per-automation. In Airtable → Automations → create trigger "When record matches conditions" → action "Send webhook":

- **URL:** `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/webhook-airtable`
- **Headers:** `Authorization: Bearer <AIRTABLE_WEBHOOK_TOKEN>`
- **Body:** include the changed record(s) and the table ID

One automation per table (clients, service_configs, derm_manifests, routes, receivables, leads).

### Samsara

**Currently blocked** — token needs "Webhooks write" scope. See [runbook.md §5](runbook.md#5-samsara-webhook-registration).

Once unblocked, run `scripts/webhooks/register-samsara.js`. Register for these event types:
- `VehicleStatsSnapshot` (fuel, odometer, engine state)
- `GeofenceEntry` / `GeofenceExit` (for visit GPS enrichment)
- `HarshEvent` (future: driver safety scoring)
- `DvirSubmission` (future: inspection sync)

---

## Rate limits — full reference

Values as of 2026-04-20. [Source docs linked.](#)

### Jobber

| Limit | Value |
|---|---|
| DDoS bucket | 2,500 req / 5 min per (app × account) |
| GraphQL query cost | 10,000 points bucket, 500 pts/sec restore |
| Webhook retry | 24 hours with exponential backoff |

Cost introspection: every Jobber response has `extensions.cost.throttleStatus.{currentlyAvailable, maximumAvailable, restoreRate}`. Monitor with `scripts/sync/lib/jobber.js` logging (see `[budget]` log lines).

### Airtable

| Limit | Value |
|---|---|
| Per base | 5 req/sec (hard cap, all tiers) |
| Per token | 50 req/sec across all bases |
| Batch write | 10 records/request → effective 50 records/sec |

### Samsara

| Limit | Value |
|---|---|
| Per token | 150 req/sec |
| Per org | 200 req/sec |
| Per endpoint | Varies (e.g. `/fleet/hos/logs` 30/sec, some endpoints 5/sec) |
| Webhook retry | 24 hours |

### Fillout

| Limit | Value |
|---|---|
| Per account | 5 req/sec (~300 req/min) |

### Supabase (our destination)

| Limit | Value |
|---|---|
| Edge Function CPU | 2 sec / request |
| Edge Function idle | 150 sec |
| Function-to-function (nested) | 5,000 req/min per request chain |
| REST / PostgREST | No global req/sec cap |
| Storage | 100 GB on Pro before overage |

---

## Testing webhooks locally

```bash
# 1. Run the function locally
supabase functions serve webhook-jobber --env-file .env

# 2. Send a test payload
curl -X POST http://localhost:54321/functions/v1/webhook-jobber \
  -H "Content-Type: application/json" \
  -H "X-Jobber-Hmac-Sha256: <computed-signature>" \
  -d @test-fixtures/jobber-client-update.json
```

Fixtures (JSON files with real-shape payloads) should live in `supabase/functions/<name>/__tests__/fixtures/`. Currently sparse — build out as we add handler logic.

---

## Future: adding a new source

When we integrate Odoo.sh as a data source (post-May 2026):

1. Add `source_system = 'odoo'` to the `entity_source_links` domain.
2. Create `supabase/functions/webhook-odoo/` (copy `webhook-jobber` as template).
3. Define the signature validation scheme with Odoo.sh.
4. Register the webhook on the Odoo side.
5. Add one ADR documenting any schema-level change (if any; hopefully none thanks to [ADR 002](decisions/002-entity-source-links.md)).

Pattern to preserve: business tables never get an `odoo_*` column. Odoo's IDs go to `entity_source_links`, same as every other source.
