# Unclogme Centralized Database

Single source-of-truth Postgres warehouse for Unclogme LLC, hosted on Supabase. Consolidates Jobber (CRM, billing, identity), Samsara (fleet telemetry) and the Fillout shift-inspection forms into one normalized schema, read by the staff and customer apps. Airtable was retired on 2026-07-24 and Odoo.sh was dropped on 2026-07-08; neither feeds this database.

- **Supabase project:** `wbasvhvvismukaqdnouk`
- **Dashboard:** https://supabase.com/dashboard/project/wbasvhvvismukaqdnouk
- **Plan:** Pro ($25/mo)
- **Architecture:** Jobber reaches us through webhooks and a 5-minute poll, with drift-reconcile jobs as a safety net; Samsara and the Fillout forms arrive through edge functions. pg_cron and Railway timed jobs run the schedules. There is no staging project: every apply reaches production.

---

## Quickstart

```bash
# 1. Clone + install
git clone https://github.com/webunclogmecom/supabase.git
cd supabase
npm install

# 2. Environment
cp .env.example .env
# Fill in secrets: see docs/security.md for where each one lives

# 3. Authenticate GitHub CLI (for workflows / PRs)
gh auth login

# 4. Verify connection to Supabase (reads production)
node scripts/probe.js

# 5. Offline checks (no network, no database)
node scripts/postman/sync_collection_description.js --check
node scripts/checks/dump_load_lines.mjs
node scripts/checks/orphaned-prose.mjs
```

`npm test` is intentionally empty. The other scripts in `scripts/checks/` read production or the live apps.

For a longer walk-through, read [`docs/onboarding.md`](docs/onboarding.md).

---

## Documentation Map

| Doc | What's in it |
|---|---|
| [CLAUDE.md](CLAUDE.md) | Rules + constraints for any AI agent working on this repo. **Read first.** |
| [docs/architecture.md](docs/architecture.md) | System design, data flow, source system integration |
| [docs/schema.md](docs/schema.md) | 28-table reference, columns, constraints, views |
| [docs/operations.md](docs/operations.md) | Column-name gotchas, overnight-shift handling, common queries |
| [docs/runbook.md](docs/runbook.md) | Incident response, webhook recovery, schema migration procedure |
| [docs/integration.md](docs/integration.md) | Edge Function contracts, webhook signatures, registration |
| [docs/security.md](docs/security.md) | Secrets, tokens, RLS, access control, rotation checklist |
| [docs/migration-plan.md](docs/migration-plan.md) | Historical: the May 2026 sunset and Odoo.sh cutover plan (Airtable retired 2026-07-24, Odoo dropped 2026-07-08) |
| [docs/company.md](docs/company.md) | Business context: fleet, clients, compliance, people |
| [docs/onboarding.md](docs/onboarding.md) | New-engineer 1-hour / 1-day / 1-week path |
| [docs/duplication-guide.md](docs/duplication-guide.md) | Clone the project to a fresh Supabase from zero (staging, demo, DR) |
| [docs/decisions/](docs/decisions/) | Architecture Decision Records (ADRs) |
| [docs/research/](docs/research/) | External-source synthesis (Claude Code best practices, etc.) |
| [docs/audits/](docs/audits/) | Historical audit snapshots |
| [apps/internal-portal/](apps/internal-portal/) | Supabase wiring specs for Yannick's internal portal prototype (the prototype file itself is kept privately since 2026-10-05) |

---

## Project Layout

```
.
├── CLAUDE.md                   AI agent operating manual
├── README.md                   this file
├── .env.example                credential template
├── docs/                       all project documentation
├── schema/
│   └── v2_schema.sql           canonical DDL for the 28-table v2 schema
├── docs/migrations/            the live SQL migrations (YYYY-MM-DD_HHMM_name.sql), applied by hand
├── migrations/, scripts/migrations/ older history; do not add files here
├── scripts/
│   ├── probe.js                connection check (reads production)
│   ├── checks/                 contract and regression checks
│   ├── sync/                   jobs the timed workflows run
│   └── probes/                 local scratch; query output is gitignored, never commit it
├── services/timed-jobs/        Railway timed jobs
└── supabase/
    └── functions/              60 edge functions plus _shared/ (webhook-airtable is retired)
```

---

## Decision Points, At a Glance

- **Webhooks first, poll and reconcile as backstops.** ADR 001 chose webhooks over cron; the 5-minute Jobber poll and the drift-reconcile jobs were added later. See [ADR 001](docs/decisions/001-webhooks-over-cron.md) and [ADR 009](docs/decisions/009-oversized-storage-and-jobber-webhooks.md).
- **Source-agnostic schema.** Zero `jobber_*` / `airtable_*` business fields; cross-system IDs live in `entity_source_links`. See [ADR 002](docs/decisions/002-entity-source-links.md).
- **3NF first.** Every schema proposal is audited against 3NF. See [ADR 003](docs/decisions/003-service-configs-3nf.md) and [ADR 005](docs/decisions/005-3nf-standing-check.md).
- **No QuickBooks.** Payments tracked in Jobber (`invoices.paid_at`). See [ADR 006](docs/decisions/006-no-quickbooks.md).
- **Samsara is permanent.** See [ADR 007](docs/decisions/007-samsara-permanent.md).

---

## Owners

| Role | Name | Decisions they own |
|---|---|---|
| Admin & Tech Director | Fred Zerpa | Architecture, schema, implementation |
| Founder / Owner | Yan Ayache | Business rules, strategy, budget |
| AI coworker (Slack `#viktor-supabase`) | Viktor | Consulted only when Fred asks |

See [docs/company.md](docs/company.md) for the full team roster.
