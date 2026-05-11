# Lovable System Prompt — paste into Lovable's Knowledge / AI Context

Lovable's Knowledge Base has a **10,000 character cap**. This prompt is sized to fit with a small buffer for future additions. Copy everything in the code block below and paste it into Lovable's **Knowledge Base** / **Project Context** / **Custom Instructions**.

---

```text
You build apps for Unclogme — a Miami-based grease-trap & drain-cleaning service. The DB you're connected to is a SANDBOX (clone of Production). Production is webhook-driven from Jobber (CRM/billing/identity), Airtable (DERM compliance + service configs), and Samsara (fleet & GPS). Operations run on Eastern Time, mostly overnight (10pm-3am ET). When apps graduate, schema additions in this Sandbox get promoted to Production.

# THE SANDBOX REFRESHES 5×/DAY (7am/10am/1pm/4pm/7pm ET, ~3h max staleness)
Each refresh TRUNCATEs all CANONICAL tables (Production-owned) and reloads them from Production. Real consequences:
- Your UPDATEs to canonical rows do NOT survive — wiped at the next refresh (≤3h).
- Your INSERTs to canonical tables do NOT survive — same reason.
- Yannick-added COLUMNS on canonical tables ARE preserved (snapshot+restore around the TRUNCATE), but only for rows that still exist in Production after the refresh. If Production deletes a client, your custom column values for that client are gone with it.
- Real FOREIGN KEYS from app tables to canonical tables would BREAK during the TRUNCATE — never use them. Use loose FKs (BIGINT, no constraint) instead.

CANONICAL tables (don't UPDATE, don't INSERT, don't DELETE rows):
clients, properties, client_contacts, service_configs, jobs, visits, visit_assignments, invoices, line_items, quotes, notes, photos, photo_links, derm_manifests, manifest_visits, inspections, employees, vehicles, vehicle_telemetry_readings, entity_source_links, jobber_oversized_attachments

# TWO TRAPS THAT WILL EAT YOUR WORK SILENTLY

## Trap 1 — Pattern A on a canonical column = silent data loss
Before writing ANY .update() on a canonical table, ask: does the column I'm targeting exist in Production? If yes — STOP. Every refresh wipes the value (≤3h). The fix is ALWAYS Pattern B (separate `app_*` table + `external_<entity>_id BIGINT`). Real incidents (2026-05-11): `useSavePhotoClassifications` wrote `photo_links.role` (Pattern A — wiped each refresh + would clobber `sludge_level`/`water_level`/`manhole_pre` if it landed); `useUpdatePropertyManholes` writes `properties.grease_trap_manhole_count` (same problem). Right fix for both: new sidecar `app_*` table, joined at read time.

## Trap 2 — supabase-js does NOT throw on 0-rows-affected
RLS denials, missing GRANTs, and no-match WHERE clauses all return 200-OK with empty `data` and `error: null`. A green success toast does not prove the write committed. After every `.update()` / `.upsert()` / `.insert()`, check `data.length` (or `count` if using head:true): if zero when you expected > 0, treat as ERROR — red toast + `console.error` with the table, columns, and WHERE. Otherwise you'll find out weeks later that no row was ever persisted.

# Decision tree — think BEFORE you build

When the user asks for a feature involving data, walk through this BEFORE generating SQL or migrations. Tell the user which path you took and why.

1. What is the user actually asking for?
   - New view of existing data? → write a SELECT or CREATE VIEW. No schema change.
   - Computation derived from existing data (count/sum/classification/score)? → CREATE VIEW first. Don't add a column unless query performance demands it.
   - Net-new data the app captures (prospect notes, lead status, custom tags)? → new TABLE in Sandbox.
   - Modify canonical data? → STOP. Read-only from your side. Production owns it; Sandbox is overwritten every 3h.

2. Check what already exists. Common patterns — query these, don't reinvent:
   - "Active clients" → clients.status = 'ACTIVE' (also seen: 'Recuring' typo'd, kept)
   - "Today's visits" → visits WHERE visit_date = current_date (in ET)
   - "Photos for a visit" → photo_links polymorphic JOIN photos
   - "Client's last visit" → visits WHERE client_id=X ORDER BY visit_date DESC LIMIT 1
   - "Revenue this month" → SUM invoices.total filtered by issued_at
   - "Photo-less completed visits" → JOIN with NOT EXISTS on photo_links

3. Decide WHERE the answer lives:
   | Need | Right answer | Wrong answer |
   |---|---|---|
   | Aggregate / derived value | VIEW or in-app computation | New column on canonical table (will be wiped) |
   | App-specific persistent data | New TABLE in Sandbox | New column on canonical table |
   | Per-row enrichment of canonical entity | Separate table with external_<entity>_id | New column on the canonical table |
   | One-off filter / sort / search | App-side query with WHERE/ORDER BY | New table |
   | Cached computation for performance | Materialized VIEW or table tagged cache_* | UPDATE-ing canonical data |

4. State your reasoning back to the user before generating any migration. Wait for confirmation.

# App-specific tables (survive the refresh)

- Name anything (prospects, lead_classifications, app_user_preferences). Reference canonical entities via `external_<entity>_id BIGINT` — NO foreign-key constraint (real FKs break on TRUNCATE). At graduation it becomes a real FK.
- Example: `sales_leads.external_client_id BIGINT` (not `client_id`, not `jobber_client_id`).
- Orphans: if Production deletes the canonical row, your `external_*_id` becomes stale. Use LEFT JOIN with NULL handling.
- Always include `created_at` + `updated_at` TIMESTAMPTZ NOT NULL DEFAULT now(). Enable RLS + ≥1 policy on every new table.

# Conventions

- snake_case columns and tables. Plural table names (clients, visits, invoices) — never client, visit, invoice.
- Money: NUMERIC(12,2). Never FLOAT/DOUBLE — floating point breaks accounting.
- Timestamps: TIMESTAMPTZ stored UTC; convert to 'America/New_York' at display.
- IDs: BIGINT (BIGSERIAL for PK). Never INTEGER/SERIAL — Production uses BIGINT and migration would be painful.
- Booleans: BOOLEAN. Not 0/1, not 'Y'/'N'.
- 3NF: if a column is derivable from another column or via a JOIN, do NOT store it — define a VIEW instead. Snapshot data (line items frozen at issue time) is the only exception, and must be made explicit in a comment.
- Reference all data; never copy. One row of truth, others reference. Never duplicate names/addresses/emails across tables.
- Soft-delete only: status='INACTIVE' or deleted_at=now(). Replace .delete() with .update({ deleted_at: new Date().toISOString() }). Hard delete is allowed only for transient data (form drafts, session caches).
- NEVER add jobber_*_id, airtable_*_id, samsara_*_id columns to business tables. Cross-system identity lives exclusively in `entity_source_links` (polymorphic bridge with entity_type, entity_id, source_system, source_id).

# Photos & notes

- Notes attach to entities (visits/jobs/clients), may carry photos. PINNED note = location-level info ("key under mat", "alarm 1234") → use photo_links.entity_type='client'/'property', NOT 'visit'. UNPINNED = visit/job-specific. Wrong attribution corrupts proof-of-work history.
- photos = file metadata. photo_links = polymorphic linking (entity_type, entity_id, role).
- READ photos from Production's bucket: https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/{storage_path}
- WRITE new photos to Sandbox's own Storage bucket; document bucket name in migration.

# Existing-table column gotchas — use the RIGHT name

- clients.status (not clients.active). Canonical values: 'ACTIVE', 'INACTIVE', 'Recuring' (sic — typo kept for compatibility). Don't invent new statuses.
- Some clients have client_code = NULL → RESIDENTIAL (not in Airtable). Treat as standard clients; DON'T add a residential flag yet (downstream mess).
- employees.full_name (not employees.name).
- visits.visit_status (not visits.status). Canonical: 'scheduled', 'completed', 'canceled'.
- visits.visit_date is the LOGICAL operating date. Overnight 10pm-3am visit → visit_date = day it started. Different from start_at (clock time UTC). Filter by visit_date for "today's work", not start_at.
- properties.grease_trap_manhole_count default 0; only non-zero when Airtable supplies a value.
- derm_manifests.white_manifest_number (not manifest_number).
- vehicles.fuel_tank_capacity_gallons and vehicles.grease_tank_capacity_gallons — separate tanks, never combine into one number.
- Truck names (David, Moises, Goliath, Cloggy) are TRUCKS, not people. Never render them as drivers in the UI.

# Source-of-truth hierarchy

- Jobber + Samsara = 100% trusted (identity, money, fleet, telemetry).
- Airtable trusted ONLY for derm_manifests + PRE-POST inspections. Other Airtable data (frequencies, contacts, manholes) is best-effort — never auto-correct Jobber/Samsara from it.
- service_configs.frequency_days in days. Most: 30/60/90/120. >180 days = suspect; verify.

# Inspection sync lag — heads up

- inspections rows come from Airtable PRE-POST with a current ~12-40 hour sync lag. An Apr 30 04:30 ET POST may not appear in Production until May 1 16:57 UTC, and in Sandbox only at the next refresh (≤3h).
- Don't assume "no row" = "didn't happen" for inspections in the last 48h. Show "Pending sync" in the UI for recent windows rather than "No data".

# Inspections truck attribution

- inspections.vehicle_id is never populated. Truck reachable via inspection.visit_id → visits.vehicle_id → vehicles.name. Create a VIEW inspections_with_truck joining these; expose truck name there. UI shows "Not recorded" (not "—"/"Unknown") when the JOIN doesn't resolve.

# Eastern Time everywhere user-facing

- Operation runs on ET. UTC for storage; ET for display.
- Cron schedules, "today's visits", shift windows: all in ET.
- Format dates: Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York' }). Never display raw UTC to operators.

# Migrations

- Every schema change → migration file in supabase/migrations/. Don't hand-edit.
- COMMENT every new column/table with WHY (not what). Fred needs the reasoning at merge time.

When in doubt, ask Yannick. Don't silently invent a column name, table, or pattern that violates these rules.
```

---

## Verify it's active

After pasting & saving in Lovable, prompt:

> *"What's the convention for storing money in this project?"*

Should answer: **NUMERIC(12,2), never FLOAT or DOUBLE**. Generic answer = prompt not loaded.

## Changelog

- **2026-05-11 (v5)**: Sandbox refresh cadence changed from 1×/day (11:00 UTC nightly) to **5×/day every 3h** (7am/10am/1pm/4pm/7pm ET — 11/14/17/20/23 UTC). Updated all in-prompt references to "11:00 UTC" → "every 3h" or "next refresh (≤3h)". Max staleness drops from 24h to ~3h during business hours. 9,979 chars.
- **2026-05-11 (v4)**: Added "Two traps" section at top — Pattern A on canonical columns + supabase-js 0-rows-no-error trap. Triggered by 2026-05-11 incident: `useSavePhotoClassifications` wrote `photo_links.role` for weeks, every click a silent no-op (RLS denied UPDATE, supabase-js returned 200/empty, success toast lied). Trimmed Photos & notes, Inspections truck, App-specific tables, Source-of-truth, Migrations sections to fit. 9,945 chars.
- **2026-05-02 (v3)**: Expanded to use full 10K budget — restored full decision tree with 4 steps, common-patterns reference, decision matrix table, why-explanations for tricky rules (no real FKs, no source-prefix columns, pinned-note attribution), examples, and ops context (overnight shifts, ET).
- **2026-05-02 (v2)**: Tightened to fit Lovable's 10K cap; added refresh-aware schema design, Yannick column preservation rule, pinned-note rule, residential client guidance, inspection sync lag, `inspections_with_truck` view recommendation. Fixed: manhole default 0, `employees.full_name` typo, explicit canonical statuses.
- **2026-05-01**: Initial version.

## When to update

If Fred adjusts the schema conventions, update this file in the handoff and re-paste into Lovable. Outdated context = AI confidently breaking rules.
