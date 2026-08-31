# RPA DERM-portal bot (Jonathan) — integration answer, 2026-07-21

Fred's reply to Jonathan's Phase 5 questions (data source, audit logs, screenshots,
deployment/triggers). Drafted + adversarially reviewed (security / ops / voice lenses) this
session. The reply text below is what Fred sends on Slack; the internal notes at the bottom are
OUR build obligations and are NOT part of the message.

---

## The reply (paste-ready)

Hi John, great work getting through the portal automation, that ViewState stuff is no fun. Answers below, numbered like yours. Quick framing since it shapes all four: the bot does GDO Online Reporting, which for us is Line Item 27 on a client's job. So the unit of work is not a manifest, it is a serviced VISIT for one of those clients. When we service such a client and their DERM manifest gets filed, that visit becomes a "please file the online report" job for the bot. Only 3 clients have this add-on today, so this is a small, targeted feed.

One ground rule up front: no database credentials leave our side, not even read-only ones. Our database is the company's single source of truth and holds customer PII, so external services talk to it through narrow endpoints we control and can revoke. Same approach our other integrations use (Jobber, Airtable, Samsara): they hit endpoints with a secret, never the database directly. You will get two keys: one you send us on every call, and a different one we send you when we trigger your service. Never reuse one for the other.

1. Data source: REST, not a DB connection. The endpoint is already live.
GET https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/rpa-derm-queue
Auth header: x-rpa-key (value sent privately). Returns JSON { generated_at, mode, count, reports: [...] }, up to 25 reports to file, oldest first. Each report object: visit_id (the work key, use it in your result POST), manifest_id, client_code, client_name, client_email, address, city, zip, county, gdo_number, service_date, dump_ticket_date, ticket_number (see 2026-07-24 addendum), jurisdiction, white_manifest_number, disposal_facility, and documents: { address: [signed URLs], receipt: [signed URLs] } (valid 4 hours, minted fresh on every fetch; download everything at the start of the run and never log or store the URLs). A visit appears until it is successfully reported, so nothing is dropped if you are down for a while; it leaves the queue permanently once the county confirms it, and is held 20 hours after any attempt (or the moment we hand it to you) so we can never double-file. ?mode=dryrun serves already-serviced historical visits for testing; those results are tagged dry-run and never count as real. The full field list will live in the repo README, so that is your schema doc. Send me the column list of the CSV you read today so I can flag any field name you expect that we do not already return.

2. Result logging: POST endpoint, same key, also live. This is what feeds our apps (we show per-client, per-visit "GDO report filed / pending / failed" in our DERM tool and on the customer's portal), so getting the fields right matters.
POST https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/rpa-derm-result
Body: { visit_id (required, from the queue), manifest_id (optional, echo it back), run_id, status, retryable (boolean: true for things like portal timeouts, false for data problems like a missing field), failure_reason, attempted_at (ISO 8601, UTC), portal_confirmation (whatever number or text the portal returns), screenshot (base64 JPEG, max 5MB), screenshot_missing_reason (only when you truly could not capture one), dry_run (true when the batch came from ?mode=dryrun) }.
Two hard rules on our side: a visit only counts as reported if the portal actually confirmed it, no optimistic success ever; and every result carries the screenshot unless capture itself failed. The POST is idempotent on (visit_id, run_id), so if you do not get a 2xx back, keep the result locally and retry the POST until you do; never treat a report as done before we acknowledge it. Two things to pin down: use the exact literal SUCCESS (uppercase) for a confirmed report, that word specifically marks a visit permanently done (any other confirmed status is fine too as long as you send portal_confirmation, but SUCCESS is the clean signal); and generate run_id ONCE per report attempt, before you hit the portal, and reuse it verbatim on every retry. Formats we enforce so you get a clean 400 not a mystery: run_id is letters, digits, dot, dash, underscore only (it becomes part of a storage key); a real SUCCESS must include portal_confirmation. attempted_at is recorded for the log only, send your best UTC timestamp and do not worry about it (our queue timing uses our own clock, so a skewed bot clock cannot cause a double-file). If a screenshot is oversized or unreadable we still record the result and just flag the missing evidence, we never drop the attempt.

3. Screenshots: agreed, paths in the DB, never raw images in a table. You do not need storage credentials at all: send the bytes in the result POST, we store them in a private bucket and record the path. The bucket is private because these images contain client data. If screenshots ever run larger than the cap we will switch you to a signed upload URL, but start with base64 in the POST.

4. Deployment and triggers.
Environment: Railway, same as our other Python service. New PRIVATE repo under our webunclogmecom GitHub org; send me a link to your current code and I will set it up, Railway auto-deploys from main. Three hygiene rules, non-negotiable because this system touches client data: the portal login and both keys live only in Railway environment variables, never in code or logs. The bot logs visit_id and status only, never request bodies, URLs, or client fields, and it deletes downloaded documents and screenshots from disk once the result POST is acknowledged, so nothing persists between runs. And no real client data, CSVs, screenshots, or portal dumps ever go in the repo; test fixtures are synthetic, and if your current repo has ever contained real data or credentials we start the org repo clean rather than migrating history.
Triggers: you own the timing, you poll. Poll the GET queue on a slow schedule (say every 15-30 min), file each report, and POST the result. That is the whole loop. You do not expose any endpoint and there is no second key: nothing on our side calls you, so you need no public URL. It is safe to run as often as you like because the queue only hands you visits still needing a filing (a SUCCESS removes one permanently), each dispensed visit is leased for 20h so a crash cannot get it re-handed-out, and the result POST is idempotent on (visit_id, run_id), so a duplicate or retried run never double-files.

Rollout gates before anything hits the county for real: first a dry-run pass over the historical visits (?mode=dryrun), then the first live report on a single visit I pick, verified on the county side, then it opens for all of them. County portal login: I will send it to you privately.

Both endpoints are live and tested end to end (auth, validation, idempotent retries, the queue lifecycle, dry-run isolation, screenshot storage), and your key is generated. Send me two things and we are integrating the same day: the CSV column list and your repo link. I will send the key privately.

---

## Internal notes (our side, not for John)

Build obligations — STATUS 2026-07-21: items 1-4 BUILT + DEPLOYED + T1-T10 tested (see migration 2026-07-21e verification record); **item 5 (event-push trigger) REMOVED 2026-07-21 (migration 21l) — Fred's call: the bot self-manages via POLL, we never push, so there is no `/run` and no run key**; item 6 (watchdog) before the batch opens. EXTRA (found by testing): the live queue has a LAUNCH CUTOFF (dump_ticket_date >= 2026-07-21) — without it the bot's first run would re-submit the entire 534-manifest historical backlog to the county; Fred widens the date deliberately if ever wanted. Keys: **RPA_BOT_KEY** in Supabase/.env (gitignored) is the ONE key; `RPA_RUN_KEY` is now unused (push removed); `RPA_BOT_KEYS` set as a function secret (comma-separated for zero-downtime rotation).

1. **`rpa-derm-queue` edge fn** (verify_jwt=false + `x-rpa-key`): reads a dedicated VIEW (not base
   tables) so the contract is decoupled; filters no-SUCCESS + no-attempt-in-20h; caps 25 oldest
   first; mints 4h signed URLs; `?mode=dryrun` serves a fixed historical sample.
2. **`rpa-derm-result` edge fn** (same key): idempotent upsert on (manifest_id, run_id); server-side
   validation (status `^[A-Z0-9_]{1,64}$`, failure_reason capped ~1000 chars, manifest must exist
   and be submittable, unknown fields rejected); stores screenshot to a PRIVATE bucket, path in the
   row; dry-run results flagged.
3. **New table** (audit opt-in per ADR 010) for submission results + run tracking; `retryable=false`
   results leave the queue until the record changes; `retryable=true` stays with the 20h cooldown.
4. **One key**: `x-rpa-key` (bot→us). The edge fns accept current+next comma-separated env values so
   rotation is zero-downtime. (A separate us→bot run-trigger key was planned but dropped — see item 5.)
5. ~~**pg_cron / event-push trigger**: pg_net POST to John's `/run`.~~ **REMOVED 2026-07-21 (migration
   21l).** Fred's decision: the bot self-manages via poll, so we never call it — no `/run`, no run key,
   no push. The event trigger `trg_zz_gdo_reporting_notify` on `manifest_visits` and its function were
   dropped. Revive from git history only if the push model is ever reinstated.
6. **Watchdog** (later, before batch opens): alert when queue non-empty AND no attempts in 26h, or
   repeated data-errors, so the audit table is not write-only.

HARDENING (audit 2026-07-21, migration 2026-07-21f + fn redeploys, all T1-T18 pass): a fresh 3-lens
audit found the catastrophic double-submit path was the REJECTED-result path (my own 21-fixes'
clock-skew reject, whitespace-inflated size check, crash-before-POST window, literal-SUCCESS-only
exit, and a cutoff constant duplicated 3x). Closed: server-clock queue gates (never the bot's
attempted_at), a dispense LEASE (public.derm_portal_leases; queue GET holds each served manifest 20h
even before any result lands), SUCCESS-OR-confirmation permanent exit, DB backstop constraints +
dry_run trigger (compliance invariants now enforced at the data layer, not just the fn),
single-source public.rpa_launch_cutoff(), accept-and-flag on oversize/undecodable screenshots +
3x storage-upload retry, and a WATCHDOG (public.v_rpa_derm_health + log_rpa_derm_health() + pg_cron
rpa-derm-health-check 09:00 ET -> sync_log status='attention'). GO-LIVE PREREQ met.

⚠ PII NOTE (audit contract-ops low): the queue signs URLs to the RAW multi-client address sheet
(the full roster the FP Blackout system redacts for customers). This is intended (county submission
needs the real document) but is a wider exposure to an outside vendor than customers get — confirm
it is covered by Jonathan's access terms; if the portal only needs the client's own row, serve the
redacted copy instead.

Review provenance: 3-lens BUILD review + 3-lens HARDENING audit, 2026-07-21 (security / ops-architecture / voice). Key findings
folded in: key separation across trust boundaries, PII rules for his Railway logs, queue-exit +
idempotency semantics, async 202 + 409 single-flight, retryable flag, dry-run data path, screenshot
cap + capture-failed path, private repo + clean history, several overclaim/voice fixes.

---

## UPDATE 2026-07-23 — first dry-run + per-manifest dedup + DERM-required flag

**John's first dry-run (2026-07-22 ~4:44-4:50pm ET): clean end to end.** He pulled the dryrun sample,
POSTed 24 `DRY_RUN_COMPLETE` results each with a screenshot in `rpa-evidence`, 0 live filings, all
server-flagged `dry_run=true`. Auth + the full round-trip both work. He also has the bot pausing at the
portal preview (no submit) during testing.

**Queue is now DEDUPED PER MANIFEST** (migration `2026-07-23_gdo_queue_dedup_per_manifest.sql`). His run
surfaced one dump twice: GDO-14117 / white **815951** (Mila) came under two visits both linked to the
one Feb-5 dump, so the per-visit queue served it twice; his own idempotency (permit+manifest) skipped
the second. Our queue must not depend on the consumer, so `v_derm_portal_queue` + `v_derm_portal_dryrun`
now emit **ONE row per `manifest_id`** (a dump ticket = the unit of a DERM online report; representative
= the visit whose service date is closest to the dump), and the queue gates (reported / 20h cooldown /
non-retryable-fail / lease) are now **manifest-scoped** so a sibling visit can never re-surface an
already-filed dump. `visit_id` is still the response work key (John's contract unchanged); the dedup
only guarantees each dump appears once. `v_derm_portal_fields` (still per-visit) + the edge fns untouched.
Dedup key is `manifest_id`, so genuinely co-loaded dumps across DIFFERENT clients keep separate reports.

**The Mila double was NOT a duplicate visit** — Samsara GPS (`vehicle_telemetry_readings`) proved the
truck was parked at the property BOTH nights (two real services on a trash-blocked-access account,
consolidated into one dump). An interim mis-deletion of the Feb-4 visit was reversed same day; the
per-manifest dedup is the correct + sole fix. Billing was never doubled (Jobber bundles both visits onto
one invoice).

**DERM-required is enforced by a FLAG, not a queue gate** (Fred 2026-07-23, migration
`2026-07-23b_gdo_flag_code27_not_derm_required.sql`). GDO reporting only applies to services that
produce a DERM manifest (pumping). Queue eligibility stays on the `27 - GDO Online Reporting` line item
ALONE — we do NOT gate on `derm_required`. Instead `public.v_gdo_reporting_derm_mismatch` lists any
code-27 visit where `fn_visit_requires_derm(v.id)=false` (live fn, so an unstamped NULL is not a false
positive), surfaced as `v_rpa_derm_health.gdo_not_derm_required` + a daily watchdog attention reason
`gdo_code27_not_derm_required`. 0 currently. **Do NOT add a derm_required gate to the queue.**

---

## Addendum 2026-07-24 — `ticket_number` + `jurisdiction` added to the queue response

**Why:** John reported the live endpoint returned `white_manifest_number` as null while
dryrun worked. Root cause was NOT a SQL difference (live and dryrun select it identically) —
it is **jurisdiction**. Broward / Palm Beach loads carry a **yellow Septage Receiving ticket**,
not a Miami-Dade white manifest #, so `white_manifest_number` is legitimately null for them.
The bot's first real live item (visit 6298 / 111-YC) was a Broward-disposed load
(yellow `309944`), so its white came back null.

**Fix (live 2026-07-24, migration `2026-07-24d` + `rpa-derm-queue` redeploy):** the response
now includes two fields on every report:

- **`ticket_number`** — the dump-ticket number to file, **regardless of county** (Miami-Dade
  loads = the white manifest #, Broward/PBC loads = the yellow ticket #). **Use this field.**
  Confirmed by ops (Diego): white or yellow, it is the number to report. Never null when a
  number exists (verified: 0 null across the whole queue).
- **`jurisdiction`** — `'dade'` | `'broward'` | `'unknown'`, if you want to branch.

`white_manifest_number` is kept for back-compat but is **null for Broward** — switch to
`ticket_number`. All other fields unchanged.

---

## Addendum 2026-08-31: every permit on a ticket is served at once, and `gdo_id` is now used

🛑 **Two statements in the original reply above are now WRONG. They are left in place because they
are the record of what was sent, but do not build against them:**

- *"the result POST is idempotent on (visit_id, run_id)"* (§2 and §Triggers). **It is now
  `(visit_id, gdo_id, run_id)`.** The old key would have rejected the 2nd and 3rd results of a run
  that filed several permits off one ticket, and a rejected result is a county filing we have no
  record of.
- The report-object field list in §1 omits **`gdo_id`**, which is now returned on every report and
  should be echoed back on the result POST.

**What changed.** An address can hold several FOG facilities behind one grease trap, each with its
own DERM permit, and DERM wants a report per permit. The queue is now keyed on
`(manifest_id, gdo_id)` and the 20-hour dispense lease is per `(visit, permit)`, so a three-permit
ticket comes back as **three rows in one pull**.

🛑 **The consequence for the bot: `visit_id` is NO LONGER UNIQUE WITHIN A BATCH.** Three rows can
carry the same `visit_id` and differ only by `gdo_id`. **A bot that de-duplicates work by `visit_id`
silently drops two of the three filings.**

**`gdo_id` is optional but wanted.** Without it we infer the permit from the visit, which attributes
by arrival order and misattributes when one filing in a run fails and another succeeds. With it,
attribution is certain; we validate it against that visit's real permit set before trusting it.

🛑 **Never send permits as a comma-separated string on a visit.** It fails our
`^GDO-[0-9]+$` filter so it files nothing, and it recreates a combined `gdos` row retired in July
because it can print verbatim on an official county sheet.

**Canonical reference is `postman/README.md` §3 and §4**, which is kept current. Our own reasoning,
the verification and the traps: `docs/reference/gdo-multi-permit-filing.md`.
