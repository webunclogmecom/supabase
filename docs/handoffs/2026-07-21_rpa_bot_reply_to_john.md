# RPA DERM-portal bot (Jonathan) — integration answer, 2026-07-21

Fred's reply to Jonathan's Phase 5 questions (data source, audit logs, screenshots,
deployment/triggers). Drafted + adversarially reviewed (security / ops / voice lenses) this
session. The reply text below is what Fred sends on Slack; the internal notes at the bottom are
OUR build obligations and are NOT part of the message.

---

## The reply (paste-ready)

Hi John, great work getting through the portal automation, that ViewState stuff is no fun. Answers below, numbered like yours.

One ground rule up front: no database credentials leave our side, not even read-only ones. Our database is the company's single source of truth and holds customer PII, so external services talk to it through narrow endpoints we control and can revoke. Same approach our other integrations use (Jobber, Airtable, Samsara): they hit endpoints with a secret, never the database directly. You will get two keys: one you send us on every call, and a different one we send you when we trigger your service. Never reuse one for the other.

1. Data source: REST, not a DB connection. The endpoint is already live.
GET https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/rpa-derm-queue
Auth header: x-rpa-key (value sent privately). Returns JSON: up to 25 manifests ready for submission, oldest first, one object per manifest, with the data fields plus signed URLs for the documents (valid 4 hours, minted fresh on every fetch; download everything at the start of the run and never log or store the URLs). Queue rules so we cannot double-submit: a manifest appears only if it has no SUCCESS on file and no attempt in the last 20 hours; SUCCESS is permanent, it never comes back. The endpoint also takes ?mode=dryrun, which serves already-submitted historical manifests for testing; results from those are tagged dry-run and never count as real.
Send me the column list of the CSV you read today and I will match the field names wherever they map cleanly and flag the ones that do not. The response field list will be documented in the repo README, so that doubles as your schema doc.

2. Audit logging: POST endpoint, same key, also live.
POST https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/rpa-derm-result
Body: { manifest_id, run_id, status, retryable (boolean: true for things like portal timeouts, false for data problems like a missing email), failure_reason, attempted_at (ISO 8601, UTC), portal_confirmation (whatever number or text the portal returns), screenshot (base64 JPEG, max 5MB), screenshot_missing_reason (only when you truly could not capture one, e.g. browser crash; report the failure anyway), dry_run (true when the batch came from ?mode=dryrun; those results are stored separately and never count as real) }.
Two hard rules on our side: a manifest only counts as SUCCESS if the portal actually confirmed it, no optimistic success ever; and every result carries the screenshot unless capture itself failed. The POST is idempotent on (manifest_id, run_id), so if you do not get a 2xx back, keep the result locally and retry the POST until you do; never treat a manifest as done before we have acknowledged the result. Two things to pin down: use the exact literal SUCCESS (uppercase) for a confirmed filing, that word specifically is what marks a manifest permanently done (any other confirmed status is fine too as long as you send portal_confirmation, but SUCCESS is the clean signal); and generate run_id ONCE per submission attempt, before you hit the portal, and reuse it verbatim on every retry of that result, that is what makes the retry idempotent. Formats the endpoint enforces so you get a clean 400 not a mystery: run_id is letters, digits, dot, dash, underscore only (it becomes part of a storage key); a real SUCCESS must include portal_confirmation. attempted_at is just recorded for the log, send your best UTC timestamp and do not worry about it (our queue timing uses our own clock, so a skewed bot clock cannot cause a double-filing). If a screenshot is oversized or unreadable we still record the result and just flag the missing evidence, we never drop the attempt.

3. Screenshots: agreed, paths in the DB, never raw images in a table. You do not need storage credentials at all: send the bytes in the result POST, we store them in a private bucket and record the path. The bucket is private because these images contain client data. If screenshots ever run larger than the cap we will switch you to a signed upload URL, but start with base64 in the POST.

4. Deployment and triggers.
Environment: Railway, same as our other Python service. New PRIVATE repo under our webunclogmecom GitHub org; send me a link to your current code and I will set it up, Railway auto-deploys from main. Three hygiene rules, non-negotiable because this system touches client data: the portal login and both keys live only in Railway environment variables, never in code or logs. The bot logs manifest_id and status only, never request bodies, URLs, or client fields, and it deletes downloaded documents and screenshots from disk once the result POST is acknowledged, so nothing persists between runs. And no real manifest data, CSVs, screenshots, or portal dumps ever go in the repo; test fixtures are synthetic, and if your current repo has ever contained real data or credentials we start the org repo clean rather than migrating history.
Triggers: schedule first, events later. Expose POST /run on your service, gated by the second key (the one we send you). Our database cron will call it nightly. Two requirements: /run returns 202 immediately and does the work in the background, and it returns 409 if a run is already in progress, so overlapping triggers cannot double-submit. We schedule everything else from our side, and this gives us one place to pause or resume the bot. Once it has run clean for a couple of weeks we can add event-driven triggering when the office approves a manifest.

Rollout gates before anything touches the county for real: first a dry-run pass over a couple of weeks of historical manifests (the ?mode=dryrun above), then the first live run on a single manifest I pick, verified on the county side, then the batch opens. County portal login: I will send it to you privately.

Both endpoints are live and tested end to end (auth, validation, idempotent retries, the queue lifecycle, dry-run isolation, screenshot storage), and your keys are generated. Send me three things and we are integrating the same day: the CSV column list, the confirmation that the record set is Miami-Dade manifests only, and the link to your current code. I will send the keys privately.

---

## Internal notes (our side, not for John)

Build obligations — STATUS 2026-07-21: items 1-4 BUILT + DEPLOYED + T1-T10 tested (see migration 2026-07-21e verification record); item 5 (pg_cron trigger) waits for Jonathan's /run URL; item 6 (watchdog) before the batch opens. EXTRA (found by testing): the live queue has a LAUNCH CUTOFF (dump_ticket_date >= 2026-07-21) — without it the bot's first run would re-submit the entire 534-manifest historical backlog to the county; Fred widens the date deliberately if ever wanted. Keys: RPA_BOT_KEY + RPA_RUN_KEY in Supabase/.env (gitignored); RPA_BOT_KEYS set as a function secret (comma-separated for zero-downtime rotation).

1. **`rpa-derm-queue` edge fn** (verify_jwt=false + `x-rpa-key`): reads a dedicated VIEW (not base
   tables) so the contract is decoupled; filters no-SUCCESS + no-attempt-in-20h; caps 25 oldest
   first; mints 4h signed URLs; `?mode=dryrun` serves a fixed historical sample.
2. **`rpa-derm-result` edge fn** (same key): idempotent upsert on (manifest_id, run_id); server-side
   validation (status `^[A-Z0-9_]{1,64}$`, failure_reason capped ~1000 chars, manifest must exist
   and be submittable, unknown fields rejected); stores screenshot to a PRIVATE bucket, path in the
   row; dry-run results flagged.
3. **New table** (audit opt-in per ADR 010) for submission results + run tracking; `retryable=false`
   results leave the queue until the record changes; `retryable=true` stays with the 20h cooldown.
4. **Two keys**: `x-rpa-key` (bot→us) and a separate run-trigger key (us→bot). Both edge fns accept
   current+next comma-separated env values so rotation is zero-downtime.
5. **pg_cron trigger**: pg_net POST to John's `/run` nightly; expects 202; treat 409 as benign.
   pg_net timeout precedent = 120s max, hence the async-202 requirement on his side.
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
