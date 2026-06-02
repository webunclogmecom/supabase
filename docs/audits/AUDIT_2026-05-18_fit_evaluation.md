# Fit Evaluation — Industry Best Practices vs Unclogme's Prod DB

**Date:** 2026-05-18
**Inputs:** [Prod audit](AUDIT_2026-05-18_prod_full.md) + [industry-practices research](../research/2026-05-18_postgres_warehouse_best_practices.md)

This doc takes the 15 PostgreSQL/Supabase practices from reputable engineering blogs and asks: **does each one apply to Unclogme specifically?** Not generic "best practice = good." Our shape:

- **Single-tenant** (one company, ~183 active clients, 4 trucks)
- **~360 MB total warehouse**, biggest table is 221 MB telemetry (under 1% of partman's economic threshold)
- **~1,500 webhook events/day** combined (Jobber 53/day, Airtable 167/day, Samsara when it works ~20/day)
- **~150-200 audited writes/day**
- **Supabase Pro plan** — managed PgBouncer, managed backups
- **Anon-permissive RLS** for MVP apps (Phase 2 auth not shipped)
- **Multi-app schema pattern locked in** (`customer`, `derm`, `ops`)
- **Soft-delete is Rule 6** (currently)
- **Source-agnostic schema is Rule 1**

---

## Verdict table

| # | Industry practice | Applies to us? | Our current state |
|---|---|---|---|
| 1 | Normalize 3NF first, denormalize with measured pattern | ✅ Yes — already our Rule 2 | ✓ Following |
| 2 | Trigger-based audit < 1k/s, pgaudit > 1k/s | ✅ Yes — we have BOTH layers | ✓ Already shipped (ADR 010) |
| 3 | RLS: index policy cols, wrap `auth.uid()` in `select`, target roles | 🟡 Half-applies — anon-only today, full apply when Phase 2 auth ships | ⚠ Premature optimization until Phase 2 |
| 4 | Multi-tenant: shared-schema + tenant_id + RLS | ❌ No — we're single-tenant; this is irrelevant | n/a |
| 4b | Schema-per-app for app isolation | ✅ Yes — exactly our pattern | ✓ `customer`, `derm`, `ops` |
| 5 | Hard-delete + JSONB archive beats soft-delete | ⚠ **Real debate** — conflicts with Rule 6, but our audit log already IS the archive | See deep dive below |
| 6 | Webhook idempotency: `ON CONFLICT` + Brandur atomic-phase | ✅ Yes — already Rule 5 | ✓ Following |
| 7 | Source-agnostic canonical schema | ✅ Yes — already Rule 1 | ✓ Mostly (1 grey area: `jobber_oversized_attachments`) |
| 8 | Bridge tables / per-type tables for cross-source identity | ✅ Yes — `entity_source_links` is exactly this | ✓ Already shipped |
| 9 | pg_partman + pg_cron above multi-GB; skip below ~200 GB | 🟡 Partial — too small for telemetry partitioning, BUT correct for audit.logs retention | See deep dive |
| 10 | Composite btree: equality leading, range trailing; `CREATE INDEX CONCURRENTLY` | ✅ Yes — audit didn't surface bad indexes; rule is forward guidance | ✓ FK columns all indexed |
| 11 | Forward-only, expand-then-contract migrations | ✅ Yes | ⚠ Informal — not codified as a rule |
| 12 | Transaction-mode pooler (6543) for serverless | ✅ Yes — Supabase Edge Functions need it | ✓ Default |
| 13 | Single reusable `set_updated_at` trigger | ✅ Yes — we have it, gaps on 3 tables | ⚠ Fix the 3 missing |
| 14 | Materialized views for slow-changing aggregates | 🟡 Maybe — depends on actual ops-report query times | See deep dive |
| 15 | `TIMESTAMPTZ` UTC + `NUMERIC` for money; never `TIMESTAMP` or `money` type | ✅ Yes — Rule 7 | ✓ 100% compliant |

**8 fully apply, we're following. 3 partially apply / deserve nuance. 1 doesn't apply (multi-tenant). 3 conflict or need a deep dive.**

---

## Deep dives — the three that need a real decision

### Deep dive #1 — Hard-delete + archive vs Soft-delete (Rule 6)

**The industry argument (Brandur Leach, ex-Stripe):** soft-delete poisons every query — you must remember `WHERE deleted_at IS NULL` everywhere, unique constraints get gnarly, and the table accumulates rows nobody can query cleanly. Better: hard-delete + write the row to a `deleted_records` archive table.

**Why Rule 6 exists for us:**
- Breaks `entity_source_links` (every business row has cross-source IDs that point back)
- Historical Field Portal pages reference visits/manifests by ID; gone = 404
- Customers + drivers expect to look back months
- Pre-2026-05-17, we had no audit trail — soft-delete WAS our memory

**Does the industry argument apply now?** Now that ADR 010 ships `audit.logs` with full old_row JSONB on every DELETE, the brandur archive table is effectively built — every hard-delete on an audited table writes the old row to `audit.logs` automatically. So technically we COULD start hard-deleting and the audit trail would preserve the row.

**But:** `entity_source_links` and FK references still break on hard-delete. And our DELETE volume is approximately zero — we don't have a problem soft-delete is solving. Brandur's "soft-delete poisons every query" pain is real for high-DELETE-volume systems; our system effectively never deletes business data.

**Verdict:** **Keep Rule 6 as-is.** The industry argument is correct in general but doesn't apply to a system where:
1. Audit trail captures pre-delete state
2. DELETE volume is near-zero
3. Cross-source ID resolution depends on persistent rows

No change needed.

### Deep dive #2 — pg_partman for telemetry vs audit.logs

**Industry rule (Crunchy Data, Supabase docs):** don't partition tables under ~200 GB; the operational complexity outweighs the gain. Use it for high-volume time-series like events, logs, telemetry above that threshold.

**Our state:**
- `vehicle_telemetry_readings` = 221 MB / 953K rows. **Three orders of magnitude below the threshold.** Not a partition candidate.
- `audit.logs` = 184 kB / 24 rows. Microscopically small. But pg_partman is the easiest way to implement 24-month retention via partition drops.
- `webhook_events_log` = 82 MB / no retention. Getting bigger every day.

**Verdict:**
- ✅ Keep audit.logs partitioned (correct use of pg_partman for retention even at small size — partition-drop is the cleanest deletion mechanism)
- ❌ DO NOT partition telemetry (too small, no benefit)
- 🟡 **Should partition webhook_events_log** — same retention rationale as audit.logs. At 82 MB and growing, a 90-day retention via monthly partitions saves storage + keeps queries fast. **NEW P1 action.**

### Deep dive #3 — Materialized views for ops reports

**Industry rule (Postgres docs, Crunchy):** if a view aggregates over slow-changing data and is queried often, materialize it and refresh on a schedule. Especially valuable for dashboards.

**Our state:**
- `ops.*` has 8 views, some of which join `visits` × `vehicles` × `clients` × `vehicle_telemetry_readings`
- Most ops report windows are small (last 24h, last week)
- We haven't measured query times — pg_stat_statements is installed but unused

**Verdict:** **Don't materialize blindly.** Run a query-cost audit first:
```sql
SELECT calls, mean_exec_time, query
FROM pg_stat_statements
WHERE query LIKE '%ops.%'
ORDER BY total_exec_time DESC
LIMIT 20;
```
If any ops view exceeds ~200 ms mean exec time AND is called multiple times per day, materialize it with pg_cron refresh. Otherwise leave as regular views.

**New P2 action:** add a pg_stat_statements pass to the quarterly audit.

---

## The 7 wins worth defending publicly

When asked "is our DB solid?", point to these:

1. **Audit trail is best-in-class for our size.** pgaudit + trigger-based row-level + webhook_events_log — exactly the 3-layer architecture industry references recommend. Two months ahead of where most companies our size are.
2. **Source-agnostic schema (Rule 1) is correct AND rare.** Many small ops shops have `jobber_id` and `airtable_id` columns scattered. We have one polymorphic bridge (`entity_source_links`). This is the GitLab/canonical-data-model pattern.
3. **3NF discipline matches Shopify's view-not-snapshot stance.** Views denormalize, base tables don't. Audit confirms only 1 base-table 3NF question (`notes.author_name`).
4. **FK integrity 100% across 40 FKs.** Stripe-grade discipline.
5. **Money + timestamp posture 100% compliant** with the Postgres community's "Don't Do This" wiki.
6. **Schema-per-app isolation** matches PlanetScale's multi-app pattern guidance.
7. **pg_partman + pg_cron for retention** matches Crunchy's small-DB advice (use it for the retention mechanism, even if storage doesn't demand it).

---

## Practices we should adopt that we haven't yet

| Practice | Action | Priority |
|---|---|---|
| **`webhook_events_log` retention via pg_partman** | Same migration shape as audit.logs (monthly partitions, 90-day retention via pg_cron) | P1 |
| **Codify expand-then-contract migration discipline** | Add a section to CLAUDE.md formalizing what we already do informally (never mix DDL and DML, always backwards-compatible, contract migrations come 1+ release later) | P2 |
| **Quarterly pg_stat_statements review** for slow queries | Add to the audit cadence; informs materialized-view decisions | P2 |
| **Consolidate to one `set_updated_at` trigger function** | Verify all triggers point to a single function (likely already do); document for future migrations | P3 |

---

## Practices we should explicitly NOT adopt

| Industry practice | Why we skip |
|---|---|
| **Multi-tenant shared-schema + tenant_id + RLS** | We have one tenant. Adding tenant_id everywhere is pure overhead for us. |
| **Hard-delete + JSONB archive (vs soft-delete)** | Audit.logs already provides the archive; cross-source FK integrity demands soft-delete. Brandur's argument doesn't fit a near-zero-DELETE-volume system. |
| **Partition `vehicle_telemetry_readings`** | 221 MB is 3 orders of magnitude below the threshold. Operational complexity > benefit. |
| **Materialize every ops view** | Wait for measured slow queries. Premature materialization is its own debt. |
| **Index every column** | We already have FK coverage; pg_stat_user_tables shows no real seq-scan pain (the two flagged tables are tiny). Index bloat is real. |

---

## The synthesis — what the audit + fit-evaluation actually say

**Foundation rating:** ✅ **Strong.** 8 of 15 industry practices fully adopted, 3 partially. The non-adoptions are correct rejections, not gaps.

**Real holes to close (in priority order):**
1. 🚨 **Samsara webhook ingestion broken** — incident-level, look at it tomorrow
2. ⚠ **`webhook_events_log` needs partman retention** — same pattern as audit.logs, ~50-line migration
3. ⚠ **`vehicle_id` 47% NULL on visits** — fleet-attribution gap; investigate sync logic
4. ⚠ **3 tables missing `updated_at` trigger** (`client_contacts`, `sync_cursors`, `webhook_tokens`) — short migration
5. ⚠ **`client_groups` + `visit_recommendations` RLS-but-no-policies** — confirm intentional or fix
6. 🟡 **`disposal_facility_id` 100% NULL on derm_manifests** — DERM Tracker is shipping to fix this
7. 🟡 **`notes.author_name` 3NF check** — likely derivable from author_id
8. 🟡 **`jobber_oversized_attachments` Rule 1 question** — rename for purity, or formally document the exception
9. 🟢 **Quarterly pg_stat_statements review** — add to cadence

**Above all:** the underlying foundation is solid. The audit didn't surface architectural problems — it surfaced operational issues (Samsara broken) and small adoption gaps (retention, 3 missing triggers). The architecture itself, cross-checked against Stripe / Shopify / GitLab / Supabase / Crunchy / pganalyze / Heroku / Brandur Leach, holds up.

---

## File references

- [Prod audit findings](AUDIT_2026-05-18_prod_full.md)
- [Industry best practices research](../research/2026-05-18_postgres_warehouse_best_practices.md)
- [Raw audit JSON](prod_full_audit_2026-05-18_raw.json)
- [ADR 010 — Audit trail](../decisions/010-audit-trail.md)
- [Supabase CLAUDE.md — 8 rules](../../CLAUDE.md)
