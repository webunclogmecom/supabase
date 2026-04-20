# ADR 001 — Webhooks over nightly cron

- **Status:** Accepted (2026-04)
- **Supersedes:** The original v1 5-script nightly sync design
- **Deciders:** Fred Zerpa, Viktor
- **Reversed on:** 2026-04-20 (GitHub daily-sync workflow deleted, commit `5253c2b`; orphaned scripts deleted in `abd209c`)

## Context

The v1 architecture pulled data nightly from Jobber, Airtable, Samsara, and Fillout via scheduled Node.js scripts running in GitHub Actions. Five scripts, one workflow, one populate orchestrator. The workflow was named `daily-sync.yml` and ran at 06:00 EDT.

Problems with that model:
- **Token refresh was structurally broken.** Jobber access tokens live ~60 min. The workflow refreshed them in-memory each run, but could not write the new token back to GitHub Secrets. Each refresh was effectively a leak; eventually the stored token drifted stale and every subsequent run failed with `JOBBER_ACCESS_TOKEN missing`. Confirmed in Action run logs `24461570335`..`24628429137`, 5 consecutive failures before deletion.
- **24-hour latency** on every change in source systems. Dashboards and scheduling views were always one day behind.
- **Silent failure tolerance.** A red daily CI email is background noise after the third one. Nobody acted.
- **Rate-limit pressure.** Nightly bulk pulls burned Jobber's 2,500-req/5-min DDoS budget and the 10k-point GraphQL cost bucket. Pagination + retry tuning was a constant yak-shave.

## Decision

Replace the cron pipeline with three Supabase Edge Functions (`webhook-jobber`, `webhook-airtable`, `webhook-samsara`), each subscribed to the source system's webhook stream. Tokens live in the `webhook_tokens` table, refreshed naturally by the Edge Functions themselves. `webhook_events_log` is the observability surface — every received payload is logged with success/failure status.

No separate drift detector. For a 4-truck fleet, per-event logging is sufficient.

## Consequences

**Positive:**
- ~Seconds of latency instead of 24 hours.
- Token refresh is self-contained (no GitHub-Secrets-write problem).
- Rate-limit pressure distributed across the day instead of concentrated in a nightly burst.
- `webhook_events_log` gives row-level observability — we can grep failures by `status='failed'`.

**Negative / accepted trade-offs:**
- If a webhook delivery fails *and* the retry window expires *and* we never notice, we lose that event. Accepted risk: `webhook_events_log` exposes it, and reconciliation can be run ad-hoc if ever needed.
- No backup reconciliation path. If webhooks break entirely (e.g. bad deploy), we notice via ops monitoring, not via automatic recovery.
- Samsara webhook registration requires "Webhooks write" scope on the API token — currently blocked. Telemetry ingestion stays at 0 rows until the token is upgraded.

**What this rules out:**
- No reintroduction of a nightly cron for the same data. If we ever need a health-check, it must be scoped narrowly (e.g. "run the test suite against live DB" without any source-system pulls).
