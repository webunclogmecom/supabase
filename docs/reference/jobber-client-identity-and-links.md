# How a Jobber client becomes one of our rows

*Written 2026-09-08, after "Bibi's Burger is empty here but Jobber has data for it" turned out to be
four client rows from one Jobber client. Everything below is measured against Prod
`wbasvhvvismukaqdnouk`, not inferred from the code.*

---

## 1. Identity lives in `entity_source_links`, nowhere else

`public.clients` has **no** `jobber_client_id` column. Its full column list is:

```
id, client_code, name, status, balance, notes, created_at, updated_at,
group_id, client_class, client_class_source, status_source
```

The only thing tying one of our clients to a Jobber client is a row in `public.entity_source_links`:

```
entity_type = 'client'
entity_id   = public.clients.id
source_system = 'jobber'
source_id   = the base64 GID, e.g. Z2lkOi8vSm9iYmVyL0NsaWVudC8xNTEyNjE5NzI=
              (= gid://Jobber/Client/151261972)
```

Two unique indexes matter, and **they are not the same shape**:

| Index | Columns | What it actually prevents |
|---|---|---|
| `idx_esl_entity_source` | `(entity_type, entity_id, source_system)` | one of OUR rows holding two links to the same source system |
| `idx_esl_source_id` | `(entity_type, source_system, source_id)` | two of OUR rows claiming the SAME Jobber object |

🛑 **`upsertEntityLink` in `_shared/entity-links.ts` names the FIRST one in its `onConflict`, but the
one that fires on a duplicate-client race is the SECOND.** ON CONFLICT only absorbs the target you
name, so the second index raises `23505` instead. That mismatch is the whole 2026-09-01 incident.

⇒ **A row with no link is unreachable forever.** Every handler resolves a Jobber object to one of our
rows through this table, so an unlinked row can never receive an update, a job, a visit or an
invoice. It is not a lagging record; it is a dead one.

## 2. The property link has a synthetic form, and it is not a property GID

Every client carries **two** property rows for one Jobber property:

| Our property | `entity_source_links.source_id` | `is_billing` |
|---|---|---|
| billing | `<CLIENT gid>_billing` — a **client** GID with a suffix | `true` |
| service | the real `gid://Jobber/Property/<n>` | `false` |

Bibi's burgers is the clean example: Jobber holds **one** property (`157977736`) whose
`isBillingAddress` is `true`; we hold `1112` (billing, synthetic link) and `1113` (service, real
link). This is the documented service/billing duplication, not a fault. `jobCreate` takes a
`propertyId`, so the billing row is never schedulable and pickers must filter `is_billing`.

## 3. Who writes `public.clients`

**Exactly one writer: `handleClient` in `supabase/functions/webhook-jobber/index.ts`.** Verified by
grep across the whole functions tree: no other edge function inserts into `clients`.

Four things reach it:

| Path | Trigger | Topic it sends |
|---|---|---|
| Live Jobber webhook | Jobber, on change | `CLIENT_CREATE` / `CLIENT_UPDATE` / `CLIENT_DESTROY` |
| `sync-jobber-poll` replay | pg_cron `jobber-poll-sync`, `1-59/5` | `CLIENT_UPDATE` only |
| `create-client` (Client App "New client") | a person | synthetic `CLIENT_UPDATE` + `PROPERTY_CREATE` |
| `scripts/sync/cron_jobber.js` | **not scheduled** since 2026-06-09 | n/a |

The webhook payload carries only `{topic, itemId}`. `handleClient` then makes its own GraphQL call
for the full client, so **the payload is a nudge, not a data source**.

## 4. 🛑 REAL JOBBER WEBHOOKS ONLY STARTED WORKING ON 2026-08-21

Before that date every genuine Jobber delivery was refused: the function read `payload.topic`, which
exists only in the flat shape our own replays send, while Jobber sends
`{data:{webHookEvent:{topic,itemId}}}`. The refusal returned without logging, so it was invisible.

Measured in `webhook_events_log`: the **webhook-only** topics (`CLIENT_CREATE`, `CLIENT_DESTROY`,
`JOB_CLOSED`, `QUOTE_SENT`, `QUOTE_APPROVED`, `VISIT_COMPLETE`, `PROPERTY_DESTROY` — the poll never
synthesises any of them) appear first on **2026-08-21** and in **none** of the 42,449 rows before it.

⚠ **`sync-jobber-poll`'s header still says "Jobber sends us no webhooks at all — this poll IS the
webhook replacement (ADR 009)".** That sentence was true when written and is now false. It is kept
in place, with a correction beside it, because it explains the 2026-08-04 property change. **Do not
reason from it.**

⇒ **The consequence is concurrency.** There are now TWO independent drivers of the same handlers.
The poll's replay loop is sequential, so alone it can never race itself — which is exactly why the
estate was safe for months and why nobody was looking for a race.

## 5. The race, and why only the create path had it

`handleClient` used to do three separate PostgREST requests:

```
findEntityBySourceId(...)      -- SELECT      "not found"
.from('clients').insert(...)   -- INSERT      a new row, committed on its own
upsertEntityLink(...)          -- INSERT      23505 on idx_esl_source_id
```

Three requests means three transactions. Concurrent handlers all read "not found", all insert, and
the losers throw **after** their client row is already committed.

Measured on 2026-09-01 for Jobber client `151261972`: four rows (573-576) inserted within 102ms
across four distinct txids, one link, three `webhook_events_log` rows reading
`entity_source_links upsert failed: duplicate key value violates unique constraint "idx_esl_source_id"`.

**Fixed 2026-09-08** by `public.fn_jobber_resolve_client(p_gid, p_name, p_class, p_balance, p_status)`
(migration `2026-09-08_1100`): find-or-create in ONE transaction, serialised per GID by
`pg_advisory_xact_lock(hashtextextended('jobber:client:'||gid, 0))`. The re-read **after** taking the
lock is the fix; the loser sees the winner's row and stops.

Proven by racing it: 8 concurrent requests against the old three-step shape produced **5** client
rows from one GID; the same 8 against the RPC produced **1**. Then 6 concurrent signed
`CLIENT_UPDATE`s at the deployed function: all 200, all `entity_id 573`, no new rows.

⚠ **`handleInvoice`, `handleQuote`, `handleJob`, `handleProperty` and `handleVisit` still have the
old shape.** Orphans created since 2026-08-21: **invoices 57, quotes 9**, jobs 0, properties 0.

⚠ **Only clients created DIRECTLY IN JOBBER ever raced.** Every client made through the Client App
(`client_create_attempts`, codes 311-323) has exactly one row: that path holds a ledger `INSERT` as
its lock, which is the pattern that works.

## 6. What DOES flow correctly (do not "fix" this)

**A Jobber rename propagates.** 11 of the 19 `clients.name` changes since 2026-08-01 carry
`app_source='jobber'` — the Skinny Louie LLC-prefix batch on 2026-08-19, `ABA` → `ABA Plumbing`,
`Excel Plumbing Services inc.` → `1681 Lenox - Excel Plumbing Services inc.` The `*/5` poll picks up
`updatedAt` changes and replays them through `handleClient`, which writes `name`.

Also correct by design: `status` is **not** blindly overwritten (Jobber only knows archived/active,
so `status_source='manual'` pins a human decision), and `client_class` follows Jobber's `isCompany`
unless `client_class_source='manual'`.

## 7. What Jobber holds that we never store

Measured against Bibi's burgers:

| Jobber field | Ours |
|---|---|
| `companyName`, `isCompany`, `isArchived`, `balance` | stored |
| `billingAddress` | stored, as the billing property |
| primary email + primary phone | stored on `client_contacts` |
| **secondary emails** | **dropped** — only the primary is read |
| **`firstName` / `lastName`** (Jobber's contact person, e.g. "Juan Castano" / "General Manager") | **dropped** — `client_contacts.name` gets the COMPANY name and `first_name`/`last_name` stay NULL for all 578 contacts |
| `customFields["Client Code"]` | parsed into `clients.client_code` |

These are pre-existing gaps, not race damage. Widening the contact sync changes every client, so it
is a decision, not a cleanup.

## 8. Finding an orphan

Do **not** reach for `scripts/sync/weekly_dedup_audit.js`. Its three detectors are blind to this
shape by construction (duplicate-code filters `client_code IS NOT NULL`; duplicate-address joins
`properties`; stale-GID selects **from** `entity_source_links` and so can only see rows that already
have a link). Measured 2026-09-08: they returned 4 / 65 / 465 rows overall and **0** of the 8 orphans.

Use the daily `jobber-sync-health` check instead (`public.log_jobber_sync_health()`, surfaced in
`ops.v_health_items`), which since 2026-09-08 counts rows with **no** link across clients, invoices,
quotes, jobs, properties and visits:

```sql
select details->>'link_orphans', details->>'link_orphans_listed', details->>'link_orphans_legacy'
  from public.sync_log where sync_source='jobber-sync-health'
 order by started_at desc limit 1;
```

⚠ **"Unlinked" only means orphan for an entity we never create ourselves.** The visits arm is
restricted to `source='jobber'` for exactly this reason: `supabase_cron` visits are only 47.9%
linked because SA generation creates them here and `sa-visit-promote` pushes them later, so unlinked
is their normal resting state. The first version of the detector reported 202 orphans, 136 of which
were our own unpushed visits.
