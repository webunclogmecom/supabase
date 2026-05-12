# ADR 015 — Supabase-native recurring visit generation

**Date:** 2026-05-12
**Status:** Accepted
**Supersedes:** The Airtable "Generate Visits" button-triggered automation (no ADR; pre-dates this decision log)
**Related:** ADR 011 (source-of-truth canonicalization), ADR 002 (entity-source-links)

## Context

For the last ~2 years, the recurring visit schedule has lived in **Airtable**:

- The office configures each client with frequency, price, anchor date, services
- Operator clicks a "Generate Visits" button → an Airtable script creates Upcoming visit rows in the Airtable Visits table
- Operators see those visits on Airtable Calendar views and use them to manually create matching jobs/visits in Jobber
- Drivers complete the work in Jobber's mobile app
- Jobber visits sync back to our Supabase warehouse via `cron_jobber` + `webhook-jobber`

Two systems are sunsetting in 2026:

- **Airtable**: sunset May 2026 (now)
- **Jobber**: sunset June 2026 (~30 days from this ADR)

The recurring schedule logic must move somewhere persistent. Options considered:

| Option | Pros | Cons |
|---|---|---|
| **A.** Write a daily cron that writes to Jobber via Jobber API | Single source (Jobber → Supabase via existing sync) | Investing in a 30-day system; Jobber API rate limits |
| **B.** Write a Supabase-native cron that writes to Supabase directly + modify cron_jobber/webhook-jobber to merge with incoming Jobber visits | Supabase becomes canonical for the schedule today; clean Jobber sunset (delete merge logic) | Bounded code complexity (~50 lines) for 30 days |
| **C.** Write to Supabase, accept dupes, nightly dedup | Simplest at write time | 30 days of dual rows; bad UX in Lovable / dashboards |
| **D.** Wait until June (Jobber sunset) | No transitional code | 30+ days of operational pain; existing 60+ overdue Recurring clients keep slipping |
| **E.** Use Jobber's native recurring-service feature | Zero engineering | Same problem — Jobber dies in 30 days |

## Decision

**Option B.** A Supabase-native daily cron (`scripts/sync/cron_generate_recurring_visits.js`) generates the recurring visit schedule directly in our Postgres `visits` table. A new `visits.source` column distinguishes who created each row, and `webhook-jobber`'s `handleVisit` function gains a small **promotion path**: when a Jobber visit arrives that matches an existing `supabase_cron`-sourced scheduled placeholder, the existing row is UPDATED in place rather than a duplicate INSERTed.

### The flow

```
4:30 AM ET daily          office today                     driver same day
       │                       │                                  │
       ▼                       ▼                                  ▼
┌──────────────┐        ┌──────────────┐                  ┌──────────────┐
│  Supabase    │        │  manually    │                  │ Jobber: mark │
│  cron writes │  →     │  create the  │  →               │ complete →   │
│  scheduled   │        │  matching    │                  │ cron_jobber  │
│  visit (rec) │        │  visit in    │                  │ pulls visit  │
│  src=cron    │        │  Jobber      │                  │              │
└──────────────┘        └──────────────┘                  └──────────────┘
                                                                  │
                                                                  ▼
                                                  ┌────────────────────────────┐
                                                  │  webhook-jobber MATCHES    │
                                                  │  the cron row by (client,  │
                                                  │  service_type, ±7 days) +  │
                                                  │  PROMOTES it: UPDATE in    │
                                                  │  place, src='jobber',      │
                                                  │  GID attached, no dupe.    │
                                                  └────────────────────────────┘
```

After June 2026 Jobber sunset, the merge path becomes a no-op (no Jobber visits arriving) and can be deleted. The cron is unchanged. Operators interact with the schedule via Lovable (Sandbox today, Prod later) and eventually Odoo.

### Schema

```sql
ALTER TABLE visits
  ADD COLUMN source text NOT NULL DEFAULT 'jobber'
  CHECK (source IN ('jobber','supabase_cron','airtable','manual','odoo'));

CREATE INDEX idx_visits_source_cron_scheduled
  ON visits (client_id, service_type, visit_date)
  WHERE source = 'supabase_cron' AND visit_status = 'scheduled';
```

Plus a Postgres trigger `trg_clients_wipe_upcoming_on_inactive` that replaces the legacy Airtable INACTIVE-wipe automation. Plus CHECK constraints on `service_configs.service_type` and `visits.service_type` enforcing `IN ('GT','CL','WD','LS')`.

### Anchor logic (Option D from design discussion)

For each `(client × service_type)` with `frequency_days > 0`:

1. `MAX(visit_date) WHERE visit_status='scheduled' AND visit_date >= today` + frequency → **extend** existing chain
2. else `MAX(visit_date) WHERE visit_status='completed'` + frequency → anchor from service history
3. else `service_configs.first_visit` → new-client anchor
4. else `today + frequency` → last resort, defer first visit one cycle

### Window logic ("2 months")

Per Fred 2026-05-12: generate visits up to the end of next calendar month. Plus a min-count rule: every (client × service) gets at least 1 future visit even if frequency_days > 60. So a 30-day client gets ~2 visits queued; a 120-day client gets 1 visit at day 120.

### Idempotency

Per-candidate-date check: any existing visit at `(same client, same service_type, visit_date within ±7 days, status IN ('scheduled','late','today','completed'))` causes the candidate to be skipped. Tolerance is ±7 days based on practical experience — wider would risk false merges; tighter would risk visible duplicates from clock skew or office date adjustments.

## Consequences

### Positive

- **Supabase becomes the canonical source of truth for the visit schedule today** — exactly where it'll be after the June Jobber sunset. Single architectural cutover, not two.
- **Solves the existing operational gap immediately** (60+ Recurring clients with no future visits booked). Backfill runs on first cron fire.
- **Office workflow unchanged** until Lovable's "upcoming visits per client" view ships. They keep using Airtable temporarily; the cron just adds the new Supabase-native rail underneath.
- **Merge logic is the explicit transition mechanism** — not architectural debt. When Jobber sunsets, the merge code is deleted, end of story.
- **Cron is independent of any source system** — relies only on our own `clients` + `service_configs` + `visits` tables. Whatever happens to Airtable/Jobber, the cron keeps running.

### Negative

- **Office can't see cron-generated visits in Airtable** (no Supabase → Airtable sync direction). The cron is fired manually until Yannick's Lovable view is live (estimated this week, 2026-05). Until then operators continue working from the existing Airtable schedule.
- **Edge case: WD/LS service types aren't inferrable from Jobber visit titles.** The merge logic matches by `service_type`, and `webhook-jobber.inferServiceType()` only returns GT or CL from title text. WD and LS placeholders won't get promoted from incoming Jobber visits; they'll be left as orphans. Mitigation: WD has 1 service_config in the system, LS has 0 — small surface today. Long-term fix is Jobber sunset (no more visits arrive to merge with).
- **±7 day tolerance is a tuning constant.** Could cause a false promotion if the office picks a date 7 days off from the planned schedule. Mitigation: tight enough that mistakes get caught (clearly different visit-date); the orphan placeholder cleanup query (`DELETE WHERE source='supabase_cron' AND visit_status='scheduled' AND visit_date < CURRENT_DATE - INTERVAL '14 days'`) catches anything that slips.

### Alternatives considered + rejected

- **A (write to Jobber API)** — invests in dying infra
- **C (accept dupes + nightly dedup)** — 30 days of bad UX in Lovable + dashboards
- **D (wait until June)** — operational pain, no win
- **E (Jobber native recurring service)** — same as A, dying infra

## References

- [scripts/sync/cron_generate_recurring_visits.js](../../scripts/sync/cron_generate_recurring_visits.js) — the cron
- [.github/workflows/generate-recurring-visits.yml](../../.github/workflows/generate-recurring-visits.yml) — schedule (currently disabled)
- [supabase/functions/webhook-jobber/index.ts](../../supabase/functions/webhook-jobber/index.ts) — `handleVisit` promotion logic, search "PROMOTE"
- [scripts/migrations/add_visits_source_and_inactive_wipe_2026_05_12.sql](../../scripts/migrations/add_visits_source_and_inactive_wipe_2026_05_12.sql) — schema migration
- Commit [`0b4ad9d`](https://github.com/webunclogmecom/supabase/commit/0b4ad9d) — initial deploy
