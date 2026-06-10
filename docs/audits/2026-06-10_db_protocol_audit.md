# 2026-06-10 — Full DB Protocol Audit (Prod canonical, `wbasvhvvismukaqdnouk`)

Six-dimension read-only audit of the `public` schema against the UnclogMe protocols
(3NF, naming, types, FK+indexes, RLS/security, schema placement + domain rules).
**Verdict: solid (B+). Zero CRITICAL findings.** Fundamentals clean; gaps were
additive hardening + two normalization items + one convention deviation.

## Confirmed clean ✅
- **Types:** 0 naked `timestamp` (136 timestamptz + 26 genuine dates), 0 text dates,
  0 float money (all 17 money cols `numeric(12,2)`), 0 varchar, all internal PK/FK bigint.
  External IDs correctly as text in `entity_source_links`.
- **3NF:** 0 stored/generated columns; no jsonb in canonical tables (only sync_log /
  webhook_events_log). Invoice/line-item totals = intentional upstream-authoritative
  Jobber snapshots, NOT derived-column violations (verified non-reconciling by design).
- **FKs:** 61 constraints, coherent ON DELETE semantics, all hot-path FKs indexed.
- **RLS/security:** 41/42 tables RLS-on; all 12 public views `security_invoker=true`;
  `webhook_tokens` fully locked (no anon/authenticated path); anon `statement_timeout=15s`;
  PII tables forced-RLS + anon SELECT-only (ship-first accepted risk).
- **Placement/domain:** schema-per-app honored (public canonical + customer/ops/derm
  views + raw staging + audit). 0 Goliath-2026 visits; no residential column; all timestamptz.

## Batch A — APPLIED 2026-06-10 ✅ (`docs/migrations/2026-06-10_batch_a_db_protocol_hardening.sql`)
1. 5 missing FK indexes: `gdos.property_id` (HIGH — 167/167 populated) + 4 review-table
   employee FKs (`shift_reviews`/`visit_reviews` × `reviewed_by`/`bonus_decided_by`).
2. Wrapped 8 policies' bare `auth.uid()` → `(select auth.uid())` (per-row re-eval perf
   anti-pattern; worst on visits/properties). All were authenticated-role; anon untouched.
3. `visit_sync_flags`: RLS enabled + anon/authenticated DML revoked (was the ONLY RLS-off
   table, with anon TRUNCATE; no app/view reads it — verified).
4. `fn_check_gdo_on_visit()`: `SET search_path = public` (was the lone SECURITY DEFINER
   function with mutable search_path; body uses unqualified public refs).
5. CHECK constraints on stable app/code-written enums: `vehicles.status`,
   `employees.status` (ACTIVE/INACTIVE), `inspections.inspection_type` (PRE/POST),
   `entity_source_links.entity_type` (13 values), `photo_links.entity_type` (4 values).

**Post-apply verification:** 0 unindexed FKs; 0 bare auth.uid() policies; vsf RLS on,
0 write grants; fn pinned; 5 checks live. **Lovable apps verified in Chrome UI:** Admin
Review (drivers/queue/bonuses ✓), Visit Calendar (71 visits + zone colors ✓), DERM
Tracker (657 visits, badges ✓), Field Portal (client page ✓). **Anon REST probe:** visits,
properties.zone, vehicles, photo_links, employees all 200-with-rows (no 200-but-empty).
**Pipeline:** 0 webhook errors; jobber_poll_pgcron green through the new CHECKs.

## Deferred — Batch B (needs decision/sequencing)
| Item | Why deferred |
|---|---|
| CHECKs on Jobber-synced statuses (`jobs.job_status`, `invoices.invoice_status`, `quotes.quote_status`, `clients.status`) | Pinning upstream-fed enums can break webhook ingestion on a new upstream value; need Jobber's documented enum sets first |
| CHECK on `visits.visit_status` | Calendar app's write vocabulary unconfirmed (cancelled? in_progress?) |
| `serial`→`generated always as identity` on 18 core tables | Protocol deviation, low risk; verify no script inserts explicit ids first |
| Drop `properties.zone` (text dup of `zones` via `zone_id`; 232/232 identical) | Read by 12 app-facing views + Visit Calendar zone colors — repoint views first keeping output column `zone` identical, THEN drop |
| Drop `gdos.client_id` (transitive via `client_location_id`; 108/108 consistent) | Blocked until the 59 unlinked GDOs get `client_location_id` (location-grain backfill) |
| Drop dead columns: `visits.duration_minutes` (0/735), `client_locations.contact_*` (0/407) | Trivial; bundle with next schema migration |
| Drop legacy `public.app_visit_reviews`/`app_shift_reviews` (0 rows) | Rollback net; retire after Admin-Review verification window — Fred sign-off |
| Relocate `public.jobber_oversized_attachments` → raw/ops | Source-prefixed naming in public; one-off migration artifact (50 rows) |
| `properties.access_days` text[] | Borderline repeating group; fine as-is unless per-day attrs needed |

Full per-dimension findings + SQL evidence: workflow run `wf_1353f00d-36b` (6 agents).
