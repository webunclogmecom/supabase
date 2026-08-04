# CLAUDE.md — AI Agent Operating Manual

**Unclogme Centralized Database (v2)** · *Maintained by Fred Zerpa · Last updated 2026-05-17*

Non-negotiable rules + quick reference for any AI agent working on this repo. **Read every session before touching anything.** Everything else is in [`docs/`](docs/).

---

## What this project is

Single source-of-truth Postgres warehouse for Unclogme LLC on Supabase project `wbasvhvvismukaqdnouk`. Webhooks from Jobber and Samsara land in Edge Functions and normalize into a 28-table 2NF/3NF schema. The third handler, `webhook-airtable`, is retired: Airtable was fully retired 2026-07-24 and is no longer a live inbound feed. Cross-system IDs live in one polymorphic bridge table (`entity_source_links`) — never as source-prefixed columns. Jobber + Airtable visit-gen sunset May 2026 (visit-gen already done 2026-05-13). **DERM capture moved to the DERM Tracker app** — it writes `derm_manifests` directly to Supabase; Airtable is retired for DERM, and as of **2026-07-21 that is finally true in code**: `'derm_manifest'` was removed from `ENTITY_TO_HANDLER` in `webhook-airtable` (Fred's explicit call). ⚠ **The 2026-06-26 "verified" note was wrong and is a lesson worth keeping**: it checked that *recent inserts* carried `app_source='derm-tracker'`, which they did, and concluded the feed was dead. The handler was still wired and still fired **55 times in the 30 days to 2026-07-14**, inserting manifests with a NULL `disposal_facility_id` (a column that appeared nowhere in that file) and wiping dump dates via null-valued keys in its `.update(row)`. **Absence of recent bad rows is not absence of a live writer** (they had been backfilled away). To retire a feed, cut the dispatch and prove a synthetic event returns `skipped`, don't infer it from data. Severing also ended Airtable PDF doc-mirroring (accepted: 545/546 live manifests already mirrored, 0 point at Airtable); stray events now land in `webhook_events_log` as `status='skipped'` rather than vanishing. **⚠ AIRTABLE IS FULLY RETIRED — we do not use Airtable anymore (Fred, 2026-07-24).** Never read it, write it, reference it, or cite an "Airtable / AT sunset" as a reason to defer or gate ANY work — that gate no longer exists. Airtable is not a live dependency of anything. Its last inbound feed, PRE-POST `inspections` via `webhook-airtable`, has gone quiet (last DB write **2026-07-14**; inbound events stopped ~2026-07-15) — treat it as dead, not live. (The Admin Review app remains the inspections review surface, reading canonical Supabase, not Airtable.) `derm_manifests` were already severed from Airtable in code 2026-07-21. **Odoo.sh is DROPPED (Fred 2026-07-08)** — CRM/client management moves to in-house apps (the planned "Client App" is slated to become the client-data master; Jobber sunset expected ~Aug-Sep 2026); Samsara is permanent.

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
- **DO NOT use Airtable, full stop (hard rule: Fred 2026-06-30, hardened 2026-07-24 when Airtable was fully retired).** Airtable is not merely stale, it is dead: never read it, write it, or use it as a source or reference for a task. Use Jobber / Samsara / the Supabase DB instead, or ask Fred. This overrides the "best-effort enrichment" latitude below.
- **Airtable = FULLY RETIRED, not a data source (Fred, 2026-07-24).** We do not use Airtable anymore — **no live inbound feed remains** (PRE-POST `inspections` went quiet, last write 2026-07-14; `derm_manifests` severed in code 2026-07-21). Do not read/write/reference it, and **never cite an "AT sunset" as a reason to defer work — that gate is gone; schedule the work on its own internal merits.** (Historically it was best-effort enrichment for service configs + client zone/hours/days/county; all superseded by Jobber / Samsara / the DB.)
- **`ops.*` merge views** COALESCE Jobber-first over Samsara. Any Airtable-sourced column one of them still falls back to is frozen history, not a live feed (Airtable fully retired 2026-07-24).
- Dropped sources: Fillout (entirely), and **Airtable (entirely, retired 2026-07-24)**. Drivers&Team/Past due/Route Creation/Leads were dropped earlier than the rest, but nothing from Airtable is live now, so do not read this line as implying any AT table survived.

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

**🛑 DO NOT TRUST A HAND-MAINTAINED LIST HERE — GENERATE IT.** This spot used to carry a list of 15
table names. **The real audited set was 31**, and the 16 omissions included **`public.zones` and
`public.gdos`**, the two tables that two separate 2026-07-29 arguments leaned on for recoverability.
Since §5.5(b) below tells you to *confirm a table is audited before treating audit silence as
evidence*, a stale list here manufactures the exact false negative that rule exists to prevent.
Always run:

```sql
select n.nspname||'.'||c.relname as audited_table
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_namespace n on n.oid = c.relnamespace
join pg_proc p on p.oid = t.tgfoid
join pg_namespace pn on pn.oid = p.pronamespace
where pn.nspname = 'audit' and p.proname = 'log_change' and not t.tgisinternal
order by 1;
```

Measured 2026-07-30: **31 tables** — 26 in `public`, 4 in `derm`
(`address_row_map`, `address_sheet_manifests`, `address_sheets`, `stamp_sheet_status`), 1 in `client`
(`saved_views`). See ADR 010 for the exclusion list + rationale.

⚠ **`client.saved_views` was opted in 2026-07-29 (Fred approved, `2026-07-29_2236`)** and the reason is
worth keeping: it is the ONE documented direct-write exception for the Client App (no SECDEF RPC),
justified on it being "the user's own UI preferences". **`is_shared` broke that justification** — a
shared view drives what a *different* staff member sees, so a rename/reshare/delete is cross-user state.
Before the trigger, `audit.logs` held **0** rows for it, which was a false all-clear of exactly the
§5.5(b) kind: nothing was watching, so provenance had to come from `owner_user_id`. Probed as
`SET LOCAL ROLE authenticated` before shipping: INSERT, UPDATE and DELETE all captured with
`table_schema='client'`.
*(A correction: the commit that added it claimed it was "the first audited table outside `public`".
That was false — the four `derm.*` tables above have carried the trigger since 2026-07-01. It is the
first outside `public` **for the Client App**, nothing more.)*

After ANY change to Prod schema, re-check this rule before declaring the migration done.

#### App-source attribution (added 2026-05-23 — see [ADR 016](docs/decisions/016-audit-app-source-attribution.md))

Every audit row now carries `app_source` and `request_context`. To find "who wrote this":
- `app_source = 'derm-tracker'` — DERM Tracker UI (derm.unclogme.app)
- `app_source = 'field-portal'` — Field Portal (fp.unclogme.app)
- `app_source = 'admin-review'` — Admin Review (**`admin.unclogme.app`** since 2026-08-04; previously
  `review.unclogme.app`, and before that `grease-buddy-dash`). ⚠ It moved because Yannick's new **Review
  Builder** app took **`reviews.unclogme.app`** (plural) and the two hosts read almost identically. All
  three Admin Review hosts stay mapped in the CASE so historical rows keep their meaning and a rollback
  is free. **`reviews.unclogme.app` is a DIFFERENT APP** and maps to `review-builder`; it runs on its own
  Supabase project (`rkgzdvktclalevibuubb`), not Prod, so that branch is a guard and never fires today.
  - ⚠ **HISTORICAL GAP 2026-07-03 → 2026-07-29: these writes landed as `other:review.unclogme.app`, NOT `admin-review`.** The app moved to its custom domain but the trigger's CASE still matched only `%grease-buddy-dash%`, so 232 rows across 4 tables fell through to the `other:` branch. Fixed forward in `2026-07-29c`; **the historical rows were deliberately NOT relabelled** (an audit trail is a record of what was observed, and rewriting it needs Fred's explicit OK). **When running the §5.5(b) "is this grant still used" check over historical data, query `app_source IN ('admin-review','other:review.unclogme.app')` or you will conclude the app went dead on 2026-07-08 when it is writing today.** This is the §5.5(b) detector failing in exactly the way §5.5(b) exists to prevent — see also the `X-App-Source` caveat below.
- `app_source = 'visit-calendar'` — Visit Calendar Lovable preview
- `app_source = 'send-derm-email'` — the DERM email edge fn ("Send DERM to city/clients"); the row also carries `sent_by_email`/`sent_by_user_id` (the human who clicked, from the app-forwarded JWT — 2026-07-21h)
- `app_source = 'gdo-report-bot'` — the Automated GDO Reporting bot (rpa-derm-queue/result edge fns; 2026-07-21i). Machine actor, not a person. **⚠ Before answering anything about how/when this bot RUNS, read [docs/reference/gdo-rpa-bot-triggers.md](docs/reference/gdo-rpa-bot-triggers.md)** — John's own doc, verbatim. It runs on HIS Railway deployment, not ours. Three traps that catch people: it has **3 triggers, not 1** (webhook, a **60-minute poll that uses the LIVE queue**, and an 8 AM EST Slack digest), `SHADOW_MODE=true` **forces every run to dry-run regardless of the URL**, and `?dry_run=true` hits a **separate 25-item QA queue** rather than production.
- `app_source = 'sql'` — direct Management API / psql / scripts (no PostgREST context)
- `app_source = 'other:<host>'` — unmapped origin (add to the trigger CASE when an app subdomain is added)
- explicit `X-App-Source: <name>` header overrides everything — use for scripts, bots, one-off curl
- ⚠ **DO NOT ASSUME AN APP'S `X-App-Source` HEADER COVERS ITS WRITES.** An app can build more than one Supabase client, and the header is per-client. Admin Review set `X-App-Source: admin-review` on **only** its secondary (legacy "prod mirror") client; the client that performed the writes that actually landed sent no header at all, so attribution fell through to the Origin CASE — which was stale.
  - 🛑 **THAT DESCRIPTION IS NOW HISTORICAL, AND THE RISK HAS INVERTED (measured 2026-08-04).** Since **2026-07-28 19:18 ET** every `admin-review` write carries `app_source_hint=admin-review`, so attribution today rides on the **header**, with the Origin CASE as the backup. That is the reverse of the sentence above. Keep both correct: the header is per-client and can silently disappear on a rebuild, the CASE is per-host and silently breaks on a domain move. **Neither alone is trustworthy.**
  - 🛑 **VERIFYING A DOMAIN MOVE: `app_source` CANNOT ANSWER IT.** After a move, both the old and new hosts are deliberately mapped to the SAME label, so grouping by `app_source` shows nothing changed. Group by the origin instead:
    `select request_context->>'origin', count(*), max(changed_at) from audit.logs where app_source='admin-review' group by 1;`
    Measured 2026-08-04 after the `review.unclogme.app` → `admin.unclogme.app` move: **zero rows have ever originated from the new host.** The branch is proven correct against the live function, but has never fired on real traffic. ⚠ And because the writing client now sends the header, a casual click is labelled by the header and does **not** exercise the Origin branch at all — so check the recorded `origin`, not the label. **Origin-based mapping is the durable source and the header is the override, so keep the CASE correct even for apps that "have a header."** As of `2026-07-29c` the CASE pins all four custom domains (`review` / `studio` / `dump` / `clients`.unclogme.app) so a header removal cannot silently open a new `other:` bucket. Specific hosts MUST stay above the `%lovable.app%` catch-all.

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
  - **Prod** `wbasvhvvismukaqdnouk` — source of truth, Pro plan, RLS hardened. **The staff Lovable apps Visit Calendar, Admin Review, DERM Tracker, and the Client App (`clients.unclogme.app`, 2026-07-24) are Supabase-Auth-gated (Google + email/pw, `@ayache.com`/`@unclogme.com`-restricted, email-confirm enforced). ✅ **DERM Stamp Studio IS NOW AUTH-GATED TOO (changed 2026-07-30, supersedes the 2026-07-24 "it is PUBLIC" note).** It moved to **`stamp.unclogme.app`** (`studio.unclogme.app` redirects there) and serves the canonical Command Deck login. Verified live 2026-07-30 while signed in: "Sign out" in the header, and the bundle builds ONE client with `db:{schema:'derm'}` + `persistSession`/`autoRefreshToken` and carries `signInWithPassword`/`signInWithOAuth`. **⇒ Its reads run as `authenticated`, so an anon-key replay of its requests correctly returns `42501` — that is the revoke working, NOT a broken app.** A session hit exactly that on 2026-07-30 and read "anon is revoked yet the public app renders" as a contradiction; the premise had simply expired. ⚠ **`audit.log_change`'s Origin CASE still pins only `%studio.unclogme.app%` and has NO pattern for `stamp.unclogme.app`** — measured 16 rows already arriving from the new origin, labelled correctly ONLY because the client sends `X-App-Source`. That is the per-client header dependency this file warns about below; pin the new host in the CASE.** **`visits` lifecycle is RPC-only as of Phase 3 (2026-07-11):** anon/authenticated can NO LONGER directly UPDATE `visit_status`/`completed_at`, nor EXECUTE the create/edit/delete/ripple/skip/unskip lifecycle RPCs (revoked in **both** `public.*` and `ops.*`); the Calendar drives lifecycle through the `set_visit_status` / `ops.set_visit_status` SECDEF wrappers (authenticated-only). **As of the 2026-07-12 anon-surface harden, anon is READ-ONLY on all business data** — it can no longer write any table/column or EXECUTE any write/exposure RPC (all revoked → authenticated + service_role; only FP `customer.*` reads + pure immutable helpers remain anon-callable). This also closed an owner-rights auto-updatable-view bypass of the Phase-3 visits lock (`v_visits_live`). Field Portal stays anon read-only. Full model + negative-test matrix: [docs/security.md](docs/security.md#publicvisits--anonauthenticated-write-model-2026-07-09-159e1c6).
  - **Sandbox #1 `ubtlwpcyntelgbykdatn` — DELETED 2026-06-11.** Verified zero consumers (0 API requests/7d; every Lovable app runs on Prod or Lovable Cloud; review data migrated to Prod canonical 2026-06-08). `sandbox-refresh.yml` retired (schedule removed + disabled); audit parity checks retired. Final backup of its unique tables: `..\backups\sandbox1_final_backup_2026-06-11.json` (parent folder, outside repo).
  - **HR Sandbox** `klgtrdwrasrlxbmfyvdh` (renamed from *Field Portal Sandbox*) — Yannick's **HR app** project (Field Portal app reads Prod directly since 2026-05-16). Legacy April-clone schema (keep as-is); data re-seeded fresh 2026-06-11 (full employees/vehicles/inspections + live subset visits). Also hosts the `frozen_leads` schema — don't touch. One-time-seed model, no periodic refresh.
  - **Client App Mirror** `mjxjhwxktedrrnochwli` (org Unclogme, created 2026-07-08) — hourly-refreshed full-snapshot mirror of Prod's client domain (19 tables) for the Client App build phase; Prod strictly read-only in the pipeline; ~$10/mo Micro. See [docs/reference/client-app-mirror.md](docs/reference/client-app-mirror.md).
- **Docs snapshot:** 2026-07-08. Visit-gen was cut over from Airtable 2026-05-13. **DERM: the DERM Tracker app writes `derm_manifests` directly; the Airtable handler was finally severed in code 2026-07-21** (the 2026-06-26 "verified" note was wrong, see the project summary above). **ZERO Airtable → Supabase automations remain.** PRE-POST `inspections` was the last one and it has gone quiet (last DB write 2026-07-14). Airtable is fully retired (Fred, 2026-07-24).

---

## ⚠ Grants, views and functions — the asymmetry that has bitten three times

**TABLES LAUNDER THROUGH AN OWNER-RIGHTS VIEW. FUNCTIONS DO NOT.**

A view owned by `postgres` with `reloptions = NULL` (i.e. **not** `security_invoker`) runs with the
OWNER's privileges, so a low-privilege caller can read base tables it holds no grant on. That is the
whole basis of the schema-per-app pattern — `customer.*`, `client.*`, `ops.*` all work this way.

**But a SECURITY INVOKER *function* called from inside that same view still executes with the
CALLER's privileges** and raises `42501` if the caller lacks SELECT on what the function touches.
The view laundering the table grant makes it look safe right up until the function fires. Three hits:

| Date | Object | What would have broken |
|---|---|---|
| 2026-07-28h | `fn_resolve_gdo_id` granted to `service_role` only | Visit Calendar 42501 for **every** staff user — caught by a rolled-back probe, not by reading the view |
| 2026-07-28t | `fn_visit_is_gdo_reporting` (INVOKER) inside `customer.gdo_reports` | Field Portal's GDO Permits section, customer-facing, on the `public` anon revoke |
| ongoing | any anon/authenticated-EXECUTE function that reads a table | the next one |

**Rules:**
- Before revoking a grant, test **every** view/RPC the affected role uses — not a sample. The Field
  Portal check passed clean on 4 of 9 views; only the full 9-view sweep found the break. **A passing
  partial check is not a passing check.**
- A helper called from an anon-reachable owner-rights view should be `SECURITY DEFINER` with a
  **pinned `search_path`** (pinning is the actual hardening; SECDEF without it is the footgun).
- Auditing "who can reach this data" means auditing function EXECUTE separately from table grants.
  `REVOKE ... ON ALL TABLES` does nothing to `EXECUTE`.
- Supabase's `ALTER DEFAULT PRIVILEGES` hands out grants nobody wrote: new tables in an exposed
  schema come out anon-readable, new `public` functions come out `authenticated`-EXECUTABLE. Check
  every new object, and revoke explicitly. (`derm.address_sheet_clients` and a SECDEF wrapper both
  needed this on 2026-07-28.)

### ✅ `public.zones_hard_delete` is INTENTIONAL admin tooling — do NOT "harden" it (settled 2026-07-29)

Recorded because it **looks** exactly like a finding and was flagged as one (by me) before being
measured. It is SECURITY DEFINER, `authenticated` can EXECUTE it, and it bulk-NULLs `properties.zone_id`
then hard-deletes a `zones` row. An auditor sees "any staff user can null 247 properties". The measured
picture says leave it:

- **It is careful, deliberate tooling**: `search_path` pinned to `public`, raises `no_data_found` on an
  unknown code, and **RETURNS `unlinked_properties`** so the caller sees the blast radius.
- **The delete is audited** (`zones` carries audit triggers; the function body says so), so a mistaken
  delete is recoverable from `audit.logs.old_row`. Reversible, not destructive.
- **Small and deliberate**: 11 zones exist, it takes an exact `code`, one zone per call, and there have
  been **2 deletes ever** across 64 zone audit rows.
- **Zones are a staff taxonomy, not client business data**, and staff already manage them
  (`app_source='visit-calendar'` is a recorded writer).
- Nulling `zone_id` when its zone is deleted is **correct cascade semantics**, not corruption — including
  for the Client App wave-1 surface that now edits `zone_id`.

The one real tension is rule #6 (never hard-delete). Narrowing it would require inventing a role model,
and **parent Building Apps rule #7 explicitly defers role-gated delete until auth roles land**, so
changing it now would be a policy decision rather than a fix. Revisit with the role work, not before.

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

### ⚠ `service_type` holds REAL SERVICE NAMES, and `service_kind` means two different things (2026-08-03)

**The `GT` / `CL` / `WD` / `LS` codes are RETIRED and are now REJECTED (`23514`).** `service_type` holds
`Pumping`, `Cleaning`, `Warranty of Drainage` and the rest of the catalogue taxonomy (11 values,
including **`Dump Offload`** — writing a CHECK from "the three recurring services" silently rejects 30
live visits). `service_configs` is held to the recurring three; `visits` allows the full set **and NULL**
(206 rows; NULL means not derivable and is the honest answer, never "default to Pumping").

**🛑 THE TRAP: `service_kind` is TWO DIFFERENT CONCEPTS.**

| Object | Meaning | Status |
|---|---|---|
| `public.service_line_items.service_kind` | was the service taxonomy | **DROPPED 2026-08-03** — use `service_type` |
| `ops.v_calendar_visit.service_kind` | **`SA` / `SC`** (Service Agreement vs Service Call) | **ALIVE — the most-read column in `ops`** |
| `ops.v_calendar_visit_detail`, `derm.v_stamp_unlinked_visits`, `derm.v_stamp_row_candidate_visits` | same SA/SC classifier | alive |

16 app queries read the SA/SC one, up to 4,186 calls each, and the Visit Calendar **equality-filters**
on it. **A find-and-replace on `service_kind` destroys it in four views with no error.** A name sweep
reports 10 objects when only **7** ever read the catalogue column. Rewrite only `sli.`-qualified
references; inspect every unqualified one by hand. This is also why `visits.service_type` was NOT
renamed to `service_kind` — the name was already taken with a different vocabulary.

**Also: `ops.fn_service_group`'s THIRD ARGUMENT is `location_target`, not `service_type`** (the
parameter is still *named* `p_type`; `CREATE OR REPLACE` cannot rename one while callers depend on it).
After the rename `service_type` reads `Pumping` for both grease trap and lift station, so it can no
longer split `PUMPING_GT` from `PUMPING_OTHER`. Passing `service_type` again repaints ~1,006 Calendar
chips silently.

**Full spec — read it before touching either name:**
[docs/reference/service-type-vocabulary.md](docs/reference/service-type-vocabulary.md).

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

### Overnight shifts → the operating-date rule (visit_date = ET CLOCK date; 06:00 cutoff REMOVED 2026-07-02)
Commercial overnight routes run ~8 PM into the next ~6 AM, but **`visit_date` is simply the ET CLOCK date of `start_at`**: `(start_at AT TIME ZONE 'America/New_York')::date`. The "operating night / which-shift" idea is **metadata for understanding only and does NOT move the date** (Fred 2026-07-02); this matches Jobber. ONE canonical derivation, shared by `webhook-jobber.operatingDateET`, `scripts/lib/operating_date_et.js`, and the live DB BEFORE trigger `fn_reconcile_visit_operating_date` (Branch 3 = `visit_date := (start_at AT TIME ZONE 'America/New_York')::date`).
- `start_at` NULL → all-day; `visit_date` stands (authoritative).
- otherwise → `visit_date` = the ET clock date of `start_at`. An early-AM (00:00 to 05:59 ET) visit KEEPS its own clock date (a 2 AM ET visit on Jun 30 is `visit_date` = Jun 30, NOT the prior night).

⚠ **The old 06:00-ET "operating night" cutoff (early-AM shifted to the PRIOR date) was REMOVED 2026-07-02.** Do NOT reintroduce it, and do NOT flag a correct early-AM `visit_date` (which equals its ET clock date) as a timezone bug. Two traps that caused the 2026-07-09 ±1-day oscillation: (1) a raw UTC slice `startAt.slice(0,10)` is +1 day for evening-ET visits (20:00 to 23:59 ET = 00:00 to 03:59 Z next day); (2) re-adding the 06:00 cutoff. Never write `visit_date` standalone: co-write it with a `start_at` change, or write `start_at` and let the trigger derive it. Full spec: [docs/reference/operating-date-rule.md](docs/reference/operating-date-rule.md).

**Consequence for the apps (Calendar):** the Calendar / `visit_date` = Jobber's clock date for BOTH evening and early-AM visits (they agree). There is no longer an intentional early-AM "prior night" gap.

**Safeguards (2026-07-01):** the BEFORE trigger `trg_aa_reconcile_operating_date` keeps the `visit_date`↔`start_at` pair consistent both ways (start_at write → derive date; pure date-drag → move start_at's day, keep the ET wall-clock). The old `handleVisit` +1 bug (took the UTC date-slice) is fixed; `ripple_reschedule_visit` now shifts days in ET (DST-safe). Always query with `visit_date` explicitly. Full spec: [docs/reference/operating-date-rule.md](docs/reference/operating-date-rule.md).

### `clients.status` values
`ACTIVE`, `RECURRING`, `PAUSED`, `INACTIVE`. AT's old `Recuring` (one r) was a typo — normalized 2026-05-13. populate.js + ops views all use `RECURRING`.

**⚠ `status='RECURRING'` does NOT mean the client generates visits.** Visit-gen keys off the JOB, not the client flag: a client generates SA visits only if it has an active, `frequency_days>0`, non-`[OLD]` `Service Agreement%` job carrying a **physical-service** line item (any SA/SC code **except 08**). Code 08 is excluded in the `public.fn_generate_sa_visits` job predicate (it lived in `generate_service_agreement_visits.js` until the 2026-08-01 port), which keys on `service_line_items.reason IN ('Service Agreement','Service Call') AND code <> '08'` (Fred/Yan 2026-07-02; code 08 wrongly had `service_type='WD'` — the legacy code, today `'Warranty of Drainage'` — so the pumping default made phantom visits). So a Warranty-of-Drainage-only client (code 08 + fees 25/26) **correctly has zero SCHEDULED recurring visits even while `status='RECURRING'`** — don't flag it as a scheduling gap.

> 🛑 **CORRECTED 2026-07-31 (Fred) — "code 08 generates NO visits" was too strong and this file used to say it.** The accurate rule is **no RECURRING visits**. Read it the old way and a legitimate warranty visit looks like corruption to the next person auditing.
> **What Warranty of Drainage actually is:** a **subscription** — the client pays a recurring fee so that, *in addition to* their regular scheduled visits, we come out if they think their grease trap is clogged. **That call-out IS a real visit**, booked ad-hoc as a **Service Call, normally at $0** because the subscription already covers it. Live examples: `132-PUM` and `021-GRA` carry **$0** visit-scoped 08 lines; `191-TEN` bills its warranty visits at **$120** each (a sanctioned variant — Fred 2026-07-31).
> **THE PRECISE RULE — it differs by LEVEL, and conflating the two is the trap (measured 2026-07-31):**
> | level | rule | evidence |
> |---|---|---|
> | a **WD-only JOB** (line 08 + fees only — the TCE shape) | **has NO visits at all**, recurring or ad-hoc | **71 of 71 such jobs carry 0 alive visits** |
> | code 08 as a **LINE ITEM on a visit** | **legitimate** — this is the call-out | 14 rows; they sit on *pumping/cleaning* jobs ("Grease Trap Pumping & Warranty" etc.), never on a WD-only job |
> ⇒ So "a WD-only job should have no visits" is TRUE and safe to assert. "Code 08 never appears on a visit" is FALSE and would delete real call-outs.
> ⇒ **`service_line_items.code='08'` is correctly `schedulable = true`. Do NOT "fix" it to false.** Besides being semantically right, `save-client-job` refuses any line item with `schedulable=false`, so flipping it would stop Warranty of Drainage being addable to a job at all. The no-recurring rule lives in the generator predicate, which is the right place for it.
> **Why TCE has a WD-only SA job:** they are invoiced for the warranty on a fixed day on its own cadence, so it is its own job rather than a line on their visit-generating SA. Both shapes are legal: WD as its own job, or WD as a line item inside an SA job alongside 01/02/04 — in the latter case the prices split by code (01-04 Pumping, 05-07 Cleaning, 08 Warranty). See [[project_client_app_billing_model]]. To confirm whether a client should get recurring visits, check its actual non-08 SA/SC line item (+ Yannick's SA-build list, which is no longer in Airtable since the 2026-07-24 retirement: ask Fred or Yannick for the current copy), not the status flag.

**⚠ `clients.status` itself is NOT authoritative for "recurring."** It flip-flopped via competing sync writers: an Airtable-`Recurring` mirror versus an ACTIVE-reset (True Barista's status ping-ponged ACTIVE↔RECURRING ~7× in May 2026, landing RECURRING by chance). The Airtable writer is gone since the 2026-07-24 retirement, so the value no longer moves on its own, but the values it left behind are still untrustworthy. **Authoritative rule (Fred 2026-07-15): a client is recurring ONLY if it's on Yannick's SA-build list OR Fred set it explicitly.** `clients.status = 'RECURRING'` but absent from that list ⇒ a *discrepancy*, not a recurring client (e.g. True Barista 209/212/213-TRUE, no SA job, one-off visits only). Many of those RECURRING values were mirrored from Airtable before it was retired; do not go looking for Airtable to confirm one, it is gone.

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

Historic workaround: `webhook-airtable` used to write the GDO Number to all `service_configs` rows
for the client (not just GT), and the 2026-05-25 backfill caught the historic gap. That feed is dead
(Airtable retired 2026-07-24), so nothing writes the GDO Number automatically today. Whatever writes
it next must keep the same write-to-all-rows behaviour.

### DERM link guards (added 2026-07-07 — read before writing `manifest_visits` or `derm_manifests`)

`public.manifest_visits` is guarded by BEFORE triggers that apply to **every** writer (apps, RPCs, scripts, backfills):
- **`trg_aa_link_same_client`** — REJECTS a link whose visit belongs to a different client than the manifest (the root cause of the 25 cross-client mis-links remediated 07-06/07). The sanctioned co-loaded-ticket path is **`public.file_manifest_on_shared_ticket(white#, client_id, visit_id)`** (files the client's own sibling manifest inheriting the shared sheet docs + links, idempotent).
- **`trg_ab_link_one_white`** — one white manifest # per visit (same-white sibling/consolidated-dump re-links allowed).
- **`trg_ac_link_visit_not_after_dump`** — REJECTS a link whose `visit_date > dump_ticket_date + 1 day` (grease is pumped BEFORE the dump; +1-day grace for entry noise / overnight operating-date timing). Blocks the fuzzy-linker "over-attach the client's NEXT visit" class. NULL dump passes.
- **`trg_zz_card_from_link`** (AFTER) — materializes the Stamp Studio card for the (ticket, client) on link.
- `public.derm_manifests` has **`CHECK service_date <= dump_ticket_date`** (grease dumps after service, never before).
- **`derm_manifests_dump_fields_present_chk` (NEW 2026-07-21): `dump_ticket_date` and `disposal_facility_id` may NOT be NULL.** Business rule (Fred): the DERM address manifest is only uploaded *after* it comes back from the city, by Diego, reading the finished paper sheet, so both values are printed on it at creation time. A manifest is born complete; linking visits is a separate later step. The three filing RPCs (`file_manifest`, `file_manifest_on_shared_ticket`, `derm.file_manifest_and_link`) now raise a readable **`22023`** first; a raw write gets **`23514`**. The constraint is deliberately **`NOT VALID`** (7 soft-deleted legacy rows carry a NULL facility) so `VALIDATE CONSTRAINT` fails **by design**, do not delete those rows to make it pass. ⚠ **Two traps when testing this:** (1) "0 NULLs today" proves nothing, that state was manufactured by a backfill of 387 rows on 2026-07-15 plus a *browser-side-only* form check; (2) `fn_derm_inherit_ticket_fields` silently heals a NULL from unanimous ticket siblings, so a random row always looks fine. **Test against a singleton ticket or a fresh number** (15 live rows are singletons) or you get a false pass. Migration: `docs/migrations/2026-07-21_derm_manifest_required_dump_fields.sql`.
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

> **`derm_required` is line-item-derived (2026-06-24, ADR 018), NOT `service_type`.** A visit needs DERM iff it has a *pumping* line item (codes 01–04/09–11); `service_type` is unreliable as a proxy — `handleVisit` falls back to a default when the line-item derive is non-concrete, and grey-water pumping was coded as cleaning. *(That default was `GT` and grey water was `CL` until the 2026-08-03 rename; today they read `Pumping` and `Cleaning`. The unreliability is unchanged — this is why the derive keys off line items, not off this column.)* Populated by `fn_visit_requires_derm` via the Calendar RPC, `handleVisit`, and nightly pg_cron `derm-required-rederive` (all monotonic — never demote a known TRUE; NULL = unknown = surfaced). Spec: [docs/reference/derm_required_by_line_item.md](docs/reference/derm_required_by_line_item.md).

To find a missing DERM link, work in the Supabase DB. **Airtable is fully retired (2026-07-24) and must not be read** — there is no AT DERM table to cross-reference any more:
1. **`derm_manifests`** — match on `white_manifest_number` + `client_id`, then compare `service_date` to the candidate visit's `visit_date`. Never match on `dump_ticket_date` alone: dump dates lag service dates by weeks.
2. **`clients.client_code`** — confirm the client matches (e.g. `010-CS`).
3. **`clients.name`** — confirm the name matches (e.g. `Chima Steakhouse`).

When all 3 align with a DB visit, link it through `public.file_manifest_on_shared_ticket(white#, client_id, visit_id)`, the sanctioned path (idempotent, and it satisfies the `manifest_visits` BEFORE-trigger guards documented above). A raw INSERT into `public.manifest_visits` (PK `(visit_id, manifest_id)`, audit trigger fires) is only for the client's own existing row.

Historical note: a one-off backfill, `scripts/sync/backfill_manifest_visits_via_at_visits_field.js`, walked every Airtable DERM record's `Visits` field, resolved the Airtable visit GID's date and matched the DB visit by client + date (±1 day). It caught 11 missed links on its first run (2026-05-22). **It is dead code: Airtable was retired 2026-07-24, so do not run it.**

Historical note on why those links were missed: `webhook-airtable`'s link logic keyed on `GT Last Visit` ±2 days, and that field drifted by weeks on jobs invoiced after the fact (Chima 010-CS visit 1511 on 3/18 had a DERM dumped 4/24, Airtable's `GT Last Visit` showed 4/20, 33 days off). That feed is gone: the handler was severed 2026-07-21 and Airtable was fully retired 2026-07-24. Manifests are filed in the DERM Tracker app and linked explicitly, so there is no weekly backfill to run and no webhook left to patch.

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
| [docs/migration-plan.md](docs/migration-plan.md) | Jobber sunset + cutover (⚠ two stale threads in that doc: Airtable's sunset is DONE, it was fully retired 2026-07-24, and Odoo was dropped 2026-07-08; successor = in-house Client App) |
| [docs/jobber-calendar-job-migration/jobs-visits-calendar-workflow.md](docs/jobber-calendar-job-migration/jobs-visits-calendar-workflow.md) | Jobs↔visits↔calendar workflow + 2026-06-23 restructure + the Calendar Create Visit DB layer |
| [docs/reference/service-type-vocabulary.md](docs/reference/service-type-vocabulary.md) | **Before touching `service_type` or `service_kind`** — the vocabulary, the two-meanings collision, and how to tell whether an app really reads a column |
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
