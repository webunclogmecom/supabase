# Unclogme Centralized Database

Single source-of-truth Postgres warehouse for Unclogme LLC, hosted on Supabase. Consolidates Jobber (CRM/billing), Airtable (service configs / DERM compliance), Samsara (fleet telemetry), and Fillout (shift inspections) into one normalized schema. Odoo.sh CRM reads from this database starting May 2026, replacing Jobber and Airtable.

- **Supabase project:** `wbasvhvvismukaqdnouk`
- **Dashboard:** https://supabase.com/dashboard/project/wbasvhvvismukaqdnouk
- **Plan:** Pro ($25/mo)
- **Architecture:** Webhooks → Edge Functions → normalized tables (real-time, no drift detector)

---

## Quickstart

```bash
# 1. Clone + install
git clone https://github.com/webunclogmecom/supabase.git
cd supabase
npm install

# 2. Environment
cp .env.example .env
# Fill in secrets — see docs/security.md for where each one lives

# 3. Authenticate GitHub CLI (for workflows / PRs)
gh auth login

# 4. Verify connection to Supabase
node scripts/probe.js
```

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
| [docs/migration-plan.md](docs/migration-plan.md) | Jobber/Airtable sunset, Odoo.sh cutover plan |
| [docs/company.md](docs/company.md) | Business context: fleet, clients, compliance, people |
| [docs/onboarding.md](docs/onboarding.md) | New-engineer 1-hour / 1-day / 1-week path |
| [docs/decisions/](docs/decisions/) | Architecture Decision Records (ADRs) |

---

## Project Layout

```
.
├── CLAUDE.md                   — AI agent operating manual
├── README.md                   — this file
├── .env.example                — credential template
├── docs/                       — all project documentation
├── schema/
│   └── v2_schema.sql           — canonical DDL for the 28-table v2 schema
├── scripts/
│   ├── jobber_auth.js          — one-time Jobber OAuth bootstrap
│   ├── probe.js                — connection sanity check
│   ├── populate/               — bulk population orchestrator (initial load + fixups)
│   ├── migrations/             — SQL migrations, applied manually
│   └── webhooks/               — registration scripts for Jobber / Samsara / Airtable
└── supabase/
    └── functions/
        ├── webhook-jobber/     — Jobber webhook receiver
        ├── webhook-samsara/    — Samsara webhook receiver
        ├── webhook-airtable/   — Airtable webhook receiver
        └── _shared/            — shared modules (supabase-client, entity-links)
```

---

## Decision Points, At a Glance

- **Webhooks-only.** No nightly cron, no drift detector. See [ADR 001](docs/decisions/001-webhooks-over-cron.md).
- **Source-agnostic schema.** Zero `jobber_*` / `airtable_*` business fields — cross-system IDs live in `entity_source_links`. See [ADR 002](docs/decisions/002-entity-source-links.md).
- **3NF first.** Every schema proposal is audited against 3NF. See [ADR 003](docs/decisions/003-service-configs-3nf.md) and [ADR 005](docs/decisions/005-3nf-standing-check.md).
- **No QuickBooks.** Payments tracked in Jobber (`invoices.paid_at`). See [ADR 006](docs/decisions/006-no-quickbooks.md).
- **Samsara is permanent.** Survives the May 2026 Jobber/Airtable sunset. See [ADR 004](docs/decisions/004-samsara-permanent.md).

---

## Owners

| Role | Name | Decisions they own |
|---|---|---|
| Admin & Tech Director | Fred Zerpa | Architecture, schema, implementation |
| Founder / Owner | Yan Ayache | Business rules, strategy, budget |
| AI coworker (Slack `#viktor-supabase`) | Viktor | Sync implementation, source data expertise |

See [docs/company.md](docs/company.md) for the full team roster.
