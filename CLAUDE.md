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

🛑 **WHEN A DELETE *IS* SANCTIONED, CHECK WHETHER THE TABLE IS AUDITED FIRST — THAT IS WHAT DECIDES
IF IT IS RECOVERABLE (2026-08-14).** The `zones_hard_delete` note below argues a delete is acceptable
partly *because* `zones` carries audit triggers, so `audit.logs.old_row` can restore it. **That
reasoning silently transfers to tables where it is false.** `public.entity_source_links` has **zero
triggers**: a DELETE there leaves **no record of any kind**, and the only recovery is a file you
remembered to write beforehand. Measured when Fred approved clearing 2 dead link rows; they were
backed up to `backups/` first, and that file is now the sole restore path.
⇒ Run the rule-8 trigger query against the specific table **before** deleting, and if it comes back
empty, write a JSON backup with a restore hint or do not proceed. Do not infer recoverability from
the fact that *other* tables in `public` are audited — the audited set is 31 tables, not all of them.
⇒ And pin the statement to primary keys **while re-asserting the predicate that made the rows
deletable** (`... WHERE id IN (...) AND NOT EXISTS (<the thing that makes it an orphan>)`), so it
cannot fire if the world changed between your read and your write.

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
  Builder** app took **`reviews.unclogme.app`** (plural) and the two hosts read almost identically.
  ⚠ **FOUR patterns map to `admin-review`, not three** (corrected 2026-08-07; the earlier "all three
  Admin Review hosts" wording undercounted). Read off `2026-08-04_1439`:
  `%admin.unclogme.app%`, `%audit.unclogme.app%`, `%grease-buddy-dash%`, `%review.unclogme.app%`.
  The old hosts stay mapped so historical rows keep their meaning and a rollback is free; **`audit.*`
  is a candidate replacement host pinned in ADVANCE** and has never served traffic, so Fred renaming
  the app again does not need a DB change. Do not "clean up" an arm because it has zero rows: that is
  the point of it. **`reviews.unclogme.app` is a DIFFERENT APP** and maps to `review-builder`; it runs on its own
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

#### 🛑 `anon` READS NOTHING TODAY, INCLUDING `customer.*`. "Field Portal stays anon read-only" is STALE (measured 2026-08-10)

Triggered by Lovable flagging *"Client contact details (phone, email) exposed publicly"* as a
**critical** issue on the Visit Calendar. **At the database layer that is not true.** Measured with
`has_table_privilege`, which does not depend on a role switch behaving:

| object | anon | authenticated |
|---|---|---|
| `public.clients`, `client_contacts`, `properties`, `visits` | **no** | yes |
| `ops.v_calendar_visit`, `ops.v_route_today` | **no** | yes |
| **all 9 `customer.*` views** | **no (0 of 9)** | yes |

Every `customer.*` view reads `authenticated=r` + `service_role=r` and nothing else.

⚠ **This contradicts two statements elsewhere in this file** ("Field Portal stays anon read-only",
"only FP `customer.*` reads + pure immutable helpers remain anon-callable"). The drift is in the
SAFE direction, the surface is tighter than documented, but a reader planning work on the assumption
that `anon` can serve the Field Portal would be wrong. **Do not widen anything back to `anon` on the
strength of those older lines without re-measuring.**

⚠ **HOW I NEARLY MISREAD THIS.** My first probe used `SET LOCAL ROLE anon` with `customer.clients`
as the must-pass control, on the assumption the docs were right. The control **failed**, and the
honest reading of a failed control is "the instrument is untrusted, conclude nothing". Re-measuring
with `has_table_privilege` showed the instrument was fine and **the control's PREMISE was wrong**.
A failing control means stop, not "the target is broken".

**Scope of that measurement, stated so nobody over-reads it:** it covers DB grants only. It does NOT
cover the PUBLIC storage buckets (`gdo-permits`, `manifests`, `GT - Visits Images` are all
`public: true`), edge functions running `verify_jwt = false`, or what a signed-in staff user can see
(which for an internal ops tool is the point). The Lovable finding is most likely the scanner
reasoning from client-side code without knowing about the auth gate, but **"the DB does not leak it"
is not the same claim as "nothing leaks it"**.

#### 🛑 `audit.logs.changed_by` HAS NEVER BEEN POPULATED. Read `jwt_claims->>'email'` instead (2026-08-07)

Measured across the whole table, with a control: **54,756 rows, `changed_by` non-null in 0 of them**,
`count(distinct changed_by) = 0`. The control is `app_source`, non-null on 49,551 rows in the same
query, so this is not a reader returning NULL for everything.

**Why:** `audit.log_change` reads `current_setting('request.jwt.claim.sub')`, **singular `claim`**.
PostgREST sets `request.jwt.claims` (plural, a JSON object). The singular key is never set, so the
column has been NULL since the trigger was written.

⚠ **Do not over-correct this into "audit.logs cannot tell us who did it."** It can, just not through
that column: `jwt_claims->>'email'` is populated on **4,578** rows. So the query is

```sql
select changed_at, table_name, operation, app_source, jwt_claims->>'email' as who
  from audit.logs where ... ;      -- NOT changed_by, which is always NULL
```

Two consequences worth carrying:
- Any past reasoning of the form *"audit.logs will record who did this"* that leaned on `changed_by`
  was wrong. Re-check anything that concluded a table was safe on that basis.
- `db_role` does not help either: `audit.log_change` is SECURITY DEFINER owned by `postgres` and
  stores `CURRENT_USER`, so **every** row reads `db_role = 'postgres'` regardless of the writing
  role. A write made as `authenticated` through PostgREST is captured (with `old_row` intact, so it
  is recoverable) but `db_role` will not reveal that a browser rather than an edge function did it.

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
  - **Prod** `wbasvhvvismukaqdnouk` — source of truth, Pro plan, RLS hardened. **The staff Lovable apps Visit Calendar, Admin Review, DERM Tracker, and the Client App (`clients.unclogme.app`, 2026-07-24) are Supabase-Auth-gated (Google + email/pw, `@ayache.com`/`@unclogme.com`-restricted, email-confirm enforced). ✅ **DERM Stamp Studio IS NOW AUTH-GATED TOO (changed 2026-07-30, supersedes the 2026-07-24 "it is PUBLIC" note).** It moved to **`stamp.unclogme.app`** (`studio.unclogme.app` redirects there) and serves the canonical Command Deck login. Verified live 2026-07-30 while signed in: "Sign out" in the header, and the bundle builds ONE client with `db:{schema:'derm'}` + `persistSession`/`autoRefreshToken` and carries `signInWithPassword`/`signInWithOAuth`. **⇒ Its reads run as `authenticated`, so an anon-key replay of its requests correctly returns `42501` — that is the revoke working, NOT a broken app.** A session hit exactly that on 2026-07-30 and read "anon is revoked yet the public app renders" as a contradiction; the premise had simply expired. ✅ **DONE, DO NOT RE-DO IT: `stamp.unclogme.app` is pinned in `audit.log_change`'s Origin CASE** (`2026-07-30_2030`, applied the same day). This paragraph used to carry a "pin the new host in the CASE" TODO; it was completed on 2026-07-30 and the instruction is retired here (2026-08-07) because a stale TODO sends a reader to do work that is already done. **Both patterns are kept**: `%studio.unclogme.app%` still matches 71 historical rows and a redirect can be undone. Worth keeping is *why it was urgent while nothing looked broken*: 16 rows were already arriving from the new origin and were labelled correctly ONLY because the Studio's single client sends `X-App-Source`, which ADR 016 makes a per-CLIENT override. Add a second Supabase client or drop that header and Studio writes would have started landing as `other:stamp.unclogme.app`, which is the per-client header dependency this file warns about below and the exact shape that cost Admin Review 232 mislabelled rows over 26 days.** **`visits` lifecycle is RPC-only as of Phase 3 (2026-07-11):** anon/authenticated can NO LONGER directly UPDATE `visit_status`/`completed_at`, nor EXECUTE the create/edit/delete/ripple/skip/unskip lifecycle RPCs (revoked in **both** `public.*` and `ops.*`); the Calendar drives lifecycle through the `set_visit_status` / `ops.set_visit_status` SECDEF wrappers (authenticated-only). **As of the 2026-07-12 anon-surface harden, anon is READ-ONLY on all business data** — it can no longer write any table/column or EXECUTE any write/exposure RPC (all revoked → authenticated + service_role; only FP `customer.*` reads + pure immutable helpers remain anon-callable). This also closed an owner-rights auto-updatable-view bypass of the Phase-3 visits lock (`v_visits_live`). Field Portal stays anon read-only. Full model + negative-test matrix: [docs/security.md](docs/security.md#publicvisits--anonauthenticated-write-model-2026-07-09-159e1c6).
  - **Sandbox #1 `ubtlwpcyntelgbykdatn` — DELETED 2026-06-11.** Verified zero consumers (0 API requests/7d; every Lovable app runs on Prod or Lovable Cloud; review data migrated to Prod canonical 2026-06-08). `sandbox-refresh.yml` retired (schedule removed + disabled); audit parity checks retired. Final backup of its unique tables: `..\backups\sandbox1_final_backup_2026-06-11.json` (parent folder, outside repo).
  - **HR Sandbox** `klgtrdwrasrlxbmfyvdh` (renamed from *Field Portal Sandbox*) — Yannick's **HR app** project (Field Portal app reads Prod directly since 2026-05-16). Legacy April-clone schema (keep as-is); data re-seeded fresh 2026-06-11 (full employees/vehicles/inspections + live subset visits). Also hosts the `frozen_leads` schema — don't touch. One-time-seed model, no periodic refresh.
  - **Client App Mirror `mjxjhwxktedrrnochwli` — DELETED 2026-08-10** (Fred's instruction). It was the hourly full-snapshot mirror of Prod's client domain (19 tables) for the Client App build phase; the app was repointed to Prod 2026-07-24 and the live bundle carries only the Prod ref, so it had no consumer for 17 days. Verified before deleting: **0** ids in the mirror absent from Prod (clients/properties/client_contacts/jobs/gdos), 0 auth users, 0 storage objects, so nothing needed backing up. Its refresh workflow had failed **154 consecutive runs** while `mirror_meta.last_refresh_at` kept advancing, leaving ~3,600 phantom rows (`visit_team` 1,453 vs 131, `visit_locations` 2,501 vs 182) that the circuit breaker refused to delete. Workflow removed in `7f0ac2f` before deletion. Final metadata snapshot: `..\backups\client_app_mirror_final_2026-08-10.json`. Full record: [docs/reference/client-app-mirror.md](docs/reference/client-app-mirror.md).
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
  - 🛑 **IT HAPPENED AGAIN ON 2026-08-07, TO SOMEONE WHO HAD READ THIS BULLET THAT MORNING**, so
    the rule as written is not enough and here is the missing half. `public.job_frequency_changes`
    shipped with `authenticated` holding **SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES and
    TRIGGER**, RLS off, no policies: a signed-in staff browser could edit, delete or truncate a
    compliance history table through PostgREST. The migration's own header asserted the opposite
    ("`authenticated` holds nothing"), and its GRANT statements were all correct. `CREATE TABLE` had
    already handed out everything **before** they ran, and a GRANT cannot remove what it did not
    create. Fixed by `2026-08-07_1420`.
  - ⇒ **A migration that verifies its own GRANT statements passes while the table stays wide open.**
    The pre-apply probe tested the constraints, the audit trigger and the grants that were WRITTEN.
    It never asked what else was there. **Read `relacl` AFTER the fact and compare it against the
    INTENDED set**, in the migration itself, with a sibling table as the control:
    ```sql
    select c.relacl from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = '<new_table>';
    -- must equal the sibling's, and has_table_privilege('authenticated', ..., 'SELECT') must be false
    ```
  - 🛑 **AND A PROBE OVER THE MANAGEMENT API CANNOT SEE THIS AT ALL.** That transport runs as
    `postgres`, which is the table OWNER and holds `rolbypassrls`, and **an owner bypasses the GRANT
    system entirely**. So "a valid row inserts cleanly" is true no matter what the ACL says, and
    every permission probe written that way is measuring nothing. `SET LOCAL ROLE authenticated`
    (and `anon`) before asserting anything grant-shaped, or use `has_table_privilege(<role>, ...)`
    which does not depend on who is asking.

### ⚠ A SECDEF function BYPASSES RLS — so wrapping a write in one can silently WIDEN it (2026-08-05)

**`postgres` has `rolbypassrls = true`** (measured; it is not a superuser, but it holds the attribute).
RLS is **enabled AND FORCED** on `public.visits` and `public.manifest_visits`. So moving a statement
the app runs as `authenticated` into a `SECURITY DEFINER` function owned by `postgres` **removes every
policy that was constraining it** — the caller gains reach they never had, and nothing errors.

This is the same privilege-laundering shape as the view/function asymmetry above, one level up: the
table grant is not the control, the *policy* is, and SECDEF drops the policy silently.

**⇒ Before wrapping any write in SECDEF, check the caller's POLICIES, not just their grants**, and probe
`SET LOCAL ROLE authenticated` both ways (direct statement vs through the function) to prove the
reachable set is unchanged. Two traps that make reading the catalogue give the wrong answer:

- **🛑 PERMISSIVE POLICIES `OR` TOGETHER, so a narrow one can be DEAD while looking like the control.**
  `visits_authenticated_update_derm_required USING (visit_status = 'completed')` reads like the guard on
  who may write that compliance column. It restricts **nothing**: `visits_app_update_authn
  USING (deleted_at IS NULL)` is OR'd alongside it and swallows it whole. Measured — `authenticated`
  updates `derm_required` on a **scheduled** visit fine (1 row). **Never quote one policy as the limit;
  enumerate every permissive policy for that role+command and OR them in your head.**
- **🛑 POLICY NAMES LIE ABOUT WHICH ROLE THEY TARGET.** Every policy on `public.manifest_visits` is named
  `anon_*` (`anon_delete_manifest_visits_authn`, `anon_insert_…`, `Allow anon read on …`) and **every one
  has `polroles = {authenticated}`**. A sweep answering "what can anon do" from policy names reports the
  opposite of the truth. **Read `polroles`, never the name.**

Worked example, and why it did NOT block the change: folding the `manifest_visits` unlink into
`set_visits_derm_required_manual` was safe **because it was measured** — `authenticated` already held both
the DELETE grant and an unrestricted DELETE policy, so the function laundered nothing. Had that policy
been anon-only, the same code would have handed every staff user a delete they did not have.
(`2026-08-05_0508_derm_manual_lock_bulk_rpc.sql`.)

### ⚠ Verifying a TRIGGER GUARD: both baselines, a changing value, and the old body as control (2026-08-05)

Three lessons from one defect, all cheap, all learned the expensive way. **This lives here and not only
in a memory folder, because memory is keyed by working directory and does NOT reach the other sessions
(root CLAUDE.md §1) — the repos do.**

- **🛑 A guard predicated on `OLD.<col>` CAN ONLY FIRE FROM ONE BASELINE. Test both.**
  `fn_lock_manual_derm_required`'s revert leg needs `OLD.derm_required_locked IS TRUE`. I verified
  `set_visit_derm_required_manual` against the right variable (a non-derm origin) but from an
  **unlocked** baseline, where that branch is unreachable. The test passed and proved nothing.
  164 rows were locked, so the baseline I skipped was the COMMON one, and the RPC turned out to honour
  requests only from the DERM origin — the exact dependency it existed to remove.
- **🛑 IT IS ALSO VALUE-DEPENDENT.** Requesting `false` on a row already `false` PASSED even on the
  broken body, because `NEW.… IS DISTINCT FROM OLD.…` never fired. So picking the right baseline and a
  no-op value still misses. Enumerate **combinations** (baseline value × baseline flag × requested
  value × origin), not one cell per variable.
- **✅ KEEP THE OLD BODY AS A POSITIVE CONTROL.** A matrix reporting 0 failures is an untested
  instrument. Re-create the previous implementation under a temp name, run the identical assertions,
  and confirm it FAILS. Mine went 24/24 on the new body and 4-pass/2-fail on the old; the second number
  is what made the first mean anything. Drop the temp object and verify it is gone.
- **🛑 TRIGGER FIRING ORDER IS ALPHABETICAL, AND IT IS LOAD-BEARING FOR ANY OBSERVER.**
  `trg_aa_derm_required_shadow` must sort BEFORE `trg_derm_required_lock`, or it would inspect
  `NEW.derm_required` *after* the revert, match nothing, and **log zero forever while looking healthy.**
  Renaming such a trigger is a breaking change. (`2026-08-05_0556`.)

### 🛑 `CREATE OR REPLACE`: COPY THE WHOLE BODY, NEVER RETYPE IT (2026-08-06)

`CREATE OR REPLACE FUNCTION` takes the **entire** body. So "I changed one clause" and "I rewrote the
function from memory" produce migrations that look identical, and **everything you fail to reproduce is
silently deleted**. The header will then honestly describe the change you *intended*, which is why this
class of defect survives review: the file reads correctly and the object does not match it.

**What it cost on live Prod.** `2026-08-06_1316` replaced `derm.fn_resolve_generated_sheet_for_ticket`.
Its header said the anti-AI auto-complete clause was the only change and that the rest was restated in
full *"not because any of it moved."* The body had been retyped rather than copied, and it lost:

| what the retype dropped | consequence |
|---|---|
| candidate selection became `select s.sheet_id … having count(*) = 1` with **no GROUP BY** | `42803` at runtime. The resolver **RAISED for every unresolved ticket for ~3.5 hours** (13:16 to 16:55) instead of returning null. |
| the `derm_manifests.derm_address_no` write | resolved tickets stopped recording which sheet number they landed on |
| `deleted_at is null` on `address_sheets`, in both the already-resolved lookup and candidacy | a soft-deleted sheet could be resolved onto |
| `on conflict (sheet_id, manifest_id) do update set slot` flipped to `do nothing` | a corrected slot stopped being applied |
| the sheet-number gate inside CANDIDATE SELECTION | kept only at placement, so a wrong candidate could be chosen |
| `and s.o_y_pct is not null` on placement, and the not-completed upsert guard | placement and completion guards gone |
| `min(m.service_date)` became `max(m.dump_ticket_date)` | causality moved from "when the work happened" to the dump date, which is not the same question |

Corrected forward (not rewritten, per the audit-trail rule) in
[`docs/migrations/2026-08-06_1655_stamp_row_confirmed_placement.sql`](docs/migrations/2026-08-06_1655_stamp_row_confirmed_placement.sql).
**Its PART 0 is the primary record: read that file, do not re-derive this list.** Re-deriving from
memory is the exact failure being documented here.

**Procedure, every time:**
1. **Copy the previous body. Do not retype it.**
   `awk '/^CREATE OR REPLACE FUNCTION <name>/,/^\$function\$;/' docs/migrations/<previous>.sql`
   and edit THAT copy. Editing the live `pg_get_functiondef` output is equally good and is what
   `2026-07-30_2030` did: anchor asserted to match exactly once, every other byte unchanged.
2. **Diff old against new** and confirm every removed line was meant to go.
3. **EXERCISE the new body** in a rolled-back probe. PL/pgSQL is **not parsed at creation time**, so
   "the migration applied" says nothing about whether the function runs. A `42803` sails straight
   through `CREATE OR REPLACE` and only fires on the first real call.
4. **"Nothing else moved" is a CLAIM, not a note.** Prove it with the diff, or delete the sentence.

### 🛑 "WHO READS THIS COLUMN?" — A WHOLE-ROW RPC READS IT WITHOUT NAMING IT (2026-08-10)

Before dropping or renaming a column, the two obvious sweeps are a regex over `pg_proc.prosrc` and a
`pg_depend` walk. **Both return a confident ZERO for a function shaped like this**, which is the
standard Client App RPC shape in this repo:

```sql
declare v_row public.properties;                 -- a %ROWTYPE local
insert into public.properties (...) returning * into v_row;
return to_jsonb(v_row);                          -- emits every column, names none
```

Measured on `client.create_property` (2026-08-10): the body contains the string `access` **zero**
times, `pg_depend` holds **0** `pg_proc` rows against `public.properties`, and `to_jsonb(v_row)`
returns **27 keys, 5 of them `access*`**. A regex sweep found 1 of the 2 real function consumers.

⇒ **Dropping a column silently changes the JSON an app receives, with no error at either end.**
So enumerate whole-row returns separately: grep for `returning * into`, `%ROWTYPE`,
`to_jsonb(v_row)` and `select * from`, and treat every hit as a consumer of **every** column.
The same applies to `select("*")` on the app side and to any full-table mirror job.

⚠ **And a string match is not a measurement.** My check of this very finding matched
`'%v_row public.properties%'` with one space; the declaration uses five, so the probe returned
`false` and briefly looked like a refutation of a correct finding. **Read `pg_get_functiondef` and
look at it** rather than asking a `LIKE` whether something is there. Compare the §5 regex-transport
trap in the root `CLAUDE.md`: same failure class, different layer.

### 🛑 STRUCTURE TELLS YOU WHAT A THING DOES, NEVER WHAT IT IS FOR — ask Fred (2026-08-05)

**Fred:** *"don't drop the derm_required filter from work_orders, because we only show derms required
jobs to the work orders."* `customer.work_orders` is the client's **DERM compliance surface by design**,
not a service history; a non-DERM job is CORRECTLY absent. There was nothing to remediate.

Both Supabase sessions recommended widening it. **Every number was right** (367 completed visits
excluded by `COALESCE(derm_required,true)=true`; 39 scheduled queued to be excluded; ~20/week, which is
simply the normal rate of non-pumping work completing). The reasoning was: `customer.scheduled_visits`
applies no DERM filter while `customer.work_orders` does, *therefore* the filter is unintentional.
**That does not follow — two views can simply have different jobs.**

- **Warning signs you are deducing intent:** "X has no such filter, therefore Y's is accidental";
  "no comment explains it"; "this looks like a service history". Measure freely; **recommend only with
  a source.** Asking costs one question.
- **⚠ CORRELATED BLINDNESS — the reason cross-checking did not save us.** Both sessions reached the
  same wrong conclusion independently and then each verified the *asymmetry*, which felt like
  corroboration but was two parties re-measuring the half never in doubt. One session ran 5 probes with
  5 adversarial refuters and got zero refutations; **all ten agents were pointed at a MEASUREMENT**, so
  no amount of them could catch it. **Redundancy scales confidence, not coverage.**
  ⇒ For anything ending in a recommendation, put one reviewer on the **CONCLUSION**, briefed to attack
  the inference and assume the numbers are right.
- Compare the mirror-image failure the same day: a probe returned REFUTED against a body that had
  already been fixed, i.e. stale numbers with sound reasoning. **Both errors sat in the layer nobody
  was auditing.**

**⚠ THIS SHAPE HIT THREE TIMES IN ONE DAY (2026-08-05), AND NOT ONE WAS A BAD NUMBER:**

| # | the measurement (correct) | the sentence wrapped around it (wrong) |
|---|---|---|
| 1 | `scheduled_visits` has no DERM filter, `work_orders` does | "therefore the filter is unintentional" |
| 2 | 9 of the 21 manifest links fall in the May bulk window | "therefore they mostly trace to it" (a plurality is not a concentration; 7 have no audit trail, 5 are July, by 3 writers) |
| 3 | one RPC call writes 2/3/1 audit rows | stated unconditionally — it holds only for the DERM origin, and **inverts the hour step 3 ships** |

⇒ **The number is almost never the weak link; the claim built on it is.** Verifying a measurement
harder cannot catch any of these. Only #2 was caught in-flight, and only because a reviewer was
briefed to attack the conclusions with the numbers assumed correct. **Instrument the inference.**

⚠ **STILL OPEN and NOT part of the closed view question:** completed visits carrying a
`manifest_visits` link while `derm_required = false`. **21 total, but scoped down to 3 that are
load-bearing (1260, 1476, 3923)** — the other 18 sit on manifests that already carry a correct pumping
link, so they are not evidence of a missing obligation. (An earlier version of this note said "21,
18 derived / 3 human-marked" and implied all 21 needed investigation; that was instance #2 above.)
A manifest on file is evidence DERM work happened, so for those 3 either the flag or the link is
wrong. Nobody has been asked to investigate; do not let it get filed under the view scoping question
and disappear.

> 🛑 **CORRECTED 2026-08-07, AND THE CORRECTION IS A SAFETY ONE. "`derm_required = false`" above is
> wrong for two of the three, and the wrong version invites the harmful action.**
> **1260 (083-SHUL) and 1476 (133-MUT) are `derm_required IS NULL` and LOCKED**, not `false`. Only
> **3923 (165-LPB)** is actually `false`, and it is **not** locked, so it is a genuinely different
> situation. Do not treat the three as one shape.
> **🛑 DO NOT UNLOCK 1260 OR 1476.** They were deliberately held back from
> `2026-08-05_0620_derm_unlock_seven_null_locked_visits.sql` (commit `35fdb13`, which unlocked the
> other seven: 1334, 1547, 1597, 5100, 5101, 5745, 5830, all of which re-derived to `true` with no
> client-visible change). Both of these derive **`false`** from `fn_visit_requires_derm`, and
> `customer.work_orders` filters `COALESCE(derm_required, true) = true` **by design** (Fred,
> 2026-08-05). So unlocking either lets the nightly re-derive write `false` and the client's **entire**
> service record for that visit leaves their Field Portal (driver, truck, decal, manholes, ticket, trap
> condition, facility), not just a DERM chip, while a real manifest sits on file. **`NULL` is fail-safe
> here and `false` is not.** 1533 (175-PV) was skipped for the opposite reason: it derives NULL, so
> unlocking it is inert.
> ⚠ **This open question is NOT licence to unlock them.** Investigating "is the flag or the link
> wrong?" is a question for a person; clearing the lock is an action that answers it destructively.
> Full workings, including the "two trios in circulation" trap:
> [docs/reference/derm_required_by_line_item.md](docs/reference/derm_required_by_line_item.md).

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

### 🛑 JOBBER SHEDS LOAD WITH AN HTML "WAITING ROOM" AT **HTTP 200** — AND 12 OF OUR 13 CALLERS MISREAD IT (2026-08-13)

Observed live: `POST https://api.getjobber.com/api/graphql` returned **HTTP 200**,
`content-type: text/html`, body `<title>Jobber | Waiting Room</title>`. **Not 429. Not 5xx. No
`errors` array.** Every signal our helpers check says "success".

The `gql` helper copied across these functions does:

```ts
let j: any = {};
try { j = await r.json(); } catch { j = {}; }      // <- the HTML becomes {}
if (r.status >= 500) ...                            // 200, so no
if (Array.isArray(j.errors) && j.errors.length) ... // undefined, so no
return { ok: true, data: j.data };                  // data === UNDEFINED, ok === TRUE
```

So the caller receives **`ok: true` with `data: undefined`**, reads `data?.client` (or `?.job`,
`?.visit`) as null, and reports *its own* not-found message. `save-client-contact` said
**"Jobber has no client at that id — the link is stale"**, which sends a person to repair a link that
is perfectly healthy. **An outage gets reported as data corruption.**

**⇒ Check the RESPONSE content-type. The status code lies.**

```ts
const ctype = r.headers.get("content-type") ?? "";
if (!ctype.includes("json")) return { ok: false, kind: "busy", detail: `Jobber returned ${ctype} at HTTP ${r.status}` };
```

**Measured 2026-08-13 with a control** (`grep 'headers.get("content-type")'`, response-side only —
the naive grep also matches the *request* header and reports everything as fine):

| inspects response content-type | functions |
|---|---|
| **yes (3)** | `save-client-contact`, `save-calendar-visit`, `jobber-push-task` |
| **no (10)** | `adopt-visit-from-jobber`, `create-client`, `jobber-push-visit`, `save-client-fields`, `save-client-job`, `sync-jobber-job-drift`, `sync-jobber-poll`, `sync-jobber-upcoming-visits`, `sync-jobber-visit-drift`, `webhook-jobber` |

**Every path that WROTE on an unanswered Jobber has been closed (2026-08-14).** The remaining 10
produce a misleading error message and nothing worse — each was traced to a named stopper (an
unhandled TypeError, a positive-match verify, or an early return), not merely "no path was found".
The three fixed ones were fixed because they wrote:

| what was fixed | it used to |
|---|---|
| `scripts/sync/cron_jobber_reconcile_anomalies.js` | soft-delete **756 visits** (512 completed, 269 with DERM links) — see the note below |
| `save-calendar-visit` | commit a cleared notes/crew save and hard-`DELETE` `visit_team`, reporting "Saved." |
| `jobber-push-task` (delete) | drop the `entity_source_links` row and report `verified_gone: true` |

🛑 **THE SHAPE THEY ALL SHARED, and it is the thing to check in the remaining 10 before trusting
them: a MISSING answer was coerced into a NEUTRAL value and then compared.** `String(undefined ?? "")`
is `""`; `(undefined || []).map(...)` is `[]`; `undefined?.task?.id` is falsy exactly like a real
`null`. So the verify passed by comparing nothing to nothing. **This is invisible to normal testing
because it only bites when the intended new value is EMPTY** — every test that sets a real value
passes. Clearing is the untested half of every field.
⇒ Require the read to have HAPPENED (a selected `id`, a `data` key) *before* comparing any field.
A content-type guard alone is NOT sufficient: a well-formed `{"data":{"visit":null}}` still needs it.

🛑 **The bad error message was the MILD case. The dangerous case was the sync layer, and it is
CLOSED (2026-08-14, `09fc892`).** For the drift reconcilers and the poll, "Jobber returned nothing for
this entity" is exactly the shape of "this entity was deleted upstream", and that is a branch which
**soft-deletes visits** (`visits.deleted_at` is set when Jobber reports a visit missing). The orphan
branch in `scripts/sync/cron_jobber_reconcile_anomalies.js` fired on
`isNotFound(res.errors) || !res.data?.visit`, which cannot tell "Jobber answered no" from "Jobber did
not answer".

⚠ **AND THE MECHANISM WAS NOT WHAT THIS SECTION FIRST ASSUMED. Do not carry the original guess
forward.** The HTML waiting room never reached that branch at all: the script's bare `JSON.parse`
throws on HTML, which was accidentally protective. The reachable shape was a **well-formed JSON reply
with no `data` key** (a throttle or an error payload), which parses cleanly and then reads as
"missing". A content-type guard alone would not have caught it.

**What closed it**, both in `gqlVisit`, both THROWING so the orphan branch can never see the value:
a non-JSON content-type is rejected, and a reply with no `data` key is rejected. Plus a
**10-consecutive-failure circuit breaker** so a real outage stops the run instead of walking the
fleet. Mutation-tested with the pre-fix body as the control.

⇒ Still true and still the rule: **do not widen any Jobber-absence branch** without proving it can
distinguish an answer of "no" from no answer at all.

⚠ A verified refusal is the SAFE outcome here and it is worth keeping: during the live event
`save-client-contact` returned `jobber_unavailable` and wrote **nothing**, leaving the contact intact.
Fail-closed is what you want when the upstream is unreadable.

### 🛑 THE NEVER-EXECUTED REPORT: `scripts/checks/never-executed.mjs` (added 2026-08-21)

**Run it before trusting any dispatch surface, and after adding one.** `node scripts/checks/never-executed.mjs`

**Why it exists.** `handlePropertyDestroy` was structurally incapable of succeeding for the entire
life of this integration and nothing knew, because **the handler had never once executed**. We found
out when it fired on a real customer property and failed. The same audit found **13 of 22 Jobber
webhook handlers with no execution on record at all**: the poll only ever synthesised `*_UPDATE`
events, so every CREATE / DESTROY / CLOSED / SENT / APPROVED path was unreachable dead code, and all
of them became reachable at once the moment the payload-shape fix landed. Production was doing our
testing. This report makes "this code has never run" a state a person can see.

**It covers 259 surfaces:** the 22 webhook topics (parsed from `TOPIC_HANDLERS` in the live source,
never hardcoded), 20 pg_cron jobs, 34 edge functions, 160 app-reachable RPCs, 23 GitHub workflows.

**🛑 THE DESIGN RULE, AND THE REASON TO TRUST THE OUTPUT: THREE VERDICTS, NEVER TWO.**

| verdict | meaning |
|---|---|
| `RAN` | evidence exists and shows execution (plus a `⏳ Nd ago` annotation past 30 days) |
| `NEVER` | an evidence source covers this surface and shows zero |
| `NO EVIDENCE` | **nothing in this system can answer the question** |

Collapsing `NO EVIDENCE` into `NEVER`, or into "fine", is the exact false all-clear this estate keeps
paying for. Every section prints its own evidence source and window, and every section carries a
**positive control that must report RAN**; if a control does not fire the section says its clean rows
prove nothing and the process exits 2. Mutation-tested both ways: pointing section 1's control at a
never-run topic correctly poisons that section, and breaking the topic parser throws instead of
reporting a clean zero.

**⚠ Two detectors in the first version were WRONG and both are worth knowing, because they are the
shapes any successor will hit:**
- **A pg_cron command does not name the edge function.** It calls a SQL wrapper
  (`SELECT public.fn_request_jobber_sync('poll')`) whose BODY holds `.../functions/v1/sync-jobber-poll`.
  Matching the cron command alone reported **29 of 34 functions unevidenced, including
  `sync-jobber-poll`, whose cron has 20,953 successes.** The report now resolves wrapper bodies too.
  **The tell was implausibility, not an error.**
- **PostgREST renders an RPC as a `pgrst_call` CTE with the function SCHEMA-QUALIFIED**
  (`"derm"."fn_blackout_targets"`) and **no opening paren after the closing quote**. Matching
  `"name"(` found zero of 160, which reads exactly like a healthy-but-idle surface.

**⚠ KNOWN BLIND SPOTS, stated so a clean run is not over-read:**
- **RPCs are structurally blind.** `track_functions = none`, so `pg_stat_user_functions` is empty and
  the only signal is `pg_stat_statements`, a volatile ~16h buffer any restart clears. 144 of 160 RPCs
  report NO EVIDENCE and that is not a finding. **Setting `track_functions = pl` is the one change
  that would make this section real** - a project config decision, not something the report assumes.
- **Edge functions have no invocation counter at all.** That section is PROXY evidence only (cron
  chain, `audit.logs.app_source`, `sync_log.sync_source`, `webhook_events_log`). A function invoked
  only from a browser leaves no trace any of those tables can see, so 22 sit at NO EVIDENCE.
- **`webhook_events_log` is trimmed** (90-day retention job; oldest row currently 2026-07-22). So
  webhook `NEVER` means "no delivery in the retained window", not "never in history".

**✅ Measured 2026-08-21 on the removal handlers, so nobody re-does it:** all six `softStatusFlip`
writes complete against real rows (rolled back, with a control proving junk status is rejected
`23514`), the GID round-trip resolves for **6 of 6** entity types, and the one real `JOB_DESTROY`
demonstrably wrote (`audit.logs`: job 1848 `action_required -> destroyed` at 05:24:57, which the poll
then converged to `archived` 20 minutes later). **No second `handlePropertyDestroy`-class defect.**
⚠ That last detail matters on its own: `job_status='destroyed'` is TRANSIENT, so a query looking for
it finds nothing even though the handler worked.

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

### Soft-delete on PROPERTIES (added 2026-08-21) + the two traps that come with it

`public.properties.deleted_at TIMESTAMPTZ` is set by `webhook-jobber`'s `handlePropertyDestroy` when
Jobber reports the property removed. `2026-08-21_0530` added the column, `2026-08-21_1200` taught the
readers about it.

**🛑 THE HARD DELETE IT REPLACED COULD NEVER HAVE SUCCEEDED, AND THAT WENT UNNOTICED FOR THE WHOLE
LIFETIME OF THE INTEGRATION.** Nine FKs point at `public.properties` and five are `NO ACTION`
(`jobs`, `visits`, `quotes`, `notes`, `ops.visit_requests`), so any property that had ever had a job
was unreachable. It was invisible because **real Jobber webhooks had never been accepted at all**:
the handler read a flat payload while Jobber sends `{data:{webHookEvent:{...}}}`, so every genuine
delivery was rejected with an unlogged 400 and the `*/5` poll masked the gap. Both fixed the same day
(`b5b23c0`, `a3dcea3`).

**🛑 TRAP 1: A BILLING PROPERTY'S `entity_source_links.source_id` IS A *CLIENT* GID WITH A
`_billing` SUFFIX. A naive "which of our properties still exist in Jobber" diff retires all 432.**
`public.properties` holds two kinds of row and they point at two different Jobber objects:

| kind | live | `source_id` looks like |
|---|---|---|
| service | 464 | `Z2lk...UHJvcGVydHkvMTIz` = `gid://Jobber/Property/123` |
| billing | 432 | `Z2lk...Q2xpZW50LzQ1Ng==_billing` = the CLIENT gid **plus `_billing`** |

Jobber models a billing address as part of the Client, not as a Property, so there is no Property gid
to store; the suffix keeps the row from colliding with the client's own link. `webhook-jobber` writes
it at `index.ts` (`source_id: ${gid}_billing`).
⚠ **AND THE OBVIOUS DIAGNOSTIC HIDES IT.** Base64-decoding the value prints
`gid://Jobber/Client/91592770` perfectly cleanly, because the decoder stops at the `==` padding and
silently discards the `_billing` bytes that are the entire point. Comparing the DECODED values makes
the two look identical while the stored strings differ. **Compare raw stored bytes; decode only to
read, never to compare.** Measured 2026-08-21: an audit that got this wrong reported
**432 of 432 billing rows as "client gone from Jobber"**. A 100% failure rate is the signature of a
broken comparison, not of broken data. After stripping the suffix: **2**.
✅ Safe by construction: `handlePropertyDestroy` resolves by `source_id`, and a `PROPERTY_DESTROY`
payload carries a Property gid, so it can never match a billing row. Asserted in
`scripts/probes/property_estate_audit.mjs`, which is the re-runnable version of all of this.

**🛑 TRAP 2: DO NOT ADD `deleted_at IS NULL` TO THE VIEWS THAT READ `properties`. Most of them would
DELETE A VISIT, not hide a property.** 30 views read `public.properties`; **7** filter it and **23**
deliberately do not. Two rules decide which:

1. **WORKLIST vs RECORD.** A worklist (things to act on) hides a retired property. A record (things
   that happened) never does. The tempting tier is "app-facing vs internal" and it is **wrong**:
   `customer.work_orders` is customer-facing AND it is the client's DERM compliance history, so
   filtering it would remove completed work orders from a regulator-facing surface because the site
   was later removed in Jobber.
2. **GRAIN.** Most of the 30 reach properties through a `LEFT JOIN` whose grain is a VISIT or a
   MANIFEST, with properties only supplying an address. A `WHERE p.deleted_at IS NULL` there deletes
   the visit. The filter is only safe where properties is the driving table, inside an aggregate or
   subquery that yields a single field, or in a `LEFT JOIN`'s **ON** clause (which nulls the columns
   and keeps the row, which is what `customer.clients` does).

Filtered: `client.properties`, `ops.properties`, `client.clients` (both LATERAL aggregates),
`customer.clients` (ON clause), `public.zones_with_usage` (the count), `derm.v_stamp_clients` (its
`ORDER BY p.id LIMIT 1` address), `client.global_search` (its properties branch).
Not filtered, on purpose: everything else, and `ops.v_depot` / `ops.v_dump_sites` additionally
because each pins ONE property by config or constant, where the right outcome is a loud
configuration error rather than a silently empty view.

⚠ **`authenticated` still holds SELECT on `public.properties` itself**, and `pg_stat_statements`
shows live PostgREST reads against the base table. The base table is deliberately unfiltered so
history and audit keep working, so **any app query written against `public.properties` rather than
`client.properties` still sees retired rows.** That is an app-side change and it is not done.

✅ **THE ESTATE WAS AUDITED BEFORE ANY RECONCILER WAS BUILT (2026-08-21, Fred's instruction).**
Measured against live Jobber: **0 orphans** among 465 live service properties, 1 unlinked legacy
property (304, an INACTIVE client with no Jobber link either), 18 Jobber properties we do not hold
(**all 18 on archived clients**), 2 billing rows whose client is gone, 0 duplicate or dangling links.
**There is no backlog, so a reconciler is not a backfill.** Nothing detects a `PROPERTY_DESTROY` that
is never delivered, so re-run `scripts/probes/property_estate_audit.mjs` rather than assuming.
⚠ Jobber's property delete **cascades to the jobs**, which arrives here as `job_status='archived'`.
That is what keeps a dead site out of the Visit Calendar's New Visit picker (which selects a JOB, not
a property). It is a two-instance observation, not a proven invariant: if a live job is ever found on
a retired property the picker WILL offer it.

### Jobber PROPERTY sync — enabled 2026-08-04, hourly, and it was dead before that

**Until 2026-08-04, a Jobber-side edit to a SERVICE property address never reached us.** Not slowly —
never. `PROPERTY_UPDATE` had produced **zero events in the lifetime of the system**, so
`public.properties` addresses were frozen at whatever the last manual full sync wrote (2026-05-27).
Found because the DUMP Pompano address was two months stale.

**Why it was invisible.** Two separate mechanisms each *looked* like they covered it:
- `sync-jobber-poll` (the LIVE poll, pg_cron `*/5`) simply had no `properties` entity, and its comment
  said properties "ride webhooks / a daily `--full`". **Both halves were false.** Jobber sends us **no
  webhooks at all** — this poll IS the webhook replacement (ADR 009) — and `--full` lives in
  `scripts/sync/cron_jobber.js`, whose schedule was **retired 2026-06-09**, with no workflow passing
  the flag.
- **BILLING addresses did flow**, because they ride `CLIENT_UPDATE` (`webhook-jobber` ~line 493). So a
  spot check of "do property addresses update?" could come back green off the billing duplicate while
  every service address was frozen. That is exactly how it hid.

**Now:** `properties` is in `sync-jobber-poll`'s `ENTITIES`, pulled as a **full 468-row sweep gated to
one run per hour** (`PROPERTY_SWEEP_MINUTE`), because properties have no `updatedAt` filter to page on.

**Three rules for anyone touching this:**
1. **Dry-run before widening it.** `scripts/sync/dryrun_property_poll.js` computes the exact row
   `handleProperty` would write for all 468 and diffs it against ours. It is what caught the
   name-blanking bug below, and it reported the real blast radius (23 changed, 79 would insert)
   before anything was scheduled.
2. **`?? null` does not catch an empty string.** Jobber returns `""`, not `null`, for an unlabelled
   property, so `name: p.name ?? null` would have overwritten a real name with blank — measured, one
   genuine loss (`"Burger Fi Doral"` → `""`). A blank from Jobber now never overwrites a name we hold.
3. **🛑 THE REPLAY IS CAPPED AT 10/CYCLE, AND RAISING IT FAILS SILENTLY.** Each replayed row is a
   sequential HTTP round-trip. At 40, pg_cron kept reporting `succeeded` and properties kept draining
   (each replay is its own request), but the **outer invocation was killed before writing its
   `sync_log` row** — 3 cycles did real work while logging nothing, so the next reader would see "last
   successful sync 20:05" and conclude the poll was dead. **If you raise the cap, verify a `sync_log`
   row still appears every cycle.** Work continuing while observability vanishes is worse than a
   clean failure.

### 🛑 JOBBER CUSTOM FIELDS HAVE NEVER SYNCED, AND A NAIVE COPY DESTROYS DATA (2026-08-17)

Yannick in Slack: the Grease Trap Size and Client Code custom fields are not reaching us, and the
15-minute crons should be doing it. **The crons are healthy and irrelevant.** Measured: of the six
entities `sync-jobber-poll` pulls, **zero request `customFields`**, and `handleProperty` issues its
own query that does not either. There is no path, so there is nothing to be slow or broken. A cron
audit answers "is the poll running", never "does the poll ask for this field".

**🛑 THE REASON THIS CANNOT BE FIXED BY JUST ADDING THE FIELD TO THE QUERY.** Jobber's numeric
custom field has `defaultValue: 0`, **no null state, and no `updatedAt`**. Every one of 474
properties returns a materialized `CustomFieldNumeric` row, 419 of them reading `0`. **A property
nobody has ever typed into is byte-identical to one a human deliberately set to zero.** So "copy
Jobber's value when it differs from ours" is not a sync, it is a wipe: measured, it would zero
**69 of our properties and destroy 47,732 recorded gallons**, plus overwrite 10 more (9 downward).
⚠ And `??` does not save you the way it does for the name-blanking bug above: Jobber sends a hard
`0`, and `0 ?? null` is `0`. Any guard keying on falsiness drops a legitimate zero too.

⇒ **Change detection requires a stored "last seen" shadow**, which is what
`sync.source_field_shadow` + `sync.fn_shadow_decision` are (`2026-08-17_1636`). Adopt only when
Jobber's current value differs from what we last saw there; unchanged means "not an edit" whatever
the value, so `0 -> 0` can never be copied while `0 -> 190` is. First run seeds silently and adopts
nothing. Both-sides-changed is recorded as CONFLICT and frozen: it is a human question.

**STATUS: LIVE INBOUND SINCE 2026-08-18. Outbound is still NOT built.** Fred: *"wire it to the
poll."* A Jobber-side edit to the Grease Trap size now reaches `public.properties` on its own,
proven unattended: Jobber was edited by hand, nothing was flagged, and the scheduled `*/5` cron
swept at 01:00 ET, restaged the property, replayed it and adopted 1800 -> 2500 with
`adopted_from`/`adopted_to` intact and its own audit label. **Outbound is still not built**: nothing
we change is pushed to Jobber (`propertyEdit` accepts a customFields-only edit and config `3061111`
is `readOnly:false`, so it is possible, just not written).

**TWO PLACES, AND MISSING EITHER MAKES IT SILENTLY INERT.** The poll does not hand its staged
payload to the handler; it POSTs an id and `handleProperty` re-queries Jobber itself.
- `sync-jobber-poll` selects `customFields` on `properties` **only for CHANGE DETECTION**. Without
  it a custom-field-only edit leaves the staged address bytes identical, the row is never restaged,
  and the handler is never replayed.
- `webhook-jobber`'s `handleProperty` selects them in its own query and passes the value on.

**🛑 THE DECISION AND THE WRITE LIVE IN ONE PLACE: `public.fn_sync_property_custom_field`**
(`2026-08-18_0210`, SECDEF, service_role only). Both the poll and
`scripts/sync/adopt_jobber_custom_fields.js` go through it. **Never write
`grease_trap_size_gallons` from a caller directly**, however small the change looks: a second
assembly of one rule is how every defect below was born. It carries all six guards, including
that a configuration missing from Jobber's payload is a FAILED READ and never an empty field.

**⚠ `p_allow_clear` is FALSE from the poll and must stay that way.** A clearing adopt is the most
destructive write this sync can make.

**⚠ A full-fleet replay is EXPECTED after any change to the poll's `fields` string.** Adding
`customFields` changed the payload bytes of all 476 staged rows at once, so every row flipped to
`needs_populate` and drained at 10 per 5-minute cycle, about 4 hours. That is the shape change, not
drift.

🛑 **THE SMOKE TEST FOUND THAT THE ADOPT PATH HAD NEVER WORKED, AND AN ADVERSARIAL SWEEP OF THE
RESULT FOUND FIVE MORE. Every one was a COMPOSITION defect: the pieces were individually correct and
individually tested, and nothing had ever run the statement the script actually emits.** Worth
carrying because the checks that passed were not weak ones, they were pointed at the wrong level:
a 16-case truth table over `fn_shadow_decision` and a sentinel lifecycle over `fn_record_shadow`,
both with hand-built arguments, both green while the composed path could not complete.

| defect | why it was invisible |
|---|---|
| adopt passed our POST-adopt value, so `IN_SYNC` (which sits above `ADOPT`) won and the drift guard aborted every adoption | both functions were correct in isolation |
| the drift guard read our value from a minutes-old snapshot, so a concurrent staff edit was overwritten and a real CONFLICT executed as an ADOPT | the guard fired correctly on *shadow* drift, so it looked alive |
| an open `conflict_at` did not freeze the row: an ordinary IGNORE re-baselined it and re-armed a later silent overwrite | `already_in_conflict` was loaded and never read |
| the seed script's `matched` control was a work-queue size, so a fully-seeded fleet reported `BROKEN` and refused to run | it read correctly on run 1, when the queue was full |
| re-applying `2026-08-17_1636` would silently revert the freeze fix | prevented only by an unrelated assertion, i.e. by luck |
| a Jobber non-answer was adopted as "empty"; under `--allow-clear` that is an UPDATE to NULL | checked in aggregate (a 10% tolerance) instead of per row |
| the `--only` flag defaulted to `[0]`, so every run WITHOUT it aborted before deciding anything | `''.split(',')` is `['']` and `Number('')` is a finite `0`; only an absent-flag run could catch it |
| the RPC raised `23502` for every property whose capacity is NULL (353 of 458), so the shadow never recorded | `to_jsonb(NULL::integer)` is SQL NULL, not JSON null, and the caller swallows the error: replay 200, `sync_log` success, dashboards green |

⇒ **When you verify tooling like this, exercise the emitted statement, not the functions it calls.**
The technique that worked: render the real template out of the source file (never retype it), run it
against arranged state in a rolled-back transaction, and **keep the pre-fix version as a control that
must still fail**. Three passing cases proved nothing until the fourth one broke.
⇒ And `public.properties.grease_trap_size_gallons` is **live** (120 changes, 3 `app_source`s,
`client.update_property_capacity` EXECUTE-able by `authenticated`), so any batch write to it needs a
value predicate, not a plan captured minutes earlier.
⇒ **A green pipeline is not evidence the feature ran.** The NULL-capacity defect sailed past a 200
replay, a cleared `needs_populate` and a `success` `sync_log` row, because the caller deliberately
cannot fail the property sync. **Ask what the feature WROTE, not whether the run succeeded**: the
check that found it was "did the RPC record a shadow for all ten replayed properties, or only for
the one that adopted?"
⇒ **And test every BASELINE, not one cell per variable.** Both the `--only` and the NULL-capacity
defects were reachable only from the baseline nobody exercised (flag absent; capacity NULL). The
`2026-08-18_0210` VERIFY shipped ten assertions and every one used a sentinel created WITH a value.

⚠ **Bind by configuration GID, never by label.** Four numeric grease-trap fields exist; two differ
only by a capital S and one of those is archived, and "GT size" appears twice.
⚠ **When `customFields` is finally added to the poll's `fields` string, the payload bytes of all 476
staged rows change at once**, so the first sweep flips every row to `needs_populate` and drains at 10
per cycle, roughly 4 hours. A full-fleet replay is expected there, not a fault.

### 🛑 WE DO NOT SYNC EMPLOYEES FROM JOBBER AT ALL, AND AN UNKNOWN CREW MEMBER IS DROPPED SILENTLY (2026-08-17)

Yannick in Slack: *"for some reason Michael Escobar does not show on calendar, he has been in jobber
for few weeks"*. **It was not a Calendar bug.** There is no employee sync, so a new Jobber team member
never arrives on his own. Employees are hand-created, and that manual step is not written down
anywhere a person would look.

Re-measured against the live code 2026-08-18, not taken from the original migration header:

| | |
|---|---|
| entities `sync-jobber-poll` pulls | `clients`, `invoices`, `jobs`, `properties`, `quotes`, `visits`. **No users.** |
| user handler in `webhook-jobber` | **zero** matches for `USER_UPDATE` / `USER_CREATE` / `handleUser` |

🛑 **AND THE FAILURE IS SILENT, NOT LOUD.** Visits DO pull `assignedUsers { nodes { id } }`, and
`syncVisitTeamFromJobber` does this:

```ts
for (const member of (nodes || [])) {
  const empId = await findEntityBySourceId('employee', 'jobber', member.id)
  if (empId) want.add(empId)              // <-- unknown user skipped, no error, no log
}
await supabase.from('visit_team').delete().eq('visit_id', visitId)   // crew wiped FIRST
if (ids.length) await supabase.from('visit_team').insert(...)
await supabase.from('visits').update({ assigned_driver_id: ids[0] ?? null })
```

With no bridge row the id resolves to null and is dropped. A visit assigned **only** to that person
therefore ends with an **empty `visit_team` and a null `assigned_driver_id`**, which is exactly the
"does not show on calendar" symptom, and it had been true for the weeks he was in Jobber.

**⇒ THE BRIDGE ROW IS THE LOAD-BEARING HALF.** An `employees` row alone puts someone in the Calendar
team picker but still drops every Jobber-side assignment. Both are required:

1. `public.employees` row, `status='ACTIVE'` (the picker lists ACTIVE only), and
2. `public.entity_source_links` (`entity_type='employee'`, `source_system='jobber'`) whose `source_id`
   is the **FULL base64 GID** `Z2lkOi8vSm9iYmVyL1VzZXIv...`, never the bare numeric id from the
   `manage_team` URL. All existing employee links store the full GID.

⚠ **Naming.** Most ACTIVE staff are stored first-name-only (Grecia, Fred, Aaron, Yannick, Diego,
Mark, Anthony); **Michael Escobar is stored under his full name** because Fred named that record
explicitly on 2026-08-18. There is no enforced convention, so match Jobber and do not "normalise" an
existing row on the strength of the majority shape.
⚠ **`employees.full_name` is UNIQUE.** Two people with the same name cannot both exist, and
retiring a duplicate requires freeing the string before the survivor can take it (a rename that
ignores this raises `23505`).

🛑 **DUPLICATE EMPLOYEES COME FROM SAMSARA, NOT FROM PEOPLE DOUBLE-ENTERING, AND IT WILL
RECUR (measured 2026-08-18).** We had two Michaels for a day. Not a fat-fingered picker entry: two
source systems each produced a row for the same human, 67 minutes apart.

| row | created | link | how |
|---|---|---|---|
| 40 `Michael` | 08-17 14:32 ET | `jobber` `gid://Jobber/User/4255910` | `2026-08-17_1210`, `match_method='manual'` |
| 41 `Michael Escobar` | 08-17 15:39 ET | `samsara 60524052` | **`match_method='webhook_new'`, auto-created by the Samsara driver feed** |

**The Samsara feed inserts an employee without reconciling against existing rows**, so anyone who is
both a Jobber user and a Samsara driver can land twice. The correct end state is what Grecia, Mark
and Anthony already look like: **ONE row carrying BOTH a `jobber` and a `samsara` link**, which is
exactly what `entity_source_links` is for. `Mark noltion` (36) and `Anthony Clark` (38) are the
residue of this happening before and being cleaned up the same way: INACTIVE, links moved off.

⇒ Resolved for Michael by `2026-08-18_1545`: samsara link moved 41 -> 40, 40 renamed, 41 retired.
⇒ **The generator is not fixed.** The next person who exists in both systems will duplicate again.
When it happens, consolidate onto the row that holds the `visit_team` history rather than the newer
row, and move the link rather than re-creating it.

✅ **COVERAGE, measured 2026-08-18: 8 ACTIVE employees, 8 with a Jobber link, 0 without.** Fred's
standing rule: *"all the drivers and team members should have a link to their Jobber reference."*
The `active_without_jobber_link` check at the end of `2026-08-18_1545` is a re-runnable probe for it.

⚠ **This will recur on the next hire.** Nothing detects it: there is no "Jobber has a user we do not"
check anywhere. Until an employee sync exists, adding a driver is a manual two-step, and the symptom
if it is forgotten is not an error but a quietly empty crew.

Worked example, including the 443-visit Jobber sweep used to find every visit he was on:
`docs/migrations/2026-08-17_1210_add_michael_escobar_driver.sql` and `..._1230_backfill_michael_visit_team.sql`.

### 🛑 The line-item drift reconciler IGNORES ARCHIVED JOBS ON PURPOSE. Do not "fix" it (Fred, 2026-08-03)

**Fred, 2026-08-03: *"leave it, don't extend the reconciler to archived jobs."*** Settled, not deferred.

`sync-jobber-job-drift` builds its candidate set with
`.not("job_status", "in", "(archived,closed,destroyed)")` (index.ts line 110), plus a 14-day
recent-terminal arm for jobs that went terminal in our DB but are still open in Jobber. Four archived
jobs (**10000171, 10000188, 2505, 10000196**) therefore hold stale line-item rows that will **never**
converge, and that is the correct outcome:

- Measured: those four appear **0 times** in `ops.client_service_options`, which filters
  `job_status <> 'archived'`. **No app surface reads them.**
- Widening the sweep adds a Jobber API call cost to **every 30-minute run, forever**, for records
  nothing queries. The reconciler is already the object of a measured throttling budget (see the
  BATCH / LINE_PAGE cost math in that file's header).
- **10000196 drifts in the OPPOSITE direction** (4 job-scope rows on our side, 5 in Jobber). It is
  pre-existing, it is not evidence the exclusion is wrong, and it is inert under the same decision.

⚠ A related trap in the same area: **never dedupe `public.line_items` DB-side.** The reconciler
multiset-diffs against Jobber and re-inserts within 30 minutes. And the duplicate groups still visible
on **live** jobs are faithful mirrors of Jobber's per-visit overrides, not orphans. Full workings:
[`docs/audits/2026-08-03_qty0_orphan_cleanup_and_source_fix.md`](docs/audits/2026-08-03_qty0_orphan_cleanup_and_source_fix.md).

### ⚠ ACCESS HOURS: the store is `properties.access_schedule` (jsonb), 24h `"HH:MM"`, and it is now CHECKed (2026-08-19)

Fred asked whether access hours should be stored 24h or 12h. **24h, and it is not really a choice:**
12h sorts wrong lexically (`"9:00 PM" < "9:00 AM"`), needs parsing on every read, is locale-dependent,
and breaks the `::time` casts queries use. **12h is a display concern only** — the Visit Calendar
converts at render (its CLAUDE.md rule 9).

**Where it lives, which is not where people look.** `public.properties.access_schedule` is **jsonb**,
per-day `{"mon":{"open":"21:00","close":"06:00"}, …}`. The flat `access_hours_start` / `access_hours_end`
you see on `client.properties`, `ops.properties`, `ops.v_calendar_visit`, `ops.v_route_today` and
`ops.v_service_due` are **DERIVED** (`public.fn_sched_open/_close/_days`) — the legacy trio was dropped
from the table on 2026-08-10. Read the derived pair; **write only `access_schedule`.**

⚠ **`text` vs `time` is MOOT here** — the values live *inside* jsonb, which has no `time` type. The only
reason to want one is to stop malformed values, and that is what the constraint now does.

**`properties_access_schedule_shape_chk`** (`2026-08-19_0130`) pins every day entry's `open`/`close` to
24h `"HH:MM"` via `jsonb_path_exists` + `like_regex`. Measured before applying: 901 properties, 199 with
a schedule, **0 would fail**, so it is **VALIDATED**, not NOT VALID. Mutation-tested with a 17-case
truth table, all correct.

- **Accepts:** NULL · `{}` · same-day · **overnight (`open > close`, 1,006 of 1,331 entries — 76%)** ·
  the `00:00`–`00:00` "All day" sentinel (32 properties / 222 calendar visits).
- **Rejects:** 12h `"9:00 AM"` · hour 25 · minute 75 · single-digit hour · truncated minutes · json
  null · missing key · number instead of string · `"HH:MM:SS"` · array · one bad day among good ones.

🛑 **THE REGEX IS DUPLICATED ON PURPOSE — CHANGE BOTH TOGETHER.** `client.update_property_operational`
is the **only** function that writes this column and it already validates the identical pattern (plus
the day keys, which a CHECK cannot do: set-returning functions like `jsonb_object_keys` are illegal in
a CHECK). **The constraint is not for that path — it is for the BYPASS path**, and that is not
hypothetical: `app_source='sql'` was the single largest writer in `audit.logs` over the preceding 12
hours at **314 rows**. A migration, script or console query reaches the column without the RPC.

⚠ `jsonb_path_exists(jsonb, jsonpath)` is IMMUTABLE and legal in a CHECK; its `_tz` sibling is STABLE
and must never be used there.

⚠ **Overnight is IMPLICIT and no column type would capture it.** `close <= open` means "into the next
morning" — correct for the commercial night routes, and 76% of the data. It is a semantic gap, not a
type gap, so every consumer computing "is arrival inside the window" must handle wraparound. Also
measured: **0 properties currently vary hours by day**, so the derived flat pair is lossless *today* —
but lossy by construction the moment one does.

### ⚠ CACHE INVALIDATION IS A DB TRIGGER SENDING A PRIVATE BROADCAST — AND IT FAILS SILENTLY

`public.tg_broadcast_inval`, attached as `zzz_broadcast_inval` on **`visits`, `clients`,
`derm_manifests`, `manifest_visits`, `address_row_map`**, calls
`realtime.send(payload, 'inval', 'inval:'||tg_table_name, true)`. The Visit Calendar subscribes to those
private `inval:*` channels and refetches on receipt. **No app subscribes to `postgres_changes`.**

🛑 **The trigger body is wrapped in `exception when others then null`.** A broken send logs **nothing**
— no error, no failed request, no audit row — and the apps simply stop refreshing. Verified working
2026-08-18; re-verify by calling `realtime.send(...)` directly as `postgres`, which is the real path and
**writes no row**.
⚠ `realtime.messages` has exactly one policy: `app_inval_read`, **read-only**, `using (topic ~~ 'inval:%')`.
Clients receive and cannot send, so a broadcast attempted with a user token returns **202 Accepted** and
is silently dropped. 202 means accepted for delivery, not delivered.

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

**🛑 `clients.status_source` ('jobber' | 'manual') GATES THE POLL'S REACTIVATION. Do not remove it or
"simplify" the branch (2026-08-13).** `webhook-jobber`'s `handleClient` reactivates any client it finds
INACTIVE-and-not-archived. That is correct for a Jobber unarchive and **wrong for a deliberate
deactivation**: setting a client INACTIVE in the Client App was silently undone by the next `*/5` poll,
landing as an ordinary `app_source='jobber'` audit row with **nothing to announce it**. Jobber has no
idea we changed anything, so there is no upstream signal to read — the intent has to be stored here.
`client.update_client_status` writes `'manual'`; the branch now skips those rows. This is the same pin
`client_class_source` already provides for `client_class`, honoured a few lines above in that same
function — **do not invent a second mechanism for the next column that needs it.**

⚠ **Only the reactivation branch is gated.** `c.isArchived` still forces INACTIVE, because there both
sides agree. ⚠ **And a status that arrived FROM Jobber stays `'jobber'`** — the pin protects human
answers, not every INACTIVE row.

**How it was proven, because the obvious test gives a false pass:** flag the client's own
`raw.jobber_pull_clients` row `needs_populate` and invoke `sync-jobber-poll`, so the poll signs and
POSTs the `CLIENT_UPDATE` itself. Then A/B the SAME row on `status_source` alone — unpinned reverted in
6s, pinned held. **Two controls are required**: the staged payload must carry `isArchived=false` (or the
archive branch is what held it), and `needs_populate` must go `TRUE → FALSE` (or the replay never ran and
"it stayed INACTIVE" proves nothing). Migration `2026-08-13_0130`, commit `b875064`.

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

**🛑 A GDO NUMBER DOES NOT CHANGE ON RENEWAL. AN EXPIRED PERMIT KEEPS ITS ROW (Fred, 2026-08-24).**
Verbatim: *"even if a GDO expires their numbers doesn't changes on renewal, so even if it's expired
keep it until the next GDO updates it, but it's number will not change unless the physical address
of the place changes."*
⇒ `permit_expiration` in the past is **not** a reason to deactivate a permit, drop its printed row
from a DERM address sheet, or withhold it from a filing. `status` decides inclusion;
`permit_expiration` is a fact about the paper. Live example: 242-WYN's **GDO-14760** (Nino Gordo)
expired 2025-12-31 and correctly keeps row 2 of every sheet it appears on. A tidy-up that expires
stale permits would silently shorten printed sheets.

**🛑 IN A MULTI-TENANT BUILDING, ATTRIBUTE A PERMIT BY THE TENANT, NEVER BY THE ADDRESS.** 241-WYN
(Wynd 27) and 242-WYN (Wynd 28) are two units at the same street address, and **two of Wynd 28's
permits were attributed to Wynd 27 by two separate audits** that verified the permit PDF's Facility
Location against the client's address -- the one field that is identical for both. GDO-13814 was
demoted 2026-06-27; **GDO-16146 survived a "skeptic-verified" full audit on 2026-07-18 and was
demoted 2026-08-24** (`2026-08-24_1530`) on Fred's reading of the Client App. The discriminator is
`gdos.client_location_id` (the tenant), not the address.
⚠ **Three more ACTIVE permit numbers are still claimed by two clients each** and each needs the same
tenant-level adjudication: `GDO-07147` (212-TRUE + 213-TRUE), `GDO-08422` (209-TRUE + 214-MYK),
`GDO-08912` (139-LTG + 144-LTG).
⚠ A client with **zero** permits is a legal state, not a gap: 241-WYN now has none. The form is
built for it -- Section B reads "GDO #", "Facility Name **(if no GDO#)**", "Complete Facility
Address **(if no GDO#)**" -- and the generator renders `greatest(1, permit_count)` = one row.

Historic workaround: `webhook-airtable` used to write the GDO Number to all `service_configs` rows
for the client (not just GT), and the 2026-05-25 backfill caught the historic gap. That feed is dead
(Airtable retired 2026-07-24), so nothing writes the GDO Number automatically today. Whatever writes
it next must keep the same write-to-all-rows behaviour.

### DERM link guards (added 2026-07-07 — read before writing `manifest_visits` or `derm_manifests`)

`public.manifest_visits` is guarded by BEFORE triggers that apply to **every** writer (apps, RPCs, scripts, backfills):
- **`trg_aa_link_same_client`** — REJECTS a link whose visit belongs to a different client than the manifest (the root cause of the 25 cross-client mis-links remediated 07-06/07). The sanctioned co-loaded-ticket path is **`public.file_manifest_on_shared_ticket(white#, client_id, visit_id)`** (files the client's own sibling manifest inheriting the shared sheet docs + links, idempotent).
- **`trg_ab_link_one_white`** — one white manifest # per visit (same-white sibling/consolidated-dump re-links allowed).
- **`trg_ac_link_visit_not_after_dump`** — REJECTS a link whose `visit_date > dump_ticket_date + 1 day` (grease is pumped BEFORE the dump; +1-day grace for dump-ticket entry noise — **NOT for overnight shifts**, which move `visit_date` EARLIER and can never make a visit lag its dump). Blocks the fuzzy-linker "over-attach the client's NEXT visit" class. NULL dump passes.
  - 🛑 **IT GUARDS THE LINK, NOT THE INVARIANT. A LEGAL LINK BECOMES ILLEGAL WHEN EITHER
    SOURCE TABLE MOVES, AND NOTHING RE-CHECKS IT** (found 2026-08-24 validating the LWT endpoint).
    The trigger fires on `manifest_visits` but reads `visits.visit_date` AND
    `derm_manifests.dump_ticket_date`. Both can move afterwards.
  - ⚠ **THE OBVIOUS DIAGNOSIS IS WRONG, AND IT COST ME A MIGRATION DRAFT.** Comparing the link
    timestamp to the visit's CURRENT `completed_at` says "the link was made against a pending visit".
    It was not. `completed_at` had been rewritten twice; the value in the row today is the SECOND
    completion. Reconstructing `visit_status` from `audit.logs` **at the link instant** shows the
    visit WAS completed when linked. **A "state at time T" read from a mutable column is a
    measurement of NOW. Rebuild it from the audit trail or do not claim it.**
  - **What actually happened to visit 6756 / ticket 830673:** linked 2026-07-22 while dated 07-19 and
    marked completed, so every guard correctly passed. On **2026-07-29 13:46
    `jobber-daily-completion-reconcile` REVERSED the completion** (status → scheduled,
    `completed_at` → NULL) because the job had not been done — a Jobber note on 07-20 04:41 reads
    *"Couldn't compete the job because the PTO had broken"*. **That** is when the link became false,
    eight hours before the date moved at all.
  - 🛑 **SO THE VISITS SIDE IS DELIBERATELY NOT BLOCKED, AND DO NOT "FIX" THAT.** The writer is
    an automated reconciler recording the TRUTH that the service never happened; a RAISE there would
    force the DB to keep asserting a service that did not occur, and would stall a cron into
    `public.sync_log`, **which nothing reads**. Measured 2026-08-24: 3 health checks in
    `attention` right now; `rpa-derm-health` has been so for 10 consecutive days after 26
    consecutive clean ones. ✅ **FIXED the same day, see "The health watchdog" below.** ⚠ And `attention` is structurally unusable as a signal, not merely
    unread: it carries no severity and no dedup, so **89% of the last 7 days' attention rows are
    one source** (`jobber_visit_drift`, 161 of 180), which re-reported the SAME unresolvable visit
    every 30 minutes. Across its history 4,408 item-reports describe **105 distinct problems**.
    Health verdicts are **138 of 34,849 sync_log rows (0.40%)**, buried under 21,863 Jobber poll
    records - `sync_log` is a sync JOURNAL and verdicts were put in the wrong table. Also `public.ripple_reschedule_visit` takes
    3,826 of the 4,569 `visit_date` writes and moves a CHAIN (avg 5.67 rows, up to 29), so a
    table-level RAISE aborts the whole ripple.
  - ⚠ **DO NOT "JUST PUT THE CHECK IN `ripple_reschedule_visit`" — IT IS THE ONE PLACE THE CHECK
    CANNOT FIRE.** I wrote that recommendation and it is wrong; the adversarial pass caught it and
    the function body confirms it. Line 19 is
    `IF m.deleted_at IS NOT NULL OR m.visit_status IN ('completed','cancelled','skipped') THEN RAISE`,
    and line 35 filters those out of the chain. **All 690 manifest-linked visits are `completed`**, so
    ripple refuses every one of them. Measured: 579 ripple moves on 157 linked visits, **0 while
    completed.** It only reaches a linked visit AFTER something un-completes it — which is exactly the
    6756 sequence, cron at 13:46 then ripple at 21:34.
  - **THREE app paths actually reach a linked visit's date**, so an RPC-level check must cover all
    three or it is theatre: `/rpc/ripple_reschedule_visit` (579 moves / 157 visits),
    `/visits` — direct PostgREST table writes (136 / 74), and **`/rpc/edit_calendar_visit`** (8 / 7).
    That last one is the dangerous shape: SECURITY DEFINER, `EXECUTE` granted to `authenticated` on
    both the `public` and `ops` copies, writes `visit_date` from `p_patch`, and its ONLY status check
    in 143 lines is `IF v_visit.visit_status = 'skipped'`. It does not refuse completed. Proof it
    reaches completed visits: audit id **22987**, 2026-06-26 14:14 ET, `fred@ayache.com` moved visit
    5836 from 06-24 to 06-21 while it was completed with a tap. It has not yet done so on a *linked*
    visit (0 of 8), but nothing stops it. **The detector is path-independent and covers all three;
    that is why it, not an RPC check, is the thing that shipped.**
  - **Shipped 2026-08-24** (`2026-08-24_1510_manifest_link_completed_visit_guard.sql`):
    **`trg_ad_link_visit_completed`** (no linking a visit that has not happened — defence in depth,
    it would NOT have caught 6756, costs 0 of 690), **`trg_ae_dump_date_keeps_links_valid`** (the
    manifest side; also closes the NULL→value hole `trg_ac` allows), and
    **`derm.v_manifest_link_date_conflicts`** — the detector, and the only thing covering the
    un-completion path. `rpa-derm-monthly` now returns `data_quality.conflicts` + a per-row
    `anomaly`, so the report cannot be filed unknowingly. ⚠ Read `data_quality.checked`: `false`
    means the overlay query failed and an empty list proves nothing.
  - **4 conflicting rows exist** (visits 1265, 1496, 3942, 6756); only 6756 breaks the +1 grace.
    ⚠ **The other three are probably the SAME bug, not overnight shifts.** For each, the other
    DERM-required visits serviced that day went onto a LATER ticket and only the flagged one was
    pulled backwards. And the grace's stated justification does not hold: it cites a 06:00-ET
    operating-date cutoff, but `fn_reconcile_visit_operating_date` was rewritten 2026-07-02 (five days
    BEFORE the guard) to use the plain ET clock date, per Fred's decision that the operating night
    "must NOT move the date" — measured, 1149/1149 visits match the ET clock date and 0 of 320
    early-AM visits are pulled back. **Shrinking the grace to 0 is the open recommendation**; it would
    reclassify those three as violations, so it is Fred's call, not a silent change.
  - ⚠ **It surfaces on a REGULATOR-FACING document.** `derm.v_lwt_monthly_rows` serves these to the
    LWT monthly filing, where they read as waste offloaded before it was collected. NOT clamped or
    hidden: silently correcting a compliance date is worse than printing an odd one.
  - 🛑 **`photos.exif_taken_at` IS NULL ON EVERY JOBBER PHOTO — AND THE PHOTOS ARE STILL DATED.
    DO NOT CONCLUDE "no photographic evidence" FROM THE TABLE.** All 24 photo rows on visit 6756 have
    NULL `exif_taken_at`, `exif_latitude` and `exif_longitude`: the metadata is stripped in transit.
    But the crew's camera app **burns the timestamp and street address into the pixels**, so opening
    the image gives you both. That is how the 6756 question was settled — two photos stamped
    `Jul 19, 2026 at 10:09:03 PM` and `10:22:55 PM` at `701 Brickell Ave, Miami FL 33131`, the second
    showing the interceptor open with a solid grease cap still in it. **Look at the image before
    concluding it cannot be dated.** (Related: `reference_normalising_decode_hides_the_difference` —
    the normalised read hides what the raw one still carries.)
  - 🛑 **AND BEWARE CIRCULAR CORROBORATION IN `derm`.** Three things look like independent
    confirmation of a link and are generated BY it: `derm_manifests.client_id` (tautological —
    `trg_aa_link_same_client` enforces it), the Stamp Studio card (`fn_card_from_link` materialises
    `derm.address_row_map` on link INSERT, leaving `source='derm-link'`, `card_from_link:true` and
    NULL reads), and `derm.v_lwt_monthly_rows` (a view over the link). **Check
    `address_row_map.source`: only `claude-vision-v1` means the paper was actually READ.**
  - 🛑 **6756 IS STILL OPEN AND THE DATABASE WAS NOT CHANGED.** **The DATA question is settled** (photos, the PTO note, the
    reconciler reversal, and a unanimous peer pattern: every other 07-29 DERM visit went onto a load
    dumped 07-30 or 08-04). **What is NOT settled is REGULATORY**: the paper filed with Miami-Dade
    lists 175-PV as a generator, so unlinking makes our DB honest and leaves the county copy saying
    something else. That is Fred's call, plus whether the 2026-07 LWT report already went out. Full
    evidence and the one-statement fix: `docs/audits/2026-08-24_manifest_link_830673_visit_6756.md`.
- **`trg_zz_card_from_link`** (AFTER) — materializes the Stamp Studio card for the (ticket, client) on link.
- `public.derm_manifests` has **`CHECK service_date <= dump_ticket_date`** (grease dumps after service, never before).
- **`derm_manifests_dump_fields_present_chk` (NEW 2026-07-21): `dump_ticket_date` and `disposal_facility_id` may NOT be NULL.** Business rule (Fred): the DERM address manifest is only uploaded *after* it comes back from the city, by Diego, reading the finished paper sheet, so both values are printed on it at creation time. A manifest is born complete; linking visits is a separate later step. The three filing RPCs (`file_manifest`, `file_manifest_on_shared_ticket`, `derm.file_manifest_and_link`) now raise a readable **`22023`** first; a raw write gets **`23514`**. The constraint is deliberately **`NOT VALID`** (7 soft-deleted legacy rows carry a NULL facility) so `VALIDATE CONSTRAINT` fails **by design**, do not delete those rows to make it pass. ⚠ **Two traps when testing this:** (1) "0 NULLs today" proves nothing, that state was manufactured by a backfill of 387 rows on 2026-07-15 plus a *browser-side-only* form check; (2) `fn_derm_inherit_ticket_fields` silently heals a NULL from unanimous ticket siblings, so a random row always looks fine. **Test against a singleton ticket or a fresh number** (15 live rows are singletons) or you get a false pass. Migration: `docs/migrations/2026-07-21_derm_manifest_required_dump_fields.sql`.
- **Soft-deleting a `derm_manifests` row re-points its Stamp cards** (`trg_ad_card_reptr_on_delete` → live (ticket,client) sibling, else NULL) and re-filing re-resolves them (`trg_resolve_card_manifest`) — so a delete+re-file never leaves a Stamp card pointing at a dead manifest (which would make it invisible). Writes only `derm.address_row_map`.

⚠ **Restore/backfill gotcha:** replaying a backup that contains an OLD cross-client pair now RAISES (BEFORE triggers fire before `ON CONFLICT`) and aborts the transaction — filter those pairs out first. Only 1 sanctioned legacy cross-client row exists (815064, pending Diego). Also: `trg_ae_ticket_key_unambiguous` RAISES when a white# collides with an existing yellow-only ticket key (or vice versa) — same filter-first rule for restores.

### 🛑 A DERM SHEET IS A REGULATOR-FACING COMPLIANCE FORM: FILL IT, NEVER MARK IT (Fred, 2026-08-04)

**Fred, verbatim:** *"The sheets cannot have a QR Code, so don't do it, the sheets should only be
filled with data, any modifications to it we already did them for the Manifest Generator, adding a QR
code is not valid."*

This binds **every generator and every pixel-writer in this repo**, above all `redact-manifest-sheet`
(which composites black boxes onto the sheet image) and the whole `derm.*` stamp-geometry / row-band
pipeline. **No QR, no barcode, no watermark, no tracking mark, no "tiny corner glyph"** on a DERM
address sheet or manifest, however small and however useful it would be to us. The only sanctioned
modification to the form is the data the form asks for, in the fields the form provides. The pdf-service
carries the same rule (`Building Apps/unclogme-pdf-service/CLAUDE.md`).

**⚠ THIS WILL BE RE-PROPOSED, AND IT SOUNDS LIKE THE OBVIOUS ANSWER.** "Print a QR of the `sheet_no` so
we can tell which sheet the driver actually used" is the natural fix for the 2026-08-04 mis-stamp (a
generated 1-client sheet was resolved onto a ticket where the driver had filled a different 3-facility
pad sheet). It was raised in that brainstorm and **rejected**. Do not re-derive it from the mechanism
and ship it.

**✅ What IS allowed: READING what DERM already prints.** The sheet number in the top right and the
facility names on each Section B row are already on the paper, and OCR **observes** the document rather
than altering it. That is why sheet identity is verified by
`derm.address_sheet_scan_reads` / `derm.address_sheet_row_reads` and the `ocr-address-sheet-*` edge
functions, and it is the ONLY sanctioned route to sheet-identity verification.

### 🛑 A GENERATED SHEET PRINTS ONE ROW PER **PERMIT**, NOT PER CLIENT (2026-08-24)

Fred: generated manifests (top-right sheet number 1000+) must be AI-stamped, and 833395 was not.
The cause was a grain mismatch, and it is the thing to know before touching any slot arithmetic.

`pdf_service/app.py` expands a client to **one row per ACTIVE, strictly well-formed `GDO-<digits>`
permit**, sorted by number, rendering a single row for a client with 0 or 1 permit. That is Fred's
rule for a multi-tenant building: one shared trap, one GDO per tenant, every permitted facility on
its own line. Confirmed on the paper for ticket-833395 / sheet 1093:

| printed row | permit | facility |
|---|---|---|
| 1 | GDO-13814 | 242-WYN Wynd 28 - Pasta |
| 2 | GDO-14760 | 242-WYN Wynd 28 - Nino Gordo |
| 3 | GDO-16146 | 242-WYN Wynd 28 - Pari Pari |
| 4 | GDO-11529 | 069-TCE |
| 5 | GDO-11532 | 032-LG |

⚠ **It is the PERMIT count, never the property count.** 242-WYN has **7 properties** and **3 permits**,
and takes **3** rows. Reaching for `public.properties` here gives the wrong answer on the one client
that makes the difference.

**The defect:** `derm.fn_generated_sheet_slot` expanded correctly, so stamps landed right, but
`derm.fn_sheet_rows_all_confirmed` read `address_sheet_clients.slot` (the CLIENT ordinal) straight
into the printed-row arithmetic `((slot-1)/5)+1` / `((slot-1)%5)+1`. On any sheet carrying a
multi-permit client every slot beneath it compared against the wrong printed row, so the gate could
never pass and the sheet could never auto-resolve. Fixed by `2026-08-24_0450`.

**⇒ `derm.v_sheet_printed_rows` is now the canonical facility-grain slot map** (one row per PRINTED
row, with `first_row` / `printed_page` / `row_on_page` / `is_first_row`). Read it. Do not re-derive
row arithmetic from `slot`, in any new object.

🛑 **`address_sheet_clients.rows_printed` IS FROZEN AT GENERATION TIME AND MUST STAY THAT WAY.**
The old code counted `public.gdos` live on every call. A printed sheet is a historical artefact and
that table is mutable, so adding or deactivating one permit for 242-WYN silently re-indexed the
**five** already-printed sheets carrying it, moving stamps onto other clients' printed rows. Through
the FP blackout that is one client shown another's line on a regulator-facing document, and nothing
would have raised. Same class as the Jobber custom-field shadow: the stored "what we saw then" is
the control, not today's value.

🛑 **THE ROW READS ARE NOT SHEET IDENTITY, AND THE SCAN-READ REQUIREMENT IS NOT REDUNDANT.**
Sheets 1091 / 1092 / 1093 are **progressive regenerations**: 1091's printed order is a strict prefix
of 1092's, which is a strict prefix of 1093's. A ticket's clients occupy the SAME printed rows on all
of them, so `fn_sheet_rows_all_confirmed` confirms **four sheets at once** and cannot tell them
apart. Only the sheet-number scan read separates them. My first draft of `2026-08-24_0450` asserted
that sheet 1091 would be refused, and the migration's own VERIFY rejected it, correctly. **Never
weaken the scan-read match on the grounds that the row reads already confirm the sheet.**

⚠ `fn_generated_sheet_slot` now returns **NULL** when the printed order was never recorded, which is
what its own comment always claimed. The old body returned **1**, i.e. a stamp on row 1 of a sheet
whose layout is unknown. 0 of the 68 bound manifests were in that state, so no live value moved.

**✅ Fleet state, measured 2026-08-24: 17 folders carry a generated sheet, 16 fully stamped.**
The one exception is **ticket-312024 and it is a PAPER problem, not code.** Its second image is
**handwritten pad sheet 421**, not page 2 of generated sheet 1099, so `fn_sheet_image_position
('ticket-312024', 2)` is NULL and the closed-world rule refuses. Image 1 matches sheet 1099 slots 1-5
exactly. Either page 2 of 1099 needs scanning, or those four clients were served on pad 421 and the
ticket is a two-sheet job. **This is the 2026-08-04 mis-stamp shape and the refusal is the system
working**, so do not force it.
⚠ Three high-confidence row reads on that folder's image 2 (`026-HAZ`, `177-STK`, `226-JEK`) are
near-miss OCR of `026-HAP` / `199-STK` / `226-JER`. They describe pad 421, not sheet 1099, and are
inert today because image position 2 is unreachable. They would become misleading if image 2 were
ever replaced with the real page 2.

✅ **THE ROW OCR IS NOW SCHEDULED** (`sheet-row-ocr-sweep`, `5-55/10`, via
`public.fn_request_sheet_row_ocr()`, added `2026-08-24_1520`). It had never been called by anything:
deployed and working for weeks, with `derm.address_sheet_row_reads` filling only when somebody
invoked it by hand. That is what left 833395 unresolved, because a ticket whose clients are a
SUBSET of its sheet can only resolve through the superset arm, which reads row reads; exact
client-set equality needs none, which is why every other sheet resolved.

🛑 **ITS TARGET PREDICATE IS AN ATTEMPT LEDGER, NOT READ-PRESENCE, AND THAT IS NOT A STYLE CHOICE.**
Copying `fn_sheet_number_ocr_targets`' "exclude pages that already have a read" would burn a vision
call on an unparseable page **every ten minutes for ever**, silently, with the cron reporting
`succeeded` throughout. The two handlers differ: `ocr-address-sheet-number` writes a row even at low
confidence, `ocr-address-sheet-rows` has `if (payload.length)` at `index.ts:205` and writes **nothing**
for a page that parses to zero rows. So `derm.row_ocr_attempts` records that we ASKED; three
attempts and the ticket is left alone.
⚠ The budget is keyed on a fingerprint of the ticket's image list, so replacing a bad scan re-arms
it. Without that a page that failed on a poor photo could never be read again.
⚠ **One TICKET per cycle, not one image.** The handler takes `{ticket}` and does every page of it,
so a 3-page ticket is 3 vision calls in one request. The number sweep's `{limit: 2}` counts images.

**✅ THE COMPLETION FLAG IS PINNED** (`2026-08-24_1545`). `derm.stamp_sheet_status` gained
`reopened_at` / `reopened_by`, maintained by `trg_aa_reopen_pin`, and
`fn_resolve_generated_sheet_for_ticket`'s auto-complete leg now has two extra predicates:
- it requires every placed stamp to be **renderable** (`stamp_page` inside the ticket's image list).
  Its only condition used to be "no card is unplaced", which never asked whether a stamp could be
  DRAWN, and is exactly why the Studio reported **3/3 over a blank sheet**;
- it **will not touch a row with `reopened_at` set**. Measured: a human set `completed=false` at
  10:56:39 ET and this leg restored `true` at 11:25:41.

🛑 **The human case is NOT the important one.** `derm.trg_zx_generated_sheet_return_review` writes the
same `completed=false` as the MACHINE's request for a visual check when a returned sheet photo
arrives, and it has fired 4 times. Row triggers fire alphabetically and `zx` sorts before `zy`, so
the request and its erasure could land microseconds apart in one transaction. **`completed=false`
means "a human must look at this" throughout this estate; the resolver was the outlier.**
⚠ A row that has NEVER been completed has `reopened_at` NULL, so first-time auto-completion is
unchanged. Distinguishing "not yet completed" from "deliberately re-opened" is the entire point.

⚠ **Open question for Fred, pre-existing and not introduced by this work:** a multi-permit client
gets **one** stamp, on the first of its printed rows (`is_first_row`), because `address_row_map`
holds one card per client per ticket. If the intent is that every permitted facility on a shared
trap is marked, the data model cannot express it today.

### 🛑 `stamp_page` IS AN ORDINAL INTO A LIST THAT MOVES. THE WITNESS IS WHAT MAKES IT SAFE (2026-08-24)

Fred deleted one address image of ticket-833395 in the DERM Tracker. The Stamp Studio then showed
**"3/3 stamped" over a blank sheet**: the counter reads `stamp_placed_at`, the renderer reads
`stamp_page`, and only the second one had broken.

**The mechanism.** `derm.address_row_map.stamp_page`, `derm.address_sheet_scan_reads.page` and
`derm.address_sheet_row_reads.page` are all **ordinals into `derm.ticket_page_images(white#)`**, a
list recomputed from the ticket's LIVE manifest images on every call. Remove an image and every
later ordinal slides down. `ticket_page_images`' own comment says OCR pages are appended
*"UNCONDITIONALLY in page order (existing stamp_page indexes must never move)"* and then discloses
the staleness gate two sentences later; the two halves of that comment contradict each other, and
the gate wins.

🛑 **THE BLANK PAGE IS THE MILD CASE.** Deleting the LAST image leaves an ordinal past the end and
the document goes blank, which is loud. Deleting a **MIDDLE** image leaves every ordinal IN RANGE
pointing at the WRONG page, and every bound check reads clean. `stamp_page` is `effective_page` in
`derm.v_stamp_row_bands` and therefore the page selector in `derm.fn_blackout_targets`, so that
produces a **customer-facing redaction built from the wrong page** rather than a blank card.

✅ **THE FIX: `derm.address_row_map.stamp_image_url`**, the image the stamp was placed on, captured
at placement time by `trg_ac_stamp_witness`, with `derm.fn_reconcile_stamp_pages(white#)` putting
the ordinal back from it. A trigger on `public.derm_manifests` fires it on the exact edit the DERM
Tracker makes. Deleting a page now re-points the surviving stamps automatically.
- The witness is captured by **one BEFORE trigger on the table, not by editing the five writers**
  (`set_stamp_position`, `auto_place_page`, `trg_autoplace_generated`, the resolver, and the next
  one). Every writer is covered and no body was retyped -- see the `CREATE OR REPLACE` rule above.
- 🛑 **It writes ONLY on a fresh placement** (INSERT, or `stamp_placed_at` changes). If it re-derived
  on any `stamp_page` change, the reconcile would confirm its own answer and the witness would be
  worthless. Renaming the trigger is also breaking: it must sort AFTER `trg_ab_autoplace_generated`.
- 🛑 **The reconcile is ALL-OR-NOTHING per ticket.** If any placed stamp's witnessed image is gone,
  it changes nothing and `derm.v_stamp_placement_health` reports the folder. A half-moved folder
  reads as healthy to a per-row check.
- 🛑 **It moves `stamp_page` ONLY.** It deliberately does NOT move `page_block_extents`,
  `page_row_rules` or `redacted_manifest_docs`. If the geometry no longer matches, the blackout lane
  re-blocks and the card goes BLANK until a person re-measures. Auto-moving an extent onto a page
  nobody measured is the act that leaked client data on 2026-08-19. A blank card is a complaint; a
  wrongly-redacted one is a regulator-facing document showing another client's line.

🛑 **WHY IT IS A WITNESS AND NOT A RE-KEY, which is the tempting "proper" fix.** `stamp_page` is the
PK of `page_block_extents` and `page_row_rules` across 626 published documents and 620 served rows
with manual band overrides. The deciding fact: **`derm.band_review` has no page column** -- it is
keyed on the band VALUES -- so a re-key leaves every human acceptance still matching while the band
describes a different physical page, converting this estate's human backstop into a false all-clear.

✅ **`derm.v_stamp_placement_health` is the watch list. Severity 1 must be EMPTY.**
Severity 2 is a stale page map (inert until the image set moves); severity 3 is a placed stamp with
no witness. ⚠ **The witness was backfilled from each stamp's own ordinal**, so `STAMP_IMAGE_MOVED`
detects divergence FROM 2026-08-24 ON and validates nothing historically. It found one thing on its
first run: `ticket-310607`'s scan read names `address_1.webp` while the live image is
`address_1.jpg`.

⚠ **`derm.sheet_page_images` disagrees with `ticket_page_images` on 17 of 131 folders and has no
reader.** Do not call it by hand to "check" a folder; it will give you the opposite of the truth.

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

**Update 2026-08-19: IT RECURRED, and there is now a DETECTOR. Read this before the 08-03 note.**

Fred, on client 306-16: *"i can't see the blackedout manifest even though is stamped by AI and then
manually by us"*. The stamp was real; the MEASUREMENT was missing, so `fn_blackout_targets` returned
nothing and the card was a permanent placeholder. **34 clients were in that state**, not one.

🛑 **THE FAILURE IS INVISIBLE BY CONSTRUCTION.** `redact-manifest-sweep` reports `succeeded` every
five minutes throughout, because **an empty work queue is a successful run**. Nothing else looks at
it. That is why it took a client noticing a blank card.

✅ **`derm.v_blackout_blocked_sheets` now names the state directly** (`2026-08-19_2320`). Empty is
healthy. Non-empty means those clients are seeing nothing. **Watch it after any stamping session.**

🛑 **KEY ON (dump_folder, effective_page), NEVER ON THE FOLDER.** My own first sweep asked whether a
FOLDER had any extent and found 4 blocked folders. The gate is per PAGE, and the detector found
**5 folders / 8 pages** — `window5-sheet3` has an extent for page 2 and none for page 1, which a
folder-level check cannot see. The migration's VERIFY caught my wrong expectation and rolled the
whole thing back.
⚠ And `effective_page` is `COALESCE(stamp_page, page)`, i.e. the STAMP page. These genuinely differ:
ticket-311780's 306-16 row is `page=1, stamp_page=2`. Keying an extent on `page` writes rows that
satisfy nothing while the migration looks applied.

🛑 **THE DOCUMENTED RERUN PATH DOES NOT EXIST.** The 07-10 note below says to rerun
`ocr-band-measure` + `apply_bands.js`. **Neither is real** — grep finds them only in prose. Every
`page_block_extents` write in this repo's history has been a hand-authored migration. So a
measurement pass is a manual task, and nothing prevents the backlog rebuilding. It has now rebuilt
twice.

✅ **GENERATED sheets (#1000+) can be templated at `25.8 / 64.4`**, the value measured for
ticket-310429, 831325 and 831938 and unchanged since. Their geometry comes from our own pdf-service,
so it is deterministic. **SCANNED sheets cannot** — measured fleet range is 23.6-29.4 top,
58.8-66.4 bottom, and templating one would be a guess about a customer-facing redaction. Two scanned
sheets (`ticket-832996`, `window5-sheet3`) are deliberately still blocked for that reason and need a
real vision pass.

**Update 2026-08-03: the GENERATED sheets have now been measured, and there is a SECOND way to snap
a page.** Two things above were true when written and are incomplete now.

1. **The 9 generated-sheet manifests were the live proof of the "no extent, no doc" rule, and they are
   fixed.** Generated sheets (#1000+) had never been through a vision pass, so `fn_blackout_targets`
   hard-gating on a `derm.page_block_extents` row returned **0 rows, nothing even queued**, and the FP
   FOG card was a permanent placeholder on all 9. Fred found it through his own invariant ("specially
   if they have a GDO Online Report, they must have a FoG eManifest", 041-MB / sheet 1072).
   `2026-08-03_0046` added the extents; `2026-08-03_0309` tightened them after Fred rejected the first
   pass on sight (*"you're removing too much, these top and bottom parts are not needed to be blacked
   out"*). Final values are the **measured span between the first and last printed form rule**, not a
   guess: `ticket-310429` p1 **25.8 / 64.4**, p2 **25.8 / 63.7**, `ticket-831325` p1 **25.8 / 64.4**
   (that scan is too light for the ink-density threshold, so it inherits p1's geometry).
   - 🛑 **NARROWING is the leak direction, widening is not.** The two boxes are opaque overwrites, so
     widening can only add black; a roster row above `blocks_top` or below `blocks_bottom` is served to
     the customer as-is.
   - 🛑 **NEVER re-derive an extent from `derm.v_stamp_row_bands`.** It is built
     `WHERE stamp_y_pct IS NOT NULL` and is therefore blind to a printed-but-UNSTAMPED slot. Sheet 1072
     page 2 has five printed slots and two stamped: a band-derived extent stops at 41.85% and serves
     everything below it. The extent must cover every printed slot, empty ones included.
   - The same release fixed an off-by-one in `redact-manifest-sheet` itself: ImageScript's `drawBox`
     takes a **1-based** y and fills `[y, y+h-1]`, so both boxes stopped one row short and a sliver of
     the previous client's address line survived. Pre-existing and fleet-wide; all 553 redacted docs
     were regenerated in place (same filenames, same URLs). Customer-side write-up:
     `Building Apps/Field Portal/docs/08-changelog.md`.
2. **`ocr-band-measure` + `apply_bands.js` is no longer the only route.** `2026-08-03_0340` added
   machine **band line-snapping** behind a confidence gate, backed by the new table
   `derm.page_row_rules` (PK `dump_folder, effective_page, rule_pct`: detected printed form-rule
   geometry as a % of page height). It writes through the EXISTING manual-override channel
   (`address_row_map.band_y0_pct` / `band_y1_pct`), so no view changed.
   🛑 **The gate is ALL-OR-NOTHING PER PAGE and must stay that way** (G1: every boundary finds a rule
   within 1.5% of page height; G2: bands stay monotonic and non-overlapping after snapping).
   Half-snapped bands stop tiling the roster, and a gap between two bands is a strip belonging to
   nobody, which is exactly how a neighbour's row becomes visible.
   ⚠ `band_source` is NOT written on that path, so a row showing `band_is_manual = true` may have been
   snapped by machine and not touched by a human. Full detail:
   `Building Apps/DERM Stamp Studio/docs/08-changelog.md`.

**🛑 UPDATE 2026-08-19, AND IT IS THE MOST IMPORTANT RULE IN THIS SECTION: AN EXTENT DOES NOT
REDACT ANYTHING. IT OPENS THE GATE ONTO WHATEVER BANDS ALREADY EXIST. NEVER ADD ONE TO A SHEET
WHOSE BANDS ARE STILL DERIVED.** Adding a `page_block_extents` row is the *unsafe* act, not the safe
one, because `fn_blackout_targets` then starts publishing that page using bands that were never on
the paper. A DERIVED band is a stamp-midpoint heuristic (`v_stamp_row_bands`), and the stamp template
is a FIXED set of y values reused across sheets, so it does not match any particular scan.

Measured the hard way. Six extents were inserted at 21:06:58Z with the blanket values `25.8 / 64.4`
copied from `2026-08-03_0309` (which measured a *different* sheet), and the `*/5` sweep published
**30 redacted documents in 90 seconds**. Three separate exposures, all confirmed by opening the
served files, not by reasoning:
  - **ticket-833049** served its five `effective_page` 1 clients a page they do not appear on. Tell:
    the object name carries the fingerprint, and all five page-1/page-2 pairs were byte-identical
    (`m1713-a6eaf476ac.jpg` == `m1716-a6eaf476ac.jpg`, 144,028 bytes).
  - **ticket-311780 / ticket-832487** left the top of the first client's slot unblacked for every
    page-mate, plus interior slivers to 1.665pp (~10px, a full text line).
  - **ticket-310590 p2**, live since 2026-08-10 and unrelated: **165-LPB is PRINTED on the sheet but
    owns no `address_row_map` row**, so the derived bands stretched across its slot from both sides.
    004-BAO's document showed 165-LPB's GDO number and name; 186-PV's showed its street address.
Repaired in `2026-08-19_2355`: 28 bands snapped to detected rules, 6 extents corrected, all 38
mis-redacted documents withdrawn, 28 regenerated and verified 129/129 regions per-pixel.

Rules that fall out of it, and the reasoning is what matters, not the numbers:
- **An unowned printed slot is the dangerous shape**, and there are two kinds: an *empty* slot (fine,
  nothing to leak) and a slot printed for a client we hold **no row for** (leaks). Derived bands do
  not know a slot exists, so they stretch across it. Snapped bands leave it to nobody and both black
  boxes cover it. **Check for a printed-but-unrowed facility before trusting any page.**
- **`band_y0`/`band_y1` must each BE a detected `page_row_rules.rule_pct`.** That is the only check
  that fails on derived bands, on a uniformly shifted tiling, and on a partly-stamped roster.
  "Bands tile contiguously" and "each stamp sits inside its own band" both PASS on the bands that
  leaked, so neither is evidence of anything.
- **The extent is bound to the printed roster, never to the band envelope.** Assert
  `top_pct <= min(band_y0)` and `bottom_pct >= max(band_y1)`, never equality: `ticket-310590` p1's
  fifth slot is empty, so its extent is deliberately WIDER than its bands. Equality would shrink the
  extent off the empty slot, which is the `2026-08-03_0046` leak.
- **G1 in `2026-08-03_0340` is NOT a gate to override.** If it fails, you are almost certainly
  evaluating it against DERIVED bands, which is the wrong operand. Against snapped bands it passes at
  distance 0.000 by construction. A first draft of `2026-08-19_2355` framed this as an override and
  was wrong; the same page's residual (1.665) appeared in that draft as both "the worst leak we
  prevent" and "not a G1 failure".
- **`fn_blackout_targets`' page-identity check is scoped to `source='claude-vision-v1'` and is
  therefore INERT for every `derm-link` sheet**, which is all of these. Until that changes, a person
  reading the client names off each scan is the only page-identity check that exists. Do it.
- **Reverse image order is NOT itself a defect.** `ticket-310590`'s `address_1` is the sheet printed
  "Page 2 of 2" and it is correct, because all that matters is that `imgs[effective_page]` holds the
  clients assigned to that `effective_page`. `ticket-833049` fails that real test; 310590 does not.
- 🛑 **Deleting an extent does NOT withdraw a published document.** `customer.work_orders` reads
  `derm.redacted_manifest_docs.url` directly and nothing garbage-collects it, so closing the gate
  leaves every bad document served *forever* and unregenerable. Withdrawing means deleting the
  `redacted_manifest_docs` row. And roll back in the order extents -> bands -> docs: NULLing bands
  first re-stales the fingerprint and the sweep republishes from the derived bands.

**🛑 `ticket-833049` IS HELD BY A DATABASE CONSTRAINT** (`page_block_extents_no_ticket_833049`).
`ticket_page_images` groups on `address_row_map.page`, and nine of its ten rows say page=1 while one
says page=2, so it emits `[address_1, address_1, address_2]` and `effective_page` 1 resolves to the
physical page 2 image. ⚠ **The obvious one-line fix (normalise the page=2 row) DOUBLES the exposure
from 5 clients to 10 and erases the only machine-visible tell** - and that row is in fact the only
one that agrees with the paper. It is also a handwritten **6-slot** form carrying 5-slot template
bands. Read PART 5 of `docs/migrations/2026-08-19_2355` before dropping that constraint.

**⚠ STILL OPEN, needs Fred: 31 already-serving pages carrying 109 documents are still on DERIVED
bands.** Tonight's sheets were simply the ones that got extents. Every one of those pages has the
same class of misalignment and wants the same snap.

> **MOSTLY CLOSED 2026-08-20 by `2026-08-20_1538_snap_remaining_derived_bands.sql`.** Re-measured
> against the real test (does the row carry a `band_y0_pct`/`band_y1_pct` override) rather than the
> counts above: **71 served documents on derived bands, not 109**. 63 rows across 17 pages were
> snapped onto detected printed rules and are regenerating. `2026-08-20_1610` then fitted 4 more.
> **13 documents across 7 pages remain and need a person**, split three ways, because the three groups need different answers:
>
> | group | pages | what is true |
> |---|---|---|
> | measured neighbour exposure | `ticket-311045` p1 (1.60pp), `ticket-310607` p1 (1.57pp), `ticket-832194` p2 (1.40pp), `ticket-831047` p1 (1.01pp) | real, same order as the 1.665pp leak confirmed on 2026-08-19 |
> | detection failed, exposure UNKNOWN | `ticket-831102` p1+p2, `ticket-831325` p1 | dark scans (roster median 210-216 vs 244-255 everywhere that worked) |
> | no exposure, left alone deliberately | `ticket-831710` p1 | fails G1 at 1.512 but every error is INWARD, so it crops its own row and reveals nobody |
>
> 🛑 **Do NOT quote the raw numbers for the middle group (23.3pp, 17.4pp, 11.4pp).** Only 3 rules
> were detected where 4 edges were needed, so every edge snapped to the same rule and the arithmetic
> is an artifact of a failed instrument. The honest word is "unknown".
>
> **🛑 THE FORM PRINTS MID-SLOT DIVIDERS AS WELL AS SLOT BOUNDARIES, SO "SNAP TO THE NEAREST
> RULE" IS AMBIGUOUS. This is the most reusable thing learned here.** Detected rules sit ~3.5pp
> apart while a client's printed slot is ~7.8pp, so a nearest-rule snap can land on a divider. On
> `ticket-310607` one edge had candidates 1.82 and 2.34 away: a coin flip, not a measurement. **That
> ambiguity, not the size of the derived error, is what makes a page unsafe to snap.**
>
> ⇒ Fit a **contiguous tiling** across the whole roster instead, and believe it only when three
> independent checks agree: (T1) every client's `stamp_y_pct` falls strictly inside its assigned
> slot, which is strong because a human placed that stamp on that client's own row; (T2) the tiling
> is contiguous, monotonic and no two clients share a slot; (T3) the chain's first and last boundary
> match the independently measured extent. `2026-08-20_1610` did this for `ticket-310607` (4 rows,
> each old band reaching 1.16-1.57pp past a printed rule into the row below).
> ⚠ Independent corroboration worth knowing: the true boundaries ink **darker** than the dividers
> between them (0.82 vs 0.75 mean). Do not use ink to choose the tiling, but do check it agrees.
> ⚠ **A tiling that "passes" can still be wrong.** Two pages passed T1-T3 and were rejected by eye:
> their slots were unevenly spaced (11.7 / 14.4 / 11.9) and on one the stamp sat 0.08pp off a
> boundary, so T1 passed on a technicality. Require roughly uniform spacing and real clearance.
>
> **✅ A PROVABLY LEAK-FREE FALLBACK EXISTS, and it needs a product decision rather than more
> analysis.** Setting a band to the two detected rules that BRACKET its stamp cannot leak: every
> slot boundary is itself a detected rule, so a bracketing interval can never cross one. The cost is
> that where a divider falls between them the client sees about half of their own row. That is a
> customer-visible degradation, so it is Fred's call, not a cleanup. Withdrawing the document is the
> other option and produces the blank FOG card he objected to on 2026-08-19.
>
> ⚠ **`fn_blackout_targets(p_limit integer DEFAULT 3)`.** Calling it with no argument returns 3 rows
> and looks like an empty backlog. I read that as "only 3 of 63 will regenerate" and nearly reported
> the migration as inert. Pass a real limit.
>
> ⚠ **4 rows on `ticket-828604` were snapped but will NEVER regenerate**: `fn_blackout_targets`
> gates on `stamp_placed_at IS NOT NULL` and those rows have none. Their documents are frozen
> snapshots carrying bands whose source no longer exists (7 such rows fleet-wide). Improving the
> data does not republish them.

### ✅ BAND GEOMETRY CAN NOW BE CHECKED MECHANICALLY: `derm.v_band_edges_off_rule` (2026-08-21)

Fred: *"prioritise building the fleet-wide printed-rule detection pass."* Done, `2026-08-21_0736`
`_0741` `_0811` `_0819`. **Check `derm.v_band_edges_off_rule` after any stamping session and after
any band edit. Empty is healthy.** It is the band-geometry sibling of
`derm.v_blackout_blocked_sheets`.

🛑 **THE WORKLIST IS EMPTY AS OF 2026-08-24, AND ALL FOUR TIERS HAVE NOW BEEN REVIEWED: 80 flagged
bands, ZERO real leaks** (`2026-08-23_2333`, `2026-08-24_0012`, `2026-08-24_1700`). Every one is
recorded in `derm.band_review` with its evidence. **Empty is healthy: anything appearing there is
new.**

🛑 **THE SINGLE MOST USEFUL MEASUREMENT, AND THE CHECK DOES NOT EXPOSE IT: SIGN THE EDGE ERROR.**
Severity 4 is "the right two boundaries, but the edges are not precisely on them". The SIZE of that
gap says nothing about safety; the DIRECTION decides it, and it is one subtraction:

| edge | below its boundary | above its boundary |
|---|---|---|
| top | inward, crops the client's OWN row | **OUTWARD, into the slot above** |
| bottom | inward | **OUTWARD, into the slot below** |

**22 of the 26 severity-4 bands were inward on BOTH edges** and cannot expose a neighbour at any
magnitude: the worst number on the whole worklist (`window4-sheet5` p2 / 136-BB, 2.618pp and
1.849pp) is inward and completely harmless. That reduced a 26-band review to 4 that needed looking
at, whose worst outward error was **0.334pp**, about two pixels, against 1.665pp for the confirmed
226-JER leak.
⇒ `derm.v_band_edge_check` exposes `top_gap_pct` / `bottom_gap_pct` as ABSOLUTE distances, which
throws away the half of the information that decides whether a finding matters. **Adding the signed
value is the cheapest improvement available to this check.** Not done yet.

⚠ **`scripts/probes/derm_band_review/sliver-ink.js` measures a sliver on the ORIGINAL scan**, per
scanline, reporting the longest dark RUN as well as the ink fraction: ink alone cannot separate a
printed rule from a dense line of text. **It was not sufficient on its own** -- on a two-pixel
top-side sliver it returned ink 0.46-0.65, which is the printed rule's own ink dominating the
fraction, and reads alarming. The served document at 16x
(`scripts/probes/derm_band_review/edge-zoom.js`) is what settled those. Use both.

⚠ **`page_grade = 'FAILED'` makes `slot_verdict` UNKNOWN, which is an evidence gap and not a finding
about the band.** Both such pages turned out to be handwritten **SIX-slot** forms, and the
alternation model assumes five, which is one reason a page grades FAILED.

⚠ **A THIRD PRINTED-BUT-UNROWED FACILITY, still with no detector:** `window4-sheet1` p2
(ticket 824713) carries a handwritten **"Pari Pari", 127 NW 27th St suite 105** that we hold no card
for. Blacked for both clients today because the bands are snapped and stop short of it, so inert --
but this is exactly what turned `ticket-310590` p2 into a real leak. With `window10-sheet4` p2 and
`window3-sheet5` p2 that is three, and all three suggest a missing manifest link. Open for Fred.

✅ **SEVERITY 1 AND 2 ARE BOTH CLEARED: 47 bands reviewed, ZERO leaks** (`2026-08-23_2333`,
`2026-08-24_0012`). Severity 2 is "the band starts or ends INSIDE a slot", which is the 226-JER
shape that actually leaked, so it carried the strongest prior of the four tiers and still produced
nothing. Causes, all verified against the paper:
1. **the form's header bar reads as a slot boundary** — full-width and indistinguishable from a real
   boundary by any local measurement;
2. **a missed mid-slot divider flips the phase** — on a dark or handwritten scan every
   boundary/divider label below the miss inverts, so a band that is exactly one printed slot reads
   as boundary-to-divider;
3. **the extra slot is empty**;
4. **the client's own handwriting overflows the printed slot**, so spanning it is correct;
5. 🛑 **THE WRITER SOMETIMES FITS MORE CLIENTS ON THE FORM THAN IT HAS SLOTS, BY HALVING THE ROWS.**
   `window7-sheet6` p1 carries EIGHT clients on a six-slot form: four normal 5.5pp slots, then four
   squeezed one per printed ROW at 2.7pp with name and address on a single line. `window10-sheet3`
   p1 does the same with seven. Their 2.7pp bands are CORRECT. **A band that tight cannot be judged
   from a whole-page render — check it against the served document**, which is how those four were
   cleared.

⚠ **Nothing in the database would have caught the four real leaks either.** They were bands holding
another facility's PRINTED text, and on ticket-831047 that neighbour has no row on the sheet at all,
so there was nothing to collide with. **The tiers are a screen, not a verdict: they turned 635
documents into 47 that a couple of hours cleared. Keep them, and expect them to be mostly false.**

✅ **THE PASSED POPULATION HAS BEEN SAMPLED TOO, WHICH IS THE CHECK NOBODY REMEMBERS TO RUN.**
Reviewing only the bands a check FLAGS cannot tell you whether it passes something it should not.
53 SERVED DOCUMENTS were opened on 2026-08-24: 37 spread evenly through the 555 passed bands, **all
11 passed bands that sit on a page the detector did not grade OK** (the least trustworthy geometry
in the passed set), and the 5 repaired leaks as controls. **Every one shows exactly one facility.**
The five repaired documents confirm the fixes are live: 226-JER's file no longer carries Wynd 28's
address, and 032-LG's no longer carries Marie Blachere.
⚠ **State the limit honestly: 48 of 555 is 8.7%.** That rules out a high leak rate in the passed
population, not a low one. What it is combined with is stronger: all 47 flagged bands were also
inspected, and all four known leaks sat in the flagged population while broken, so the check
demonstrably catches this defect class.

🛑 **TWO PRINTED-BUT-UNROWED FACILITIES FOUND BY EYE, AND THERE IS STILL NO DETECTOR FOR THIS:**
`window10-sheet4` p2 carries **Chima Steakhouse, 2400 East Las Olas Blvd** and `window3-sheet5` p2
carries a **Carrot Express**, both printed on the sheet with no `address_row_map` row. Both sit in a
GAP between bands today, so both are blacked for every client and neither leaks. But this is exactly
what turned `ticket-310590` p2 into a leak on 2026-08-19, and it suggests those two tickets are
missing a manifest link. Open for Fred.

✅ **`derm.band_review` is the ledger.** A band a person has looked at and accepted drops off the
worklist, so "empty is healthy" stays true. 🛑 **It is keyed on the BAND VALUES, not just the row: edit
the band and the review stops matching and the row returns to the worklist.** An acceptance is a
statement about one geometry, never a standing exemption, and both migrations prove it by moving a
reviewed band mid-transaction and asserting it comes back. Use
`scripts/probes/derm_band_review/annotate.js` to render a page with its detected rules drawn over the
scan, and `served.js` when the bands are too tight to judge that way.

✅ **SEVERITY 1 IS CLEARED, AND THE RESULT IS WORTH KNOWING BEFORE YOU WORK THE REST: 22 bands, 15
pages, ZERO leaks** (`2026-08-23_2333`). Severity 1 is "the band covers more than one printed slot",
the shape that leaked all of Marie Blachere to 032-LG, and it screened at zero precision. Four
causes, each verified against the paper:
1. **the form's header bar reads as a slot boundary** (4) — the bottom edge of "B: Origination of
   Waste" is full-width and indistinguishable from a real boundary by any local measurement;
2. **an undetected mid-slot divider flips the phase** (9) — on a dark or handwritten scan the faint
   divider inside a slot is missed and every label below it inverts;
3. **the extra slot is empty** (5);
4. **the client's own handwriting overflows the printed slot** (2) — so `SPANS_MULTIPLE` is
   sometimes the CORRECT state, not merely imprecise.

⚠ **Nothing in the database would have caught the four real leaks either.** They were bands holding
another facility's PRINTED text, and on ticket-831047 that neighbour has no row on the sheet at all,
so there was nothing to collide with. Telling "covers an empty slot" from "covers an occupied one"
means reading the page. **The tier is a screen, not a verdict: it turned 635 documents into 22 that
an hour cleared. Keep it, and expect it to be mostly false.**

✅ **`derm.band_review` is the ledger.** A band a person has looked at and accepted drops off the
worklist, so "empty is healthy" stays true. 🛑 **It is keyed on the BAND VALUES, not just the row: edit
the band and the review stops matching and the row returns to the worklist.** An acceptance is a
statement about one geometry, never a standing exemption, and the migration proves it by moving a
reviewed band and asserting it comes back. Use `scripts/probes/derm_band_review/annotate.js` to
render a page with its detected rules drawn over the scan; that is what the review was done with.

🛑 **TWO VERDICTS, AND SAFE IS THE CONJUNCTION. Reading either one alone is the mistake that
shipped at 07:36 and was fixed at 08:11.**

| | question | values |
|---|---|---|
| `edge_verdict` | is a line of TEXT bisected? | `ON_RULE` / `OFF_RULE` / `UNSCANNED` / `STALE` |
| `slot_verdict` | does the band cover exactly the printed rows THIS CLIENT owns? | `ONE_CLIENT` / `PART_SLOT` / `SPANS_MULTIPLE` / `ODD_SLOT` / `UNKNOWN` |

The pass shipped with `edge_verdict` alone and its own comment saying "ON_RULE is necessary, not
sufficient". **A caveat in a comment is not a control: 39 structurally wrong bands were passing it**,
29 with an edge on a mid-slot divider or header bar and 10 containing a whole slot boundary. An edge
on ANY printed rule is safe from bisecting text, and says nothing about which slot the band covers.

🛑 **`ONE_CLIENT`, NOT `ONE_SLOT` (renamed 2026-08-24). A CLIENT CAN LEGITIMATELY OWN SEVERAL
PRINTED SLOTS.** A generated sheet prints one row per ACTIVE GDO permit, so 242-WYN with three
permits owns three consecutive slots and its band must cover all three: they are its own facilities,
and blacking two would hide the client's own compliance record from itself. The old rule
(`inner_boundaries = 0 AND inner_dividers = 1`) is just the N=1 case of the real one
(`= N-1` and `= N`), which is why 637 of 638 bands did not move when this shipped.
`expected_slots` is a visible column, so a flagged row shows what the check expected.

🛑 **N IS PER PAGE, NOT PER CLIENT, and the obvious implementation is wrong.** Reading
`address_sheet_clients.rows_printed` (the permit count) breaks a correct band: on sheet 1082,
043-MIL's two permits are printed rows 5 and 6, which STRADDLE a page boundary, so on either page it
owns exactly one slot. N counts `derm.v_sheet_printed_rows` entries whose `printed_page` maps
**through `derm.fn_sheet_image_position`** to the band's `effective_page` -- `effective_page` is an
IMAGE POSITION and `printed_page` is the LOGICAL page, and those genuinely differ.
⚠ 577 of 638 bands resolve no generated sheet (the handwritten `window<N>-sheet<M>` set) and fall
back to N=1. The permit rule is a fact about OUR generator, not about a sheet filled in by hand.

⚠ `slot_verdict` uses the kind of the NEAREST rule whatever the distance, so a band can be
`ONE_CLIENT` + `OFF_RULE`: the right two boundaries, edges a few tenths off them. That combination is
the lowest-risk group on the worklist.

🛑 **`UNSCANNED` IS A DISTINCT STATE FROM CLEAN**, and `derm.page_rule_scans` is what makes them
distinguishable: one row per page the detector RAN on, whatever the outcome. Before this pass, rules
existed for 30 of 160 pages, so **515 of 626 served bands sat on pages with zero detected rules** and
the check's silence meant "unread". A page graded `FAILED` there is known-undetectable; a page absent
from it has never been looked at.

**How detection works, in one line:** score each scanline by the LONGEST CONTIGUOUS HORIZONTAL RUN of
dark pixels across the full form width. A printed rule is one unbroken run; a line of text inks as
much but in many short pieces. Ink fraction, which the 2026-08-03 detector used, cannot separate
them, which is why it failed on a light scan. Run ~1.00 = a slot boundary spanning the whole form;
run ~0.41 = a mid-slot divider stopping at the first vertical column line. `page_row_rules.kind`
records which, from the strict ALTERNATION of the two down the roster rather than from a threshold.

⚠ **`SPANS_MULTIPLE` HAS ONE KNOWN FALSE POSITIVE, 4 of the current 14.** The bottom edge of the
form's "B: Origination of Waste" header bar is a full-width printed line and is **indistinguishable
from a slot boundary by any local measurement** — checked on `ticket-831047` p1 against the paper:
run 0.990 and 2px thick, versus 0.991 and 3px for the real boundary below it. Its tell is positional:
the interior boundary is both the first on the page and above the band's own stamp.

**⚠ THE TOOLING IS `scripts/probes/derm_band_review/`, AND ITS README LISTS THE SCORERS THAT WERE
MEASURED AGAINST KNOWN TRUTH AND REJECTED. Read it before building another one.** Four were rejected
before the run-length one worked; a fifth (the stamp test, below) was built, measured and thrown away.

🛑 **THE STAMP TEST DOES NOT DISCRIMINATE PHASE. DO NOT RE-ADD IT.** It looks like the obvious
independent control: a person placed each stamp on that client's own row, so the correct boundary set
holds exactly one stamp per slot (T1 from `2026-08-20_1610`). It agreed with the run-length phase on
128 of 133 pages, which reads as corroboration. **It cannot work**: the interval between two
consecutive mid-slot DIVIDERS also contains exactly one stamp, offset by half a pitch, so both phases
score identically by construction and the differences were end-of-list artifacts. Adopting it flipped
`ticket-832194` p1 from five clean bands to four `SPANS_MULTIPLE`. T1 discriminates only when each
stamp is tested against ITS OWN assigned slot, and that assignment is what the classification is
trying to establish.

⚠ **`page_row_rules`' primary key includes `source` since `2026-08-21_0811`, and that is load-bearing.**
Without it an upsert from a new generation overwrites the provenance of any hand-recorded rule at the
same position, and a later `DELETE ... WHERE source = ...` removes it outright from a table with no
audit trigger. That happened to 61 of the 198 hand-recorded rules on 2026-08-21. Nothing was lost
only because the detector had re-found every position, which is why they collided in the first place.
**The regression corpus would have quietly become the detector's own output, and recall would have
kept improving for the wrong reason.**

⚠ **A confirmed practical limit: my own eyes were 0.66pp out.** `2026-08-21_0651` set a repaired edge
to 33.500 from a ruler render, describing the printed rule as being at 33.30. The detector puts it at
34.156. The repair was safe (whitespace, nothing bisected) but off the rule by more than half a text
line. **Use the detector for the value; use eyes to decide which edges are wrong.**

⚠ **Two traps in the pipeline itself, both of which manufactured findings.** (1) The roster trim
margin was 1.0pp and on `window3-sheet5` p2 the first real boundary sits 1.08pp above the measured
extent top, so the trim cut it and that band led the worklist with a 5.5pp gap that was pure artifact.
The fix was TWO LISTS: the edge check uses every rule found, because a header bar is a real printed
rule; the classification uses the roster's alternating chain with the bars removed, because they
break the alternation. (2) Peak refinement can move a detection by half the suppression distance, so
one printed line was detected twice 0.32pp apart on 9 pages, and **in an alternating sequence a single
duplicate flips every label below it** — two pages verified clean by eye were reporting bands that
span multiple slots.

### 🛑 JOBBER NOTES ARE SCOPED TO THE **JOB**, NOT THE VISIT (Fred, 2026-08-18)

`Visit.notes` reads like a per-visit field and is not one. **JobNote is JOB-scoped** (every visit
of the job returns the whole job's note history), **ClientNote is CLIENT-scoped** (repeats on every
visit of that client, for ever). Proven on Jobber with a control, on a client with two completed
visits on the SAME DAY on different jobs: **0 JobNotes shared**, and the one note they do share is
the ClientNote.

⇒ A driver's photo can only belong to a visit **of that note's job**, which is why two visits close
in time usually disambiguate themselves: they are normally different jobs (measured: **70 of 140**
same-client pairs inside the 2-day window, exactly half). The residual 70 are same-job, 11 of them
same-date, where the crew is identical in 11 of 11 and only `completed_at` separates them.

**Before touching photo attribution, read
[docs/reference/jobber-note-photo-attribution.md](docs/reference/jobber-note-photo-attribution.md)**
- the two-anchor rule (distance on `completed_at`, eligibility on `noon(visit_date)`, so a photo
can never be handed to a sibling that later refuses it), the 24h trust cutoff on `completed_at`
(109 of 1,072 completed visits sit further from their own visit_date, worst case 34 days), and the
repair that ran on 2026-08-18: **99 cross-job links soft-deleted** after Jobber was asked which job
owns each attachment (102 disputed, 3 fail-closed skips, 0 photos orphaned, 0 cross-client, all of
them May `jobber_migration`). ⚠ **34 same-job duals and 80 same-job "farther visit" links were
deliberately LEFT ALONE**: inside one job Jobber does not link notes to visits at all, so only a
heuristic could decide them.

⚠ **The sync is ADD-ONLY**: it can put a photo on the right visit but never takes it off the wrong
one, so shipping a better rule does not heal history.

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

### 🛑 THE LWT MONTHLY ENDPOINT SCOPES PER **ACTIVITY**, NOT PER TICKET (2026-08-24)

`GET /functions/v1/rpa-derm-monthly?month=YYYY-MM` (read-only, `x-rpa-key`, ETag) feeds Jonathan's
Miami-Dade **Liquid Waste Transporter** monthly filing from `derm.v_lwt_monthly_rows`.

The form covers *"all transportation activities where liquid waste was picked up **OR** offloaded in
Miami-Dade County"*, and an ACTIVITY is a pickup. **Both obvious builds are wrong, in opposite
directions**, and both were measured over 2026 before anything was written:

| build | effect |
|---|---|
| filter on "offloaded in Dade" alone | **DROPS 11 tickets / 53 activities** (Broward offloads carrying Dade pickups) |
| apply the OR at TICKET grain | **OVER-reports**, because **20 tickets mix counties** |

Measured on August: ticket `311045` has **0 in-scope rows of 2**, `312024` **3 of 9**, `310590`
**6 of 8**. So the predicate is `pickup county = 'Dade' OR the ticket offloaded in Miami-Dade`,
evaluated per row. The asymmetry that makes it cheap: if the ticket offloaded in Dade then every
pickup on it qualifies, so only Broward-offload tickets get trimmed.

**The predicate lives in the VIEW (`in_scope`), never in the edge function.** That keeps it testable
without HTTP and stops a second, divergent copy appearing the next time something needs it.

🛑 **`pickup_date` IS `visits.visit_date`. NEVER `derm_manifests.service_date`**, which is a misnomer
holding the DUMP date (622 of 659 LIVE manifests have the two identical; 37 differ). Serving it would make every
pickup equal its own offload. **If you ever see that, service_date has crept back in** - the
migration's VERIFY asserts against exactly this.

⚠ **`gallons` is ALWAYS null and that is the contract, not a gap.** The filed quantity is the TRUCK
CAPACITY resolved from the decal on the caller's side; we store no measured volume per load. `truck`
and `truck_capacity_gallons` are served so the caller has the input. The fee arithmetic
(`total gal x $0.00419`, **truncated** to cents, never rounded) lives only in John's generator, which
is validated against filed county pages. Do not add a second implementation here.

⚠ **Ticket number is `coalesce(white_manifest_number, yellow_ticket_number)`** and that is total:
white 502 / yellow 157 / neither 0 / colliding 0, and the 502-157 split matches the disposal-facility
split EXACTLY, which is what makes `white => Miami-Dade offload` a fact rather than a convention.
`wwtp_ticket_number` and `wwtp_receipt_number` are populated **0** times: never read them.

⚠ **County vocabulary differs by table.** `public.properties.county` stores `'Dade'`;
`public.disposal_facilities.county` stores `'Miami-Dade'`. Comparing them naively matches nothing.

⚠ **`state` IS AN EXPLICIT MAPPING, NOT `'FL'`. `client_name` IS PUNCTUATION-FOLDED, AND ACCENTS
ARE DELIBERATELY KEPT** (`2026-08-25_0400`, after Fred's "yes normalise both"; hardened by
**`2026-08-25_1200`**, which moved the whitespace handling into
**`derm.fn_normalize_state_input()`** and made the Québec arm collation-proof — read BOTH
migrations, the 0400 one alone no longer describes the live object). The view used to
serve `state` as whatever `public.properties.state` held, which was **`Florida` 663 rows and `FL` 13
on the same form**.

🛑 **THE ONE-LINE FIX WOULD FALSIFY A COMPLIANCE FORM.** `properties.state` holds SIX values:
`Florida` 868 · `FL` 41 · **`California` 5 · `Québec` 2 · `New York` 1** · `fl` 1 (live rows;
the raw table reads Florida 869 / FL 43). Only Florida/FL/null
reach this view *today*, so a constant `'FL'` would look perfectly correct and would relabel a Quebec
or California property the first time one took a Miami-Dade pickup. The CASE maps known states
explicitly and **passes anything unrecognised through VERBATIM**, so a surprise is visible instead of
quietly wrong. Proven by outcome, not by reading the SQL: a rolled-back probe drove 14 values through
the live view and `Ontario`/`Puerto Rico`/`XYZZY` each came back unchanged, which a constant cannot do.

🛑 **THE PUNCTUATION HALF IS NARROWER THAN IT SOUNDS, AND THE OBVIOUS `unaccent()` WOULD MISSPELL A
COUNTY FORM.** The non-ASCII in this data splits two ways and only one half is an artifact:

**Measured over the WHOLE of `public.clients.name` (456 rows) and `public.properties.address`
(921 rows), not just the rows currently in the view** — any client can enter this view later, so a
census scoped to today's rows is the wrong instrument:

| codepoint | where | in the view | verdict |
|---|---|---|---|
| **U+2019** curly apostrophe | 5 client rows — Fialkoff's ×2, NOEL'S, +2 with no `client_code` | 9 rows / 3 names | **ARTIFACT, folded to `'`** |
| **U+00A0** non-breaking space | 1 client row — `280-AN` "Aryeh Nackache" | 0 rows | **ARTIFACT, folded to a space** (it IS in the replace chain) |
| **U+00E2** "Fendi Château Residences" | 1 client row, `167-FEN` | 2 rows | **CORRECT SPELLING, kept** |
| **U+00ED** "Aníbal Tineo" | 1 client row (no `client_code`) | 0 rows | **CORRECT SPELLING, kept** |
| **U+00F1** "224/409/448 Española Way" | 6 address rows (ids 96, 111, 233, 577, 718, 862) | 10 rows | **CORRECT SPELLING, kept** |
| **U+00E8** the two Québec addresses | 2 address rows (ids 234, 882) | 0 rows | **CORRECT SPELLING, kept** |

⚠ That is **8 property rows carrying non-ASCII in `address`**, across THREE street numbers, not
two. An earlier version of this table named only 409 and 448; **224 Española Way** is the third.
The in-view count of 10 is a different grain (rows in the view, not properties) and is correct.

⚠ `address` is not folded at all, and both of its codepoints are letters, so that decision is safe —
but it is safe *because both are letters*, not because address is clean. If typographic punctuation
ever lands in an address it will print on the county form exactly as `Fialkoff's` did.
⚠ **The fold is FIELD-scoped, not FORM-scoped.** Only `client_name` folds. The other nine served
string columns (`address`, `city`, `county`, `zip`, `state`, `disposal_facility`, `truck`,
`ticket_number`, `client_code`) are unfolded and unwatched — all measured at 0 typographic
codepoints today, against a control of 6 on raw `clients.name`.

Española Way is a real Miami Beach street and Fendi Château is the registered business name.
**Stripping them misspells a regulator-facing document, which is worse than the inconsistency being
fixed.** So the fold is a fixed list of seven typographic characters (both quote pairs, both dashes,
NBSP), never a character-class strip. ⇒ **A verification that asserts "0 non-ASCII" is asserting the
regression.** The migration's VERIFY requires `name_nonascii = 2` and `addr_nonascii = 10` to SURVIVE.

⚠ **PRESENTATION ONLY.** `public.properties.state` and `public.clients.name` are untouched, so every
other app still renders exactly what it always did. Fixing it at source would touch the Field Portal,
the Client App and every work order, and is a separate decision nobody has taken.

⚠ Re-validated after the change: all **8 months of 2026** still agree with an independent SQL
recomputation on tickets, rows and excluded counts (690/589 unchanged, 126 tickets), and the served
payload was inspected directly — 0 curly apostrophes reach the bot, both accented strings survive.

⚠ **Month selects on the OFFLOAD date**, so a ticket is never split across two reports and a pickup
can legitimately fall in the previous month (ticket 831710 offloaded 2026-08-02 carries a 2026-07-30
pickup).

**Validated 2026-08-24:** the endpoint's grouping was cross-checked against an independent SQL
recomputation for **all 8 months of 2026** and agreed on tickets, rows and excluded counts every time.
Full design, the six open questions for John, and the read-vs-write reasoning:
[docs/specs/2026-08-24-lwt-monthly-endpoint-design.md](docs/specs/2026-08-24-lwt-monthly-endpoint-design.md).

### 🛑 THE DERM PORTAL QUEUE HAS FOUR GATES, AND ONE OF THEM CANNOT SEE THE OUTSIDE WORLD

`public.v_derm_portal_queue` excludes a (manifest, permit) when **any** of these holds. Know which
one you are fighting before you touch anything:

| gate | excludes when | why |
|---|---|---|
| 1 | a non-dry-run `SUCCESS` or a `portal_confirmation` exists | never re-file a filed report |
| 2 | any non-dry-run attempt in the last **20h** | never hammer the county portal |
| 3 | a **non-retryable** non-SUCCESS attempt **newer than `f.updated_at`** | a data error holds until the row changes |
| 4 | a dispense lease on the manifest in the last **20h** | never double-serve a manifest |

⚠ It is also `DISTINCT ON (manifest_id)`, so **only ONE permit per manifest is served per pass**
(ordered by `gdo_id`, then `abs(visit_date - dump_ticket_date)`, then `visit_id`). A (visit, permit)
can be legitimately absent from the queue because a SIBLING row won the DISTINCT ON, not because a
gate blocked it.

🛑 **GATE 3'S FRESHNESS ANCHOR IS A *DATABASE* TIMESTAMP, SO A FIX MADE OUTSIDE THE DATABASE IS
STRUCTURALLY INVISIBLE TO IT.** Cost three days on 2026-08-24: Jonathan fixed GDO-11024's portal
credential **at the county**. Nothing in our data changed, so the gate stayed shut, his digests read
"queue empty" on the 21st/22nd/23rd, and **no amount of hourly polling could ever have re-opened it**.
`f.updated_at` is `GREATEST(visits.updated_at, manifest updated_at/created_at)`.

✅ **The sanctioned answer is now `public.fn_requeue_derm_portal(visit_id, gdo_id, reason, by)`**
(`2026-08-24_1900`), which records an explicit operator decision that gate 3 honours.
**Do NOT go back to `update derm_manifests set updated_at = now()`** — it works, but it is a side
effect standing in for an intention: no reason, no name, no trail.
- **It relaxes gate 3 and ONLY gate 3.** Gates 1, 2 and 4 still apply, and the return value NAMES
  whichever one is still holding the row.
- **It returns the post-condition, not "ok".** A requeue that inserts a row and changes nothing is
  the worst outcome, because the operator believes they acted. Read `queued_now` and
  `still_blocked_by`.
- **Self-limiting, which is why there is deliberately NO expiry:** a fresh attempt writes a
  submission newer than the marker and the gate closes again by itself. A requeue buys exactly one
  more pass. **Do not "improve" it into a flag that stays on.**
- A reason is required, and the whitespace class is stripped: `btrim()` alone strips ASCII SPACE
  only, so a TAB / NEWLINE / NBSP reason used to defeat the guard entirely.
- 🛑 **IT REFUSES A NULL `p_gdo_id`, AND THAT REFUSAL IS LOAD-BEARING.** The view's anchor matches
  `rq.gdo_id IS NULL OR ...`, so a NULL requeue row re-opens gate 3 for **EVERY permit on the
  manifest** — 14 manifests carry 2+ permits. The TABLE still supports NULL for a deliberate
  manifest-wide re-open; it just must never be reachable by omitting an argument.
- `requested_by` prefers the **JWT** over the caller-supplied `p_by`. It used to be the other way
  round, which let any caller write somebody else's email onto the only attribution this table has.
- ⚠ **`still_blocked_by` must stay at least as specific as the fallback it shadows.** A branch added
  in front of a correct ELSE swallowed the honest answer once already: the "a sibling won the
  DISTINCT ON" branch checked only the MANIFEST, so a nonsense or wrong-client `gdo_id` was told its
  row would "come up on a later pass" when it never would. There is now a `pair_exists` check first.
- `derm_portal_requeue` IS the audit trail (who, when, why) and is therefore deliberately not audited.

⚠ **`v_rpa_derm_health.queue_depth` COUNTS MANIFESTS, NOT FILINGS.** The view is
`DISTINCT ON (manifest_id)`, so it answers *"how many manifests can the bot pick up this pass"*, never
*"how many DERM filings are outstanding"*. Measured 2026-08-24: **59 candidate pairs across 37
manifests**, and **13 manifests carry 2+ unfiled permits** — a backlog read off `queue_depth` is
understated by up to 37%, and any alert threshold on it saturates. **Do not build a backlog metric
on it.**

⚠ **`public.v_rpa_derm_health` DEPENDS on this view** (it is `queue_depth`), as do
`fn_record_manual_gdo_report` and `fn_resolve_rpa_permit`. Keep the COLUMN LIST identical and
`CREATE OR REPLACE` works; change the columns and it becomes drop-and-recreate, which
[discards grants](docs/migrations/). **After any edit, assert the queue did not WIDEN** — extra rows
mean the bot files reports that should not go out.

### 🛑 THE HEALTH WATCHDOG: EMAIL ON STALENESS, AND SILENCE MEANS HEALTHY (2026-08-24)

Four `log_*_health()` crons write a verdict into `public.sync_log`. **Nothing reads `sync_log`** and
nothing ever will: health verdicts are **138 of 34,849 rows (0.40%)** there, under 21,863 Jobber poll
records. It is a sync JOURNAL. Three checks sat in `attention` for days with nobody told, one of them
a Miami-Dade DERM report that never filed.

**The chain now:** `log_*_health()` -> `sync_log` -> `ops.v_health_items` -> `fn_health_alert_scan()`
-> `public.health_alert_state` -> edge fn `health-escalate` -> **Resend -> fred@ayache.com**.
Driven by cron `health-escalation` (`30 13 * * *`, jobid 30) via `fn_request_health_escalation()`.

**It emails only when an item is NEW, or has been open >= 3 DAYS unacknowledged** (then weekly, not
daily). Resolutions ride along in a mail already going out and never trigger one.
**SILENCE IS THE NORMAL, HEALTHY OUTCOME. Do not "fix" it into a daily summary** - that is precisely
what made `sync_log` unreadable, and Fred chose this threshold deliberately after seeing the numbers
(only 7 attention streaks of 3+ days in two months, about one email per eight days).

⚠ **The Slack digest that shipped earlier the same day is RETIRED** (workflow + script deleted).
It posted on *change*, which leaves the opposite hole: a problem that appears once and then sits
produces exactly ONE message and then silence for ever. Restoring it is a `git revert`, not a rewrite.

🛑 **ACKNOWLEDGEMENT IS ALWAYS TIME-BOXED. There is deliberately NO permanent mute.**
`fn_health_ack(check, item, days, reason)` rejects `days<1`, `days>365`, and an empty reason.
`blackout-health`'s `ticket-833049` is frozen on purpose by a CHECK constraint and will NEVER
resolve; without an expiry it would mail for ever and become the new wallpaper. A permanently
silenced problem is an unknown problem.

🛑 **THE MARK HAPPENS ONLY AFTER RESEND ACCEPTS, AND THAT ASYMMETRY IS THE POINT.**
`fn_health_alert_scan()` records what it SAW but not that it alerted; the edge function calls
`fn_health_alert_mark_sent()` only on a 2xx. **A failed send REPEATS tomorrow instead of vanishing.**
For a watchdog a duplicate is cheap and a miss is the whole failure mode. Do not merge the two calls.

⚠ **`RESEND_API_KEY` is an EDGE secret and is NOT in vault**, so Postgres cannot email directly.
That is why this is cron -> `net.http_post` -> edge fn, using `edge_invoke_service_key` like the four
`fn_request_*` helpers. `unclogme.com` is Verified in Resend.

⚠ **A new health check MUST be added to the CASE in BOTH `ops.v_health_items` and
`ops.v_health_status`** or it contributes zero items, always looks unchanged, and can never escalate.
Two places by accident of history; if you touch one, check the other.

⚠ **Timing:** the escalation runs 13:30 UTC because `blackout-health` writes at 08:00 ET and
`ops.v_health_items` reads only the LATEST run of each check. In WINTER that gap narrows to 30
minutes. **If `blackout-health` moves, move `health-escalation` too**, or it reports a day-stale
blackout verdict and says nothing changed.

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
