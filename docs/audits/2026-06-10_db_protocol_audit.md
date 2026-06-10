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

## Batch B1 — APPLIED 2026-06-10 ✅ (`docs/migrations/2026-06-10b_batch_b1_checks_identity_cleanup.sql`)
Gated on the read-only pre-flight (workflow `wf_6e9ebcbe-82c`); Fred approved app_* drop,
identity conversion, and zone repoint+drop.
1. **CHECKs on the Jobber-synced statuses** — pinned to the LIVE-INTROSPECTED GraphQL
   enums (version 2026-04-16; natively lowercase) **plus** the local softStatusFlip
   values (`closed`/`destroyed`): jobs (12 values), invoices (7), quotes (7). Plus
   `clients.status` (4) and `visits.visit_status` (`scheduled/completed/cancelled`).
   Pre-req fixes shipped same cycle: webhook-jobber `'canceled'`→`'cancelled'`
   (never-fired path, deployed) + populate.js status normalization.
2. **All 18 serial-style PKs → `generated always as identity`** (scan found no active
   explicit-id writer; sandbox refresh is COPY; FP loaders already OVERRIDING).
   Stale Sandbox one-off `backfill_sandbox_photos.js` archived.
3. **Dropped `client_locations.contact_*`** (0/407, zero refs).
4. **gdos client/location consistency trigger** (guards `client_id` vs
   `client_location_id` drift until the 59-GDO backfill allows dropping client_id).
5. **Dropped legacy `app_visit_reviews`/`app_shift_reviews`** (0 rows; Sandbox keeps the
   real rollback copies) — and in doing so **found + fixed a latent bug**: the
   `inspections_with_review` view still read the EMPTY legacy table, so shift review
   statuses always showed 'pending'; repointed to canonical `shift_reviews` →
   5 reviewed shifts immediately visible.

**Post-apply verification:** 5 CHECKs live; 0 serial PKs left; forced live poll cycle
pushed all 5 entity types through the redeployed webhook into the constrained,
identity-PK tables — 0 failures, 0 webhook errors.

## Still deferred (Batch B2)
| Item | Why |
|---|---|
| Drop `properties.zone` + `visits.duration_minutes` | Approved + GO, but real surgery: repoint 12 zone views (`z.code AS zone` via `zone_id`; 2 dual-alias views need 2 joins) + keep `duration_minutes` output in 5 views (`NULL::integer` — Admin Review selects it), drop 2 sync triggers (`properties_sync_zone_columns_trg`, `zones_cascade_code_rename_trg`), rewrite webhook-airtable:219 to resolve `zone_id` + deploy, update populate.js zone/duration writes + `backfill_properties_from_at.js`, then drop the columns. Full recipe in pre-flight `wf_6e9ebcbe-82c` (drop-dependencies dimension). |
| Drop `gdos.client_id` | Still blocked on the 59-GDO `client_location_id` backfill (drift now guarded by trigger) |
| Relocate `public.jobber_oversized_attachments` → raw/ops | One-off migration artifact; defer-acceptable, recorded exception |
| `properties.access_days` text[] | Fine as-is unless per-day attributes are ever needed |

Full per-dimension findings + SQL evidence: workflow run `wf_1353f00d-36b` (6 agents).
