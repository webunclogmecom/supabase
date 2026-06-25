# Activity History / Audit Trail — design spec

*2026-06-25. Status: DESIGN — awaiting Fred's review before implementation.*
*Decisions locked: app-level attribution for v1 · scope = visits + clients + derm_manifests ·
secret redaction = redact + keep trigger (Phase 0, already shipped).*

## 1. Goal

Surface a human-readable **"who changed what, and when"** history for visits (and clients +
DERM manifests), starting in the Calendar app's visit drawer and reusable across the other
apps. Build entirely on the **existing** `audit.logs` capture layer — this is an additive
**read/render layer**, not a new audit engine.

## 2. Why this shape (research-backed)

A 7-agent research sweep + live DB verification (2026-06-25) established:

- **Keep the engine.** `audit.logs` (monthly pg_partman partitions, ~22.5k rows, `audit.log_change()`
  triggers on 22 tables incl. `visits`) already records operation + full before/after JSON +
  `record_pk` + `app_source` (from Origin / `X-App-Source`) + `changed_at`. It is a superset of
  Supabase's `supa_audit` (archived 2025). temporal_tables / CDC add dependencies and still don't
  capture the actor. Validated against ADR-010.
- **Three real gaps:** (1) secret leak — `webhook_tokens` tokens were stored in plaintext
  (**fixed in Phase 0**); (2) **actor attribution** — `changed_by` is null on all rows because the
  apps query with the anon key (verified: 0/22,477 populated; only 2 generic logins; 5 of 6 crew
  have no email), so per-person names are a *prerequisite project*, not a query; (3) **no surfacing
  layer** — `audit.logs` is RLS-locked to `authenticated` with no anon grant, so a `SECURITY DEFINER`
  RPC is the only viable read path.

## 3. Scope

**In (Phase 1):** visit / client / DERM-manifest change history, surfaced via one reusable RPC;
the Calendar visit-drawer "Activity" tab is the first consumer.
**Out (later phases):** real per-person names (Phase 2), a global ops activity feed + "System"
identity + more entities (Phase 3), hash-chaining tamper-evidence (deferred), bonus/payroll
review history (excluded from v1 — sensitive; would need per-record access gating).

## 4. Architecture

### 4.1 Foundation (exists)
`audit.logs` + `audit.log_change()`. Phase 0 (shipped, `2026-06-25_audit_redact_webhook_token_secrets.sql`)
added `audit.redacted_columns` and strips secrets at capture; history purged. No further capture
changes except the `txid` addition in §4.5.

### 4.2 The read RPC — `public.get_record_history`
Single reusable function; the **only** door into audit data (raw `audit.logs` stays unreachable by anon).

```
public.get_record_history(
  p_table       text,                 -- whitelisted entity ('visits' | 'clients' | 'derm_manifests')
  p_record_id   text,                 -- REQUIRED (no open enumeration)
  p_since       timestamptz default null,
  p_hide_system boolean     default true,
  p_limit       int         default 50,
  p_cursor      jsonb        default null   -- keyset: {changed_at, id}
) returns setof <history_row>
```
`history_row` = `{ entry_id, changed_at, actor_label, actor_type, app_source, operation, changes jsonb, txn_id }`
where `operation ∈ created|updated|deleted` and `changes` = array of `{field_label, old, new}`.

Hard rules inside the function:
- `SECURITY DEFINER`, `SET search_path = ''` (like `log_change`), owner = postgres, **revoke from
  PUBLIC then GRANT EXECUTE to anon + authenticated** (anon needed — apps use the anon key).
- **Table whitelist** enforced in-body (`CASE`/lookup); anything else → raise. `webhook_tokens`
  and all non-whitelisted tables are unreachable regardless of args.
- **`p_record_id` required** — single-record history only (mitigates the public-anon-key
  enumeration risk for a 6-person internal tool; documented, signed-off).
- **Column allowlist per table** — never returns raw `old_row`/`new_row`; only the rendered diff of
  allowlisted columns.
- Diff: for UPDATE, one `changes` entry per allowlisted column where `old_row->col IS DISTINCT FROM
  new_row->col`; INSERT → `created`; a `deleted_at` null→ts transition → `deleted` (not a field diff);
  hard DELETE → `deleted`.
- **Keyset pagination** on `(changed_at desc, entry_id desc)` — never OFFSET (preserves partition
  pruning); always date-bounded.

### 4.3 Render config (data-driven, per entity)
`audit.entity_render_config(table_name, column_name, label, render_type, fk_table, fk_label_sql)`
where `render_type ∈ date | enum | fk | money | bool | text | hidden`. The RPC renders each changed
field via its config: dates → **ET**, enums → pretty (`GT`→"Grease Trap"), FK ids → friendly name
(driver/client/vehicle), money → `$`, `hidden` → skipped (noise fields like sync cursors;
`updated_at` is already stripped at capture). Seeded for visits / clients / derm_manifests; adding
an entity later = new config rows, no function change.

### 4.4 Actor model
- **v1 (now): app-level.** `actor_type = 'human'` when `app_source ∈
  (visit-calendar, field-portal, derm-tracker, admin-review)`, else `'system'`
  (`sql`/`*-cron`/`jobber-reconcile`/`send-derm-email`/null). `actor_label` = friendly
  ("Edited in Visit Calendar" / "Jobber sync" / "System"). Honest — the data cannot name a person yet.
- **Phase 2 (later): per-person.** Create individual crew Supabase Auth logins; backfill
  `employees.email`; `employees.auth_user_id uuid` FK + a `handle_new_user` link trigger; switch each
  app's data calls to thread the signed-in **session JWT** (verify both `apikey` + `Authorization`
  headers); then `changed_by` populates automatically and the RPC resolves it to a crew name. Gated on
  an authenticated-role RLS re-test across apps (their RLS is currently anon-permissive).

### 4.5 Grouping (txid)
Add `txid bigint` (+ `statement_ts timestamptz`) to `audit.logs`, captured via `txid_current()` in
`audit.log_change()`. Lets the RPC/UI collapse a multi-field save into ONE timeline entry
("Fred updated visit — date Jun 26→28, driver Mark→Grecia") and group bulk writes (e.g. the
676-visit SA backfill) into one parent row instead of inferring from near-identical timestamps.

### 4.6 Security
Secret redaction shipped (Phase 0). `audit.logs` stays out of PostgREST's exposed schemas and keeps
no anon grant; the RPC is the sole boundary (whitelist + column-allowlist + `webhook_tokens` hard
exclusion live *inside* the function). Append-only posture: only the `SECURITY DEFINER` trigger
writes; no UPDATE/DELETE grants to app roles. (Hash-chaining deferred — DB-only tamper-evidence has
a hard ceiling for a 6-person tool.)

### 4.7 UI (Calendar first)
A per-visit **"Activity" tab** in the visit drawer: timeline of *actor · what changed · when*
(relative time in-row, absolute **ET** on hover), person vs. sync icon, **human edits shown by
default with a "Show Jobber sync" toggle** (most visit rows are automated poll writes), multi-field
saves coalesced (via txid), bulk writes grouped. A **"history starts May 17, 2026"** floor is shown
(capture began then; pre-Phase-2 rows have no person). Then the same RPC feeds client + DERM-manifest
history on their detail views; a global "Recent activity" ops page is Phase 3.

## 5. Indexes
`audit.logs` already has a partial expression index on `record_pk->>'id'`. Confirm/extend coverage for
the per-record query shape on clients + derm_manifests (expression index on
`(table_name, (record_pk->>'id'), changed_at desc)` or per-table partial), so the feed stays fast on
the partitioned table.

## 6. Phasing
- **Phase 0 — DONE:** secret redaction + history purge.
- **Phase 1 (this build):** `get_record_history` RPC + `entity_render_config` (seed visits/clients/
  derm_manifests) + the `txid` capture addition + indexes + the Calendar "Activity" tab.
- **Phase 2:** per-person attribution (crew logins, email backfill, `auth_user_id` link, apps thread
  the session JWT, authenticated-RLS re-test).
- **Phase 3:** "System" identity polish, global Recent-activity ops page, extend to more entities.

## 7. Open items for Fred (confirm during review)
- **Retention:** pg_partman currently hard-drops partitions > 24 months. OK, or lengthen / archive
  before drop (DERM forensic history can be ~3 years)?
- **Anon-RPC access:** the RPC is EXECUTE-able by anon (the public app key) and returns any single
  record's history by id. Acceptable for a 6-person internal tool (documented), tightened to
  authenticated-only after Phase 2 — confirm.
- **v1 entities:** visits + clients + derm_manifests confirmed; add anything else now?

## 8. Doc-drift to fix in the same cycle
The audited-table lists in `CLAUDE.md` (Rule 8) and ADR-010 are stale (real set = 22 tables). Correct
both from `pg_trigger` when this lands. A new ADR will record the redaction denylist + the
`get_record_history` surfacing boundary.
