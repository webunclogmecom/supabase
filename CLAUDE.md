# CLAUDE.md — AI Agent Operating Manual

**Unclogme Centralized Database (v2)** · *Maintained by Fred Zerpa · Last updated 2026-05-13*

Non-negotiable rules + quick reference for any AI agent working on this repo. **Read every session before touching anything.** Everything else is in [`docs/`](docs/).

---

## What this project is

Single source-of-truth Postgres warehouse for Unclogme LLC on Supabase project `wbasvhvvismukaqdnouk`. Webhooks from Jobber, Airtable, and Samsara land in three Edge Functions and normalize into a 28-table 2NF/3NF schema. Cross-system IDs live in one polymorphic bridge table (`entity_source_links`) — never as source-prefixed columns. Jobber + Airtable visit-gen sunset May 2026 (visit-gen already done 2026-05-13); DERM + PRE-POST stay on AT until further notice; Odoo.sh CRM takes over CRM; Samsara is permanent.

---

## The 7 non-negotiable rules

### 1. Source-agnostic schema
**Zero `jobber_*` / `airtable_*` / `samsara_*` / `fillout_*` / `odoo_*` columns on any business table.** Cross-system identity lives in `entity_source_links`. If you're tempted to propose a source-prefixed column, stop and use the bridge table. Fred is the explicit guardrail on this. See [ADR 002](docs/decisions/002-entity-source-links.md).

### 2. 3NF standing check
Every schema proposal states, per column: *"Does this depend on the whole key, and nothing else?"* If a column depends on another column in the same table (2NF) or via FK transitive dep (3NF), **it does not get stored**. It's computed on read via a view. See [ADR 005](docs/decisions/005-3nf-standing-check.md).

### 3. Reference all data
Related data via FK, never copied. No snapshot columns duplicating join-available values. Intentional denormalization ([ADR 004](docs/decisions/004-intentional-denormalization.md)) is the only exception — documented, one-time.

### 4. Source-of-truth trust hierarchy (revised 2026-04-29)
- **Jobber + Samsara = 100% trusted.** Jobber owns identity, addresses, contacts, jobs, visits, invoices, line_items, quotes, notes/photos, employees. Samsara owns vehicles, drivers (field), GPS/telemetry, geofences.
- **Airtable = best-effort enrichment, NOT authority.** Trusted only for `derm_manifests` and `inspections` (PRE-POST). Service configs, client enrichment (zone, hours, days, county) — treat as suggestions. Airtable throws wrong data regularly; never let it override Jobber/Samsara.
- **`ops.*` merge views** COALESCE Jobber-first over Airtable/Samsara.
- Dropped sources: Fillout (entirely), Airtable Drivers&Team/Past due/Route Creation/Leads.

### 5. Idempotent upserts only
Every sync/population script uses `ON CONFLICT` on natural keys. Re-runnable with zero data corruption. No exceptions.

### 6. Never hard-delete
Business data uses `status = 'INACTIVE'` or equivalent. Hard deletes break `entity_source_links` and historical joins. Only deletes allowed: `webhook_events_log` retention trimming + legacy `entity_source_links` archival post-sunset.

### 7. Timestamps in UTC, money in `NUMERIC(12,2)`
All `TIMESTAMPTZ` stored UTC; display layer converts. All money `NUMERIC(12,2)`. `updated_at` trigger-managed — **never set it manually**.

---

## Collaboration rules

### With Fred (user)
- **No approval for routine actions.** Fred pre-approves; never pause for "can I do this?" confirmation.
- **Ask before destructive ops.** `DROP`, `DELETE`, `git reset --hard`, `git push --force`, etc. → explicit confirmation.
- **Save tokens.** Don't generate Excel/screenshots/markdown unless asked.
- **Critical reasoning over agreement.** Fred values pushback. If his proposal has a flaw, say so with reasoning.

### With Viktor (AI coworker in Slack, `U0AKTMAMWP9`)
- **Ask first on dev changes** — new tables, FKs, column renames, Edge Function logic. Probes don't need consent.
- **Critically reason** on his replies. He sometimes uses wrong column names; verify against [docs/schema.md](docs/schema.md).
- **Poll cadence** — every 3 min, max 3 attempts (9 min). After that, Fred has final say.
- **Channel:** `#viktor-supabase` (`C0B08S21HHD` — recreated 2026-04-29; prior `C0AN9KDP5B8` is dead).
- **When Fred messages Viktor**, always schedule a 3-min polling cron.

### With Yan (founder)
Yan owns strategy, budget, business rules. Fred owns architecture + implementation. Route accordingly.

---

## Environment

- **OS:** Windows. Use forward-slash inside code strings; tool calls use `C:\Users\FRED\Desktop\Virtrify\Yannick\Claude\Supabase\...`
- **Node ≥ 20**, npm, Supabase CLI, `gh` CLI (keyring-authed — never embed PATs in URLs).
- **Supabase project:** `wbasvhvvismukaqdnouk`. Pro plan. US East.
- **Today:** 2026-05-13. Visit-gen sunset from AT 2026-05-13; DERM + PRE-POST AT automations still active.

---

## Column-name gotchas

Full table in [`docs/operations.md`](docs/operations.md#column-name-gotchas). Most-repeated mistakes:

| Wrong | Right | Table |
|---|---|---|
| `c.active = true` | `c.status = 'ACTIVE'` or `'RECURRING'` | clients |
| `e.name` | `e.full_name` | employees |
| `v.status` | `v.visit_status` | visits |
| `v.is_complete` | `(v.visit_status = 'COMPLETED')` | visits |
| `sc.next_visit`, `sc.status` | Use `clients_due_service` view | service_configs (dropped 2026-04-20) |
| `m.manifest_number` | `m.white_manifest_number` | derm_manifests |
| `v.tank_capacity_gallons` | `v.fuel_tank_capacity_gallons` or `v.grease_tank_capacity_gallons` | vehicles |

### Truck names are NOT people
**Moises, David, Goliath** — trucks. **Cloggy** — truck (only daytime-only one). Never respond to "David did the visit" as if David is a person without checking [docs/operations.md](docs/operations.md#truck-name--person-name).

### Overnight shifts
Commercial trucks work 10pm–3am. `visit_date` is the logical operating date, not the clock date of `start_at`. Use `visit_date` explicitly or ±12h windows. See [operations.md](docs/operations.md#overnight-shift-handling).

### `clients.status` values
`ACTIVE`, `RECURRING`, `PAUSED`, `INACTIVE`. AT's old `Recuring` (one r) was a typo — normalized 2026-05-13. populate.js + ops views all use `RECURRING`.

---

## Documentation map

| Doc | When to read |
|---|---|
| **CLAUDE.md** (this file) | Every session start |
| [README.md](README.md) | First-time orientation |
| [docs/schema.md](docs/schema.md) | Looking up a column / constraint / view |
| [docs/architecture.md](docs/architecture.md) | Data flow / source systems |
| [docs/operations.md](docs/operations.md) | Writing a query / report (gotchas, patterns) |
| [docs/runbook.md](docs/runbook.md) | Incidents, deploys, migrations |
| [docs/integration.md](docs/integration.md) | Edge Functions / webhooks / rate limits |
| [docs/security.md](docs/security.md) | Secrets / tokens / RLS / rotation |
| [docs/migration-plan.md](docs/migration-plan.md) | Jobber/AT sunset + Odoo cutover |
| [docs/company.md](docs/company.md) | Business context: fleet, clients, compliance |
| [docs/onboarding.md](docs/onboarding.md) | New to project |
| [docs/decisions/](docs/decisions/) | ADRs — *why* something is the way it is |
| [docs/research/](docs/research/) | External-source synthesis (Claude Code best practices, etc.) |
| [docs/audits/](docs/audits/) | Historical state snapshots |
| [apps/visit-view/](apps/visit-view/) | Yannick's upcoming-visits view (Claude Design → handoff → wiring) |
| [OPS_LIST_YAN.md](OPS_LIST_YAN.md) | Current Yan to-do (auto-regenerated from `scripts/probes/generate_ops_list_yan.js`) |

---

## Commit & PR conventions

- **Subject ≤ 70 chars.** Imperative ("Add X", "Fix Y"). Not "Added", not "Fixing".
- **Body explains *why*, not *what*.** Diff shows what.
- **Co-author line** required on Claude commits:
  `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`
- **Never** skip hooks (`--no-verify`), bypass signing, or force-push to main without explicit ask.
- **Destructive ops** only with explicit Fred approval.

---

## When you're not sure

1. **Re-read this file** — 80% of mistakes are forgetting a rule above.
2. **Grep the codebase** before asking.
3. **Check `docs/`** — answer is usually there.
4. **Check `webhook_events_log`** for data-path questions.
5. **Ask Viktor** for source-data questions.
6. **Ask Fred** for architecture questions. He is the final word.

---

*Every structural change to schema, architecture, or sync must update this file and/or relevant `docs/`. No drift between code and docs.*
