# Building New Apps on the Unclogme Database

**Audience:** Yan (building) + Viktor (advising) · **From:** Fred · **Last updated:** 2026-04-21

This is the task-oriented guide for building apps (like the Sales App) that extend Unclogme's centralized database with new, app-specific data. Your app reads from the main Unclogme database (read-only) and writes only new app-specific tables to a separate "apps" Supabase project that you own.

Read this first, then browse `docs/` for reference material.

---

## 1. The architecture: two databases, one source of truth

```
┌──────────────────────────────────────────────────────────┐
│  Main Unclogme DB (wbasvhvvismukaqdnouk)                  │
│  ───────────────────────────────────────                  │
│  - Webhook-driven source of truth                         │
│  - Live updates from Jobber, Airtable, Samsara, Fillout   │
│  - 28+ business tables: clients, visits, invoices, etc.   │
│  - YAN READS FROM HERE (read-only via Viktor integration) │
└──────────────────────────────────────────────────────────┘
                         ▲
                         │  Sales App reads clients/visits/etc.
                         │  (read-only through Viktor / direct REST)
                         │
┌────────────────────────┴─────────────────────────────────┐
│  Yan's Apps DB (Unclogme Apps — qyvagxgaggzqyivqfbrj)     │
│  ───────────────────────────────────────                  │
│  - STARTS EMPTY                                           │
│  - ONLY new Sales-App-specific tables (sales_leads,       │
│    proposals, outreach_touches, …)                        │
│  - Never contains a copy of clients / visits / invoices — │
│    those are read from main DB                            │
│  - Writes freely during the build phase                   │
└──────────────────────────────────────────────────────────┘
                         │
                         │  (weeks/months later)
                         ▼
                    Merge back to main DB
                    (new tables land in prod)
```

### What this DOES NOT mean

- ❌ **Do not apply our baseline schema to your DB.** Your DB starts empty. Every table you create is one *you designed* for the Sales App's specific needs.
- ❌ **Do not copy clients / visits / invoices tables.** Those are in main DB. Read them; don't duplicate them.
- ❌ **Do not set up periodic sync from main to your DB.** No ETL. Your app queries main DB directly via Viktor's read-only integration.

### What this DOES mean

- ✅ Your app makes **two connections**: read from main DB, write to your DB.
- ✅ When your new table needs to reference a main-DB row (e.g. a sales lead for a specific client), store the main-DB ID as a **plain `BIGINT` column**. No FK constraint — you can't enforce FKs across databases. At merge time, the FK becomes real.
- ✅ At merge: we `CREATE TABLE sales_leads …` on main DB, add the FK constraints (now enforceable — `clients` lives alongside), copy the rows. **No conflicts because there's no duplicated data to reconcile.**

---

## 2. Non-negotiable rules

**Break these and the merge won't work.** Each rule maps to a decision record in `docs/decisions/`.

### 2.1 Zero source-prefixed columns

No `stripe_*`, `auth0_*`, `shopify_*` columns on any table. If your app integrates with an external system, track cross-system IDs in an `entity_source_links`-style polymorphic bridge table (see §5.3).

See [ADR 002](docs/decisions/002-entity-source-links.md).

### 2.2 3NF check on every new column

For every new column, state in your migration's header comment: *"Does this depend on the whole key, and nothing else?"* If the answer involves a transitive dependency (another column in the same table or a column reachable via FK), the column should be view-computed, not stored.

See [ADR 005](docs/decisions/005-3nf-standing-check.md) and [ADR 010](docs/decisions/010-drop-stored-derived-columns.md).

### 2.3 Reference all data via FK, never copy

Within your own DB: if two of your tables reference the same concept, one holds the authoritative row and the other FKs to it. No duplicated names/addresses/emails across your tables.

Across DBs (your DB ↔ main DB): use a **loose `BIGINT` column** storing the main-DB ID. No FK constraint (can't enforce cross-DB). Document this inline in the migration's header:

```sql
-- external_client_id: references main-DB clients.id.
-- Loose FK (cross-DB) during build phase; becomes enforced FK at merge.
external_client_id BIGINT NOT NULL
```

At merge, we replace `external_client_id` with a proper `client_id BIGINT REFERENCES clients(id)`.

### 2.4 Idempotent upserts only

Every insert uses `ON CONFLICT` on natural keys. Re-running any script is always safe.

### 2.5 Soft deletes, not hard deletes

Use `status = 'INACTIVE'` or a `deleted_at TIMESTAMPTZ` column. Never `DELETE FROM` on business data.

### 2.6 Timestamps UTC, money `NUMERIC(12,2)`, `updated_at` trigger-managed

Same conventions as main DB. The `updated_at` trigger function (`trg_set_updated_at()`) is a 10-line utility — copy it when you need it (§5.4).

### 2.7 No QuickBooks data

Out of scope everywhere. See [ADR 006](docs/decisions/006-no-quickbooks.md).

---

## 3. Setting up your new Supabase project

If Yan hasn't already created it: create a new Supabase project under the same Unclogme org (so membership gives Fred access without a separate invite).

```bash
# On your machine
unzip unclogme-handoff.zip -d unclogme-apps-build
cd unclogme-apps-build

# Copy .env.example → .env and fill in YOUR project's credentials
cp .env.example .env
# edit .env — set SUPABASE_URL, SUPABASE_PROJECT_ID, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_PAT
# to YOUR new project's values (NOT the main prod DB)
```

**Your new DB is empty at this point. That is correct. Do not apply the main-DB baseline to it.**

You also need read access to main DB. Two paths:
- **Via Viktor** — if Viktor is helping you build the Sales App, they already have a `Main DB - Read Only` integration. Ask Viktor to run reads on main DB.
- **Direct (for app code)** — use the main DB's anon key (public) + apply RLS policies if you ever expose the connection to untrusted clients. For dev, direct use with a service-role-free path is fine.

---

## 4. The "apply our baseline" step does not exist

Previous versions of this doc told you to apply `schema/v2_schema.sql` + 10 migrations to your new project. **That was wrong.** Mirroring the baseline creates a sync/drift problem that the extension model avoids. Do not do it.

Your DB grows purely from app-specific `CREATE TABLE` migrations *you author* in §5.

The `schema/` folder + `scripts/migrations/` in this handoff are included for **reference only** — to show you the patterns, conventions, column types, constraint styles, and header comments we use. You study these; you don't apply them.

---

## 5. Adding NEW tables for your app

### 5.1 Migration template

Create `scripts/migrations/NN_your_table_name.sql` (where NN is the next number, starting at 001 in your project). Use this template:

```sql
-- ============================================================================
-- Migration: <short name>
-- ============================================================================
-- Purpose:
--   <1-2 sentence what + why>
--
-- 3NF check (per column):
--   col_a — direct attribute of the PK. ✓
--   col_b — direct attribute of the PK. ✓
--   fk_col — FK link within this DB. ✓
--   external_client_id — loose cross-DB BIGINT reference to main
--     DB's clients.id. Becomes enforced FK at merge.
--
-- Consumers:
--   - <which Sales App screen/feature reads this>
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS <table_name> (
  id                   BIGSERIAL PRIMARY KEY,
  <local_fks>          BIGINT REFERENCES <other_local_table>(id),
  <cross_db_refs>      BIGINT,   -- main-DB ID; see header
  <direct_attrs>       <type> NOT NULL,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_<table>_<col>
  ON <table_name> (<col>);

COMMENT ON TABLE <table_name> IS
  '<purpose> | 3NF clean | Sales App | consumers: <list>';

-- If you use updated_at, apply the shared trigger (see §5.4)
DROP TRIGGER IF EXISTS trg_<table>_updated_at ON <table_name>;
CREATE TRIGGER trg_<table>_updated_at
  BEFORE UPDATE ON <table_name>
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

COMMIT;
```

### 5.2 Cross-DB references (the key pattern)

When a new Sales App table needs to point at a client or visit in main DB:

```sql
CREATE TABLE sales_leads (
  id                   BIGSERIAL PRIMARY KEY,
  external_client_id   BIGINT NOT NULL,              -- main DB clients.id (loose)
  status               TEXT NOT NULL DEFAULT 'new',
  score                INTEGER,                       -- app-computed
  notes                TEXT,
  assigned_to          BIGINT,                        -- main DB employees.id (loose)
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_sales_leads_external_client_id
  ON sales_leads (external_client_id);
```

- `external_client_id` is plain `BIGINT`. No FK constraint (cross-DB can't enforce).
- The Sales App knows which value to store because it read the client row from main DB first.
- At merge: `external_client_id` is renamed to `client_id` with a real `REFERENCES clients(id)` constraint.

Call the column `external_<entity>_id` consistently. Makes the merge mechanical — search/replace.

### 5.3 External-system IDs for your app (Stripe, Salesforce, HubSpot, etc.)

If the Sales App tracks its own external IDs (e.g., each `sales_leads` row has a Salesforce opportunity ID), **do not add a `salesforce_opportunity_id` column**. Mirror the main DB's pattern: create a local `app_source_links` table:

```sql
CREATE TABLE app_source_links (
  id              BIGSERIAL PRIMARY KEY,
  entity_type     TEXT NOT NULL,        -- 'sales_lead', 'proposal', etc.
  entity_id       BIGINT NOT NULL,       -- FK-in-spirit to the local table
  source_system   TEXT NOT NULL,         -- 'salesforce', 'hubspot', …
  source_id       TEXT NOT NULL,
  match_method    TEXT,
  created_at      TIMESTAMPTZ DEFAULT now(),
  UNIQUE (entity_type, entity_id, source_system),
  UNIQUE (entity_type, source_system, source_id)
);
```

At merge time, rows here get copied into main DB's `entity_source_links` with matching `entity_type` / `source_system` values. Zero schema change needed on main.

### 5.4 Shared utility: `trg_set_updated_at()` trigger function

If any of your tables has an `updated_at` column that should auto-refresh on UPDATE, copy this utility into your DB (one-time):

```sql
CREATE OR REPLACE FUNCTION trg_set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;
```

Put it in `scripts/migrations/000_utility_functions.sql` on your side. Then attach the trigger per table as shown in §5.1.

### 5.5 Use EXISTING tables where possible? (Heads up — different from main-DB rule)

In main DB we say "use existing tables where possible." **That rule does NOT apply here** because you don't have any existing tables to reuse.

All main-DB reads happen through the Viktor read-only integration (or direct read via main-DB's anon key). You never duplicate a main-DB table into your DB just to "reuse" it.

The existing-tables rule applies WITHIN your DB: once you've created `sales_leads`, if you later need to track per-lead notes, extend `sales_leads` with a note column if it's 1:1, or create a `sales_lead_notes` table if it's 1:N. Don't create `sales_leads_v2`.

### 5.6 Write an ADR for anything architectural

If you introduce a new pattern (a new polymorphic bridge, a new approach to event sourcing, etc.), write an ADR in `docs/decisions/` numbered 011+. One page: Status, Context, Decision, Consequences. I review it before it ships.

---

## 6. How the eventual merge works

When your Sales App is ready to fold into main DB, Fred + Viktor run the merge:

### 6.1 Schema diff

For every migration file in your `scripts/migrations/` (other than the utility function if it already exists on main), apply it to main DB. Idempotent by design.

### 6.2 Convert loose cross-DB refs to real FKs

Every `external_<entity>_id BIGINT` column becomes `<entity>_id BIGINT REFERENCES <entity>(id)`. Example:

```sql
-- On main DB:
ALTER TABLE sales_leads RENAME COLUMN external_client_id TO client_id;
ALTER TABLE sales_leads ADD CONSTRAINT sales_leads_client_id_fk
  FOREIGN KEY (client_id) REFERENCES clients(id);
```

If any `external_client_id` value doesn't exist in main's `clients` (data drift during build), we catch them here and reconcile.

### 6.3 Data copy

For each new table, `COPY` rows from your DB to main DB. `ON CONFLICT` handles re-runs.

### 6.4 `app_source_links` → `entity_source_links`

Copy rows with matching entity_type/source_system semantics.

### 6.5 Cutover

Sales App switches its write connection from your DB to main DB. Your DB becomes archival.

The merge is mechanical if §2 rules were followed. It's painful if they weren't.

---

## 7. What to send back for merge review

When you think the Sales App is ready:

1. **All your migration files** (`scripts/migrations/NN_*.sql`) — we apply these to main DB in order
2. **Any ADRs you wrote** (`docs/decisions/011+`)
3. **A list of new tables + row counts** in your DB
4. **A schema diff**: `pg_dump --schema-only` against your project
5. **A list of all `external_*` columns with their renamed-target column name** (so merge can mechanize the rename)
6. **A list of which main-DB tables your app's rows reference** (so we know what FKs we're adding)

Fred + Viktor review, apply, cutover.

---

## 8. Reading order for onboarding

1. `CLAUDE.md` — the rules (15 min)
2. `docs/architecture.md` — main DB data flow (10 min)
3. `docs/schema.md` — main DB table reference, **to understand what you'll reference via cross-DB IDs** (10 min skim)
4. `docs/decisions/` — ADRs 002, 005, 009, 010 first; others as needed (20 min)
5. `docs/operations.md` — main DB gotchas (5 min)
6. This file (you're here)
7. `supabase/functions/webhook-jobber/index.ts` — example of `entity_source_links` in actual code (20 min)

Total: ~90 min to full context.

---

## 9. Pre-flight checklist before starting

- [ ] New Supabase project created; credentials in `.env`
- [ ] Read access to main DB confirmed (via Viktor or direct anon key)
- [ ] Read `CLAUDE.md`, `docs/architecture.md`, ADRs 002/005/009/010, this file
- [ ] Understand the **extension model** — your DB only holds NEW tables; no baseline copy
- [ ] Understand the **`external_<entity>_id BIGINT`** pattern for cross-DB references
- [ ] Drafted a first migration for your first Sales App table using the §5.1 template

Once all boxes are checked, build freely. Fred + Viktor review your work before the merge.

---

## 10. Support channels

- **Fred (architecture, merge approval):** direct Slack DM
- **Viktor (source-data expertise, DB design partner):** `#viktor-sales`, `#viktor-supabase`, or DM
- **ADR proposals:** write first, send to Fred for review before merging

---

*If anything is unclear, escalate to Fred before shipping. Better to ask a "dumb" question than to create merge debt.*
