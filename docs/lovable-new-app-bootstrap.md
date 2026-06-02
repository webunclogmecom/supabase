# Lovable Project Bootstrap — UnclogMe App

Paste at project start. Works alongside the workspace Knowledge (conventions + canonical names + handoff). This doc carries the **canonical schema shapes** to mirror.

---

## STEP 0 — Yannick fills this in before kicking off

```
App name:        ________________
Primary user:    [ ] Admin  [ ] Customer  [ ] Driver  [ ] Auditor  [ ] Other
Core purpose:    (one sentence) ________________
Entities touched: (from canonical list) ________________
Auth model:      [ ] email/password  [ ] magic link  [ ] public read-only  [ ] OAuth
```

---

## STEP 1 — Schema plan BEFORE code

Before generating any migration:

1. Draft full table list — names, columns, types, FKs, RLS intent.
2. Cross-check every entity against the canonical schema (Step 2). For mapped entities, use canonical names + types exactly.
3. Unmapped entities → `app_<noun>` prefix.
4. State per table: **"is this 3NF?"** + **"what FKs reference what?"**
5. **Paste the plan to Yannick. Wait for OK before writing SQL.**

Why: Field Portal skipped this step. Migration needed 8 compatibility views + 3 SQL files + manual schema exposure. Don't repeat it.

---

## STEP 2 — Canonical schema reference

Use these shapes as the **starting point** for any entity your app touches. Column names + types are **normative** — match them. Add columns if needed (note in `HANDOFF.md`); omit columns you don't need.

**Every table also has** `created_at TIMESTAMPTZ NOT NULL DEFAULT now()` and `updated_at TIMESTAMPTZ NOT NULL DEFAULT now()` (omitted below for brevity), plus a `BEFORE UPDATE` trigger bumping `updated_at`.

### `clients`
```
id              BIGINT       PRIMARY KEY
name            TEXT         NOT NULL              -- NO code prefix
client_code     TEXT         NULL                  -- e.g. '168-AVA'
status          TEXT         CHECK IN ('ACTIVE','RECURRING','PAUSED','INACTIVE')
group_id        BIGINT       NULL  FK → client_groups
phone           TEXT         NULL
email           TEXT         NULL
```

### `properties`
```
id                              BIGINT       PRIMARY KEY
client_id                       BIGINT       NOT NULL FK → clients
street_address                  TEXT
city, state, zip                TEXT
latitude, longitude             DOUBLE PRECISION
default_disposal_facility_id    BIGINT       NULL  FK → disposal_facilities
grease_trap_manhole_count       INTEGER      NULL
created_at, updated_at          TIMESTAMPTZ
```

### `visits`
```
id                      BIGINT       PRIMARY KEY
property_id             BIGINT       FK → properties
client_id               BIGINT       FK → clients         -- denorm OK for fast filter
visit_date              DATE         NOT NULL             -- logical operating date (overnight shifts cross midnight)
visit_status            TEXT         CHECK IN ('SCHEDULED','IN_PROGRESS','COMPLETED','CANCELLED')
truck_id                BIGINT       NULL  FK → vehicles
manhole_count           INTEGER      NULL
ticket_number           TEXT         NULL
trap_condition_notes    TEXT         NULL
completed_at            TIMESTAMPTZ  NULL
```

### `line_items`
```
id                  BIGINT          PRIMARY KEY
visit_id            BIGINT          FK → visits
service_type        TEXT            NOT NULL
quantity            NUMERIC
unit                TEXT
unit_price          NUMERIC(12,2)
total               NUMERIC(12,2)
```

### `notes`
```
id              BIGINT       PRIMARY KEY
entity_type     TEXT         CHECK IN ('visit','client','property')
entity_id       BIGINT       NOT NULL
body            TEXT         NOT NULL
note_date       DATE         NOT NULL    -- the real-life date of the note
author          TEXT         NULL

```

### `photos`
```
id              BIGINT       PRIMARY KEY
storage_path    TEXT         NOT NULL    -- Supabase Storage path
source          TEXT         NOT NULL    -- 'jobber' | 'app-upload' | etc.
uploaded_at     TIMESTAMPTZ

```

### `photo_links`
```
id              BIGINT       PRIMARY KEY
photo_id        BIGINT       FK → photos
entity_type     TEXT         CHECK IN ('visit','inspection','note','derm_manifest')
entity_id       BIGINT
role            TEXT         NULL    -- Jobber attachment category; leave NULL on app uploads

```

### `photo_classifications`
```
photo_link_id           BIGINT       PRIMARY KEY FK → photo_links
service_phase           TEXT         CHECK IN ('before','after','internal','extra','unknown')
classified_by_user_id   UUID         NULL FK → auth.users
quality_flag            TEXT         NULL
notes                   TEXT         NULL
created_at, updated_at  TIMESTAMPTZ
```

### `inspections`
```
id              BIGINT       PRIMARY KEY
visit_id        BIGINT       FK → visits
phase           TEXT         CHECK IN ('pre','post')
water_level     NUMERIC      NULL
sludge_level    NUMERIC      NULL
performed_at    TIMESTAMPTZ

```

### `derm_manifests`
```
id                      BIGINT       PRIMARY KEY
white_manifest_number   TEXT         NOT NULL UNIQUE        -- THE canonical column name
service_date            DATE         NOT NULL
client_id               BIGINT       FK → clients
disposal_facility_id    BIGINT       FK → disposal_facilities
gallons_grease          NUMERIC
gallons_sludge          NUMERIC
gallons_water           NUMERIC
```

### `manifest_visits`  (join)
```
manifest_id     BIGINT       FK → derm_manifests
visit_id        BIGINT       FK → visits
PRIMARY KEY (manifest_id, visit_id)
```

### `service_configs`
```
id              BIGINT       PRIMARY KEY
client_id       BIGINT       FK → clients
service_type    TEXT         NOT NULL CHECK IN ('GT','CL','OTHER')
frequency       TEXT         -- 'weekly' | 'bi-weekly' | 'monthly' | 'quarterly' | 'one-time'
material_type   TEXT         NULL
is_active       BOOLEAN      DEFAULT true

```

### Lookups (full schema on request — ask Yannick)
- `vehicles` — `id, name, decal_number, is_active, created_at, updated_at`
- `employees` — `id, full_name, role CHECK IN ('driver','helper','plumber','office','admin'), is_active, ...` (column is `full_name`, NOT `name`)
- `disposal_facilities` — `id, name, address, latitude, longitude, is_active, ...`
- `client_groups` — `id, name, ...` (parent chains like 'Subway', 'Marriott')

### `entity_source_links`  (THE one place external IDs live)
```
id              BIGINT       PRIMARY KEY
entity_type     TEXT         CHECK IN ('client','property','visit','employee','vehicle','...')
entity_id       BIGINT       NOT NULL
source          TEXT         CHECK IN ('jobber','airtable','samsara','fillout','ramp','derm')
source_id       TEXT         NOT NULL    -- whatever the source's id is (string)
UNIQUE (source, source_id)

```

**Never add `jobber_id`, `airtable_record_id`, `samsara_vehicle_id`, etc. columns to entity tables.** Always go through `entity_source_links`. If you need to look up "the client whose Jobber id is X," do `JOIN entity_source_links esl ON esl.entity_id = clients.id AND esl.entity_type='client' AND esl.source='jobber' AND esl.source_id='X'`.

---

## STEP 3 — App-specific tables (`app_*` prefix)

For tables only your app needs — UI state, overrides, classifications, review workflows — prefix with `app_`. Examples: `app_visit_reviews`, `app_property_overrides`, `app_user_preferences`.

Sandbox-only. Fred decides at migration: promote to canonical, wrap in a per-app schema view, or leave behind.

---

## STEP 4 — Migrations + seed

- Every schema change → versioned `.sql` migration. No "edit table in dashboard."
- Migrations are **idempotent** (`CREATE TABLE IF NOT EXISTS`, `ALTER TABLE ADD COLUMN IF NOT EXISTS`) and wrapped in `BEGIN; ... COMMIT;`.
- Seed data: 3-5 fake rows per table. **Never seed with real UnclogMe client info** — Fred handles real-data import after migration.

---

## STEP 5 — RLS + auth (project-specific notes)

See workspace Knowledge for the principles. Project-specifics:

- For per-user data, scope with `auth.uid()`:
  ```sql
  CREATE POLICY my_data_select ON app_user_preferences
    FOR SELECT TO authenticated
    USING (user_id = auth.uid());
  ```
- Service-role operations → Edge Functions only.

---

## STEP 6 — Handoff checklist

When Yannick says **"feature complete"**:

- [ ] Schema is frozen. No more migrations.
- [ ] Full app code committed + pushed.
- [ ] Lovable Supabase project URL + project ref shared with Fred.
- [ ] `docs/SCHEMA.md` — every table, every column, every FK, every RLS policy. Sourced from the live DB, not from memory.
- [ ] `docs/HANDOFF.md` covering:
  - Every deviation from this bootstrap doc, and **why** (this is critical — Fred needs to know what to keep vs. rewrite).
  - Every `app_*` table — what it's for, where it's written, where it's read.
  - Auth role expectations per route.
  - Edge functions list (paths + purposes).
  - Storage buckets used (names + privacy settings).
- [ ] Demo recording (Loom or similar) showing the golden path end-to-end.

After handoff, Fred provisions a per-app sandbox cloned from Prod canonical, Yannick re-points the app to the new sandbox, Fred validates, then promotes to Prod.

---

(Forbidden moves and "ASK FIRST" rule live in the workspace Knowledge — read both docs together.)
