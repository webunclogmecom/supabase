# CLAUDE.md — AI Agent Operating Manual

**Unclogme Centralized Database (v2)** · *Maintained by Fred Zerpa · Last updated 2026-05-17*

Non-negotiable rules + quick reference for any AI agent working on this repo. **Read every session before touching anything.** Everything else is in [`docs/`](docs/).

---

## What this project is

Single source-of-truth Postgres warehouse for Unclogme LLC on Supabase project `wbasvhvvismukaqdnouk`. Webhooks from Jobber, Airtable, and Samsara land in three Edge Functions and normalize into a 28-table 2NF/3NF schema. Cross-system IDs live in one polymorphic bridge table (`entity_source_links`) — never as source-prefixed columns. Jobber + Airtable visit-gen sunset May 2026 (visit-gen already done 2026-05-13). **DERM capture moved to the DERM Tracker app** — it writes `derm_manifests` directly to Supabase; Airtable is retired for DERM (verified 2026-06-26: recent inserts are `app_source='derm-tracker'` with no Airtable source link). **PRE-POST inspections are now the ONLY live Airtable feed** — still ingested via `webhook-airtable` (the sole writer of `inspections`); the Admin Review app is their front-end / review surface, but the data still rides Airtable into Supabase. **Odoo.sh is DROPPED (Fred 2026-07-08)** — CRM/client management moves to in-house apps (the planned "Client App" is slated to become the client-data master; Jobber sunset expected ~Aug-Sep 2026); Samsara is permanent.

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
- **DO NOT use Airtable unless Fred EXPLICITLY tells you to (hard rule, Fred 2026-06-30).** Airtable is **stale / not up to date** — never read it, write it, or use it as a source or reference for a task. Use Jobber / Samsara / the Supabase DB instead, or ask Fred. This overrides the "best-effort enrichment" latitude below.
- **Airtable = best-effort enrichment, NOT authority.** As of 2026-06-26, Airtable's ONLY live inbound feed is **`inspections` (PRE-POST)** via `webhook-airtable` (its sole DB writer). **`derm_manifests` no longer come from Airtable** — the DERM Tracker app writes them directly (`app_source='derm-tracker'`; recent rows carry no Airtable source link). Service configs, client enrichment (zone, hours, days, county) — treat as suggestions. Airtable throws wrong data regularly; never let it override Jobber/Samsara.
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

Current audited set: clients, service_configs, properties, visits, photo_classifications, derm_manifests, manifest_visits *(opted in 2026-05-18 for DERM Tracker)*, disposal_facilities, vehicles, employees, webhook_tokens, derm_email_sends *(opted in 2026-06-04)*, municipality_regulators *(opted in 2026-06-05)*. See ADR 010 for the exclusion list + rationale.

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

### With Viktor (AI coworker in Slack) — on-demand only
- **Contact Viktor ONLY when Fred explicitly asks.** The old "ask Viktor first on every dev change + poll every 3 min for a reply" protocol is **retired (2026-06-09)** — no automatic consults, no auto-scheduled polling crons. Implement dev changes directly (modular, non-breaking, verified); Fred is the reviewer.
- If Fred DOES tell you to message Viktor: tag him `<@U0AKTMAMWP9>` in `#viktor-supabase` (`C0B08S21HHD`) and reason critically on his replies (he sometimes uses wrong column names — verify against [docs/schema.md](docs/schema.md)).

### With Yan (founder)
Yan owns strategy, budget, business rules. Fred owns architecture + implementation. Route accordingly.

---

## Environment

- **OS:** Windows. Use forward-slash inside code strings; tool calls use `C:\Users\FRED\Desktop\Virtrify\Yannick\Claude\Supabase\...`
- **Node ≥ 20**, npm, Supabase CLI, `gh` CLI (keyring-authed — never embed PATs in URLs).
- **Supabase projects (all in `Dev - Unclogme` org, us-east-1):**
  - **Prod** `wbasvhvvismukaqdnouk` — source of truth, Pro plan, RLS hardened. **The 4 staff Lovable apps (Visit Calendar, Admin Review, DERM Tracker, Stamp Studio) are Supabase-Auth-gated (Google + email/pw, `@ayache.com`/`@unclogme.com`-restricted, email-confirm enforced).** **`visits` lifecycle is RPC-only as of Phase 3 (2026-07-11):** anon/authenticated can NO LONGER directly UPDATE `visit_status`/`completed_at`, nor EXECUTE the create/edit/delete/ripple/skip/unskip lifecycle RPCs (revoked in **both** `public.*` and `ops.*`); the Calendar drives lifecycle through the `set_visit_status` / `ops.set_visit_status` SECDEF wrappers (authenticated-only). **As of the 2026-07-12 anon-surface harden, anon is READ-ONLY on all business data** — it can no longer write any table/column or EXECUTE any write/exposure RPC (all revoked → authenticated + service_role; only FP `customer.*` reads + pure immutable helpers remain anon-callable). This also closed an owner-rights auto-updatable-view bypass of the Phase-3 visits lock (`v_visits_live`). Field Portal stays anon read-only. Full model + negative-test matrix: [docs/security.md](docs/security.md#publicvisits--anonauthenticated-write-model-2026-07-09-159e1c6).
  - **Sandbox #1 `ubtlwpcyntelgbykdatn` — DELETED 2026-06-11.** Verified zero consumers (0 API requests/7d; every Lovable app runs on Prod or Lovable Cloud; review data migrated to Prod canonical 2026-06-08). `sandbox-refresh.yml` retired (schedule removed + disabled); audit parity checks retired. Final backup of its unique tables: `..\backups\sandbox1_final_backup_2026-06-11.json` (parent folder, outside repo).
  - **HR Sandbox** `klgtrdwrasrlxbmfyvdh` (renamed from *Field Portal Sandbox*) — Yannick's **HR app** project (Field Portal app reads Prod directly since 2026-05-16). Legacy April-clone schema (keep as-is); data re-seeded fresh 2026-06-11 (full employees/vehicles/inspections + live subset visits). Also hosts the `frozen_leads` schema — don't touch. One-time-seed model, no periodic refresh.
  - **Client App Mirror** `mjxjhwxktedrrnochwli` (org Unclogme, created 2026-07-08) — hourly-refreshed full-snapshot mirror of Prod's client domain (19 tables) for the Client App build phase; Prod strictly read-only in the pipeline; ~$10/mo Micro. See [docs/reference/client-app-mirror.md](docs/reference/client-app-mirror.md).
- **Docs snapshot:** 2026-07-08. Visit-gen sunset from AT 2026-05-13. **DERM AT automation retired — the DERM Tracker app now writes `derm_manifests` directly (verified 2026-06-26).** PRE-POST inspections (`webhook-airtable`) are the only AT → Supabase automation left.

---

## Column-name gotchas

Full table in [`docs/operations.md`](docs/operations.md#column-name-gotchas). Most-repeated mistakes:

| Wrong | Right | Table |
|---|---|---|
| `c.active = true` | `c.status = 'ACTIVE'` or `'RECURRING'` | clients |
| `e.name` | `e.full_name` | employees |
| `v.status` | `v.visit_status` | visits |
| `v.is_complete` | `(v.visit_status = 'completed')` *(lowercase — canonical value, verified 2026-05-18)* | visits |
| any `SELECT … FROM visits` | add `WHERE deleted_at IS NULL` *(soft-delete column added 2026-05-29 — see "Soft-delete on visits" below)* | visits |
| `sc.next_visit`, `sc.status` | Use `clients_due_service` view | service_configs (dropped 2026-04-20) |
| `m.manifest_number` | `m.white_manifest_number` | derm_manifests |
| `v.tank_capacity_gallons` | `v.fuel_tank_capacity_gallons` or `v.grease_tank_capacity_gallons` | vehicles |

### Soft-delete on visits (added 2026-05-29)

`public.visits.deleted_at TIMESTAMPTZ` is set by
`scripts/sync/cron_jobber_reconcile_anomalies.js` when Jobber returns
"Visit not found" for a stored GID (deleted upstream or converted to a Task).
**Every query against `visits` MUST filter `deleted_at IS NULL`**, otherwise
soft-deleted rows leak back into Calendar / Field Portal / DERM Tracker.

Already patched (2026-05-29): `ops.v_calendar_visit`, `customer.scheduled_visits`,
`public.manifest_pickable_visits`, `public.visits_with_status`.

**Canonical base view (2026-06-24): `public.v_visits_live` = `visits WHERE deleted_at IS NULL`.**
New ops/app views should read `v_visits_live`, NOT bare `public.visits`, so the soft-delete filter
can't be forgotten. FIXED 2026-06-24 (`2026-06-24_v_visits_live_softdelete.sql`): `ops.visits`,
`ops.v_route_today`, `ops.v_service_due`, `ops.v_truck_utilization`, `ops.v_driver_kpi`,
`ops.v_revenue_summary` re-pointed to it; `ops.v_derm_compliance` got the filter in the DERM migration.

Pending follow-up (low-impact): `public.visits_recent`, `public.visits_with_review`,
`customer.recommendations`, `customer.inspection_items`, `customer.wo_photos`, `customer.permits`
(`customer.work_orders` already filters). Re-point these at `v_visits_live` when touched.

Hard-delete is still forbidden in general (Rule 6) — `deleted_at` is the
canonical soft-delete pattern for visits. One-off hard-deletes for clearly
broken rows (e.g. completed-then-rescheduled visits ops cannot operate on)
require explicit Fred sign-off and run via a manual script (see
2026-05-29 visit 5146 009-CN repair for the audited pattern).

### Truck names are NOT people
**Moises, David, Goliath** — trucks. **Cloggy** — truck (only daytime-only one). Never respond to "David did the visit" as if David is a person without checking [docs/operations.md](docs/operations.md#truck-name--person-name).

### Overnight shifts → the operating-date rule (refined 2026-07-01)
Commercial overnight routes run **~8 PM into the next ~6 AM**, so **`visit_date` = the OPERATING NIGHT the route is FOR**, NOT the clock date of `start_at`. ONE canonical derivation, shared by `webhook-jobber.operatingDateET`, `sync-jobber-visit-drift.adoptTarget`, and the DB trigger `trg_aa_reconcile_operating_date` (`OVERNIGHT_CUTOFF = 06:00 ET`):
- `start_at` NULL, or ET time **00:00:00** (placeholder) → all-day; `visit_date` stands as the operating date.
- ET time **00:00:01–05:59** (early-AM) → the **PRIOR** ET date (it belongs to the prior night's route).
- evening / daytime → that ET date.

**Consequence for the apps (esp. Calendar):** evening visits → Calendar date = Jobber date (agree). **Early-AM visits (after midnight)** → the Calendar shows the **prior operating night** while Jobber shows the actual clock date a day later — **intentional, NOT a mismatch** (a 2 AM visit on Jun 30 belongs to the Jun 29 night → `visit_date` = Jun 29). Don't "fix" that gap.

**Safeguards (2026-07-01):** the BEFORE trigger `trg_aa_reconcile_operating_date` keeps the `visit_date`↔`start_at` pair consistent both ways (start_at write → derive date; pure date-drag → move start_at's day, keep the ET wall-clock). The old `handleVisit` +1 bug (took the UTC date-slice) is fixed; `ripple_reschedule_visit` now shifts days in ET (DST-safe). Always query with `visit_date` explicitly. Full spec: [docs/reference/operating-date-rule.md](docs/reference/operating-date-rule.md).

### `clients.status` values
`ACTIVE`, `RECURRING`, `PAUSED`, `INACTIVE`. AT's old `Recuring` (one r) was a typo — normalized 2026-05-13. populate.js + ops views all use `RECURRING`.

**⚠ `status='RECURRING'` does NOT mean the client generates visits.** Visit-gen keys off the JOB, not the client flag: a client generates SA visits only if it has an active, `frequency_days>0`, non-`[OLD]` `Service Agreement%` job carrying a **physical-service** line item (any SA/SC code **except 08**). **Code 08 "Warranty of Drainage" is a billing-only subscription — a recurring CHARGE, not a truck roll — and generates NO visits** (Fred/Yan 2026-07-02; code 08 wrongly had `service_type='WD'`, so the GT-default made phantom visits — now excluded in the `generate_service_agreement_visits.js` JOB_PREDICATE, which keys on `service_line_items.reason IN ('Service Agreement','Service Call') AND code <> '08'`). So a Warranty-of-Drainage-only client (code 08 + fees 25/26) **correctly has zero scheduled visits even while `status='RECURRING'`** — don't flag it as a scheduling gap. To confirm whether a client should get recurring visits, check its actual non-08 SA/SC line item (+ Yannick's SA-build list, Airtable base `app6TThMjeY1PRTrR` → `Job Line Items`), not the status flag.

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

### DERM link guards (added 2026-07-07 — read before writing `manifest_visits` or `derm_manifests`)

`public.manifest_visits` is guarded by BEFORE triggers that apply to **every** writer (apps, RPCs, scripts, backfills):
- **`trg_aa_link_same_client`** — REJECTS a link whose visit belongs to a different client than the manifest (the root cause of the 25 cross-client mis-links remediated 07-06/07). The sanctioned co-loaded-ticket path is **`public.file_manifest_on_shared_ticket(white#, client_id, visit_id)`** (files the client's own sibling manifest inheriting the shared sheet docs + links, idempotent).
- **`trg_ab_link_one_white`** — one white manifest # per visit (same-white sibling/consolidated-dump re-links allowed).
- **`trg_ac_link_visit_not_after_dump`** — REJECTS a link whose `visit_date > dump_ticket_date + 1 day` (grease is pumped BEFORE the dump; +1-day grace for entry noise / the 06:00-ET cutoff). Blocks the fuzzy-linker "over-attach the client's NEXT visit" class. NULL dump passes.
- **`trg_zz_card_from_link`** (AFTER) — materializes the Stamp Studio card for the (ticket, client) on link.
- `public.derm_manifests` has **`CHECK service_date <= dump_ticket_date`** (grease dumps after service, never before).
- **Soft-deleting a `derm_manifests` row re-points its Stamp cards** (`trg_ad_card_reptr_on_delete` → live (ticket,client) sibling, else NULL) and re-filing re-resolves them (`trg_resolve_card_manifest`) — so a delete+re-file never leaves a Stamp card pointing at a dead manifest (which would make it invisible). Writes only `derm.address_row_map`.

⚠ **Restore/backfill gotcha:** replaying a backup that contains an OLD cross-client pair now RAISES (BEFORE triggers fire before `ON CONFLICT`) and aborts the transaction — filter those pairs out first. Only 1 sanctioned legacy cross-client row exists (815064, pending Diego). Also: `trg_ae_ticket_key_unambiguous` RAISES when a white# collides with an existing yellow-only ticket key (or vice versa) — same filter-first rule for restores.

### FP Blackout — customer-safe redacted DERM sheets (added 2026-07-10, Fred-approved)

The Field Portal's "DERM FOG eManifest" card serves a **server-side redacted copy** of the shared
multi-client address sheet: only the viewing client's Stamp-Studio band + the form header/footer are
visible; the whole measured roster region is blacked. Pipeline: Studio stamps → vision measurement pass
(`derm.page_block_extents` = full-roster extent per page, ALL slots incl. empty) → line-snapped bands
(`derm.v_stamp_row_bands`, manual > derived) → `derm.fn_blackout_targets` (gates: fully-banded sheet,
measured extent REQUIRED, order-consistency, page-identity, staleness fingerprint) → edge fn
`redact-manifest-sheet` (service_role-only; EXIF-safe; deletes superseded files) → `manifests/redacted/*`
→ `customer.work_orders.derm_manifest_url` (client-checked join). pg_cron `redact-manifest-sweep` (*/5,
limit 1 — edge CPU cap). The WWTP receipt card serves the raw disposal receipt ONLY when its image URL
is vision-classified safe in `derm.receipt_doc_class` (97/97 verified receipts; new uploads hidden until
classified). ⚠ RULES: NEW stamped pages generate NOTHING until a measurement pass adds their extent
(rerun: export pages → `ocr-band-measure` workflow → `apply_bands.js`); NEVER widen the visible region
from banded-card math alone (that was the v2 leak, caught by Fred 2026-07-10 — see
`docs/audits/2026-07-10_ocr_band_refinement.md` + migrations `2026-07-10_fp_blackout_*.sql`).

### DERM 2-week rule (added 2026-05-22, per Fred)
**Any completed visit older than 2 weeks that needs DERM (i.e. `derm_required IS NOT false`) SHOULD have a `manifest_visits` row linking it to a `derm_manifests` record with both `derm_manifest_url` and `derm_address_url`.** If it doesn't, treat it as a data gap and investigate.

> **`derm_required` is line-item-derived (2026-06-24, ADR 018), NOT `service_type`.** A visit needs DERM iff it has a *pumping* line item (codes 01–04/09–11); `service_type='GT'` is unreliable (handleVisit defaults to GT; grey-water pumping is coded CL). Populated by `fn_visit_requires_derm` via the Calendar RPC, `handleVisit`, and nightly pg_cron `derm-required-rederive` (all monotonic — never demote a known TRUE; NULL = unknown = surfaced). Spec: [docs/reference/derm_required_by_line_item.md](docs/reference/derm_required_by_line_item.md).

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
| [docs/migration-plan.md](docs/migration-plan.md) | Jobber/AT sunset + cutover (⚠ Odoo references are stale — Odoo dropped 2026-07-08; successor = in-house Client App) |
| [docs/jobber-calendar-job-migration/jobs-visits-calendar-workflow.md](docs/jobber-calendar-job-migration/jobs-visits-calendar-workflow.md) | Jobs↔visits↔calendar workflow + 2026-06-23 restructure + the Calendar Create Visit DB layer |
| [docs/reference/line-item-lifecycle-and-jobber-edit-ripple.md](docs/reference/line-item-lifecycle-and-jobber-edit-ripple.md) | Line-item scopes; how scheduled vs completed visits reflect services; Jobber job-edit ripple + propagation |
| [docs/reports/sa-status-report.md](docs/reports/sa-status-report.md) | Regenerating the SA status report (coverage gaps + old open jobs PDF) |
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
- **Push every commit to origin** (updated 2026-05-27, per Fred). Fred pre-approves
  pushes to non-protected branches — no need to ask. Same trust model as the
  "no approval needed for routine actions" rule. Plain fast-forward `git push`
  only; force-push to `main` still requires explicit ask.
- **Never** skip hooks (`--no-verify`) or bypass signing without explicit ask.
- **Destructive ops** only with explicit Fred approval.

---

## When you're not sure

1. **Re-read this file** — 80% of mistakes are forgetting a rule above.
2. **Grep the codebase** before asking.
3. **Check `docs/`** — answer is usually there.
4. **Check `webhook_events_log`** for data-path questions.
5. **Ask Fred** for architecture + source-data questions. He is the final word (he loops in Viktor only if he chooses to).

---

*Every structural change to schema, architecture, or sync must update this file and/or relevant `docs/`. No drift between code and docs.*
