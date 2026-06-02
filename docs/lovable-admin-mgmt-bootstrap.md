# Lovable Project Bootstrap — UnclogMe **Admin Management**

Paste at project start. Pairs with the workspace Knowledge (conventions + canonical names + handoff). This doc gives you the **3-page spec + canonical schema shapes to mirror exactly** for the clients / employees / trucks admin app.

---

## What this app is

An internal admin tool with **3 pages** for managing core business records. The user has spreadsheet-style expectations (Airtable-like): see rows, click cells, edit inline, save.

| Page | Canonical table edited | Read also from |
|---|---|---|
| **Client management** | `clients` | `properties`, `client_groups`, `service_configs`, `gdos`, `entity_source_links` |
| **Employee management** | `employees` | (nothing else for v1) |
| **Truck management** | `vehicles` | (nothing else for v1) |

Primary user: **Admin only** (Fred + Yan + future ops admins). No customer-facing routes, no field-driver routes. All write paths run as `authenticated` with an admin role check.

---

## STEP 0 — App metadata

```
App name:        admin-mgmt (or whatever Yan/Yannick prefer)
Primary user:    [x] Admin
Core purpose:    Spreadsheet-style CRUD for clients, employees, trucks (core ops admin).
Entities touched:
  - clients (edit)
  - properties (edit, via client detail)
  - employees (edit)
  - vehicles (edit)
  - client_groups (read; edit later)
  - service_configs (read; edit later)
  - gdos (read; nice-to-have for v1)
  - entity_source_links (read-only — show Jobber/Airtable IDs as reference, never edit)
Auth model:      [x] email/password (Supabase Auth)
```

---

## STEP 1 — Schema plan BEFORE code

For THIS app, the canonical tables already exist in Prod. **You should NOT design new schemas for clients/employees/vehicles.** Mirror the shapes in STEP 2 exactly — Fred's promotion-to-Prod step will simply re-point the app at the canonical tables.

If you find yourself wanting to add a column to a canonical table:
- **STOP. ASK YANNICK FIRST.** Fred owns canonical evolution.
- If it's truly app-only state (e.g. "last-viewed filter", "Yan's saved view"), put it in an `app_*` table.

The only schema work expected in this app:
- Optional `app_admin_users` if you want a UI to manage which `auth.users` have admin role (alternative: store role in `auth.users.raw_user_meta_data->>'role'`).
- Optional `app_saved_views` if you want filter presets like Airtable views.

---

## STEP 2 — Canonical schema (authoritative as of 2026-05-25)

These shapes come from Prod (`public.*`). Column names and types are **normative — match them exactly**. Every table also has the audit trigger writing to `audit.logs` automatically — your app does not need to write audit rows manually.

Every table has:
```
created_at  TIMESTAMPTZ  DEFAULT now()
updated_at  TIMESTAMPTZ  DEFAULT now()
```
Plus a `BEFORE UPDATE` trigger bumping `updated_at`. **Never set `updated_at` manually.**

### `clients`  (Client management page edits THIS)
```
id           BIGINT       PRIMARY KEY  (sequence)
client_code  TEXT         NULL          -- e.g. '168-AVA', '009-CN'. Stable external code from ops.
name         TEXT         NOT NULL      -- business display name. NO code prefix in the name itself.
status       TEXT         NULL          -- 'ACTIVE' | 'RECURRING' | 'PAUSED' | 'INACTIVE'
balance      NUMERIC      NULL          -- account balance (USD; canonical decimal)
notes        TEXT         NULL          -- free-text ops notes
group_id     BIGINT       NULL  FK → client_groups
```

**Notes for the page UI:**
- `status` is canonical lifecycle — show as a dropdown, never "active boolean".
- `name` should NOT contain the client_code; render code separately in the row header (e.g. "168-AVA — AVA Restaurant").
- Phone, email, address fields are NOT on `clients` — they live on `properties` (one client can have multiple properties; show in a detail panel).

### `properties`  (related — Client management page reads/edits via client detail)
```
id                              BIGINT       PRIMARY KEY
client_id                       BIGINT       NOT NULL FK → clients
name                            TEXT         NULL    -- optional location nickname
address                         TEXT         NULL    -- single-line street address
city                            TEXT         NULL
state                           TEXT         NULL DEFAULT 'FL'
zip                             TEXT         NULL
country                         TEXT         NULL DEFAULT 'US'
county                          TEXT         NULL    -- e.g. 'Dade'
zone                            TEXT         NULL    -- ops routing zone
latitude                        NUMERIC      NULL
longitude                       NUMERIC      NULL
geofence_radius_meters          NUMERIC      NULL
geofence_type                   TEXT         NULL
access_hours_start              TEXT         NULL    -- 'HH:MM' (stored as text, not time)
access_hours_end                TEXT         NULL    -- 'HH:MM'
access_days                     TEXT[]       NULL    -- ['mon','tue','wed','thu','fri','sat','sun']
access_notes                    TEXT         NULL
is_primary                      BOOLEAN      NULL DEFAULT true   -- primary service location
is_billing                      BOOLEAN      NULL DEFAULT false  -- billing address
grease_trap_manhole_count       INTEGER      NOT NULL DEFAULT 0  -- 0..50 CHECK
default_disposal_facility_id    BIGINT       NULL  FK → disposal_facilities
notes                           TEXT         NULL
```

### `client_groups`  (lookup — Client page filter)
```
id      BIGINT  PRIMARY KEY
name    TEXT    NOT NULL          -- e.g. 'Pura Vida', 'Carrot Express', 'Casa Neos'
status  TEXT    NOT NULL DEFAULT 'ACTIVE'
notes   TEXT    NULL
```

### `gdos`  (related — Client page nice-to-have: "how many active permits at this client's properties?")
```
id                     BIGINT       PRIMARY KEY
client_id              BIGINT       NOT NULL FK → clients
property_id            BIGINT       NOT NULL FK → properties
gdo_number             TEXT         NOT NULL          -- e.g. 'GDO-10877'. Permit number from Miami-Dade DERM.
location_label         TEXT         NULL              -- e.g. 'KITCHENS' for multi-facility properties (Casa Neos: KITCHENS / BARS / LOUNGE)
permit_expiration      DATE         NULL              -- annual; renews Dec 31
permit_document_path   TEXT         NULL              -- Supabase Storage path
max_frequency_days     INTEGER      NULL              -- city-mandated max service interval (CHECK > 0)
status                 TEXT         NOT NULL DEFAULT 'ACTIVE'   -- CHECK IN ('ACTIVE','EXPIRED','INACTIVE')
notes                  TEXT         NULL
```

**For v1 on the Client page**: read-only badge showing "N active GDOs" with a link to drill into them. Don't build a full GDO editor in this app.

### `service_configs`  (related — Client page read-only badge)
```
id                       BIGINT       PRIMARY KEY
client_id                BIGINT       NOT NULL FK → clients
property_id              BIGINT       NULL  FK → properties
service_type             TEXT         NOT NULL          -- CHECK IN ('GT','CL','WD','LS')
frequency_days           INTEGER      NULL              -- e.g. 30, 60, 90
first_visit              DATE         NULL
last_visit               DATE         NULL
stop_date                DATE         NULL
price_per_visit          NUMERIC      NULL              -- USD
schedule_notes           TEXT         NULL
equipment_size_gallons   NUMERIC      NULL
material_type            TEXT         NULL
permit_number            TEXT         NULL              -- legacy; canonical permit lives on `gdos`
permit_expiration        DATE         NULL              -- legacy; canonical permit lives on `gdos`
permit_document_path     TEXT         NULL              -- legacy
```

### `employees`  (Employee management page edits THIS)
```
id            BIGINT  PRIMARY KEY
full_name     TEXT    NOT NULL    -- the column is FULL_NAME, not "name"
role          TEXT    NULL        -- free text in Prod today; recommended values:
                                  --   'driver','helper','plumber','office','admin'
status        TEXT    NULL DEFAULT 'ACTIVE'
shift         TEXT    NULL        -- 'day' | 'night' | other
email         TEXT    NULL
phone         TEXT    NULL
hire_date     DATE    NULL
access_level  TEXT    NULL        -- e.g. 'admin','staff','viewer'
notes         TEXT    NULL
```

**Notes for the page UI:**
- The column is `full_name` — never `name`. This trips up every new app.
- `role` has no CHECK constraint in Prod (yet) but use the dropdown values above for consistency.
- Show all employees by default; let admin filter by status / role / shift.

### `vehicles`  (Truck management page edits THIS)
```
id                              BIGINT      PRIMARY KEY
name                            TEXT        NOT NULL    -- truck name. Real names: 'Moises','David','Cloggy','Goliath'
make                            TEXT        NULL        -- 'Kenworth' etc.
model                           TEXT        NULL        -- 'T880' etc.
year                            INTEGER     NULL
vin                             TEXT        NULL
license_plate                   TEXT        NULL
decal_number                    TEXT        NULL
fuel_tank_capacity_gallons      NUMERIC     NULL
grease_tank_capacity_gallons    NUMERIC     NOT NULL    -- NOT NULL in Prod; required field
status                          TEXT        NULL DEFAULT 'ACTIVE'
notes                           TEXT        NULL
```

**Notes for the page UI:**
- A truck `name` IS the truck's identity — NOT a person's name. Moises/David/Cloggy/Goliath are TRUCKS, not employees.
- `grease_tank_capacity_gallons` is required (NOT NULL); validate in the form.
- Prod does NOT currently have a `water_tank_capacity_gallons` column. If you need that for the UI, ASK YANNICK FIRST before adding — Fred owns canonical evolution.

### `entity_source_links`  (read-only on this app — never UPDATE)
```
id                BIGINT       PRIMARY KEY
entity_type       TEXT         NOT NULL    -- 'client','property','employee','vehicle', etc.
entity_id         BIGINT       NOT NULL
source_system     TEXT         NOT NULL    -- 'jobber','airtable','samsara','ramp','derm'
source_id         TEXT         NOT NULL    -- the source's id (string)
source_name       TEXT         NULL        -- the source's display name
match_method      TEXT         NULL
match_confidence  NUMERIC      NULL
synced_at         TIMESTAMPTZ  NULL DEFAULT now()
UNIQUE (source_system, source_id)
```

**Show as reference info** in the detail panels (e.g. "Jobber ID: abc123"). **Never let the user edit these.** Cross-system identity is managed by sync, not by this app.

### `disposal_facilities`  (lookup — properties.default_disposal_facility_id FK)
```
id              BIGINT   PRIMARY KEY
name            TEXT     NOT NULL
facility_type   TEXT     NOT NULL    -- e.g. 'dump','wwtp'
address, city, state, zip   TEXT
latitude, longitude         NUMERIC
status          TEXT     NOT NULL DEFAULT 'ACTIVE'
notes           TEXT     NULL
```

### Canonical column-name gotchas to enforce

| Wrong | Right | Where |
|---|---|---|
| `clients.active` boolean | `clients.status` IN ('ACTIVE','RECURRING','PAUSED','INACTIVE') | clients |
| `employees.name` | `employees.full_name` | employees |
| `vehicles.tank_capacity_gallons` | `vehicles.fuel_tank_capacity_gallons` or `vehicles.grease_tank_capacity_gallons` | vehicles |
| Truck "did the visit" treated as person | Truck is a **vehicle**, not a person | vehicles vs employees |
| `properties.street_address` | `properties.address` (single-line) | properties |
| `entity_source_links.source` | `entity_source_links.source_system` | entity_source_links |
| `service_configs.frequency` (text) | `service_configs.frequency_days` (INTEGER) | service_configs |

---

## STEP 3 — App-specific tables (`app_*` prefix)

For this app, you'll likely need **at most** these two (and possibly neither):

### Option A: `app_admin_users` — if you want a UI for managing who's admin
```sql
CREATE TABLE app_admin_users (
  user_id  UUID PRIMARY KEY REFERENCES auth.users(id),
  granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  granted_by UUID REFERENCES auth.users(id),
  notes TEXT
);
```
Alternative: skip the table and store `role='admin'` in `auth.users.raw_user_meta_data`. Either works. Pick one and stay consistent.

### Option B: `app_saved_views` — if you want Airtable-style saved filter presets
```sql
CREATE TABLE app_saved_views (
  id           BIGSERIAL PRIMARY KEY,
  user_id      UUID NOT NULL REFERENCES auth.users(id),
  page         TEXT NOT NULL CHECK (page IN ('clients','employees','vehicles')),
  name         TEXT NOT NULL,
  filter_json  JSONB NOT NULL,
  is_shared    BOOLEAN NOT NULL DEFAULT false,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

**Don't build these speculatively** — ship v1 without them and add only if Yan asks.

---

## STEP 4 — Migrations + seed

- For canonical tables (`clients`, `properties`, `employees`, `vehicles`, `client_groups`, `gdos`, `service_configs`, `disposal_facilities`, `entity_source_links`): create them in your sandbox using the shapes in STEP 2. No additions, no changes.
- For `app_*` tables: standard migration pattern (`CREATE TABLE IF NOT EXISTS ... BEGIN/COMMIT`).
- **Seed with 3–5 fake rows per table**. Never use real UnclogMe client/employee/vehicle data — Fred handles real-data load at promotion.

---

## STEP 5 — RLS + auth (this app's specifics)

This app **edits canonical tables**, so the RLS story is stricter than read-only apps:

1. **RLS ON for every table on day one.** No exceptions.
2. All write paths must run as `authenticated`. Anon writes will be revoked at Prod migration — if any write path requires anon today, it'll break.
3. **Admin-only writes.** Policy pattern:
   ```sql
   CREATE POLICY clients_admin_write ON clients
     FOR ALL TO authenticated
     USING (
       (auth.jwt() -> 'user_metadata' ->> 'role') = 'admin'
       OR EXISTS (SELECT 1 FROM app_admin_users WHERE user_id = auth.uid())
     );
   ```
   (Pick whichever admin-check you went with in STEP 3.)
4. **Read can be authenticated-anyone** for the dropdowns (employees → driver picker, vehicles → truck picker), but writes always require admin.
5. `app_saved_views` rows: scope reads/writes by `user_id = auth.uid()` (own saved views only). For shared views (`is_shared = true`), allow read for all authenticated.
6. **Never write directly to `entity_source_links` from this app.** Read-only.

---

## STEP 6 — Handoff checklist

When Yan says **"feature complete"**:

- [ ] Schema frozen. No more migrations.
- [ ] Full app code committed + pushed.
- [ ] Lovable Supabase project URL + ref shared with Fred.
- [ ] `docs/SCHEMA.md` — every table, every column, every FK, every RLS policy. Sourced from your live sandbox DB.
- [ ] `docs/HANDOFF.md` covering:
  - Every deviation from this bootstrap doc + **why** (Fred decides at Prod migration: keep, rewrite, or backport to canonical).
  - Every `app_*` table — purpose, write paths, read paths.
  - Admin auth scheme used (metadata vs `app_admin_users`).
  - Any column you wished was on the canonical table (Fred may promote to canonical if useful org-wide).
- [ ] Demo Loom of the 3 pages working end-to-end (add row, edit row, archive row, save view).

After handoff: **this app is 2-stage** (CRUD on canonical, no Edge Functions, no scale/perf dependency). Fred goes Lovable → Prod directly via a per-app schema view, validates the writes against the real schema + audit triggers on a brief staging pass, then flips it live. No intermediate Fred-clone sandbox is needed.

---

## App-specific design notes

### Airtable-style UX expectations for the Client page

Yan said *"similar to Airtable interface for clients"*. That means:
- **Spreadsheet-style table** with all clients as rows.
- **Click a cell to edit inline** (status dropdown, balance number input, client_code text, etc.) — don't hide everything behind a "Edit" modal.
- **Multi-row selection + bulk actions** (set status, change group) — at least allow bulk PAUSED/INACTIVE.
- **Column filters** at the top of each column (search by name, filter status to ACTIVE only, group_id picker).
- **Inline detail panel** when a row is clicked: shows the client's properties (with their addresses), service_configs (with frequency_days), GDOs (count + list).
- **Save = explicit button** OR **autosave on blur** — pick one and be consistent. (Autosave is more Airtable-like; explicit save is safer for a canonical admin tool. Yan's call.)

### Employee + Truck pages — simpler

These are smaller record sets (a few employees, ~4 vehicles). A standard table with inline edit + "Add new" button is enough. No bulk actions needed.

### Audit-trail surface (nice-to-have)

The canonical `audit.logs` table records every UPDATE on these tables (full row JSONB before/after). Consider adding a small "Recent changes" panel on each detail page that reads:
```sql
SELECT changed_at, app_source, db_role, jwt_claims->>'email' AS user, old_row, new_row
FROM audit.logs
WHERE table_name = 'clients' AND record_pk->>'id' = $1::text
ORDER BY changed_at DESC
LIMIT 10;
```
Set `X-App-Source: admin-mgmt` header on all writes so audit rows attribute correctly (see ADR 016 — Fred can explain).

### Defensive write rules for this app

Because this app edits canonical:
- **Never hard-delete a client/employee/vehicle** — set `status = 'INACTIVE'` instead. Hard deletes break `entity_source_links` joins and historical visits.
- **Validate before submit**:
  - `clients.status` must be one of the 4 enum values
  - `employees.full_name` non-empty
  - `vehicles.grease_tank_capacity_gallons` > 0
  - `vehicles.name` unique (you can add a unique index or just check in the form)
- **Numeric inputs**: money fields use `NUMERIC` precision — use `string`/`number` carefully on the client and round display only at render.
- **Never expose `entity_source_links` editing** — it's sync-managed, not user-managed.

### What this app does NOT do

So you don't drift into scope creep:
- ❌ Schedule or edit visits (separate app — Visit Calendar)
- ❌ Edit GDOs (Fred handles via migrations + ops bot; this app is read-only for GDOs)
- ❌ Edit DERM manifests (DERM Tracker app)
- ❌ Manage payments, invoices, line items (separate)
- ❌ Show maps, GPS, telemetry (Field Portal handles)
- ❌ Sync to/from Jobber, Airtable, Samsara (Edge Functions handle)

---

## TL;DR

1. Read the workspace Knowledge first (conventions).
2. Read STEP 2 of this doc — those are the **exact** canonical shapes; do not deviate.
3. Build 3 pages: Clients (Airtable-style), Employees, Trucks. All admin-only.
4. RLS on day one, writes as `authenticated` + admin check.
5. Set `X-App-Source: admin-mgmt` on every write so audit attribution works.
6. Freeze schema, write HANDOFF.md, hand off.

---

*Forbidden moves and "ASK FIRST" rule live in the workspace Knowledge — read both docs together.*
