# HR Sandbox — schema, data refresh & migration-prep notes

**Project:** `klgtrdwrasrlxbmfyvdh` ("HR Sandbox", us-east-1, Free plan) — formerly the *Field Portal Sandbox*, renamed/repurposed 2026-06-11 for **Yannick's HR app** (in development).
**Last data refresh:** 2026-06-15 (via `scripts/sync/hr_sandbox_refresh.js`).
**Maintained by:** Fred / Claude. **Purpose of this doc:** keep the sandbox stocked with realistic data without disturbing Yannick's setup, and pre-stage the eventual HR-app → Prod migration.

---

## 1. What it is

A standalone Supabase project Yannick builds his HR (employee-management) Lovable app against, so he has realistic data without touching Prod. It is a **one-time clone of Prod from ~April 2026** that has since **diverged** (Prod moved forward; the sandbox schema was frozen at clone time). It is NOT periodically auto-refreshed structurally — only its **data** is topped up on demand (see §3).

## 2. Schema / architecture (legacy April-clone — DO NOT "upgrade" it)

The public schema is the April-2026 Prod clone. **Yannick has added no custom tables and no custom columns** (verified 2026-06-15 — every drift below is Prod moving forward, not HR diverging). Treat the legacy shape as the contract until the migration (§4); do not retrofit Prod's newer schema onto it unless Yannick asks.

**Drift vs current Prod (snapshot 2026-06-15):**

- **HR-only tables (legacy, Prod has since DROPPED them):** `app_visit_reviews`, `app_shift_reviews` — the old review/bonus tables from the April era. Prod replaced these with canonical `visit_reviews` / `shift_reviews` (2026-06-08). If the HR app reads/writes the `app_*` tables, that's a migration touch-point (§4).
- **Prod-only tables (9, added since the clone — absent in HR):** `client_locations`, `visit_locations`, `zones`, `service_line_items`, `visit_reviews`, `shift_reviews`, `derm_email_sends`, `municipality_regulators`, `visit_sync_flags`.
- **Prod-only columns (added since the clone):** `clients.client_class`; `derm_manifests.{deleted_at, derm_address_no, derm_address_extra_urls, derm_manifest_extra_urls, fog_manifest_url, notes}`; `disposal_facilities.county`; `gdos.client_location_id`; `jobs.frequency_days`; `line_items.visit_id`; `properties.zone_id`; `visits.{deleted_at, notes, service_line_item_id}`.

**Other schemas in the project:**
- `frozen_leads` (13 tables, 7 views) — Yannick's Miami-Dade prospecting database (its own comment: "UnclogMe prospecting database: GDO permits, enrichment, route density scoring. Master = DERM (Miami-Dade DERM portal). Created 2026-05-25."): 9,890 GDO permits in `gdo_universe`, loaded 2026-05-26, last written 2026-07-20. **NEVER touch.** Not Yannick's HR data; unrelated to the refresh. It is the only Miami-Dade frozen-leads copy in Supabase: Prod's `leads` schema holds only the Boca Raton BSI leads (ADR 020), the Sales App's 8,166 prospects live in Convex, and the paused project named "frozen leads" (`oodjstkceacbmznccgia`, created the same day) has been idle since. **Since 2026-11-16 every object in it except `v_active_clients` is OWNED by Yannick's own login `yannick_leads`** (§6): he reads, writes and changes its structure; we never write to it as postgres.
- `audit` — standard audit schema (same as Prod).

## 3. Data refresh — `scripts/sync/hr_sandbox_refresh.js`

**Run it whenever Yannick wants fresh data:**
```
cd Supabase
node scripts/sync/hr_sandbox_refresh.js            # dry-run (preview)
node scripts/sync/hr_sandbox_refresh.js --execute  # apply
```
Env: `SUPABASE_PAT` (required), `HR_SANDBOX_PROJECT_ID` (defaults to `klgtrdwrasrlxbmfyvdh`).

**How it stays schema-safe:**
- **Column-intersection.** Every write uses only columns present in BOTH Prod and HR. Prod's newer columns/tables are silently skipped → the legacy schema is never altered. (This is why the older `hr_sandbox_topup.js`, which pulled Prod's full column list, would now fail; this script supersedes it for the drift era. `hr_sandbox_topup.js` was deleted 2026-10-07, timed-jobs move step 0.)
- **Reference tables UPSERTed** (refresh values + new rows): `employees`, `vehicles`, `clients` (subset), `client_groups`, `disposal_facilities`. Safe because Yannick adds no rows to these and edits none (verified: no HR-side writes).
- **Event tables ADDITIVE only** (`ON CONFLICT DO NOTHING`): `properties`, `jobs`, `invoices`, `gdos`, `inspections` (full history), `visits` (subset, live only), `visit_assignments`, `entity_source_links`. Never deletes, never mutates existing rows.
- **Sequences resynced** after, so the HR app's own inserts won't collide.
- **Never touches:** `frozen_leads`, the `app_*` tables, any view/policy/grant, or anything Yannick adds.

**Current data (2026-06-15):** full 34 employees + 4 vehicles + 293 inspections; 44-client subset for clients/visits/jobs/invoices/properties/gdos. (Employees/inspections are full because the HR app needs every person; clients/visits stay a subset to keep the Free-plan project small.)

**Cadence:** on-demand (Yannick asks → run it). No cron — it's a dev sandbox; a scheduled refresh isn't worth the Free-plan churn. Revisit if Yannick wants nightly.

## 4. Migration-prep — when the HR app graduates to Prod

When the HR app is ready for production, it should follow the **schema-per-app** pattern (one Postgres schema per app on Prod, apps never query `public` directly) and the `unclogme-db-integration-audit` skill. Concrete touch-points this sandbox creates:

1. **Re-point to Prod** (`wbasvhvvismukaqdnouk`) and create an **`hr` schema** of views/RPCs over canonical `public` (like `customer.*` for Field Portal). The app reads/writes its `hr` schema, not `public`.
2. **Reconcile the legacy `app_*` tables.** If the HR app uses `app_visit_reviews`/`app_shift_reviews`, remap to canonical `public.visit_reviews` / `public.shift_reviews` (real FKs on `visit_id` / `employee_id+shift_date`). They are NOT in Prod anymore.
3. **Adopt the drifted columns/tables** the HR app depends on (employees are unchanged, so HR-core is low-risk; the drift mostly affects clients/visits/derm, which HR may not use).
4. **Auth + RLS:** apply the app-auth-gate pattern (`docs/specs/2026-06-15-app-auth-gate-design.md`) — but HR data is employee PII, so it warrants **stricter RLS than the internal-apps gate** (real per-user auth, not the shared-account model), decided at migration time.
5. **Do not migrate `frozen_leads`** as part of HR — it's separate legacy data.

## 5. Rules (for any agent touching this project)

- Schema-preserving only: never `ALTER`/`DROP` the legacy public schema; refresh = column-intersected + additive (use the script).
- Never touch `frozen_leads` or anything Yannick adds. It is his (owned by `yannick_leads` since 2026-11-16, section 6); read it, never write to it as postgres.
- This is a **dev sandbox** — it is out of scope for the Prod app-auth-gate effort; it carries the same "anon, public URL" exposure and gets a proper gate only when it goes to Prod (§4.4).
- Cross-ref: `Building Apps/CLAUDE.md` (app landscape), the auth spec, and memory `feedback_no_direct_sandbox_mutations`.

## 6. Yannick's own login to the Miami-Dade frozen leads (2026-11-16, Trello #211)

Yannick: *"Also I want to connect the Supabase of the dade frozen leads to my cloud. How do I do that?"*; Fred: *"let's
give him the api key with a read only"*, on which copy *"HR Sandbox now"*, then *"can we make the API so he can
read/write ? he will make a lot changes to the DB"* and, asked what kind, *"Tables too, on the HR Sandbox"*.

- **What exists:** login role `yannick_leads` (5 connections, 60 s statement timeout, `search_path` frozen_leads first,
  no special attribute, member of no role). It OWNS every object in `frozen_leads` (13 tables with their sequences and
  indexes, 6 views, 16 functions, 7 enum types) except `v_active_clients`, which reads OUR client list and stays
  postgres's (he has SELECT on it). He has USAGE and CREATE on the schema, not the schema. `postgres` is a member of
  `yannick_leads` (INHERIT, SET), so our admin login keeps full rights on his objects. He connects through the pooler,
  session mode: `aws-1-us-east-1.pooler.supabase.com:5432`, user `yannick_leads.klgtrdwrasrlxbmfyvdh`, SSL. The
  password lives only in the workspace's git-ignored `.local-secrets/yannick-frozen-leads-login.txt`; it reached the
  server only as a SCRAM verifier, because this project logs every DDL request in full (`log_statement = ddl`).
- **Also changed on the sandbox:** CREATE on schema `public` was taken from PUBLIC (it was `=UC/postgres`), so a login
  with no grant of its own cannot create there. anon, authenticated and service_role held it only through PUBLIC; the
  API cannot run DDL for them. Undo: `grant create on schema public to public;`.
- **Replaced the same day:** the first build, a read-only API key over a view schema `leads_api`
  ([`sandbox/2026-11-16_leads_api_read_only.sql`](sandbox/2026-11-16_leads_api_read_only.sql), tested 28 of 28, never
  handed over). Its views would have blocked his column changes, so `leads_api` and `leads_reader` were dropped and
  PostgREST `db_schema` is back to `public,graphql_public`.
- **Backup before the change:** workspace `backups/2026-11-16_hr_sandbox_frozen_leads_before_yannick_login.json`
  (35 MB: every row of the 13 tables, columns, constraints, indexes, 12 triggers, 42 policies, views, functions, enums,
  owners, grants, sequence positions).
- **Proven live 2026-11-16, 24 of 24, logged in as him through the pooler:** reads 9,890 permits and his views; inside a
  rolled-back transaction ADD COLUMN, INSERT, UPDATE (his triggers and the audit trigger fire), DELETE, CREATE TABLE,
  VIEW, FUNCTION and INDEX all work; refused (42501): `public.employees`, `public.clients` (read and write), `auth.users`,
  `storage.objects`, CREATE TABLE in public, CREATE SCHEMA, CREATE ROLE, changing or dropping `v_active_clients`. Nothing
  stayed afterwards; the old read-only key answers 406; the sandbox API still answers 200.
- 🛑 **THE KILL SWITCH IS TWO LINES.** `alter role yannick_leads nologin;` alone did NOT cut him off in the rehearsal: the
  pooler handed back a connection it already held, and a login is only checked on a new connection. With
  `select pg_terminate_backend(pid) from pg_stat_activity where usename = 'yannick_leads';` as well, a new connection is
  refused (XX000); `alter role yannick_leads login;` lets him back in. Full undo, and the build:
  [`sandbox/2026-11-16b_frozen_leads_yannick_login.sql`](sandbox/2026-11-16b_frozen_leads_yannick_login.sql).
- 🛑 **We never WRITE to `frozen_leads` as postgres.** A table owner's triggers run with the rights of whoever writes
  the row, so a postgres write would run his trigger code as postgres. Reading is fine. The refresh script never touches it.
- Its three audit triggers (`contacts`, `gdo_universe`, `hours_of_operation` -> `audit.log_change`, SECURITY DEFINER)
  still log his row changes to `audit.logs`. He may drop them; it is his data.
