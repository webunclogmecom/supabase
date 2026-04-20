# Viktor — Database Access Setup

**Last updated:** 2026-04-20

Viktor (AI coworker in Slack, `U0AKTMAMWP9`) uses two Supabase projects for Yan's Sales App:

| Project | Access | Purpose |
|---|---|---|
| **Main Unclogme DB** (`wbasvhvvismukaqdnouk`) | Read-only via `viktor_readonly` Postgres role | Fresh operational data — clients, visits, DERM manifests, photos, notes |
| **Yan's Sales App DB** (Yan creates — not yet set up) | Full write via service_role key | Sales App's own tables for new data; merged back to main DB later |

---

## 1. Main DB — read-only for Viktor

### 1.1 How it's enforced

Dedicated Postgres login role `viktor_readonly` with:

- **SELECT only** on `public` and `ops` schemas (45 tables/views)
- **No INSERT / UPDATE / DELETE / TRUNCATE** grants anywhere
- **Revoked** on `webhook_tokens` (holds OAuth credentials — Viktor should never see these)
- `NOSUPERUSER`, `NOCREATEDB`, `NOCREATEROLE`, `NOINHERIT`
- Connection limit: 10 concurrent

Applied via: [`scripts/migrations/create_viktor_readonly_role.sql`](../scripts/migrations/create_viktor_readonly_role.sql).

### 1.2 Connection strings Viktor uses

**Pooler (recommended — IPv4, works from anywhere):**
```
postgresql://viktor_readonly.wbasvhvvismukaqdnouk:<PW>@aws-1-us-east-1.pooler.supabase.com:6543/postgres
```

**Direct (for long sessions, may require IPv6):**
```
postgresql://viktor_readonly:<PW>@db.wbasvhvvismukaqdnouk.supabase.co:5432/postgres
```

Password is **not** in this repo. It's in Fred's credential store and was sent to Viktor via Slack DM (see §4 below).

### 1.3 What Viktor can read

Everything under `public.*` and `ops.*` except `webhook_tokens`. Specifically:

- Core business: `clients`, `client_contacts`, `properties`, `service_configs`, `employees`, `vehicles`, `jobs`, `visits`, `invoices`, `quotes`, `line_items`, `inspections`, `expenses`, `derm_manifests`, `routes`, `receivables`, `leads`
- Junctions: `visit_assignments`, `manifest_visits`, `route_stops`
- Photo + notes: `photos`, `photo_links`, `notes`, `jobber_oversized_attachments`
- Telemetry: `vehicle_telemetry_readings`
- Cross-system IDs: `entity_source_links`
- Views: `clients_due_service`, `client_services_flat`, `visits_with_status`, `v_vehicle_telemetry_latest`, `ops.v_route_today`, `ops.v_service_due`, etc.
- Sync observability: `sync_cursors`, `sync_log`, `webhook_events_log`

### 1.4 What Viktor cannot do

- Any write to any table (INSERT/UPDATE/DELETE rejected at grant level)
- Read `webhook_tokens` (OAuth credentials)
- Create schema, roles, or DBs
- Execute stored procedures (EXECUTE revoked)

### 1.5 Password rotation

Every 90 days or immediately on suspected compromise:

```sql
ALTER ROLE viktor_readonly WITH PASSWORD '<new>';
```

Then DM Viktor the new password. Log the rotation in [`docs/runbook.md §8`](runbook.md#8-incident-log).

---

## 2. Yan's Sales App DB — Viktor has full access

**Not yet set up.** Yan creates the new Supabase project from the handoff zip per [`handoff/BUILDING-NEW-APPS.md`](../handoff/unclogme-handoff/BUILDING-NEW-APPS.md) §3.

Once created:

- Yan hands Viktor the new project's `service_role` key for write access
- Viktor can freely `INSERT`/`UPDATE`/`DELETE` on any table in Yan's new project
- **NO read-only role needed there** — Yan owns that DB

When the Sales App is ready to go live, Fred + Viktor merge Yan's schema + data into the main DB. At merge time, the Sales App's connection string switches from Yan's build project to a role on the main DB (could be a dedicated `sales_app` role similar to `viktor_readonly` but with write access to Sales App tables only).

---

## 3. Why this design

### 3.1 Two DBs, not one

- **Separation of concerns**: the main DB is production data (live webhooks from Jobber, Samsara, Airtable). Yan's Sales App writes experimental new tables — we don't want that mixing with production until reviewed.
- **Independent deploy cycles**: Yan iterates on the Sales App without coordinating schema changes with Fred's ongoing 3NF cleanup work.
- **Merge-gated quality**: when Yan's work is ready, Fred reviews the schema diff + data before merging. Mistakes stay in the build DB.

### 3.2 Postgres role, not JWT / RLS

- **JWT + RLS** would require enabling RLS on every table + writing `anon`-bound policies. Affects other consumers (the Lovable integration Fred is already evaluating).
- **Dedicated Postgres login user** isolates Viktor's access without touching `anon` / `authenticated` configuration.
- Password-based Postgres auth is what Viktor's tooling supports natively — no custom JWT signing, no Supabase configuration toggles.

### 3.3 Direct Postgres, not HTTP API

Viktor can use either. The docs show Postgres pooler first because:
- Most Python/Node PG libraries (`psycopg2`, `pg`, `asyncpg`) support Postgres connection strings natively
- The connection pooler handles IPv4 for environments that can't do IPv6
- PostgREST (the HTTP API) requires extra JWT/role config work; direct PG is simpler

If Viktor prefers HTTP API, he can still use the anon key — but RLS would need to be enabled for real isolation. We're not there yet. Direct PG is the recommended path.

---

## 4. Viktor Slack handoff

Credentials were sent to Viktor (user `U0AKTMAMWP9`) via Slack DM on 2026-04-20. The DM contains:
- The pooler connection string (recommended)
- The direct connection string (backup)
- Username + password
- Reminder that access is read-only + password rotation cadence

Fred has a copy of the password in his credential store.

**If Viktor changes integration mechanism** (e.g., starts using HTTP API instead of direct PG), the `viktor_readonly` role still works via a role-claim JWT — just needs the `SUPABASE_JWT_SECRET` (not in this repo; fetch from Supabase dashboard if needed).

---

## 5. When this setup changes

- **Yan's new Supabase project goes live** → update §2 with the project ref + confirm Viktor has service_role
- **Yan's schema grows** → Viktor's read-only grants on the main DB may need additional read permissions (unlikely — all business data is already in the 45 granted tables)
- **Sales App goes to production** → schema merges back, a dedicated `sales_app_write` role with narrow INSERT/UPDATE grants replaces Yan's service_role usage
- **Suspected compromise** → rotate password immediately (§1.5) and audit queries in Supabase dashboard logs

---

## Related docs

- [`handoff/unclogme-handoff/BUILDING-NEW-APPS.md`](../handoff/unclogme-handoff/BUILDING-NEW-APPS.md) — what Yan needs to do to set up his new DB
- [`docs/security.md`](security.md) — overall credential management + rotation procedures
- [`scripts/migrations/create_viktor_readonly_role.sql`](../scripts/migrations/create_viktor_readonly_role.sql) — the idempotent migration
