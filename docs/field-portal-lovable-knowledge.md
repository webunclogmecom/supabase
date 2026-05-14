# UnclogMe Field Portal — Database Foundation (Lovable Knowledge)

> **Paste this verbatim into Lovable's "Knowledge" / "Custom Instructions" /
> "Project Context" field. It tells Lovable how to write database changes
> so the Sandbox schema stays migrate-ready to Production.**

---

## What this project is

UnclogMe is a commercial grease-trap / drain-cleaning service operator
in Miami-Dade (and surrounding counties). The **Field Portal** is the
in-app interface for the **field operators** — commercial drivers, day
plumbers, helpers. The portal is the daily driver-facing surface:

- See today's assigned visits + route
- Log visit completion (notes, status, observations)
- Flag issues with trucks / equipment / clients
- View access hours, GDO permit info, last-visit history per client
- Reference truck status (fuel, water, sludge, last maintenance)
- Submit PRE-POST shift inspections

## The database you're writing to

You are connected to the **Field Portal Sandbox** Supabase project
(ref: `klgtrdwrasrlxbmfyvdh`). It already contains a clean snapshot of
UnclogMe's canonical Production schema — 27 tables, 44 sample clients
(30% of active/recurring with visit history), 249 visits, 528 line_items,
240 DERM manifests, and ~1,158 cross-system identity links.

This sandbox is **migrate-ready**: every schema change you make here
will eventually be migrated back to Production. To make that migration
safe and ergonomic, every table, column, constraint, index, and policy
you add MUST follow the rules below.

---

## The 8 non-negotiable rules

### 1. 3NF (Third Normal Form) for every new column

For every column you add, ask:
> **"Does this column depend ONLY on the table's primary key — nothing else?"**

- Depends on another column in the same table (2NF violation) → don't store it.
- Reachable via FK from another column (3NF violation) → don't store it.
- Compute on read via a `VIEW` or in the application layer instead.

**BAD:** storing `client_name` on a `visits` row. The name depends on
`client_id`, not on `visit.id`. Read it via `JOIN clients`.

**GOOD:** storing `duration_minutes` on a visit when that value is
specifically about that visit's elapsed time and not derivable from
other stored columns.

If you genuinely must denormalize for performance, declare it as a
one-time documented exception with a `COMMENT ON COLUMN` explaining
why. Default answer is don't.

### 2. Source-agnostic schema

NEVER create columns named with these prefixes on existing canonical tables:
`jobber_*`, `airtable_*`, `samsara_*`, `fillout_*`, `odoo_*`, `lovable_*`.

Cross-system identity (a Jobber ID, an Airtable record ID, a Samsara
address ID for the same logical entity) lives in the **`entity_source_links`**
bridge table. It's already in the schema. It's polymorphic:

```
entity_source_links (
  id, entity_type, entity_id, source_system, source_id, created_at, …
)
```

For any external system ID, INSERT into `entity_source_links`. Don't
add a `_id` column.

**New Field-Portal-specific tables** (tables you create) CAN have any
name. The rule is about columns on canonical tables.

### 3. Timestamps in UTC, money in NUMERIC(12,2)

- All datetime columns: **`TIMESTAMPTZ`** storing UTC. Application
  layer converts to Eastern Time for display. Never `TIMESTAMP`
  (without timezone).
- All money columns: **`NUMERIC(12,2)`**. Never `FLOAT`, never `REAL`,
  never `MONEY`. The (12,2) format supports values up to $9,999,999,999.99.
- `updated_at` columns: trigger-managed, declared as
  `TIMESTAMPTZ NOT NULL DEFAULT NOW()` with a `BEFORE UPDATE` trigger
  to bump. NEVER write to `updated_at` from application code.

### 4. Idempotent upserts only

Every INSERT path that may re-run (sync scripts, backfills, retries)
must use `ON CONFLICT (...) DO UPDATE` or `DO NOTHING` on a natural
key.

If a table has no natural key beyond the auto-`id`, add a `UNIQUE`
constraint on the meaningful business columns:

```sql
UNIQUE (client_id, service_type)    -- service_configs
UNIQUE (visit_id, employee_id)      -- visit_assignments
UNIQUE (entity_type, entity_id, source_system, source_id)  -- entity_source_links
```

### 5. Soft deletes only for business data

For ANY business data (clients, visits, properties, vehicles, employees,
service_configs, etc.), use a `status` column with values like
`'ACTIVE'`, `'INACTIVE'`, `'PAUSED'`, `'CANCELLED'`. **NEVER `DELETE`**
rows that have FK references or historical meaning.

Hard `DELETE` is only acceptable for:
- `webhook_events_log` retention trims
- Draft rows that were never published/used
- True throwaway data (sessions, idempotency caches)

### 6. Reference all data — don't copy

Related data is **referenced via FK, never copied**. If a visit display
needs the client's name, the visit's UI/query does `JOIN clients`. The
visit row does NOT store `client_name`. Same applies to email, phone,
address, status, every attribute that lives on a parent table.

### 7. Naming conventions

| Thing | Convention | Example |
|---|---|---|
| Table | `snake_case`, plural noun | `visits`, `service_configs` |
| Column | `snake_case`, singular | `visit_date`, `total_amount` |
| Primary key | `id` (BIGINT, identity) | `id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY` |
| Foreign key | `<referent>_id` | `client_id` references `clients.id` |
| Boolean | `is_*` / `has_*` / `was_*` prefix | `is_primary`, `has_issue` |
| Enum value | `TEXT` + `CHECK` constraint | `CHECK (service_type IN ('GT','CL','WD','LS'))` |
| Timestamp | `_at` suffix | `created_at`, `completed_at`, `paid_at` |
| Date (no time) | `_date` suffix | `visit_date`, `due_date` |
| Money | `NUMERIC(12,2)` | `total_amount`, `outstanding_amount` |
| Bridge table | both FK names, no `id` if composite PK | `visit_assignments(visit_id, employee_id)` |

### 8. Canonical enum values

When you reference these columns, use ONLY these exact string values:

```
clients.status            : 'ACTIVE' | 'RECURRING' | 'PAUSED' | 'INACTIVE'
visits.visit_status       : 'scheduled' | 'completed' | 'cancelled'
service_configs.service_type : 'GT' | 'CL' | 'WD' | 'LS'
   (GT = Grease Trap, CL = Auxiliary Cleaning, WD = Water Discharge / warranty,
    LS = Lift Station. "MAIN CL" is NOT a service_type — it's an org label.)
invoices.invoice_status   : 'paid' | 'past_due' | 'awaiting_payment' | 'draft' | 'bad_debt'
vehicles.status           : 'ACTIVE' | 'INACTIVE'
inspections.inspection_type : 'PRE' | 'POST'
```

If you create a new column that's enum-like, follow the same pattern:
`TEXT NOT NULL CHECK (column_name IN ('VALUE1', 'VALUE2', ...))`.

---

## Trust hierarchy (when you read from multiple sources)

```
Jobber + Samsara data = 100% trusted, canonical
   (visits, clients, properties, invoices, line_items,
    vehicles, telemetry, GPS, fuel, geofences)

Airtable data = best-effort enrichment ONLY for:
   - `derm_manifests` (DERM compliance records)
   - `inspections` (PRE-POST shift inspections)

Everything else previously in Airtable is unreliable. Never let
Airtable values override Jobber/Samsara.
```

---

## Existing tables you should know about (don't recreate them)

| Table | Purpose | Notes |
|---|---|---|
| `clients` | Every commercial + residential client | 44 sample rows. `client_code` for commercial (e.g. `174-VIN`), NULL for residential. |
| `client_contacts` | Phones, emails, primary contact | FK to clients |
| `properties` | Service addresses | A client can have multiple. `is_primary = true` for the main one. Has `access_hours_start/end`, `access_days`, GPS, geofence. |
| `service_configs` | The (client × service_type) subscription | `frequency_days`, `price_per_visit`, GDO `permit_number` + `permit_expiration` for GT. |
| `visits` | Every visit, past + scheduled | FK to clients, properties, jobs, invoices, vehicles. `visit_date` is the LOGICAL operating date (overnight shift handling). |
| `visit_assignments` | Bridge: which employees worked the visit | Composite (visit_id, employee_id). |
| `jobs` | Jobber jobs | FK to clients + properties |
| `invoices` | Jobber invoices | FK to clients + jobs |
| `line_items` | Invoice line items | FK to invoices |
| `quotes` | Sales quotes | FK to clients |
| `notes` | Notes on visits/clients | `visit_id` FK, polymorphic via `entity_type` if needed. |
| `derm_manifests` | DERM disposal compliance records | FK to clients. White / yellow manifest numbers, dump ticket dates. |
| `manifest_visits` | Bridge: DERM manifest covers which visits | |
| `vehicles` | The fleet (trucks: Moises, David, Cloggy, Goliath) | NEVER attribute visits to people — only to trucks. |
| `employees` | Drivers, helpers, office staff, admins | App auth users map here by email. Has `role` and `status`. |
| `inspections` | PRE-POST shift inspections | FK to vehicles + employees. From Airtable's PRE-POST automation. |
| `entity_source_links` | Polymorphic bridge to source systems | THE place for any external-system ID. Don't add `_id` columns to canonical tables. |
| `webhook_tokens` | OAuth tokens for Jobber/Samsara/Airtable | Don't touch from app. |
| `webhook_events_log` | Operational audit trail | Retention-managed. |
| `vehicle_telemetry_readings` | Samsara GPS pings, fuel, engine state | Heavy; query views, not raw table when possible. |

---

## Truck names are NOT people

**Moises, David, Cloggy, Goliath** are the four trucks. They are NOT
people's names. Drivers are tracked in `employees` and assigned via
`visit_assignments`. When the UI says "Moises did the visit", that
means truck Moises was the vehicle on that visit — the actual driver
is one of the assigned employees.

Never invent driver names. If the UI needs to show a driver, look up
`visit_assignments → employees.full_name`.

---

## Authentication & app users

The Field Portal uses **Supabase Auth** (`auth.users` table, Supabase
manages). Each authenticated app user **MUST map** to an existing row in
the **`employees`** table by matching email address.

- Do NOT create a parallel `app_users` or `field_portal_users` table.
- Use the existing `employees` table for any user attribution.

Suggested pattern for new tables that need user attribution:

```sql
created_by_employee_id BIGINT REFERENCES employees(id),
```

To resolve `auth.uid()` → `employees.id` at query time, write a
SECURITY DEFINER function or a view:

```sql
CREATE OR REPLACE FUNCTION current_employee_id() RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT e.id FROM employees e
  JOIN auth.users u ON LOWER(u.email) = LOWER(e.email)
  WHERE u.id = auth.uid()
  LIMIT 1;
$$;
```

---

## RLS policies

Every NEW table you create MUST have **Row-Level Security enabled**.
Default starter policies (tighten as roles become clear):

```sql
ALTER TABLE my_new_table ENABLE ROW LEVEL SECURITY;

CREATE POLICY "authenticated_read"   ON my_new_table FOR SELECT
  TO authenticated USING (true);
CREATE POLICY "authenticated_insert" ON my_new_table FOR INSERT
  TO authenticated WITH CHECK (true);
CREATE POLICY "owner_update"         ON my_new_table FOR UPDATE
  TO authenticated USING (created_by_employee_id = current_employee_id());
-- DELETE: omitted on purpose (soft-delete via status column)
```

Never use `USING (true)` on UPDATE without a real condition. Tighten
to per-row ownership or role-based as soon as you know the role model.

---

## Checklist when adding a new table

When the Field Portal needs a new feature that requires a new table:

- [ ] Name is `snake_case`, plural noun, describes the entity
- [ ] `id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY`
- [ ] `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
- [ ] `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` + `BEFORE UPDATE`
      trigger to bump it
- [ ] FK columns named `<referent>_id` (e.g., `client_id` → `clients.id`,
      `visit_id` → `visits.id`)
- [ ] `status` column with `CHECK` constraint, if rows can be deactivated
- [ ] UNIQUE constraint on natural business keys (the "what makes this
      row distinct in real life" combination)
- [ ] RLS enabled, starter policies in place
- [ ] `COMMENT ON TABLE my_table IS '<purpose, 1-2 sentences>'`
- [ ] If the table tracks something cross-system, plan how
      `entity_source_links` is used (don't add `external_id` columns)

---

## What NOT to do

| Don't | Why |
|---|---|
| ALTER existing canonical tables to add Field-Portal-specific columns | Migrating back to Prod becomes messy. Add a NEW table with FK back. |
| Create columns like `jobber_id`, `airtable_record_id`, `samsara_address_id` on canonical tables | Use `entity_source_links` instead. |
| Store computed/aggregated values (totals, counts, last_visit, days_overdue) | Use views or compute on read. They drift. |
| Use `VARCHAR(N)` | Use `TEXT` + `CHECK` for length validation. |
| Use `TIMESTAMP` (without timezone) | Always `TIMESTAMPTZ`. |
| Use `FLOAT`, `REAL`, or `MONEY` for currency | Always `NUMERIC(12,2)`. |
| Create a parallel `users` / `app_users` table | Use the existing `employees` table. |
| Hard-DELETE business rows | Soft-delete via `status` column. |
| Use `auth.uid()` directly in RLS without mapping to `employees.id` | Write a `current_employee_id()` helper function. |
| Re-introduce `MAIN CL` as a CL service | "MAIN CL" is an Airtable label, not a service. CL = AUX Cleaning only. |
| Attribute a visit to a person | Visits attribute to TRUCKS (Moises / David / Cloggy / Goliath). |
| Specific arrival times for SCHEDULED visits | Scheduled visits have only `visit_date`. Times come from `start_at` when COMPLETED. |

---

## Migration back to Production (how it works)

When your work in Sandbox is ready to land in Prod:

1. A maintainer (Fred) reviews the schema diff.
2. Writes a SQL migration file (additive — never destructive of Prod data).
3. Tests on a Prod snapshot.
4. Applies during a quiet window.

You don't run this migration yourself. Just keep the schema clean
enough that the diff is reviewable. The above rules are what make a
diff reviewable.

---

## When in doubt

- Lean toward the **more normalized, more explicit option**. Cost of
  cleaning up a denormalized table later is much higher than the cost
  of joining at read time.
- Prefer **adding a new table** over altering an existing one.
- Prefer **views** over duplicated columns.
- Prefer **FK + JOIN** over copying values.
- Prefer **TEXT + CHECK** over `VARCHAR(N)`.
- Prefer **soft delete** over hard delete.
- Prefer **idempotent upsert** over plain INSERT.

These rules exist because the Sandbox is a feature branch — every
piece of work here lands in Prod eventually.

---

*Last updated 2026-05-14. If something here conflicts with a Lovable
default or auto-generated migration, the rule above wins. Push back
on the auto-generated change.*
