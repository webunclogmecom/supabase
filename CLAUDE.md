# CLAUDE.md — AI Agent Operating Manual

**Unclogme Centralized Database (v2)** · *Maintained by Fred Zerpa · Last updated 2026-05-17*

Non-negotiable rules + quick reference for any AI agent working on this repo. **Read every session before touching anything.** Everything else is in [`docs/`](docs/).

---

## What this project is

Single source-of-truth Postgres warehouse for Unclogme LLC on Supabase project `wbasvhvvismukaqdnouk`. Webhooks from Jobber, Airtable, and Samsara land in three Edge Functions and normalize into a 28-table 2NF/3NF schema. Cross-system IDs live in one polymorphic bridge table (`entity_source_links`) — never as source-prefixed columns. Jobber + Airtable visit-gen sunset May 2026 (visit-gen already done 2026-05-13); DERM + PRE-POST stay on AT until further notice; Odoo.sh CRM takes over CRM; Samsara is permanent.

---

## The 8 non-negotiable rules

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

### 8. Audit-trail standing check (NEW 2026-05-17 — see [ADR 010](docs/decisions/010-audit-trail.md))
Every new business table or schema change must **explicitly opt-in or opt-out** of `audit.logs` triggers, documented in the migration header.

- **Default for tables with human-editable fields** → opt-in. Add `CREATE TRIGGER audit_<table> AFTER INSERT OR UPDATE OR DELETE ON public.<table> FOR EACH ROW EXECUTE FUNCTION audit.log_change();`
- **Default for sync-only append tables (Jobber/AT/Samsara)** → opt-out, document why in migration header.
- **Adding a column** to an already-audited table is automatically captured (full-row JSONB) — no action needed.
- **Renaming an audited table** requires updating the trigger reference.
- **Disabling audit on an existing table** requires explicit Fred sign-off in the migration header.
- **No table that touches `customer.*`, billing, DERM compliance, or webhook secrets is allowed to skip audit.** Hard rule.

Current audited set: clients, service_configs, properties, visits, photo_classifications, derm_manifests, manifest_visits *(opted in 2026-05-18 for DERM Tracker)*, disposal_facilities, vehicles, employees, webhook_tokens. See ADR 010 for the exclusion list + rationale.

After ANY change to Prod schema, re-check this rule before declaring the migration done.

#### App-source attribution (added 2026-05-23 — see [ADR 016](docs/decisions/016-audit-app-source-attribution.md))

Every audit row now carries `app_source` and `request_context`. To find "who wrote this":
- `app_source = 'derm-tracker'` — DERM Tracker UI (derm.unclogme.app)
- `app_source = 'field-portal'` — Field Portal (fp.unclogme.app)
- `app_source = 'admin-review'` — Admin Review (grease-buddy-dash)
- `app_source = 'visit-calendar'` — Visit Calendar Lovable preview
- `app_source = 'sql'` — direct Management API / psql / scripts (no PostgREST context)
- `app_source = 'other:<host>'` — unmapped origin (add to the trigger CASE when an app subdomain is added)
- explicit `X-App-Source: <name>` header overrides everything — use for scripts, bots, one-off curl

Old rows (pre-2026-05-23 18:30 UTC) have `app_source IS NULL` — no attribution available retroactively.

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
- **Supabase projects (all in `Dev - Unclogme` org, us-east-1):**
  - **Prod** `wbasvhvvismukaqdnouk` — source of truth, Pro plan, RLS hardened.
  - **Sandbox** `ubtlwpcyntelgbykdatn` — Yannick's *internal portal* Lovable app reads here. Auto-refreshed from Prod 5×/day by `sandbox-refresh.yml`. Don't write to canonical tables directly. Don't touch Yannick's tables/columns.
  - **Field Portal Sandbox** `klgtrdwrasrlxbmfyvdh` — Yannick's *Field Portal* Lovable app (created 2026-05-14). Free plan, 500 MB cap. **Clone-of-Prod model**: seeded once via `clone-prod-to-field-portal.yml` workflow, then diverges as Yannick iterates. Migration of his changes back to Prod (with 3NF / proper schema) is a separate forward-task.
- **Today:** 2026-05-13. Visit-gen sunset from AT 2026-05-13; DERM + PRE-POST AT automations still active.

---

## Column-name gotchas

Full table in [`docs/operations.md`](docs/operations.md#column-name-gotchas). Most-repeated mistakes:

| Wrong | Right | Table |
|---|---|---|
| `c.active = true` | `c.status = 'ACTIVE'` or `'RECURRING'` | clients |
| `e.name` | `e.full_name` | employees |
| `v.status` | `v.visit_status` | visits |
| `v.is_complete` | `(v.visit_status = 'completed')` *(lowercase — canonical value, verified 2026-05-18)* | visits |
| `sc.next_visit`, `sc.status` | Use `clients_due_service` view | service_configs (dropped 2026-04-20) |
| `m.manifest_number` | `m.white_manifest_number` | derm_manifests |
| `v.tank_capacity_gallons` | `v.fuel_tank_capacity_gallons` or `v.grease_tank_capacity_gallons` | vehicles |

### Truck names are NOT people
**Moises, David, Goliath** — trucks. **Cloggy** — truck (only daytime-only one). Never respond to "David did the visit" as if David is a person without checking [docs/operations.md](docs/operations.md#truck-name--person-name).

### Overnight shifts
Commercial trucks work 10pm–3am. `visit_date` is the logical operating date, not the clock date of `start_at`. Use `visit_date` explicitly or ±12h windows. See [operations.md](docs/operations.md#overnight-shift-handling).

### `clients.status` values
`ACTIVE`, `RECURRING`, `PAUSED`, `INACTIVE`. AT's old `Recuring` (one r) was a typo — normalized 2026-05-13. populate.js + ops views all use `RECURRING`.

### GDO permits — location-bound (added 2026-05-25, per Fred)

A GDO (Grease Disposal Operator permit) is issued by Miami-Dade DERM to a **physical
location**, not the business operating there. If a property changes hands (Yan's
Restaurant → Fred's Restaurant at the same address), the GDO stays — same number, same
max-frequency, same PDF. Beyond the permit number, a GDO carries the city-mandated
**max service frequency** (e.g. "GT must be pumped at least every 90 days") and the
**expiration date**.

**Schema implication**: currently `service_configs.permit_number` + `permit_document_path`
sit at the (client, service_type) level. Eventually these belong on `properties`
(see [operations.md → GDO permits](docs/operations.md#gdo-permits--bound-to-location-not-client-per-fred-2026-05-25)
for full design + migration plan).

For now the workaround: webhook-airtable writes GDO Number to all `service_configs` rows
for the client (not just GT). The 2026-05-25 backfill caught the historic gap.

### DERM 2-week rule (added 2026-05-22, per Fred)
**Any completed visit older than 2 weeks that needs DERM (i.e. `derm_required != false`, typically GT service) SHOULD have a `manifest_visits` row linking it to a `derm_manifests` record with both `derm_manifest_url` and `derm_address_url`.** If it doesn't, treat it as a data gap and investigate.

To find the missing DERM in AT, cross-reference three fields on the AT DERM table:
1. **`Visits`** — array of AT visit GIDs. Look each up in AT `Visits` table to get the true visit date (often differs from `GT Last Visit` field by weeks because dump dates lag behind service dates).
2. **`Client Code #3 (from Client)`** — lookup of `clients.client_code`. Confirm match (e.g. `010-CS`).
3. **`Client Name (from Client)`** — lookup of `clients.name`. Confirm match (e.g. `Chima Steakhouse`).

When all 3 align with a DB visit, INSERT into `public.manifest_visits` (PK `(visit_id, manifest_id)`, audit trigger fires).

Re-runnable backfill: [`scripts/sync/backfill_manifest_visits_via_at_visits_field.js`](scripts/sync/backfill_manifest_visits_via_at_visits_field.js). Walks every AT DERM record's `Visits` field, resolves the AT visit GID's date, matches DB visit by client + date (±1 day). Caught 11 missed links on first run (2026-05-22).

The webhook-airtable's primary link logic uses `GT Last Visit` ±2 days — that field drifts by weeks on jobs invoiced after the fact (Chima 010-CS visit 1511 on 3/18 had a DERM dumped 4/24, AT's `GT Last Visit` showed 4/20, 33 days off). Run the backfill script weekly until the webhook is patched to use the `Visits` field as primary signal.

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
| [apps/internal-portal/](apps/internal-portal/) | Yannick's full internal-tool prototype (Dashboard, Sales, Scheduling, Visits, Ops). Single-file React+CDN. Pre-built UI; wiring to live Supabase pending. |
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
