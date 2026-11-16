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
- `frozen_leads` (13 tables, 7 views) — Yannick's Miami-Dade prospecting database (its own comment: "UnclogMe prospecting database: GDO permits, enrichment, route density scoring. Master = DERM (Miami-Dade DERM portal). Created 2026-05-25."): 9,890 GDO permits in `gdo_universe`, loaded 2026-05-26, last written 2026-07-20. **NEVER touch.** Not Yannick's HR data; unrelated to the refresh. It is the only Miami-Dade frozen-leads copy in Supabase: Prod's `leads` schema holds only the Boca Raton BSI leads (ADR 020), the Sales App's 8,166 prospects live in Convex, and the paused project named "frozen leads" (`oodjstkceacbmznccgia`, created the same day) has been idle since.
- `leads_api` (14 views, since 2026-11-16) — read-only window on `frozen_leads` for ONE outside reader, Yannick (§6). Adds nothing to `frozen_leads`.
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
- Never touch `frozen_leads` or anything Yannick adds.
- This is a **dev sandbox** — it is out of scope for the Prod app-auth-gate effort; it carries the same "anon, public URL" exposure and gets a proper gate only when it goes to Prod (§4.4).
- Cross-ref: `Building Apps/CLAUDE.md` (app landscape), the auth spec, and memory `feedback_no_direct_sandbox_mutations`.

## 6. Yannick's read-only API key to the Miami-Dade frozen leads (2026-11-16, Trello #211)

Yannick: *"Also I want to connect the Supabase of the dade frozen leads to my cloud. How do I do that?"*; Fred: *"let's
give him the api key with a read only"*, and on which copy: *"HR Sandbox now"*.

- **What exists:** schema `leads_api`, 14 owner-rights views (`select *` of `frozen_leads` tables and views), readable by
  role `leads_reader` only (granted to `authenticator`); PostgREST `db_schema` = `public,graphql_public,leads_api`. The key
  is a JWT with `"role": "leads_reader"`, signed with the project's legacy HS256 secret (a "previously used" signing key,
  still accepted), expiring 2027-11-16. It lives only in the workspace's git-ignored `.local-secrets/` (never in a repo).
- **Left out on purpose:** `enrichment_log` (raw Google requests, 3 carry key-like text), `automation_outbox`,
  `automations`, `crm_users`, `v_my_tasks`, and `v_active_clients` (OUR client list). Add a view to `leads_api` if asked.
- **Why not expose `frozen_leads` itself:** the project's public key would then read `v_active_clients` (anon holds
  SELECT and a view has no RLS) and four lead tables, and that key ships in Yannick's apps.
- **Why it cannot write:** `leads_reader` holds SELECT on the 14 views and nothing else; no table in an exposed schema
  grants anything to PUBLIC; the 8 functions PUBLIC may run there are 6 trigger functions, `gen_short_id` (random text)
  and `graphql` (pg_graphql not installed); no dblink / http / pg_net.
- **Proven live 2026-11-16, 28 of 28:** every view reads (count 9,890), 1,000 rows per request at most; insert, update and
  delete 403 (42501); `frozen_leads` 406, `public.employees` 403, `v_active_clients` 404; the public key or the legacy anon
  key alone 401; a fake-signed key 401 (the control); data unchanged afterwards. Kill switch rehearsed: off 403, on 200.
- **Turn it off:** `revoke leads_reader from authenticator;` (next request refused). Full undo, and the build itself:
  [`docs/sandbox/2026-11-16_leads_api_read_only.sql`](sandbox/2026-11-16_leads_api_read_only.sql). Revoking the legacy
  HS256 signing key in the dashboard also kills it.
- 🛑 **The refresh script and the rules above still apply:** never touch `frozen_leads`; a new reader gets its own view
  here, never a grant there.
