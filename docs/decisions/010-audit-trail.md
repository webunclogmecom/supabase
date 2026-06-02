# ADR 010 — Audit Trail Architecture

**Status:** Accepted (2026-05-17)
**Decider:** Fred Zerpa
**Implemented:** 2026-05-17 via migrations `2026-05-17a` through `2026-05-17e`

## Context

By May 2026 the canonical Prod DB hosts:
- Customer-visible data (Field Portal compliance documents, visit history, photos)
- Regulatory data (DERM manifests, disposal facilities, white manifest numbers)
- Billing-adjacent data (`service_configs.price_per_visit`, `frequency_days`)
- Security-sensitive data (`webhook_tokens.access_token`, `client_secret`)

With multiple writers — Jobber webhooks, Airtable webhooks, Samsara webhooks, Admin Review (anon-permissive RLS), background sync cron jobs, manual SQL via Management API — and **zero audit trail**, we have no answer to:

- *"When did this manhole count change?"*
- *"Who reclassified this photo to internal yesterday?"*
- *"Was the DERM manifest #821472 modified after it was filed?"*
- *"Why is `webhook_tokens.access_token` different from this morning?"*
- *"What did the visit row look like before AT sync overwrote it?"*

Pre-Phase-2 auth (anon writes) we can't capture *who*, but we can capture *when*, *what changed*, and *what role made the change* — and the column will start populating *who* automatically when auth ships, without a re-migration.

## Decision

Implement a **three-layer audit trail** on Prod:

### Layer 1 — pgaudit extension (system-level)

Captures statement-level activity that triggers can't see: DDL (CREATE/ALTER/DROP), role/permission grants, function executions, bulk writes. Output goes to Supabase Logs.

Configured at the **role level** (Supabase recommendation):
- `authenticator`: `ddl, role, function, write`
- `service_role`: `ddl, role, function, write, misc`
- `postgres`: `ddl, role`
- `anon`: **not logged** (would flood logs with Field Portal customer reads)

`pgaudit.log_catalog=off` (no catalog query noise). `pgaudit.log_relation=on` (capture table names for context). `log_parameter` left at platform default (off, secure).

### Layer 2 — `audit.logs` (row-level triggers, structured)

Custom trigger-based audit log, queryable as a table. Schema separation:

```
audit
├── logs (PARTITION BY RANGE (changed_at))
│   ├── logs_p2026_05  (monthly partitions, managed by pg_partman)
│   ├── logs_p2026_06
│   └── ...
└── log_change()  (SECURITY DEFINER trigger function)
```

Schema:
- `id BIGINT GENERATED ALWAYS AS IDENTITY`
- `table_schema TEXT`, `table_name TEXT`
- `record_pk JSONB` — handles composite primary keys
- `operation TEXT CHECK (INSERT/UPDATE/DELETE)`
- `old_row JSONB`, `new_row JSONB` — full row state minus `updated_at` (auto-managed, noise)
- `changed_by UUID` — `auth.uid()`, NULL when anon (activates automatically when Phase 2 auth ships)
- `db_role TEXT` — `CURRENT_USER` (anon/authenticator/service_role/postgres)
- `jwt_claims JSONB` — `request.jwt.claims` for PostgREST context
- `changed_at TIMESTAMPTZ DEFAULT now()`

Trigger function (`audit.log_change`) is `SECURITY DEFINER` with `SET search_path = ''` (Supabase security mandate). It skips no-op UPDATEs (where only `updated_at` differs) to avoid Jobber-sync churn noise.

RLS:
- `authenticated`: SELECT all (Phase 2 admin UI will read here)
- `service_role`: bypass (default Supabase behavior; needed for retention cron)
- `anon`: NO access
- **No UPDATE or DELETE policies** — append-only by design

Retention: **24 months** via `pg_partman` monthly partitions + automatic drop. Maintenance runs every 6h via `pg_cron`.

### Layer 3 — `webhook_events_log` (already existed)

Captures external-source provenance (Jobber, Airtable, Samsara webhook payloads). No change — acknowledged as part of the audit picture.

## Tables audited (Layer 2)

| Table | Rationale |
|---|---|
| `clients` | Slug + status changes break Field Portal QR access; legal-name changes billing-relevant |
| `service_configs` | Billing-adjacent (price + frequency) |
| `properties` | Manhole defaults, access notes, address (Field Portal display) |
| `visits` | `manhole_count`, `visit_status`, `completed_at` (Admin Review writes) |
| `photo_classifications` | Customer-visibility decisions; Admin Review's primary surface |
| `derm_manifests` | DERM regulatory data |
| `manifest_visits` | Human link/unlink via DERM Tracker (opted in 2026-05-18) |
| `disposal_facilities` | Regulatory reference (2 rows, but tracked) |
| `vehicles` | DERM filings; fleet compliance |
| `employees` | Payroll-adjacent |
| `webhook_tokens` | OAuth secrets — every change is security-sensitive |

## Tables NOT audited (explicit exclusions)

| Table | Why |
|---|---|
| `webhook_events_log` | IS the audit log for inbound webhooks (recursion + storage explosion) |
| `entity_source_links` | High-volume mechanical bridge; sync changes, no human edits |
| ~~`manifest_visits`~~ | **Moved to audited set 2026-05-18** via migration `2026-05-18a_derm_schema_and_anon_writes.sql`. DERM Tracker introduces human link/unlink writes; per Rule 8 opt-in. The original "AT-sync-only, derivable" rationale no longer applies. |
| `vehicle_telemetry_readings` | 953K rows / 221 MB; pure Samsara, no human edits |
| `photos`, `photo_links` | Append-only from `jobber_notes_photos.js` |
| `invoices`, `line_items`, `quotes`, `jobs`, `notes` | Jobber-sourced, append-only |
| `inspections`, `inspection_items` | Airtable PRE-POST sync, append-only |
| `visit_assignments` | Jobber webhook, low forensic value |
| `sync_log`, `sync_cursors` | Operational metadata |
| **Sales App Supabase project** (`qyvagxgaggzqyivqfbrj`) | Separate project entirely. `audit.logs` exists only on Prod (`wbasvhvvismukaqdnouk`). Sales App writes never reach this audit trail. If Sales App ever needs its own audit, deploy the same 3-layer setup there (it's a Free-plan project, so partition-storage budget matters). |

## Trade-offs considered

- **`supa_audit` package** — Supabase's open-source generic audit package. **Rejected**: archived as of Feb 2025, no longer maintained. Wrote our own with the same design ideas.
- **pgaudit only (no triggers)** — covers DDL but loses row-level before/after on business data. **Rejected**: too coarse for forensics on a `photo_classifications` reclassification.
- **Triggers only (no pgaudit)** — misses DDL, GRANT/REVOKE, service-role bulk operations. **Rejected**: insufficient for SOC2-grade tracking.
- **Selective columns (only changed columns logged)** — saves marginal disk. **Rejected**: complexity > savings at our scale (~240 MB over 24 months projected).
- **Audit `manifest_visits`** — initially proposed. **Rejected**: high churn, mechanical, derivable from `derm_manifests`.
- **12-month retention** — SOC2 floor. **Rejected**: too short for the "what did this look like 18 months ago?" scenario. Settled on 24 months.

## Consequences

- Storage growth: ~240 MB / 24 months on Prod (negligible vs `vehicle_telemetry_readings` at 221 MB).
- pgaudit log volume: bounded by role-scoping + no `read` class.
- Write overhead: trigger adds microseconds to each audited write. Invisible at our volume (~150-200 audited rows/day).
- New rule of standing (see CLAUDE.md rule 8): every new business table must explicitly opt-in or out of `audit.logs` triggers at migration time.

## Migrations

- `2026-05-17a_audit_schema_layer2.sql` — schema, table, function, partitioning, cron, RLS
- `2026-05-17a_audit_function_patch.sql` — fixes for `ANY`, `NULLIF`, `CURRENT_USER` keyword qualification
- `2026-05-17b_audit_triggers_business.sql` — clients, service_configs, properties, visits
- `2026-05-17c_audit_triggers_compliance.sql` — photo_classifications, derm_manifests, disposal_facilities
- `2026-05-17d_audit_triggers_sensitive.sql` — vehicles, employees, webhook_tokens
- `2026-05-17e_enable_pgaudit.sql` — Layer 1 extension + role config

## Smoke test (2026-05-17)

Verified end-to-end:
- UPDATE `photo_classifications.service_phase` `internal → after` → audit row captured with old/new
- Revert `after → internal` → 2nd audit row captured
- No-op UPDATE (same value) → no audit row (correctly skipped via IS DISTINCT FROM filter)
- `record_pk JSONB`, `db_role = 'postgres'`, `changed_at` UTC populated correctly

## Tier 1 critical alerts (2026-05-17)

The raw audit log is useful for forensics but doesn't notify anyone. Layered on top: a thin polling job emits Slack alerts for the four conditions that warrant immediate human attention.

- **Script:** `scripts/alerts/audit_critical_poll.js`
- **Workflow:** `.github/workflows/audit-critical-poll.yml` (`*/5 * * * *`)
- **Channel:** `#viktor-supabase` (`C0B08S21HHD`), no @-tags
- **State:** `public.sync_cursors` row `entity='audit_alerts'`, advanced per run; first run seeds to `now() - 5 min`
- **Window buffer:** trailing 15s, so late commits aren't missed

### Conditions

| # | Condition | SQL filter |
|---|---|---|
| 1 | `webhook_tokens` modified by non-`service_role` | `table_name = 'webhook_tokens' AND db_role <> 'service_role'` |
| 2 | Hard DELETE on `clients` / `derm_manifests` / `service_configs` | `operation = 'DELETE' AND table_name IN (…)` |
| 3 | Mass-change spike: > 200 audit events / minute | `COUNT(*) > 200 GROUP BY date_trunc('minute', changed_at)` |
| 4 | Anon write outside the allow-list | `db_role='anon' AND (table,operation) NOT IN ALLOW_LIST` |

**Anon allow-list** (whitelist of legitimate anon writes from the Field Portal Lovable app):

- `photo_classifications:INSERT`
- `photo_classifications:UPDATE`
- `visits:UPDATE`
- `properties:UPDATE`

When granting anon write access to a new surface (new RLS policy on a public table), update `ANON_ALLOWED` in `audit_critical_poll.js` in the same migration cycle. Otherwise the first legitimate write will fire a false alarm.

### Explicitly NOT included (Tier 2/3/4 rejected)

- Daily summary digest of all audit writes — not enough signal/noise to justify
- Per-app `audit_history` views (`review.audit_history`, `derm.audit_history`) — wait until a UI is asking for it
- Weekly compliance roll-up — DERM filings already covered by ops process

If forensic queries get common, add a `audit.recent_changes` view directly on `audit.logs`. Don't pre-build per-app views.

### Tampering on `audit.logs` itself

The trigger function's recursion guard (`IF TG_TABLE_SCHEMA = 'audit' THEN RETURN`) means installing a trigger on `audit.logs` wouldn't self-log. Tampering detection therefore relies on **Layer 1 (pgaudit)** — DDL + write events on the `audit` schema land in Supabase Postgres Logs. Future enhancement: a Logflare-driven Slack alert on `pgaudit` events targeting `audit.*`.

## References

- [Postgres Audit Logging Guide — Bytebase](https://www.bytebase.com/blog/postgres-audit-logging/)
- [pganalyze E8: pgAudit vs supa_audit](https://pganalyze.com/blog/5mins-postgres-auditing-pgaudit-supabase-supa-audit)
- [PGAudit on Supabase](https://supabase.com/docs/guides/database/extensions/pgaudit)
- [supa_audit (archived)](https://github.com/supabase/supa_audit)
- [SOC 2 Data Retention Guide — Konfirmity](https://www.konfirmity.com/blog/soc-2-data-retention-guide)
