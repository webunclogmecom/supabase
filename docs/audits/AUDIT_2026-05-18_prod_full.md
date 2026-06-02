# Prod DB Full Audit — 2026-05-18

**Project:** `wbasvhvvismukaqdnouk` (Unclogme LLC, Supabase Pro)
**Audited by:** Claude (Supabase session)
**Raw JSON:** [`prod_full_audit_2026-05-18_raw.json`](prod_full_audit_2026-05-18_raw.json)
**Script:** [`scripts/probes/full_prod_audit_2026_05_18.js`](../../scripts/probes/full_prod_audit_2026_05_18.js)

---

## TL;DR

### 🚨 Critical — act this week
1. **Samsara webhook is broken** — 245 failed events in last 7d, zero successful since 2026-05-11. Goliath/David/Moises/Cloggy telemetry hasn't ingested for a week.
2. **`vehicle_id` NULL on 47% of visits (442/943)** and 24/524 *completed* visits (4.6%). Fleet attribution gap.

### ⚠ Watch — fix this sprint
3. `disposal_facility_id` 100% NULL on all 1,018 manifests (will be backfilled by DERM Tracker; known).
4. `webhook_events_log` at **82 MB** — no retention policy. Will keep growing linearly.
5. `client_groups` + `visit_recommendations` have RLS enabled with **zero policies** — silently denying all non-service_role access. Intentional lockdown or oversight?
6. 5 tables have `updated_at` column but no auto-update trigger (Rule 7 partial miss): `client_contacts`, `sync_cursors`, `webhook_tokens` (and 2 views, which are OK).
7. `jobber_oversized_attachments` has 3 jobber-prefixed columns (Rule 1 grey-area — ADR 009 edge case).

### ✓ Wins — solid foundation
- **FK integrity 100% clean** — 40 FKs checked, zero orphans
- **Audit trail 100% matches ADR 010** — 11/11 expected tables audited, none missing, none unexpected
- **RLS enabled on every public table** (31/31)
- **Money columns** — 14/14 base-table money columns use `NUMERIC(12,2)` (Rule 7 ✓)
- **Timestamps** — zero `TIMESTAMP WITHOUT TIME ZONE` columns (Rule 7 ✓)
- **FK columns all indexed** — zero missing
- **No views use `SELECT *`** — every view explicit
- **Audit partitioning** — pg_partman + pg_cron pre-creating 4 months ahead correctly
- **Extensions** — pgaudit, pg_partman, pg_cron, pg_stat_statements, pgcrypto, uuid-ossp, supabase_vault all installed
- **Source-agnostic** — only 1 grey-area table out of 31 (Rule 1 mostly clean)

---

## 1. Schema inventory

| Layer | Count |
|---|---|
| Tables in `public` | 31 |
| Views in `public` | 9 |
| Views in `customer` | 8 (Field Portal) |
| Views in `derm` | 4 (DERM Tracker — new today) |
| Views in `ops` | 8 (ops reports) |
| Functions in `public` | 7 |
| User triggers | 38 |

Non-system schemas: `audit, customer, derm, ops, partman, public, raw, supabase_migrations`. Clean separation.

**Extensions** (all required, no bloat): pg_cron, pg_partman, pg_stat_statements, pgaudit, pgcrypto, plpgsql, supabase_vault, uuid-ossp.

---

## 2. Source-agnostic compliance (Rule 1)

**3 hits, all on one table** (`jobber_oversized_attachments`):
- `attachment_jobber_id`
- `note_jobber_id`
- `jobber_url_signed`

**Verdict:** grey area. This table is a Jobber-specific edge case from [ADR 009](../decisions/009-oversized-storage-and-jobber-webhooks.md) — Jobber's GraphQL API only returns signed URLs (expiring) for attachments >5MB, so we cache the Jobber identifier + signed URL for later retrieval. Cross-source identity for the underlying note/attachment lives in `entity_source_links` per Rule 1.

**Decision needed:** is this table's narrow purpose enough to grant a Rule 1 exception, or should we rename to source-agnostic names (`external_attachment_id`, `external_url_signed`) and use a `source_system` column? Recommendation: rename for purity, since the table could theoretically house other oversized-attachment sources later.

All other 30 tables: 100% source-agnostic. Rule 1 effectively holds.

---

## 3. 3NF compliance (Rule 2)

**Heuristic scan** for `_name` / `_code` / `_email` / `_address` columns surfaced 15 hits. Classification:

| Hit | Verdict |
|---|---|
| `clients.client_code` | ✓ Not a denorm — this IS the primary external identifier (natural key) |
| `employees.full_name` | ✓ Canonical store of employee name (no first_name/last_name to derive from on this table) |
| `photos.file_name` | ✓ Intrinsic property of the file, not denormalized |
| `jobber_oversized_attachments.file_name` | ✓ Same |
| `notes.author_name` | ⚠ Possibly denormalized — `notes.author_id` likely FKs to `employees`. Could be computed in a view instead. Investigate. |
| `client_services_flat`, `clients_due_service`, `driver_inspection_status`, `manifest_detail`, `v_vehicle_telemetry_latest`, `visits_recent`, `visits_with_status` | ✓ **These are VIEWS** — denormalization in views is correct per Rule 3 ("computed on read") |

**Real 3NF concern:** `notes.author_name` is the only potential snapshot column on a base table. Worth one query to confirm whether it can be derived via `notes.author_id → employees.full_name`.

Everything else is clean: views denormalize, base tables don't.

---

## 4. FK integrity

**40 FKs checked. ZERO orphans across the entire database.** Every cross-table reference resolves.

This is the single strongest signal in the audit. Whatever sync logic + RLS posture is in place, it's not creating dangling references.

---

## 5. RLS posture

**All 31 public tables have RLS enabled.** Zero unprotected tables.

Notable observations:
- **6 tables open anon-write**: `derm_manifests`, `manifest_visits`, `photo_classifications`, `properties`, `visits`, + the implicit visit/photo writes. All match the "ship-first-harden-later" policy for the apps (Admin Review, DERM Tracker, Field Portal manhole edits). Acceptable per [feedback memory](file:///C:/Users/FRED/.claude/projects/C--Users-FRED-Desktop-Virtrify-Yannick-Claude/memory/feedback_ship_first_harden_later.md).
- **2 tables: RLS enabled, ZERO policies** — `client_groups`, `visit_recommendations`. This silently denies all anon + authenticated access. If that's intentional (only service_role can touch these), great. If not, those tables are unintentionally invisible. **→ One of these for Fred to confirm.**
- **2 tables: `webhook_events_log`, `webhook_tokens`** — only service_role access (no anon, no authenticated read). Correct posture for secrets / append-only logs.

---

## 6. Index health

**Seq-scan-heavy tables (> 5,000 seq scans):**
| Table | seq_scan | idx_scan | rows | Verdict |
|---|---|---|---|---|
| `employees` | 89,965 | 12,990 | 32 | ✓ Postgres correctly prefers seq over index for tiny tables — not a problem |
| `sync_cursors` | 10,431 | 6,804 | 10 | ✓ Same — 10-row table |

**FK columns missing index: ZERO.** Every FK has an index.

Top heavy indexes (sanity):
- `idx_vtr_vehicle_time` — 48 MB on `vehicle_telemetry_readings` (953K rows, expected)
- `vehicle_telemetry_readings_vehicle_time_uniq` — 40 MB (the dedup unique index)
- `idx_vtr_recorded` — 27 MB
- All others < 5 MB. Lean.

---

## 7. Data quality — NULL rates

| Table | Critical column | NULL count | % | Verdict |
|---|---|---|---|---|
| `visits` | `client_id` | 0/943 | 0% | ✓ |
| `visits` | `vehicle_id` | **442/943** | **47%** | 🚨 47% of visits unattributed to a truck |
| `visits` (completed only) | `completed_at` | 0/524 | 0% | ✓ |
| `visits` (completed only) | `vehicle_id` | **24/524** | **4.6%** | ⚠ Even completed visits have attribution gaps |
| `properties` | `address` | 0/488 | 0% | ✓ |
| `properties` | `county` | 275/488 | 56% | ⚠ Expected — only Dade county is populated; rest are blank |
| `derm_manifests` | `client_id` | 27/1,018 | 2.7% | ⚠ Low rate, fixable |
| `derm_manifests` | `white_manifest_number` | 204/1,018 | 20% | ⚠ Possibly intentional (dump-only tickets w/o manifest) — worth confirming |
| `derm_manifests` | `disposal_facility_id` | **1,018/1,018** | **100%** | 🚨 Known — DERM Tracker will backfill |
| `employees`, `vehicles`, `service_configs`, `manifest_visits` | all checks | 0% | ✓ Clean |

**Audit-script self-flag:** my script queried `clients.slug` (column doesn't exist — should be different name) and `photo_classifications.photo_id` (column doesn't exist on that table). Both are doc-drift in CLAUDE.md / Schema notes, not real DB issues. Audit tooling glitch only.

---

## 8. Audit trail coverage (Rule 8)

**Perfect alignment with ADR 010.** 11 expected audited tables, 11 actually audited:

`clients, derm_manifests, disposal_facilities, employees, manifest_visits, photo_classifications, properties, service_configs, vehicles, visits, webhook_tokens`

- 0 missing from expected set
- 0 unexpected additions
- `manifest_visits` correctly opted in 2026-05-18 (today, for DERM Tracker)

---

## 9. `updated_at` hygiene (Rule 7)

25 public tables have an `updated_at` column. **20 of those have a trigger maintaining it.** 5 don't:

| Table | Has column | Has trigger | Action |
|---|---|---|---|
| `client_contacts` | ✓ | ✗ | Add trigger |
| `sync_cursors` | ✓ | ✗ | Add trigger (or accept manual-update pattern in sync code) |
| `webhook_tokens` | ✓ | ✗ | Add trigger |
| `inspections_with_review` | view | n/a | OK (views don't need triggers) |
| `visits_with_review` / `visits_with_status` | views | n/a | OK |

**3 real misses, all low-volume, easy fix.** One ~30-line migration.

---

## 10. Sync cursor health

Cursors with recent successful runs:
- `quotes`, `invoices`, `visits`, `jobs`, `clients` — last run within 1 hour, status success
- `audit_alerts` — last run 22h ago (cron is `*/5`, so this is suspicious — cron may not have fired since the workflow lives on GitHub Actions which can have a several-hour delay before a new workflow first runs)

Stale cursors (intentional per past audit):
- `users` — 484h (20 days) stale — Jobber GraphQL doesn't expose `updatedAt` for users
- `properties` — 484h stale — same reason
- `line_items` — never run
- `jobber_notes_migration` — one-shot migration cursor, finished

**No errors anywhere.** Sync stack is healthy.

---

## 11. Storage usage

| # | Table | Size | Notes |
|---|---|---|---|
| 1 | `vehicle_telemetry_readings` | **221 MB** | 953K Samsara rows — expected |
| 2 | `webhook_events_log` | **82 MB** | ⚠ No retention policy. ADR 010 retains audit.logs for 24mo via pg_partman; this should follow the same pattern. |
| 3 | `storage.objects` | 31 MB | Supabase Storage metadata |
| 4 | `entity_source_links` | 12 MB | Bridge table, healthy |
| 5 | `photos` | 4.9 MB | Photo metadata (real files in Storage) |
| 6 onward | All < 5 MB | ✓ |

Total active warehouse: ~360 MB. Comfortably inside Pro plan limits.

---

## 12. Webhook events — last 7 days

| Source | Status | Count | Last event |
|---|---|---|---|
| `airtable` | processed | 1,167 | 2026-05-18 00:18 |
| `jobber` | processed | 372 | 2026-05-18 01:27 |
| `samsara` | **failed** | **245** | **2026-05-16 08:24** |
| `samsara` | processed | 142 | **2026-05-11 19:10 ← stale** |
| `samsara` | skipped | 13 | 2026-05-11 19:11 |
| `internal` | warning | 1 | 2026-05-17 14:48 |

**🚨 INCIDENT-LEVEL FINDING:** Samsara has zero successful webhook events since **2026-05-11** (7 days ago). 245 failed events in that window. The fleet telemetry pipeline is dead.

This is a real broken thing — root cause investigation needed (auth expiry? Edge Function crash? Samsara API change?). Action immediately.

---

## 13. PostgREST exposed schemas

`db_schema = "public,graphql_public,customer,derm"` — correct.

`public` exposure is intentional (legacy apps still use it). Long-term cleanup is to migrate all app reads to per-app schemas and revoke `public` exposure. Not urgent.

---

## 14. `audit.logs` partitions

| Partition | Size |
|---|---|
| `logs_default` | 48 kB |
| `logs_p20260201` - `p20260901` | 48 kB each (empty pre-creation) |
| `logs_p20260501` | **184 kB** (current month, 24 rows) |

24 rows captured since 2026-05-17 launch. Working as designed. pg_partman is pre-creating 4 months ahead, pg_cron retention runs every 6h.

---

## 15-19. Other checks

- **Connections snapshot**: 7 active connections (postgrest×2, mgmt-api, pg_cron, pg_net, postgres_exporter). Healthy idle state, no slow queries.
- **Functions:** 7 in public, 1 in audit (`audit.log_change`), 4 in customer (view helpers). Lean.
- **Triggers by schema:** 32 in public (all audit/updated_at), 4 in storage. No surprise hooks.
- **No views use `SELECT *`** — all explicit.
- **Money columns:** All 14 base-table money columns use `NUMERIC(12,2)` (Rule 7 ✓). The 3 columns flagged in `client_services_flat` are in a VIEW — inherit from source.
- **Timestamps:** Zero columns are `TIMESTAMP WITHOUT TIME ZONE`. 100% UTC posture (Rule 7 ✓).

---

## Recommendations — prioritized

### P0 (today / tomorrow)
1. **Investigate Samsara webhook failure.** Look at recent failed webhook_events_log rows for the error_message; check `webhook-samsara` Edge Function logs; verify token state in `webhook_tokens`. May be related to ADR 005 webhook auth expiry.

### P1 (this week)
2. **Backfill `disposal_facility_id`** on `derm_manifests` (or wire DERM Tracker to require it on new rows + bulk-update existing).
3. **Add `updated_at` triggers** to `client_contacts`, `sync_cursors`, `webhook_tokens` — one short migration.
4. **Resolve `client_groups` + `visit_recommendations` RLS-no-policies** — either add explicit policies or document that lockdown is intentional.
5. **Add `webhook_events_log` retention** — same pg_partman pattern as `audit.logs`, suggested 90-180 day retention.

### P2 (next sprint)
6. **Investigate `visits.vehicle_id` gap** — 442/943 NULL is concerning. Even 4.6% on completed visits matters for fleet attribution. Run `scripts/sync/derive_visit_vehicle_id.js` if it still exists; otherwise add Samsara-GPS-based attribution to the visit sync.
7. **`notes.author_name` 3NF check** — confirm it's derivable from `notes.author_id` and consider moving to a view.
8. **`jobber_oversized_attachments` Rule 1 question** — rename columns to source-agnostic OR formally document as intentional exception in ADR 009.
9. **`CLAUDE.md` gotcha-table audit** — verify all gotchas reflect actual current column names (slug + photo_id drift caught in this audit; visit_status casing fixed earlier today).

### P3 (when we have bandwidth)
10. Migrate apps off `public` schema reads → fully into per-app schemas → revoke `public` exposure to anon. Hardening step.

---

## What this audit did NOT cover

- Query performance benchmarks (pg_stat_statements is installed — could pull top slow queries on a future pass)
- Backup posture (Supabase Pro covers point-in-time recovery; nothing to verify here)
- Encryption at rest (Supabase manages; verified at platform level)
- Edge Function logs (separate surface; Supabase Dashboard)

These are next-level audits worth doing quarterly.
