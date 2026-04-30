# CLAUDE.md — AI Agent Operating Manual

**Unclogme Centralized Database (v2)** · *Maintained by Fred Zerpa · Last updated 2026-04-30*

This file is the non-negotiable rules + quick reference for any AI agent (Claude, Viktor, future agents) working on this repository. **Read this every session before touching anything.**

For everything else, this is an index into [`docs/`](docs/).

---

## What this project is, in one paragraph

Single source-of-truth Postgres warehouse for Unclogme LLC, hosted on Supabase project `wbasvhvvismukaqdnouk`. Webhooks from Jobber, Airtable, and Samsara land in three Edge Functions which normalize into a 28-table 2NF/3NF schema. Cross-system IDs live in one polymorphic bridge table (`entity_source_links`) — never as source-prefixed columns. Jobber and Airtable sunset May 2026; Odoo.sh takes over CRM; Samsara is permanent.

---

## The 7 non-negotiable rules

### 1. Source-agnostic schema

**Zero `jobber_*` / `airtable_*` / `samsara_*` / `fillout_*` / `odoo_*` columns on any business table.** Cross-system identity lives in `entity_source_links`. If you're tempted to propose a source-prefixed column, stop and use the bridge table. Fred is the explicit guardrail on this. See [ADR 002](docs/decisions/002-entity-source-links.md).

### 2. 3NF standing check

Every schema proposal states, per column:

> "Does this depend on the whole key, and nothing else?"

If a column depends on another column in the same table (2NF violation) or on a column in a different table reachable via FK (3NF violation — transitive dep), **it does not get stored**. It gets computed on read via a view. See [ADR 005](docs/decisions/005-3nf-standing-check.md).

### 3. Reference all data

Related data is referenced via FK, never copied. No snapshot columns that duplicate values available via join. Intentional denormalization ([ADR 004](docs/decisions/004-intentional-denormalization.md)) is the only exception — documented, justified, one-time.

### 4. Source-of-truth trust hierarchy (revised 2026-04-29)

- **Jobber + Samsara = 100% trusted.** Jobber owns identity, addresses, contacts, jobs, visits, invoices, line_items, quotes, notes/photos, employees (office/admin via users). Samsara owns vehicles, drivers (field staff), GPS/telemetry, geofences.
- **Airtable is fully trusted ONLY for**: `derm_manifests` and `inspections` (PRE-POST table). Everything else from Airtable — service configs (frequencies, prices, GDO), client enrichment fields (zone, hours, days, county) — is treated as best-effort enrichment, not authority. **Airtable throws wrong data regularly**; never let it override Jobber/Samsara on overlapping fields.
- **Dropped sources (2026-04-29)**: Airtable `Drivers & Team` (stale roster — departed staff), `Past due` (use Jobber `invoices` directly), `Route Creation` (routing moves to Viktor's skill), `Leads` (lead capture moves to Odoo), Fillout entirely (inspections moved to Airtable PRE-POST; expenses live in Ramp).
- **`ops.*` merge views**: COALESCE Jobber-first over Airtable/Samsara. See [company.md §technology-stack](docs/company.md#technology-stack-current--roadmap).

### 5. Idempotent upserts only

Every sync/population script uses `ON CONFLICT` on natural keys. Scripts must be re-runnable with zero data corruption. No exceptions.

### 6. Never hard-delete

Business data uses `status = 'INACTIVE'` or equivalent. Hard deletes break `entity_source_links` and historical joins. The only delete operations in this database are webhook_events_log retention trimming and legacy `entity_source_links` archival after sunset.

### 7. Timestamps in UTC, money in `NUMERIC(12,2)`

All `TIMESTAMPTZ` stored UTC; display layer converts. All money `NUMERIC(12,2)`. `updated_at` is trigger-managed; **never set it manually**.

---

## Collaboration rules

### With Fred (the user)

- **No approval needed for routine actions.** Fred pre-approves; never pause for "can I do this?" confirmation. Document what you did.
- **Ask before destructive operations.** Any `DROP`, `DELETE`, `git reset --hard`, `git push --force`, or similar gets explicit confirmation.
- **Save tokens.** Don't generate Excel, screenshots, or markdown files unless asked. Spend context on engineering.
- **Critical reasoning over agreement.** Fred values pushback. If his proposal has a flaw, say so — with reasoning, not deference.

### With Viktor (the AI coworker in Slack)

- **Ask Viktor first on dev changes.** New tables, new FKs, column renames, Edge Function logic. Tests and probes don't need his consent.
- **Critically reason on his replies.** Viktor has strong cognitive responses but sometimes uses wrong column names. Always verify against [docs/schema.md](docs/schema.md).
- **Poll cadence.** Check for replies every 3 minutes, max 3 attempts (9 min total). If no reply, move on — Fred has final say.
- **Slack channel:** `#viktor-supabase` (ID `C0B08S21HHD` — recreated 2026-04-29 21:31 CEST; the prior `C0AN9KDP5B8` is dead).
- **When Fred messages Viktor, always schedule a 3-min polling cron.** Per Fred's standing instruction.

### With Yan (founder)

- Yan owns strategy, budget, and business rules. Fred owns architecture and implementation. Route questions accordingly.

---

## What I can assume about the environment

- **OS:** Windows (Fred's machine). Use forward-slash paths inside code strings, but absolute paths in tool calls use `C:\Users\FRED\Desktop\Virtrify\Yannick\Claude\Supabase\...`.
- **Node ≥ 20**, npm, Supabase CLI, `gh` CLI (authed via keyring — never embed PATs in URLs).
- **Supabase project:** `wbasvhvvismukaqdnouk`. Pro plan. Single region (US East).
- **Current date:** 2026-04-27. May 2026 Jobber/Airtable sunset is ~3 weeks out.
- **No QuickBooks**, no Ramp integration in this DB. See [ADR 006](docs/decisions/006-no-quickbooks.md).

---

## Quick reference: column-name gotchas

Full table in [`docs/operations.md`](docs/operations.md#column-name-gotchas). The ones agents repeatedly get wrong:

| Wrong | Right | Table |
|---|---|---|
| `c.active = true` | `c.status = 'ACTIVE'` | clients |
| `e.name` | `e.full_name` | employees |
| `v.status` | `v.visit_status` | visits |
| `v.is_complete` | `(v.visit_status = 'COMPLETED')` or use `visits_with_status` | visits (dropped 2026-04-20) |
| `sc.next_visit`, `sc.status` | Use `clients_due_service` view (computed on read) | service_configs (dropped 2026-04-20) |
| `m.manifest_number` | `m.white_manifest_number` | derm_manifests |
| `v.tank_capacity_gallons` | `v.fuel_tank_capacity_gallons` or `v.grease_tank_capacity_gallons` | vehicles |
| `visit_photos`, `inspection_photos` | `photos` + `photo_links` (unified) | photos (dropped 2026-04-20) |

### Truck names are NOT people

- **Moises, David, Goliath** — trucks. Not technicians.
- **Cloggy** — truck. The only daytime-only truck.

Never respond to "David did the visit" as if David is a person without checking [docs/operations.md](docs/operations.md#truck-name--person-name).

### Overnight shifts

Commercial trucks work 10pm–3am as standard. `visit_date` is the logical operating date, not the clock date of `start_at`. Use ±12h windows or `visit_date` explicitly. Details in [operations.md](docs/operations.md#overnight-shift-handling).

---

## Known blockers (as of 2026-04-30)

Summarized; full details in [docs/runbook.md §6](docs/runbook.md#6-outstanding-population-gaps) and the latest AUDIT files.

| Blocker | Status | Tracking |
|---|---|---|
| **🆕 Full wipe + repop 2026-04-29** | ✅ **Done.** Cross-source visit dedup successful: 377 AT visits merged into Jobber rows, 2,081 AT-only historical kept standalone, 1,807 Jobber-canonical. Total visits 3,888. Inspections from Airtable PRE-POST: 242 rows. | This file + populate.js + ADR 011 |
| **🆕 Frequency multiplier bug fixed 2026-04-30** | ✅ populate.js step 5 was multiplying GT/CL frequencies by 30 (assuming months); Airtable actually stores days. Result: 201 service_configs had 30× inflated values. After `freqMul: 1` fix + step-5 re-run, only 4 outliers + 2 zeros remain (real Airtable data errors for Yan to fix). | [scripts/populate/populate.js:676](scripts/populate/populate.js) |
| **🆕 Dormant tables dropped 2026-04-30** | ✅ `routes`, `route_stops`, `receivables`, `leads`, `expenses` removed from schema. Routing → Viktor skill, past-due → Jobber `invoices`, leads → Odoo, expenses → Ramp. | [scripts/migrations/drop_dormant_tables_2026_04_30.sql](scripts/migrations/drop_dormant_tables_2026_04_30.sql) |
| **🆕 Samsara telemetry polling 2026-04-30** | ✅ New cron `cron_samsara_telemetry.js` runs every 10 min, pulls `/fleet/vehicles/stats?types=engineStates,fuelPercents,obdOdometerMeters,gps`. Schema migration added lat/lng/speed/heading columns + `UNIQUE(vehicle_id, recorded_at)`. Tested locally — 3 trucks reporting. Started collecting historical telemetry now so fuel/water-burn model has data when built. | [.github/workflows/samsara-poll.yml](.github/workflows/samsara-poll.yml) + [scripts/sync/cron_samsara_telemetry.js](scripts/sync/cron_samsara_telemetry.js) |
| **Live sync — Airtable** | ✅ Fully live since 2026-04-23. 10 automations on 5 tables. Token rotated 2026-04-28. | [docs/airtable-automation-setup.md](docs/airtable-automation-setup.md) |
| **Live sync — Samsara** | ✅ **Working** — 296 webhook events processed (address/driver/alert events). Vehicle stats covered by polling cron, NOT webhooks (Samsara doesn't offer webhooks for stats). | [supabase/functions/webhook-samsara/index.ts](supabase/functions/webhook-samsara/index.ts) + samsara-poll workflow |
| **Live sync — Jobber** | 🟡 Polling fallback every 2 min via GitHub Actions (works fine). Real webhook delivery still intermittent — Jobber Support replied 2026-04-29 saying their own webhook logs aren't fully functional, suggested testing with webhook.site. In-Development vs Published apps make zero delivery difference per support. | [.github/workflows/jobber-poll.yml](.github/workflows/jobber-poll.yml) |
| **Repo public 2026-04-28** | ✅ Token rotation done. 0 leaks. GitHub Actions free unlimited. | — |
| **Daily DB hygiene** | ✅ Shipped 2026-04-28. `daily-cleanup.yml` runs 09:00 UTC. | [scripts/sync/daily_cleanup.js](scripts/sync/daily_cleanup.js) |
| **Cross-session Jobber token sync** | ✅ Fixed 2026-04-25. | [scripts/sync/jobber_token.js](scripts/sync/jobber_token.js) |
| **Supabase security alerts** | ✅ All cleared 2026-04-25/27. RLS, security_invoker views, FK indexes done. | — |
| **Jobber notes + photos re-migration (2026-04-29)** | 🟡 **Running in background.** First run got to client 264/425 + 692 notes / 2,800 photos before HTTP timeout. Resumed 2026-04-29 from sync_cursors checkpoint. | [scripts/migrate/jobber_notes_photos.js](scripts/migrate/jobber_notes_photos.js) |
| 35 oversized attachments | ⚠️ Local backup in `oversized_backup/` (3.4 GB) — Jobber signed URLs expired. After photo re-migration finishes, separate one-shot will re-import these from local backup. | [scripts/migrate/rescue_oversized.js](scripts/migrate/rescue_oversized.js) |
| Fillout source | ✅ **DROPPED 2026-04-29.** All inspection ingestion moved to Airtable PRE-POST. `pullFillout`, `cache.fillout`, `_fillout_name` employee fields, `employeeByFilloutName` idmap all removed from populate.js. | populate.js |
| `completed_by` text resolution post-repop | 🟡 Airtable Visits table has no `Completed By`/`Driver` field — confirmed 2026-04-30 via field schema audit. Pre-Jobber driver attribution genuinely unrecoverable. Dead `Completed By`/`Driver` reads removed from populate.js step 10b. | populate.js step 10b |
| Yan's Airtable fix list | ⚠️ 6 service_configs need correction in Airtable: 005-BUB GT=0, 167-FEN CL=0, 021-GRA GT/CL=360/364, 002-41 GT=300, 056-STM CL=240. After Yan fixes, re-run `populate.js --step=5`. | docs/runbook.md (TODO add section) |

---

## Documentation map

**Always check these before asking a question or making an assumption:**

| Doc | Use when… |
|---|---|
| [README.md](README.md) | First-time orientation |
| **CLAUDE.md** (this file) | Every session start. Rules + quick reference. |
| [docs/schema.md](docs/schema.md) | Looking up a column, constraint, or view |
| [docs/architecture.md](docs/architecture.md) | Reasoning about data flow or source systems |
| [docs/operations.md](docs/operations.md) | Writing a query or report — gotchas, patterns |
| [docs/runbook.md](docs/runbook.md) | Something is broken; or doing a deploy/migration |
| [docs/integration.md](docs/integration.md) | Edge Function contracts, webhook registration, rate limits |
| [docs/security.md](docs/security.md) | Secrets, tokens, access control, rotation |
| [docs/migration-plan.md](docs/migration-plan.md) | May 2026 sunset, Odoo.sh cutover |
| [docs/company.md](docs/company.md) | Business context: fleet, clients, compliance, people |
| [docs/onboarding.md](docs/onboarding.md) | New to the project (first hour / day / week) |
| [docs/duplication-guide.md](docs/duplication-guide.md) | Cloning the project to a new Supabase from zero |
| [docs/decisions/](docs/decisions/) | Architecture Decision Records — *why* something is the way it is |
| [AUDIT_2026-04-27.md](AUDIT_2026-04-27.md) · [AUDIT_2026-04-28.md](AUDIT_2026-04-28.md) | End-to-end audit snapshots — read the latest first |

---

## Project layout

```
.
├── CLAUDE.md                   ← this file
├── README.md                   ← elevator pitch + quickstart
├── .env.example                ← credential template
├── docs/                       ← all project documentation
│   ├── architecture.md
│   ├── schema.md
│   ├── operations.md
│   ├── runbook.md
│   ├── integration.md
│   ├── security.md
│   ├── migration-plan.md
│   ├── company.md
│   ├── onboarding.md
│   └── decisions/              ← 8 ADRs
├── schema/
│   └── v2_schema.sql           ← canonical DDL
├── scripts/
│   ├── jobber_auth.js          ← one-time OAuth bootstrap
│   ├── probe.js                ← sanity check
│   ├── populate/               ← bulk population orchestrator (one-shot)
│   ├── migrations/             ← SQL migrations
│   └── webhooks/               ← webhook registration scripts
└── supabase/
    └── functions/
        ├── webhook-jobber/     ← Jobber events
        ├── webhook-samsara/    ← Samsara events
        ├── webhook-airtable/   ← Airtable events
        └── _shared/            ← shared helpers
```

---

## Commit & PR conventions

- **Subject line under 70 characters.** Imperative mood ("Add X", "Fix Y", "Remove Z"). Not "Added", not "Fixing".
- **Body explains the *why*, not the *what*.** The diff shows what; the body tells the future reader why it was needed.
- **Co-author line** required on commits authored by Claude:
  ```
  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  ```
- **Never skip hooks** (`--no-verify`, `--no-gpg-sign`) unless Fred explicitly asks.
- **Never force-push to main.**
- **Destructive operations** (reset --hard, push --force, checkout --) only with explicit Fred approval.

---

## When you're not sure

1. **Re-read this file** — 80% of mistakes come from forgetting a rule above.
2. **Grep the codebase** before asking a question.
3. **Check `docs/`** — the answer is usually there.
4. **Check `webhook_events_log`** for data-path questions.
5. **Ask Viktor** for source-data questions.
6. **Ask Fred** for architecture questions. He is the final word.

---

*Every structural change to schema, architecture, or sync must update this file and/or the relevant `docs/` file. Documentation is not an afterthought — it's how we keep a small team fast. If you ship code without updating docs, you shipped half the work.*
