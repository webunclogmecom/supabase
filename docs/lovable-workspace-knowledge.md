# UnclogMe — Lovable Workspace Knowledge

This Knowledge applies to **every project** in this Lovable workspace. Don't override its rules per-project — project-level context can ADD to this, never REPLACE it.

## The user you're helping

- **Yannick** — designer/builder, primary user in this workspace.
- **Fred** — tech lead, owns the canonical Prod database. Will migrate every app you build into Prod.
- **Yan** — co-founder, sets product direction.

## The business (one minute)

- **UnclogMe LLC** — Miami-Dade FL commercial plumbing: grease trap (GT) pumping, septic, drain cleaning, jetting. DERM-licensed waste hauler (every disposal trip needs a manifest).
- Scale: ~183 active clients, 4 trucks, ~$674K ARR, ~40% margin.
- **Time zone: Eastern Time.** DB stores UTC; UI displays ET. Always pin to `America/New_York`.

## How every app's database lifecycle works

**Default — 2 stages:**
```
1. Build in Lovable's auto-provisioned Supabase   ← prototype (seeds)
2. Fred promotes the app to Prod canonical        ← live (per-app schema)
```

**Escalate to 3 stages** (Fred inserts a Prod-clone sandbox between 1 and 2) IF the app: writes to ≥3 canonical tables AND has Edge Functions/triggers · needs real data volume to test UX or perf · handles DERM/payments/sensitive PII. CRUD admin/dashboard apps stay at 2 stages.

**Your DB is a prototype. It will be replaced.** Shape it so the replacement is a small mapping, not a rewrite.

## DB design — non-negotiable conventions

### 1. Normalization (3NF)
- Every new table: state explicitly **"is this 3NF?"** before you write the DDL.
- Related data is referenced by FK, **never copied**.
- Enumerable values go in a lookup table, not a free-text column.

### 2. Naming
| Where | Convention | Example |
|---|---|---|
| DB tables/columns | `snake_case` | `client_id`, `created_at` |
| TS code | `camelCase` | `clientId`, `createdAt` |
| FK columns | `<table>_id` (singular) | `property_id`, NOT `propertyId` or `propertiesId` |
| Booleans | `is_<state>` / `has_<thing>` | `is_active`, `has_grease_trap` |
| Timestamps | `<event>_at` (timestamptz) | `completed_at`, `uploaded_at` |
| Dates | `<event>_date` (date) | `service_date`, `note_date` |

### 3. Types
- **IDs**: `BIGINT` (sequence) or `UUID`. **Never TEXT.**
- **Money**: `NUMERIC(12,2)`. **Never FLOAT, never TEXT, never `*_cents BIGINT`** (canonical is decimal).
- **Time**: `TIMESTAMPTZ` in UTC.
- **Enums**: `TEXT` + `CHECK` constraint. **Don't use Postgres ENUM types** — they're a pain to evolve.

### 4. Every table must have
```sql
created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
```
Plus a `BEFORE UPDATE` trigger that auto-bumps `updated_at`. Install one shared `tg_set_updated_at()` function and attach the trigger to every table. **Never set `updated_at` manually** — the trigger owns it.

### 5. NEVER — the hard rules

These break the canonical migration. Don't argue, don't "optimize past them":

- ❌ **Source-prefixed columns** like `jobber_id`, `airtable_record_id`, `samsara_vehicle_id`. Source IDs live in **one** canonical table called `entity_source_links` (see below). Never inline source IDs on entity tables.
- ❌ **TEXT for money/dates/booleans/IDs.**
- ❌ **Invented entity names** when a canonical one fits (see next section).
- ❌ **Soft-delete via `is_deleted` flag** AND ❌ **hard delete of business records.** Use explicit lifecycle states (`status = 'INACTIVE'`/`'PAUSED'`). Hard deletes break `entity_source_links` and historical joins.
- ❌ **Same datum stored in two tables.** Pick one home and reference it.
- ❌ **Anon-write assumptions in Prod-bound code.** Anon writes get revoked at Prod migration — write paths must work as `authenticated`.

### 6. External-source lookups — first result wins

External sources (DERM bot, Jobber, Samsara, Airtable) are non-deterministic — same query can return different results across runs. **Trust the first successful classification**; don't auto-re-query to "double-check" (you'll overwrite a correct first answer with a noisy second one). Re-verify via a separate manual review, not an automatic re-fetch.

## Canonical entity names — reuse, don't reinvent

If your app needs any of these concepts, **use the exact table name**:

| Concept | Canonical table name |
|---|---|
| Customer / business account | `clients` |
| Physical location belonging to a client | `properties` |
| Scheduled or completed service event | `visits` |
| Billable services within a visit | `line_items` |
| Free-text annotations | `notes` |
| Photo metadata (storage_path, source) | `photos` |
| Photo ↔ entity M2M join | `photo_links` |
| Photo phase tag (before/after/internal/extra) | `photo_classifications` |
| Pre/post trap inspection at a visit | `inspections` |
| DERM waste disposal certificate | `derm_manifests` |
| Manifest ↔ visit join | `manifest_visits` |
| Miami-Dade GDO permit (per property) | `gdos` |
| Per-client subscription config (frequency/type) | `service_configs` |
| Truck fleet | `vehicles` |
| Staff | `employees` |
| Disposal facility lookup | `disposal_facilities` |
| Client group lookup (parent chains) | `client_groups` |
| External source IDs (jobber/airtable/samsara) | `entity_source_links` |

If your app needs something **not** on this list, ASK YANNICK FIRST. Cheaper to clarify than to refactor at handoff.

### Critical naming gotchas (frequent mistakes)

| Wrong | Right | Where |
|---|---|---|
| `clients.active` boolean | `clients.status` IN ('ACTIVE','RECURRING','PAUSED','INACTIVE') | clients |
| `visits.status` | `visits.visit_status` | visits |
| `visits.is_complete` | `(visits.visit_status = 'COMPLETED')` | visits |
| `employees.name` | `employees.full_name` | employees |
| `derm_manifests.manifest_number` | `derm_manifests.white_manifest_number` | derm_manifests |
| `properties.street_address` | `properties.address` (single-line; city/state/zip are separate columns) | properties |
| `vehicles.tank_capacity_gallons` | `vehicles.grease_tank_capacity_gallons` (NOT NULL — required) or `vehicles.fuel_tank_capacity_gallons` | vehicles |
| `service_configs.frequency` (TEXT) | `service_configs.frequency_days` (INTEGER) | service_configs |
| `entity_source_links.source` | `entity_source_links.source_system` | entity_source_links |
| Truck = person ("Moises did the visit") | Truck is a **vehicle**, not a person. **Moises, Cloggy, David, Goliath are TRUCK names.** Drivers are separate employees. | vehicles vs employees |

### App-specific tables → prefix `app_`

Anything that lives only in your app's DB (UI state, overrides, classifications, review workflows) gets the `app_` prefix. Examples: `app_visit_reviews`, `app_property_overrides`. Signals to Fred at migration: "sandbox-only; decide what to do" — he'll promote, wrap in a per-app schema view, or leave behind.

## Frontend stack — defaults

Vite + React + TypeScript + Supabase JS · React Router · Tailwind + shadcn/ui · TanStack Query (server state) · Zustand (local UI state, no Redux) · react-hook-form + zod (validate client-side AND in DB constraints). One `createClient` per app; for non-`public` schemas pass `{ db: { schema: '<app_schema>' } }`.

## Auth & security

- **RLS ON for every table on day one.** No exceptions.
- Use **Supabase Auth** (email/password or magic link). No custom auth.
- Plan write paths for the **`authenticated` role** from day one. Anon writes get revoked at Prod migration.
- Service-role operations (server-side) go in **Edge Functions**. Never expose the service-role key client-side.
- Never log PII or auth tokens to the console.
- For sensitive entities (PII, financial), scope policies with `auth.uid()`, not blanket `USING (true)`.
- **Apps that write to canonical tables (clients, properties, employees, vehicles, gdos, etc.) must scope writes to an admin role** — not blanket `authenticated`. Check via `auth.jwt() -> 'user_metadata' ->> 'role' = 'admin'` or a dedicated `app_admin_users` table.

### Audit attribution — every write sets `X-App-Source`

Pass `global: { headers: { 'X-App-Source': '<your-app-slug>' } }` when you call `createClient`. Without it, audit rows attribute as `'other:<host>'` and we lose accountability. Existing slugs: `derm-tracker`, `field-portal`, `admin-review`, `visit-calendar`. Pick a new stable slug for your app and tell Fred.

For apps that edit canonical, consider surfacing a "Recent changes" panel from `audit.logs` (it records every UPDATE with full before/after JSONB + `app_source` + `changed_by`).

## The ASK-FIRST rule

Before writing any migration, **paste the full table plan to Yannick** (names + columns + types + FKs + 3NF check). Wait for confirmation.

Also ASK FIRST to: use a table name not on the canonical list, use a type not in §3, break normalization "for performance", wire anon writes, or add a column to a canonical entity (Fred owns canonical evolution).

## Handoff — when Yannick says "feature complete"

1. **Freeze the schema.** Commit + push.
2. Share with Fred: Lovable Supabase URL/ref, `docs/SCHEMA.md` (every table/column/FK), `docs/HANDOFF.md` (every deviation + why, every `app_*` table + purpose, auth role expectations, edge functions, your `X-App-Source` slug), and a Loom demo.

By default Fred goes Lovable → Prod (per-app schema) directly. For escalated apps (see lifecycle above), Fred clones Prod into a sandbox, Yannick re-points, Fred validates, then promotes.

## TL;DR for every new app

1. Read the per-project bootstrap doc Yannick paste at project start.
2. Draft your schema plan, run the 3NF check, paste to Yannick BEFORE writing migrations.
3. Use canonical entity names. `app_*` prefix for app-only tables.
4. Audit columns + RLS on every table.
5. Plan for `authenticated` writes; **admin-only writes for canonical-editing apps.**
6. Set `X-App-Source` header on every write.
7. Freeze schema at "feature complete" and write HANDOFF.md.
