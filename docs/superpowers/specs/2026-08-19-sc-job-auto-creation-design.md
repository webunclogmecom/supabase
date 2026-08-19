# Every property carries a Service Call job

*Design spec. Written 2026-08-19. Author: Supabase session, with Fred.*

## The ask

Fred, 2026-08-19:

> "Yes add the SC job creation to create-client. So maybe this is better for the modal of new clients
> at the Clients App and at the Calendar App, let's add a checkbox at the top of the address of the
> client, that indicates to use that address as the first property address, by default is checked ...
> And with that, when creating a property it should always, doesn't matter if it's at the Clients App
> or the Calendar App, it should always create a SC Job for that property."

Three outcomes:

1. Creating a client creates its first property AND a Service Call job on that property.
2. Both New Client dialogs get a default-checked "use this address as the first property" checkbox.
3. Creating a property, from any app, always creates a Service Call job for it.

## Why this matters

A client with no job cannot be scheduled. `jobCreate` needs a Jobber `propertyId`, so a client with
no property can never be given a job either. Measured 2026-08-19: client **308-LOU**, created that
morning through the real dialog, landed correctly (ACTIVE, property linked, Jobber-imported) and had
**zero jobs**, so it could not take a visit or a queue item until somebody noticed. That is the hole.

## Decisions already taken (do not re-litigate without Fred)

| Question | Ruling | Source |
|---|---|---|
| Checkbox unchecked, Calendar App | Reveal a second address block; that address becomes the property | Fred, 2026-08-19 |
| Checkbox unchecked, Clients App | Create no property at all | Fred, 2026-08-19 |
| The address when no property is created | Save it as the client's **billing address** | Fred, 2026-08-19 |
| Jobber `propertyCreate` | Build it, bringing it forward of the Jobber sunset | Fred, 2026-08-19 |
| Backfill existing uncovered properties | **NO.** Do not backfill | Fred, 2026-08-19 |
| Scope | Both phases | Fred, 2026-08-19 |

The `propertyCreate` ruling reverses a scope decision Fred approved on 2026-07-30
(`docs/migrations/2026-07-30_0709_client_create_property_rpc.sql`: properties are Jobber-mastered
during the bridge, and a locally created property does not reach Jobber, accepted until the Jobber
sunset). Fred was shown that this ruling reverses it and confirmed. Record it as a change of
decision, not as a bug fix.

## Measured ground truth

Everything below was measured against Prod on 2026-08-19, not inferred.

**A Service Call job is:** title exactly `Service Call`; `frequency_days = 0`; `start_at`/`end_at`
NULL; `billing_type = 'visit_based'`; `invoice_frequency = 'per_visit'`; `property_id` and
`client_id` set; `job_status` whatever Jobber returns, lowercased. Measured across 269 live SC jobs.

**An SC job carries no line items.** 269 live SC jobs hold 0 job-scoped line items, against a
positive control of 176 live SA jobs holding 323. It is enforced, not merely observed:
`webhook-jobber` wipes job-scoped lines on every replay and re-inserts only for titles beginning
`Service Agreement`. SC charges live on the visit (151 live visit-scoped lines prove that path).

**The title is load-bearing.** `ops.v_calendar_visit` classifies on it, and
`public.fn_generate_sa_visits` gates recurring visit generation on the `Service Agreement%` prefix.
An SC job therefore can never start booking trucks, and a decorated title (a client name, a date, a
suffix) silently reclassifies the job.

**There is no `jobDelete` and no `jobArchive`.** The only teardown is
`jobClose(modifyIncompleteVisitsBy: DESTROY_ALL)`, which also destroys the job's scheduled visits. A
mis-created job is permanent. Every idempotency check therefore runs BEFORE Jobber is touched.

**`propertyCreate` exists and is unused.** Introspected live:
`propertyCreate(clientId: EncodedId!, input: PropertyCreateInput!)` where `PropertyCreateInput` is
`{ properties: [PropertyAttributes] }` and `PropertyAttributes.address` is `AddressAttributes`
(`street1, street2, city, country, province, postalCode`). A repo-wide grep for `propertycreate`
returns zero hits, so no code has ever called it.

**A billing-twin property GID cannot take a job.** 428 property links have the shape
`<base64>_billing`. All 428 decode to `gid://Jobber/CLIENT/<n>` with the literal ASCII `_billing`
appended, so they are client ids, not property ids, and `jobCreate` rejects them. `is_billing` is a
perfect proxy for this today but is written by two independent writers and is not an enforced
invariant, so **select on the link shape, never on `is_billing`**.

**`entity_type = 'job'` is already in the `entity_source_links` CHECK whitelist**, so the job link
needs no migration. This is the one failure mode the 2026-08-06 `calendar_day_marker` incident had
that this work does not.

## Architecture

Three server-side pieces and one UI change. The rule lives on the server so it cannot drift between
the two apps.

```
New Client dialog (Clients App or Calendar)
      |
      v
  create-client  --(property_mode)-->  Jobber clientCreate (+ properties[] or billingAddress)
      |                                        |
      |                                  replay CLIENT_UPDATE, then PROPERTY_CREATE
      |                                        |
      +--------------------------------> ensureServiceCallJob(client_id, property_id)
                                                |
Add Property (Clients App)                      v
      |                                  save-client-job {action:'create', kind:'SC'}
      v                                         |
  save-client-property --> Jobber propertyCreate --> replay PROPERTY_CREATE --+
```

### Component 1: `ensureServiceCallJob()`

A shared helper in `supabase/functions/_shared/`. Every path that creates a property calls it. It is
the single definition of "this property gets a Service Call job", so the rule cannot be assembled
twice (the failure that produced the custom-field sync defects on 2026-08-18).

Signature: `ensureServiceCallJob({ db, authHeader, clientId, propertyId })`.

Steps, in order:

1. **Resolve the property's real Jobber GID** from `entity_source_links` where
   `entity_type='property' AND source_system='jobber' AND entity_id=<propertyId> AND source_id NOT
   LIKE '%\_billing'`. Destructure the error and branch on it. A DB error must not read as "no link
   found", because that is the fail-open shape create-client was hardened against.
   No real GID means return `{ ok: false, reason: 'property_not_in_jobber' }` and create nothing.
2. **Idempotency check, before Jobber.** Does an active job already exist with
   `property_id = <propertyId>` and `lower(btrim(title)) = 'service call'` and `job_status NOT IN
   ('archived','closed','destroyed')`? If yes, return `{ ok: true, created: false, job_id }`. This
   runs first because there is no undo.
3. **Delegate to `save-client-job`**, forwarding the caller's `Authorization` header so the write is
   attributed to the human who submitted the form:
   ```
   POST /functions/v1/save-client-job
   { action: 'create', client_id, patch: { kind: 'SC', property_id,
     billing_type: 'visit_based', invoice_frequency: 'per_visit' } }
   ```
   Send nothing else. `services`, `fees`, `start_date` and `frequency_days` are either hard-refused
   for SC or silently ignored.
4. **Return what landed, re-read from `public.jobs`**, never echoed from the input.

`save-client-job` already performs the read-back verify (asserting title and property GID) and
records the job row and its link together through `public.fn_record_client_job`. It is the proven
creator: 9 live SC jobs came through it. Do not reimplement any of that here.

### Component 2: `create-client` changes

**New input field `property_mode`,** one of:

| Value | Behaviour | Used by |
|---|---|---|
| `client_address` (default) | Today's behaviour. The one address is sent as `properties[0]` and becomes the first property. | Both apps, checkbox checked |
| `separate` | `properties[0]` is built from `property_address`; the client's own address is sent as `billingAddress`. | Calendar, checkbox unchecked |
| `none` | No `properties[]`. The typed address is sent as `billingAddress` only. No property, no SC job. | Clients App, checkbox unchecked |

The address requirement moves: street, city and ZIP stay required for `client_address` and
`separate`, and for `none` they are required as a billing address but produce no property. The
current refusal message explains itself in terms of `jobCreate` needing a propertyId; under `none`
that consequence is the caller's explicit choice, so the response must carry an explicit
`schedulable: false` flag and a human sentence saying the client cannot be scheduled until a
property is added.

**After the property lands, call `ensureServiceCallJob`.** It is the last step and its failure must
never roll back the client or the property, because there is no `clientDelete`.

**Ledger and attention view.** `client_create_attempts` gains `jobber_job_gid text` and
`job_id bigint`, mirroring the existing `jobber_client_gid` / `client_id` pair, plus a
`job_step text` recording `skipped` (mode `none`), `created`, `existing` or `orphaned`.
`public.v_client_create_attention` gains a branch in the same migration, with its own sentence:
"Jobber holds a job we never recorded. Check Jobber before retrying." Without that branch a job-step
orphan is invisible, because the view keys entirely on the client-level status.

**One idempotency key spans all three steps.** A retry after the job step fails must not re-run the
client create. The key is per user submission, not per step.

**Fix the missing content-type guard.** `create-client`'s `gql` helper checks only `r.status >= 500`
and `j.errors`, so a Jobber Waiting Room reply (HTML at HTTP 200) returns `ok: true` with
`data: undefined`. It bites before the mutation, on the client-code uniqueness check and both
duplicate searches, so an outage currently presents as "that code is free" or "no duplicates". Add
the response content-type check the three guarded functions already use. This is a live bug in the
function this work builds on, and it is in scope.

**`status = 'created'` keeps its current meaning: the client landed.** It must not be widened to
mean client plus property plus job, because `created` releases the code reservation on purpose
(migration `2026-08-12_2045`) and holding the reservation across the job step would turn the ledger
into a permanent second registry. The job step reports through `job_step`, not through `status`.

### Component 3: `save-client-property` (new edge function)

Mirrors `save-client-contact` and `save-client-fields` in naming, auth and shape.

1. Staff gate: bearer token, `db.auth.getUser()`, email ends `@ayache.com` or `@unclogme.com`.
   `verify_jwt = false` in `config.toml`, matching its siblings, because the gate is stricter than
   the gateway check.
2. Resolve the client's Jobber GID. Fail closed if absent.
3. `propertyCreate(clientId, { properties: [{ address: { street1, city, province: 'FL',
   postalCode, country: 'USA' } }] })`.
4. Content-type guard, then `userErrors`, then a read-back verify by value.
5. Replay a signed synthetic `PROPERTY_CREATE` webhook to materialise the row through
   `handleProperty`, the one writer for properties, **and check the returned `entity_id`**.
   `create-client` discards that result today, which is why its property leg has no verification at
   all. That is precedent not to copy.
6. `ensureServiceCallJob(...)`.
7. Return the property id, the job id, and what landed.

Then repoint the Clients App's Add Property button at this function, and only after the new bundle
is verified live, make `client.create_property` refuse with a readable error directing callers here.
Deploy order matters: this is a tightening, so the UI ships first (parent Client App rule on deploy
direction).

### Component 4: the dialogs

Both apps get a checkbox directly above the address block, default checked, labelled
**"Use this address as the first property"**.

- **Calendar App, unchecked:** reveal a second address block, "Property address", with the same
  Places autocomplete and the same validation as the primary one. That address is sent as
  `property_address` with `property_mode: 'separate'`.
- **Clients App, unchecked:** no second block. Send `property_mode: 'none'`. Show an inline note:
  this client will have no service address and cannot be scheduled until a property is added.

The Calendar dialog is a faithful transplant of the Clients App one (shared ids `new-client-*`,
shared `create-client` contract), so the two must stay in sync on everything except the unchecked
branch, which is deliberately different.

Note for the Calendar: Places autocomplete on `calendar.unclogme.app` currently returns 403 because
the referrer allowlist entry needs to be `https://calendar.unclogme.app/*` rather than a bare host.
The dialog degrades to plain typing until that is fixed. It does not block this work.

## What this deliberately does NOT do

- **No backfill.** Fred, 2026-08-19. For the record of why the number moved: a naive sweep fires on
  184 properties, the `client_code` gate cuts it to 30, removing test clients leaves 25, and 13 of
  those previously held a Service Call somebody deliberately archived. Auto-creating would resurrect
  closed work.
- **No auto-SC for Jobber-inbound properties.** Jobber is the master for jobs, and a Jobber user who
  creates a property without a job meant to. The rule is scoped to app-initiated creation.
- **No fees, services, timeframe or frequency on an SC job.** Refused by `save-client-job` on create
  and on edit. Fred, 2026-08-06: "the SC shouldn't have any kind of Line Item ... SC can only have
  line items at the moment of creating a visit."
- **No change to `status='created'` semantics**, per the reservation-release reason above.

## Verification plan

Every check below needs a control that must fire, because a sweep returning zero is an untested
instrument.

1. ✅ **Contract probe: DONE 2026-08-19, and the `none` path works exactly as ruled.** Measured with
   three real Jobber clients (named `TEST ...` so `webhook-jobber`'s junk filter refuses to import
   them), each read back and then archived:

   | `property_mode` sent | Jobber `billingAddress` | Jobber `clientProperties` | property street |
   |---|---|---|---|
   | `client_address` | 1 Client Street | **1** | 1 Client Street |
   | `separate` | 1 Client Street | **1** | 2 Property Way |
   | `none` | 1 Client Street | **0** | none |

   Confirmed visually in the Jobber UI for both the target and the control: the `none` client shows
   the empty "Add properties so you can organize work by location" state, while `client_address`
   lists a real property. Our DB was unchanged throughout (448 clients, 901 properties).

   🛑 **AND IT CORRECTS A BELIEF THIS SPEC WAS BUILT ON.** `client_address` mints **ONE** Jobber
   property, not two. Jobber back-fills `billingAddress` FROM `properties[0]` but creates no separate
   billing property. **The billing twin is OUR row, not Jobber's**: `handleClient` inserts it from
   `billingAddress` (webhook-jobber:628). That is precisely why its link is the synthetic
   `<gid>_billing` string rather than a real Property GID, and it is why `ensureServiceCallJob` must
   select on link shape. The exclusion rule is unchanged and now rests on a measured mechanism rather
   than an inference.

   ⚠ **How the probe first lied, worth keeping:** its read query asked for `client { properties }`,
   which is not a field (the real one is `clientProperties`), and it discarded `errors`. It returned
   `property_count: 0` for **all three** modes, including the one we know produces a property. A
   confident zero across the board, from a query that never ran. Print the errors, and keep a case
   in every probe whose answer you already know.
2. **`ensureServiceCallJob` idempotency:** call it twice against the same property. Second call must
   return `created: false` and Jobber must hold exactly one Service Call. Control: a property with
   no SC job must return `created: true` in the same run.
3. **Billing-twin refusal:** call it against a property whose only link is a `_billing` synthetic.
   Must refuse without touching Jobber. Control: the same client's real property must succeed.
4. **Fail-closed pre-check:** simulate a DB error on the existing-job lookup and confirm it refuses
   rather than proceeding. A discarded error returns `data: null`, which reads as "no job exists"
   and would create a duplicate in front of an operation with no undo.
5. **All three property modes end to end**, asserting on the DB rows that land, not on the response:
   `client_address` gives one real property plus one SC job; `separate` gives a property at the
   second address; `none` gives no non-billing property, no SC job, and `schedulable: false`.
6. **Ledger and attention view:** force a job-step failure and confirm the attempt appears in
   `v_client_create_attention` with the job sentence. Mutation test: with the new branch removed,
   the same state must be invisible. That second half is what proves the branch works.
7. **Title exactness:** the created job must read exactly `Service Call`, and
   `ops.client_service_options` must list it for that client. A title check alone is not enough,
   because the app-facing consequence is whether the Calendar can dispatch against it.
8. **Visual check in both apps** after any Prod write, per the standing rule. Backend-only is not an
   exemption.

Use test client **112-YA** for exercised paths, and revert anything created.

## Deploy order

1. Migration: ledger columns plus the attention-view branch. Additive, safe alone.
2. `create-client`: content-type guard fix, `property_mode`, `ensureServiceCallJob` call.
3. Both dialogs: the checkbox. Verify each published bundle before moving on.
4. `save-client-property` plus the Clients App Add Property repoint.
5. Only then: make `client.create_property` refuse.

Steps 1 to 3 are Phase 1 and cover all current traffic. Steps 4 and 5 are Phase 2, serving a feature
invoked once in its lifetime (a smoke test on 2026-07-31 whose row was deleted 79 seconds later).

## Documentation owed at ship

Per workspace rule 4b, app-visible changes are documented in the app's own folder in the same cycle:
`Building Apps/Client App/docs/08-changelog.md`, `Building Apps/Visit Calendar/docs/08-changelog.md`,
and both `CLAUDE.md` files for the rules that must not be regressed (the exact title, the
billing-twin exclusion, the no-undo constraint). DB reasoning and the migration header go in
`Supabase/docs/`.

One correction is owed regardless of this work:
`docs/jobber-calendar-job-migration/jobs-visits-calendar-workflow.md` claims every active or
recurring client has a Service Call ("0 missing"). Audited 2026-08-19 against Fred's denominator,
clients with at least one completed visit in the last 6 months: 234 clients, 915 visits, **0
INACTIVE**, 3 with no client code, and 12 without a strict Service Call job, of which 8 hold an
active Service Agreement and 3 more carry SC-class jobs titled `Service` or `Emergency call`. The
honest correction is narrow, and the sharp finding is separate: **3 clients we visited have no active
job at all** (235-LOU with 5 visits, 107-PV with 2, ABA Plumbing with 1). That is an ops question,
not a scheduling-rule question, and it is out of scope here.

## Known adjacent issue, out of scope

`sync-jobber-poll` clears `needs_populate` on transport success (`wr.ok`) rather than on the
handler's reported `entity_id`, while `handleProperty` returns HTTP 200 with `entity_id: 0` when it
defers and `handleClient` returns `-1` when it skips a junk name. Combined with the 2026-08-12
byte-identical rule, a row cleared that way is never re-flagged, so `needs_populate = 0` cannot
distinguish "correctly skipped forever" from "deferred, should retry". Investigated 2026-08-19: all
17 currently unlanded staged properties are legitimately absent (16 belong to deliberately junked
archived clients `X 1` to `X 15` and `NOT USE Capas Burger`, 1 no longer exists in Jobber), so
nothing is lost today. Fixing it by simply keeping deferred rows flagged would recreate the
43-row starvation bug, because those 16 would occupy the 10-per-cycle replay budget forever. A real
fix needs `entity_id`-aware clearing plus a bounded retry that parks a stuck row visibly.
