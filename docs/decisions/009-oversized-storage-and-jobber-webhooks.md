# ADR 009 — Oversized attachment storage + Jobber webhook delivery path

**Status:** Proposed · **Date:** 2026-04-27 · **Decider:** Fred Zerpa

---

## Context

Two unrelated decisions, batched here because both surfaced during the 2026-04-22 → 2026-04-27 audit cycle and both need a "ship it" choice before May-2026 sunset.

### Part A — 35 oversized Jobber video attachments

The Jobber notes/photos migration (2026-04-21) found 35 video files (24× `.mov`, 11× `.mp4`) totaling **3.45 GB** that exceed Supabase Pro's per-object limit of **50 MB**. They were logged to `jobber_oversized_attachments` with their signed Jobber S3 URLs (72-hour validity).

On 2026-04-22, before those URLs expired, `scripts/migrate/rescue_oversized.js` downloaded all 35 files to `oversized_backup/` (gitignored, ~3.4 GB on Fred's local disk). The files are safe but **not** queryable through the project DB. Long-term storage decision is pending.

### Part B — Jobber webhook delivery is intermittent

22 webhook subscriptions are configured in the Jobber Developer Center, the app is OAuth-authorized against the production Unclogme account (account_id `1444605`), our Edge Function is deployed and verified end-to-end (replay tests pass). Yet only **6 real webhook events** have arrived since 2026-04-21, none reliably. Today: zero. Diagnosis points at the app's "In Development" status, but Jobber's docs don't explicitly say in-dev apps suppress webhooks.

In contrast: Airtable live sync (10 automations, Path B Bearer) is fully functional — 50+ events processed in last 36 h. Samsara delivers but HMAC-fails on real events (separate signing-secret discrepancy, tracked in `CLAUDE.md` known blockers).

---

## Decision A — Cloudflare R2 for oversized attachments

**We will use Cloudflare R2** for the 35 oversized files.

| Option | Cost / mo | Setup time | Operational fit |
|---|---|---|---|
| **Cloudflare R2** ✅ chosen | **~$0.05** (3.5 GB @ $0.015/GB; egress free) | ~30 min one-time | Files only viewed by employees a few times/year; free egress means no surprises |
| Backblaze B2 | ~$0.02 storage + $0.01/GB egress | ~30 min | Cheaper at rest, but egress fees become a worry if a viewer scrolls a lot |
| AWS S3 | ~$0.08 + $0.09/GB egress | ~30 min | Most expensive both ways |
| Supabase **Team** plan | **+$574/mo** (Pro $25 → Team $599) | Toggle in dashboard | Solves limit but dramatically over-priced for 35 files |
| Keep local only | $0 | done | No redundancy. If Fred's laptop dies, files are gone. Unacceptable for compliance evidence. |

**Implementation notes:**
- Add `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ACCOUNT_ID` to `.env` and Supabase secrets.
- Write `scripts/migrate/upload_oversized_to_r2.js` — iterates `oversized_backup/`, uploads with key `oversized/<attachment_jobber_id>/<file_name>`, records the resulting URL in a new `oversized_attachments.r2_url` column.
- Add a tiny lookup helper to `webhook-jobber/index.ts`: when a NOTE handler later encounters an oversized attachment (>50 MB pre-check), upload to R2 instead of Supabase Storage.
- Document the bucket + auth pattern in `docs/integration.md` and `docs/security.md`.
- Schema migration: `ALTER TABLE jobber_oversized_attachments ADD COLUMN r2_url text;` (3NF-clean — `r2_url` is identity + location, not duplicated business data).

**Why not Supabase Vault / Storage at higher tier:** Vault is for secrets, not blobs. Team plan upgrade is a $7,000/yr decision for 35 files — burns budget that's better spent elsewhere (Odoo licensing, Samsara expansion, etc.).

**Cost ceiling:** even if we accumulate 100× more oversized media before sunset, R2 is ~$5/mo. Linear and cheap.

---

## Decision B — Jobber webhook delivery: hybrid path

**We will keep webhooks ON, add a poll fallback, and email Jobber support.** Three actions, not one.

### B1. Keep webhooks configured (status quo)
Edge Function and 22 subscriptions remain in place. Whatever delivery rate Jobber chooses to give us, we accept.

### B2. Build a 5-minute polling job
`scripts/sync/cron_jobber.js` (purpose-built for stateless CI execution — does not reuse `incremental_sync.js`) pulls Jobber GraphQL deltas based on `sync_cursors.last_synced_at`, upserts into `raw.jobber_pull_*`, and replays through the live `webhook-jobber` Edge Function. Runs on a GitHub Actions cron (`*/5 * * * *`) — chosen over `*/2` to stay within the free-tier 2,000 min/mo for our private repo.

- Pros: Effectively-live for an ops business (5 min ≈ instant operationally). Covers **notes**, which Jobber doesn't webhook at all (zero NOTE_* topics in WebHookTopicEnum). No dev-center mystery.
- Cons: ~288 runs/day at ~60s each = ~8,640 min/mo worst case. GitHub jitter usually delivers far less. If we ever exceed free tier, options are: make repo public (unlimited free Actions), bump to `*/10`, or migrate to Cloudflare Workers Cron Triggers.

This makes webhook flakiness a non-issue: webhooks are a "nice to have" speed-up; the cron is the SLA backstop.

### B3. Email Jobber API support
Letter is already drafted (see chat history 2026-04-23). Send it. Even if support says "publish the app to fix delivery," we'll have the answer documented.

---

## Consequences

**A:**
- New monthly cost: ~$0.05 (negligible).
- New runtime dependency: R2 bucket + 4 env vars.
- Upgrade path: same script can lift-and-shift to S3/B2 if R2 ever becomes restrictive.

**B:**
- New runtime dependency: GitHub Actions cron (free under 2,000 min/mo private-repo allowance — we'll use ≤30 min/day).
- Webhook diagnosis is no longer blocking: even if Jobber webhooks never improve, our DB is at most ~5 min stale.
- Documentation grows: `docs/integration.md` adds a "polling fallback" section; `docs/runbook.md` adds a "what if cron fails" section.

---

## Status / next steps

| Step | Owner | Tracking |
|---|---|---|
| Create Cloudflare account + R2 bucket `unclogme-oversized` | Fred (5 min in dashboard) | this ADR |
| Generate R2 API token, save to `.env` and Supabase secrets | Fred (5 min) | this ADR |
| Implement `scripts/migrate/upload_oversized_to_r2.js` | Claude | follow-up commit |
| Add `r2_url` column + migrate the 35 records | Claude | follow-up commit |
| GitHub Actions cron for `incremental_sync.js` | Claude | follow-up commit |
| Send api-support@getjobber.com letter | Fred | this ADR |

---

*Once steps complete, this ADR is **Accepted**.*
