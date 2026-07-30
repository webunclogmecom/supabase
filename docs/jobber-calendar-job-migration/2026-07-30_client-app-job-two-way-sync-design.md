# Client App "New job" — two-way Jobber sync (design)

*2026-07-30 · Supabase session · implements Fred's ask verbatim: "when creating the job, it has
to be a two-way flow with Jobber, where if we edit it, create, or delete it has to have the same
functionality with Jobber, so we need 100% sync with it, every 30 minutes we need to check we're
sync … every time we change this … we need to wait until that's reflected on Jobber (loading
toaster like the Calendar)."*

Companion docs: the research this design is built on lives in the session transcript
(4-agent sweep, 2026-07-30); app-side contract in
`Building Apps/Client App/docs/08-changelog.md` (same-day entry). Prior scoping:
`Building Apps/Client App/docs/2026-07-26_phase2-writes-scoping.md` (wave 2).

---

## 1. The core decision: synchronous verified saga, NOT a sync_state clone

The Calendar runs two generations of Jobber write plumbing:

- **Gen 1 (async)**: DB-first write → trigger → pg_net fire-and-forget → `jobber-push-visit` →
  `visits.sync_state` pending/confirmed/failed → the app POLLS sync_state for the toaster →
  */3 stale-pending cron + auto-retry ladder + flags table + drift arms.
- **Gen 2 (sync, 2026-07-29)**: the app AWAITS `save-calendar-visit`, which pushes Jobber →
  **re-reads Jobber to verify** → only then writes the DB → returns; failure returns a readable
  message and the DB is untouched (form stays dirty).

**Jobs get Gen 2 only.** Rationale, not preference: visits need Gen 1 because they are written by
many async sources (drag, ripple, cron generation, completion reconcile). Jobs are written from
exactly ONE surface — the Client App dialog. A synchronous await IS Fred's "wait until that's
reflected on Jobber" toaster, with strictly stronger guarantees than polling (the DB row is only
ever written after Jobber verification, so a jobs row is *born* confirmed). Consequences:

- **No `jobs.sync_state`, no flags table, no stale-pending cron, no auto-retry ladder.** Nothing
  can be pending: on failure the DB was never touched and the dialog stays dirty for a human
  retry. (Trap this avoids: `suppress_jobber_push` does-not-dequeue has no jobs analogue because
  there is no queue.)
- The 30-minute reconcile (§4) is the ONLY async machinery, and it is one-directional
  (Jobber → DB), because with a verified-synchronous writer any DB-vs-Jobber divergence means
  either an office-side Jobber edit (adopt) or a direct DB write (surface — never auto-push).

## 2. Jobber facts the design is shaped by (all measured 2026-07-30, live schema 2026-04-16)

1. **There is no `jobDelete` / `jobArchive`.** The complete state surface is `jobCreate`,
   `jobEdit`, `jobClose(modifyIncompleteVisitsBy!)`, `jobReopen`, `job*LineItems`, notes.
   ⇒ App "Delete job" = `jobClose` with `DESTROY_ALL` (destroys Jobber's incomplete visits,
   keeps the closed job + its number forever). The UI must say that honestly — "close", not
   "delete", semantics.
2. **`jobCreate` takes `propertyId`, not `clientId`** — the client is implied. ⇒ we resolve the
   property's Jobber GID from `entity_source_links`; a property with no GID (12 of 817 today,
   including any created by our own Add Property) **cannot host a Jobber job** — the UI picker
   marks them and the server refuses readably (`client.properties` gains `jobber_linked`).
3. **`invoicing` is REQUIRED on create**: `invoicingType` (VISIT_BASED | FIXED_PRICE) +
   `invoicingSchedule` (PER_VISIT | ON_COMPLETION | …). UI exposes two choices: "Per visit"
   (VISIT_BASED/PER_VISIT — the account's dominant pattern) and "Fixed price" (FIXED_PRICE/
   ON_COMPLETION).
4. **RECURRING is derived, never settable** — a job becomes recurring via
   `scheduling.recurrence` (RRULE). **We deliberately NEVER send `scheduling`**: our own daily
   generator (`generate_service_agreement_visits.js`) is the visit-minting authority
   (6-month horizon, 60-day Jobber push scope). A Jobber-side RRULE would double-generate
   visits and the drift reconciler would fight it forever. Jobber jobs we create are born
   UNSCHEDULED; cadence lives in the **"Frequency" numeric custom field**
   (`CustomFieldConfigurationNumeric` gid `…/3743514`, appliesTo ALL_JOBS) which is what
   `handleJob`/reconcile read into `jobs.frequency_days`.
5. **Line items**: create requires `name`, `unitPrice`, `quantity`, `saveToProductsAndServices`
   (always **false** — true pollutes the account catalog). Name format is load-bearing for the
   taxonomy join: `<2-digit code> - <service_line_items.title>` (measured live:
   `"08 - Service Agreement - Warranty of Drainage"`). Jobber line items are SHARED job-scoped
   objects (no VisitLineItem type) — edit by Jobber lineItemId, create-first-then-delete-old.
6. **Title is a behaviour class, not a label**: `'Service Agreement%'` prefix vs exact
   `'service call'` drives the pickers, the SA-carries-lines/SC-carries-none sync rule, AND the
   visit-generation predicate; `'[OLD]'` anywhere removes the job from everything. ⇒ the UI
   never free-texts a title. SA title = `Service Agreement - <primary service title>`;
   SC title = exactly `Service Call`. **Title is not editable in the app.**
7. **Verification semantics**: HTTP 200 always; success = `userErrors.length === 0` AND
   `payload.job != null`, then a re-read of the job. `timeframe.startAt` is a DATE in;
   `Job.startAt` reads back as a UTC DateTime — compare as ET dates, never raw strings.
8. **The write app's mutations never echo through webhooks** (READ-app registration), and the
   */5 poll cursors jobs on `createdAt` only. ⇒ after `jobCreate` the edge fn itself writes
   `public.jobs` + the `entity_source_links` row (full base64 GID) in the same request, or the
   next poll imports a duplicate. Our own created-jobs DO get picked up by the next poll
   (createdAt > cursor) and replayed as JOB_UPDATE — harmless: the ESL row routes it to an
   UPDATE with identical values.
9. Throttle: 10k-point bucket, 500 pts/s restore, no HTTP headers — read
   `extensions.cost.throttleStatus`, retry THROTTLED/429 with backoff (copy `gql()` from
   `jobber-push-visit`).

## 3. The pieces

### 3a. Migration `2026-07-30_*_client_job_two_way_sync.sql`
- **Audit opt-in for `public.jobs`** (ADR 010): it has NO audit trigger today; it is about to
  take its first human write path. `line_items` stays opted OUT (documented: sync wipes/
  reinserts it constantly; audit there would be volume noise with no forensic value —
  job-level audit rows capture the business change).
- `client.properties` gains `jobber_linked boolean` (ESL existence) — appended last, so
  CREATE OR REPLACE is legal.
- `public.fn_close_job_visits(p_job_id)` SECDEF, service_role-only: soft-deletes the job's
  still-scheduled visits (never completed ones) with `app.suppress_jobber_push='on'`
  (SET LOCAL) **and settles `sync_state='confirmed'` in the same statement** — the
  suppress-does-not-dequeue lesson. Called by the close saga AFTER Jobber's `DESTROY_ALL`
  already destroyed its side.
- `fn_request_jobber_sync` URL map gains `'jobs-drift'`; pg_cron
  `jobber-job-drift-reconcile` every `*/30 * * * *`.

### 3b. Edge fn `save-client-job` (the saga; `verify_jwt = true`)
Called directly by the browser with the user's JWT (CORS preflight echoed before auth).
Handler re-checks: bearer decodes, staff domain on the email claim. Actions:

| action | Jobber side | verify | DB side (service client, `X-App-Source: client-app`) |
|---|---|---|---|
| `create` | `jobCreate` (property GID, derived title, invoicing, `timeframe.startAt`, `instructions`, SA line items, Frequency CF) | re-read job: number/title/status/dates/lines/property GID | INSERT `jobs` (identity id; Jobber's number/status/dates/total) + ESL + SA `line_items` |
| `edit` | change-aware: `jobEdit` (timeframe / instructions / Frequency CF) and/or line-item mutations (create→edit→delete by Jobber id, create-first) | re-read + field compare (ET dates) | UPDATE only the verified fields; SA line wipe/reinsert to the read-back state |
| `close` | `jobClose(DESTROY_ALL)` | re-read `jobStatus` | UPDATE `job_status` to Jobber's derived value + `fn_close_job_visits` |
| `reopen` | `jobReopen` | re-read `jobStatus` | UPDATE `job_status` |

Failure at any Jobber step → return the readable message; **no DB write happened**. Failure
between Jobber-create and DB-write is the one dangerous window: the fn links ESL **first**,
jobs row second, and if the DB write dies it returns `db_write_failed` telling the user the job
EXISTS in Jobber — the next */5 poll then imports it through the ESL row (self-healing, no
duplicate). No-clobber semantics preserved: never NULL `client_id`/`property_id`/
`frequency_days`; `total` from Jobber read-back.

### 3c. Edge fn `sync-jobber-job-drift` + cron (the 30-minute check)
Port of `scripts/sync/reconcile_jobs.js` with its three known holes fixed:
- runs on **pg_cron** (vault-bearer SECDEF wrapper), not GitHub Actions — the */2 poll was
  throttled by GitHub to ~2-3h, which is why sub-hourly crons live in pg_cron here;
- candidate set includes jobs **DB-archived in the last 14 days** (the 076-TCE/056-STM class:
  archived here, open in Jobber, could never self-heal);
- **batch reads** via `jobs(filter:{ids:[…50]})` instead of one call per job (~10 calls/run).
Diffs Jobber → DB: `job_status`, `title`, `frequency_days` (CF), `start_at`/`end_at`, and the
SA line-item set (wipe/reinsert only on diff). Jobber-gone → `archived`. One `sync_log` row
per run (`sync_source='jobber_job_drift'`). It never pushes outbound: divergence created
DB-side is SURFACED in the log, not auto-pushed (with a verified-synchronous writer, DB-side
drift means someone bypassed the saga — that is a finding, not a heal).
**The GitHub `reconcile-jobs.yml` schedule is retired** (workflow_dispatch kept) — one
reconciler, not two writers.

### 3d. UI (Client View Pro)
- **New job** (enabled in place, per the 2026-07-26 rule): kind (Service Agreement / Service
  Call) → property (Jobber-linked only; unlinked listed disabled with "Not in Jobber yet") →
  SA: services multi-pick from the catalog (schedulable codes, prices required — catalog
  `unit_price` is all NULL, the $0 lesson) + frequency days → start date → billing → optional
  instructions.
- **Edit** on the job card: frequency, dates, instructions, SA line items. No title edit.
- **Delete** = destructive confirm with honest copy ("closes the job in Jobber and removes its
  upcoming visits — Jobber keeps closed jobs forever"); archived cards get **Reopen**.
- **The toaster**: the dialog awaits the fn — spinner copy "Waiting for Jobber…", success only
  after the fn returns ok (which itself means verified), failure keeps the dialog open + dirty
  with the server's message verbatim. No optimistic anything (the 30s-timer lesson).

## 4. What this deliberately does NOT do
- No Jobber-side visit scheduling/recurrence (§2.4) — visits stay our generator's job.
- No title editing, no job_status writing (derived), no hard delete (impossible + rule 6).
- No `client.*` view ever becomes writable; everything goes through the edge fn.
- SA visit generation for a NEW qualifying job happens at the next daily 06:00 ET run — not
  instantly. Documented in the UI copy ("visits appear on the Calendar by tomorrow morning").

## 5. Test plan (executed on the test client 112-YA, which the visit-gen predicate excludes)
create SC → verify in Jobber web UI (screenshot) + DB (jobs/ESL/audit rows) + app card;
edit frequency → Jobber custom field visually + DB; close → Jobber shows closed + DB status +
visits soft-deleted; reopen → both sides again; create SA with line items + prices → line
items visible in Jobber + DB; close it (cleanup — closed jobs linger on 112-YA by Jobber's
design). Reconcile: run `sync-jobber-job-drift` manually, verify 0 diffs after the tests, then
flip one DB field, run again, verify it heals inbound.
