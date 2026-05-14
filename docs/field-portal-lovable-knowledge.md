# UnclogMe Field Portal — DB Foundation (Lovable Knowledge)

You are connected to **Field Portal Sandbox** Supabase project `klgtrdwrasrlxbmfyvdh`. It contains a clone of UnclogMe's canonical Production schema (27 tables, 44 sample clients, 249 visits, 240 DERM manifests, 1,158 cross-system identity links). Every schema change you make here will be migrated back to Production. Follow the rules below so the migration stays safe.

## Domain

UnclogMe = commercial grease-trap / drain-cleaning operator in Miami-Dade. **Field Portal** is the in-app surface for **field operators** (commercial drivers, day plumbers, helpers): see today's route, log visit completion, flag issues, view access hours + GDO permits + last-visit history, submit PRE-POST shift inspections.

## Non-negotiable rules

1. **3NF.** For every new column, ask: "does this depend ONLY on the table's PK?" If it depends on another column in the row (2NF) or via FK (3NF), don't store it — JOIN at read time or use a view.
2. **Source-agnostic schema.** Never create `jobber_*`, `airtable_*`, `samsara_*`, `fillout_*`, `lovable_*` columns on canonical tables. Cross-system identity lives in the polymorphic `entity_source_links(entity_type, entity_id, source_system, source_id)` bridge table.
3. **TIMESTAMPTZ + NUMERIC(12,2).** All datetime columns are `TIMESTAMPTZ` storing UTC (app converts to ET for display). All money columns are `NUMERIC(12,2)`. Never `TIMESTAMP`, `FLOAT`, `REAL`, `MONEY`. `updated_at` is trigger-managed — never write to it from app code.
4. **Idempotent upserts.** Every INSERT path uses `ON CONFLICT (...) DO UPDATE/NOTHING` on a natural key. Add `UNIQUE` constraints on business keys (e.g., `UNIQUE(client_id, service_type)` on `service_configs`).
5. **Soft delete only.** Business data uses a `status` column (`'ACTIVE'`, `'INACTIVE'`, `'PAUSED'`, etc). Hard `DELETE` only for retention trims, drafts never used, throwaway data.
6. **Reference, don't copy.** Use FK + JOIN. Never store `client_name` on `visits`, never duplicate email/phone/address from a parent table.

## Naming conventions

| Element | Convention |
|---|---|
| Table | `snake_case` plural noun (`visits`, `service_configs`) |
| Column | `snake_case` singular (`visit_date`, `total_amount`) |
| Primary key | `id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY` |
| Foreign key | `<referent>_id` (e.g. `client_id` → `clients.id`) |
| Boolean | `is_*` / `has_*` / `was_*` prefix |
| Enum | `TEXT NOT NULL CHECK (col IN ('A','B',...))` |
| Timestamp | `_at` suffix (`created_at`, `completed_at`) |
| Date | `_date` suffix (`visit_date`, `due_date`) |

## Canonical enum values (don't invent variants)

```
clients.status               : 'ACTIVE' | 'RECURRING' | 'PAUSED' | 'INACTIVE'
visits.visit_status          : 'scheduled' | 'completed' | 'cancelled'
service_configs.service_type : 'GT' | 'CL' | 'WD' | 'LS'
  GT=Grease Trap (incl. main pipe / "Gray Water pumping" cleaning)
  CL=Auxiliary Cleaning (AT label "AUX Cleaning"; NOT "MAIN CL")
  WD=Water Discharge / warranty
  LS=Lift Station
invoices.invoice_status      : 'paid' | 'past_due' | 'awaiting_payment' | 'draft' | 'bad_debt'
vehicles.status              : 'ACTIVE' | 'INACTIVE'
inspections.inspection_type  : 'PRE' | 'POST'
```

## Data source trust hierarchy

- **Jobber + Samsara = 100% canonical** for visits, clients, properties, invoices, line_items, vehicles, telemetry, GPS, geofences.
- **Airtable = best-effort enrichment** ONLY for `derm_manifests` + `inspections` (PRE-POST). Never override Jobber/Samsara with Airtable values.

## Existing tables (don't recreate)

`clients`, `client_contacts`, `properties`, `service_configs`, `visits`, `visit_assignments`, `jobs`, `invoices`, `line_items`, `quotes`, `notes`, `derm_manifests`, `manifest_visits`, `vehicles`, `employees`, `inspections`, `entity_source_links`, `webhook_tokens`, `webhook_events_log`, `vehicle_telemetry_readings`, `photos`, `photo_links`, `sync_cursors`.

Key facts:
- A client can have multiple `properties`; `is_primary=true` for the main one. Properties carry `access_hours_start/end`, `access_days`, GPS, geofence, GDO `permit_number` / `permit_expiration`.
- `visits.visit_date` = LOGICAL operating date (overnight shifts: a truck starting Mon 11pm and finishing Tue 2am has `visit_date=Monday`).
- Scheduled visits have only `visit_date`. Clock times (`start_at`, `completed_at`) populate when COMPLETED.
- **Trucks are not people.** Moises / David / Cloggy / Goliath are vehicles in `vehicles`. Drivers are in `employees`, joined via `visit_assignments`. Never display a person's name unless you can resolve it via `visit_assignments → employees.full_name`.

## Authentication & app users

Field Portal uses Supabase Auth (`auth.users`). Each app user MUST map to a row in **`employees`** by email — do NOT create a parallel `users` / `app_users` table.

For user attribution on new tables, use `created_by_employee_id BIGINT REFERENCES employees(id)`. Helper to map `auth.uid()` → `employees.id`:

```sql
CREATE OR REPLACE FUNCTION current_employee_id() RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER AS $$
  SELECT e.id FROM employees e
  JOIN auth.users u ON LOWER(u.email) = LOWER(e.email)
  WHERE u.id = auth.uid() LIMIT 1;
$$;
```

## RLS on every new table

```sql
ALTER TABLE my_new_table ENABLE ROW LEVEL SECURITY;
CREATE POLICY "auth_read"   ON my_new_table FOR SELECT TO authenticated USING (true);
CREATE POLICY "auth_insert" ON my_new_table FOR INSERT TO authenticated WITH CHECK (true);
CREATE POLICY "owner_update" ON my_new_table FOR UPDATE TO authenticated
  USING (created_by_employee_id = current_employee_id());
-- No DELETE policy. Soft-delete via status column.
```

Tighten `USING (true)` as soon as roles are clear.

## Checklist for every new table

- [ ] `snake_case` plural name
- [ ] `id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY`
- [ ] `created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
- [ ] `updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` + `BEFORE UPDATE` trigger
- [ ] FK columns named `<referent>_id`
- [ ] `status TEXT` + CHECK constraint if deactivatable
- [ ] `UNIQUE` constraint on natural business keys
- [ ] RLS enabled with starter policies
- [ ] `COMMENT ON TABLE ... IS '<purpose, 1-2 sentences>'`
- [ ] External IDs go in `entity_source_links`, NOT as `_id` columns

## What NOT to do

| Don't | Why |
|---|---|
| ALTER canonical tables to add Field-Portal-specific columns | Migration to Prod gets ugly. Add a NEW table with FK back. |
| Add `jobber_id`/`airtable_record_id` columns on canonical tables | Use `entity_source_links`. |
| Store computed values (totals, days_overdue, last_visit, MTD sums) | Use views; values drift. |
| Use `VARCHAR(N)` | Use `TEXT` + `CHECK`. |
| Use `TIMESTAMP` (no tz) | Always `TIMESTAMPTZ`. |
| Use `FLOAT`/`REAL`/`MONEY` for currency | Always `NUMERIC(12,2)`. |
| Create a `users` table | Use `employees`, map by email. |
| Hard-DELETE business rows | Soft-delete via status. |
| Re-introduce `MAIN CL` as a CL service | MAIN CL is an Airtable label, NOT a service. CL = AUX Cleaning only. |
| Attribute a visit to a person | Visits attribute to trucks; resolve people via `visit_assignments → employees`. |
| Show specific arrival times on SCHEDULED visits | Scheduled visits only have `visit_date`. Times come from `start_at` when COMPLETED. |
| Use `auth.uid()` directly in RLS | Wrap via `current_employee_id()`. |

## Migration cycle to Production

You don't run the migration yourself. A maintainer (Fred) will:
1. Review the schema diff between Sandbox and Prod.
2. Write an additive SQL migration (never destructive of Prod data).
3. Test on a Prod snapshot.
4. Apply during a quiet window.

Your job: keep the schema diff clean and reviewable by following the rules above.

## When in doubt

Pick the more normalized / more explicit option. Adding a new table is preferred over altering an existing one. Views over duplicated columns. FK + JOIN over copied values. Soft delete over hard delete. Idempotent upsert over plain INSERT.
