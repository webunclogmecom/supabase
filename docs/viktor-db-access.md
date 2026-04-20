# Viktor — Database Access Setup

**Last updated:** 2026-04-20 (v2 — after switching to Viktor's native integration path)

Viktor (AI coworker in Slack, user `U0AKTMAMWP9`) uses two Supabase projects for Yan's Sales App work. Access is enforced through **Viktor's native Supabase integration tool controls**, not via custom database credentials.

| Project | Viktor integration name | Access level | Purpose |
|---|---|---|---|
| **Main Unclogme DB** (`wbasvhvvismukaqdnouk`) | `Supabase - Main DB - Read Only` | Read-only at tool layer | Fresh operational data |
| **Yan's Sales App DB** | `Supabase - yan supa new apps` | Full write | Sales App's own tables; merged back to main DB later |

---

## 1. Main DB — read-only for Viktor

### 1.1 How it's enforced

Viktor's native Supabase integration exposes 13 tools (Upsert, Update, Select, Insert, Delete, Count, Batch Insert, RPC, Proxy Get/Post/Put/Patch/Delete). Each tool has an independent setting:

- **Off** — Viktor cannot invoke this tool at all
- **Ask for confirmation** — Viktor requires human approval before each invocation
- **Run automatically** — Viktor invokes without asking

For the main DB integration, the settings are:

| Tool | Setting | Reasoning |
|---|---|---|
| Upsert Row | **Off** | Write |
| Update Row | **Off** | Write |
| Insert Row | **Off** | Write |
| Delete Row | **Off** | Write |
| Batch Insert Rows | **Off** | Write |
| Remote Procedure Call | **Off** | RPC can call mutating Postgres functions |
| Proxy Post | **Off** | Raw HTTP POST — write |
| Proxy Put | **Off** | Raw HTTP PUT — write |
| Proxy Patch | **Off** | Raw HTTP PATCH — write |
| Proxy Delete | **Off** | Raw HTTP DELETE — write |
| **Select Row** | Ask for confirmation | Read — human-in-the-loop for targeted queries |
| **Count Rows** | Run automatically | Safe aggregate read |
| **Proxy Get** | Run automatically | Raw HTTP GET — read |

With 10 write-side tools Off, Viktor physically cannot invoke a mutating operation against the main DB from this integration — regardless of the underlying credentials.

### 1.2 Why this is sufficient

The tool-layer restriction is the primary control. No additional Postgres-level role or JWT-role-based restriction is needed because:

1. Viktor's tool runtime enforces the Off state — there is no bypass from a tool whose setting is Off.
2. Even if Viktor's credentials under the hood are service_role-level, the tool runtime never generates a write call.
3. The integration settings are owned by Fred (as admin in Viktor's UI). Changing a tool back to Ask/Automatic is an auditable admin action.

### 1.3 What about a dedicated read-only Postgres role?

An earlier version of this doc (2026-04-20 morning) set up a `viktor_readonly` Postgres login role with SELECT-only grants, intended for a direct PG connection. That role was **dropped the same day** when we discovered Viktor's native integration is the correct path — see [`scripts/migrations/drop_viktor_readonly_role.sql`](../scripts/migrations/drop_viktor_readonly_role.sql).

Rationale: unused credentials rot. A password that's delivered once via Slack DM and never used is a liability, not a safety net. If a future non-Viktor client ever needs read-only access (BI tool, analytics dashboard), we'll recreate the role at that time using [`scripts/migrations/create_viktor_readonly_role.sql`](../scripts/migrations/create_viktor_readonly_role.sql) as a template.

---

## 2. Yan's Sales App DB — Viktor has full access

Yan created a separate Supabase project (visible in Viktor as `yan supa new apps`). Viktor has all 13 tools enabled there, since Yan's Sales App needs to write.

Schema baseline for Yan's new project is applied via the handoff zip per [`handoff/BUILDING-NEW-APPS.md`](../handoff/unclogme-handoff/BUILDING-NEW-APPS.md) §3–§4.

When the Sales App is ready to go live, Fred + Viktor merge Yan's schema + data into the main DB. At that point a third Viktor integration can be stood up ("Main DB - Sales App Write") with narrow INSERT/UPDATE grants on the Sales-App-specific tables, while the existing read-only integration remains for reads.

---

## 3. Admin responsibilities

### 3.1 Who controls the integration settings

Owner: Fred (admin in Viktor's UI). Any change to "Off" / "Ask" / "Automatic" on a tool for either integration should be reviewed against this doc.

### 3.2 Access tab

Viktor's integration also has an **Access** tab that scopes which team members can invoke each tool. For the main DB integration, restrict to Fred + Yan only — no field staff should be able to run SQL directly against production.

### 3.3 Audit trail

Viktor logs every tool invocation (visible under Usage in the UI). Review monthly for anomalies — especially any confirmation-required invocations that were approved.

### 3.4 When a tool is added

If Viktor adds a new Supabase tool (e.g., a future "Stored Procedure Batch Exec"), it arrives at a default state. Update the table in §1.1 and set the new tool's state intentionally.

---

## 4. Merge-time access model (future)

When Yan's Sales App schema merges into the main DB:

1. The Sales-App-specific tables get their own INSERT/UPDATE grants on the main DB (via a narrow Postgres role, not service_role).
2. Viktor's main-DB integration either:
   - Gets its tools upgraded selectively (e.g., Insert Row turned on for specific tables), or
   - A new integration "Main DB - Sales App Writes" is created with its own credentials and tool set.
3. The existing read-only integration stays in place for all other reads.

Decision to be made at merge time.

---

## Related docs

- [`handoff/unclogme-handoff/BUILDING-NEW-APPS.md`](../handoff/unclogme-handoff/BUILDING-NEW-APPS.md) — what Yan + Viktor do to set up the new Supabase project
- [`docs/security.md`](security.md) — overall credential management
- [`scripts/migrations/create_viktor_readonly_role.sql`](../scripts/migrations/create_viktor_readonly_role.sql) — PG role template (currently unused; kept as reference)
- [`scripts/migrations/drop_viktor_readonly_role.sql`](../scripts/migrations/drop_viktor_readonly_role.sql) — drop migration, applied 2026-04-20
