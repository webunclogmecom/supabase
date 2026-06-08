# PRE-POST Inspections — DB Schema Research & Audit

**Date:** 2026-06-08 · **Author:** Claude (with Fred)
**Trigger:** review the inspections subsystem before patching the live `idx_inspections_shift_unique` sync failure — confirm a protocol-compliant design, map the AT → DB → apps pipeline, and stage the path to the Admin Review app becoming the source.
**Source of truth now:** Airtable `PRE-POST insptection` table → `webhook-airtable`.
**Future source:** the **Admin Review** app writes inspections directly (AT retires for this table).
Applies the `unclogme-db-integration-audit` framework + the 8 non-negotiable rules.

---

## TL;DR

- `public.inspections` is **already a clean, canonical, protocol-compliant table** (3NF, source-agnostic, `bigint` identity, `timestamptz`, FKs to vehicles/employees, cross-system identity via `entity_source_links`). It's planned + live — **not new work**, and **no table redesign is needed**.
- It is **source-agnostic by design**, so swapping the source Airtable → Admin Review later needs **no schema change** — only a new `source_system` writer (`entity_source_links`) / `app_source` attribution.
- The "two inspections, same day" question resolves cleanly: **identity = the source record** (`entity_source_links` UNIQUE on `entity_type, source_system, source_id`), which is exactly "mirror Airtable 1:1." Airtable has **no shift object** — each submission is a flat record — so the `idx_inspections_shift_unique` index (a *later* add-on, not in the original v2 schema) fights both Airtable's model and our 1:1 source model. **It is the live bug.**
- **The most impactful gap is NOT the constraint** — it's that the handler **never maps Airtable's "Valve closed" / "Report Issue" fields**, so two live consumer views render dead/misleading data.

---

## 1. Current live schema (Prod, 2026-06-08)

| Column | Type | Null | Notes |
|---|---|---|---|
| `id` | bigint | NO | identity PK |
| `vehicle_id` | bigint | YES | FK → `vehicles(id)` |
| `employee_id` | bigint | YES | FK → `employees(id)` |
| `shift_date` | date | NO | logical operating date |
| `inspection_type` | text | NO | 'PRE' \| 'POST' — **no CHECK** |
| `submitted_at` | timestamptz | YES | from AT `Date` |
| `sludge_gallons` | integer | YES | |
| `water_gallons` | integer | YES | POST only |
| `gas_level` | text | YES | 'Full'/'3/4'/'1/2'/'1/4'/'Empty' — **no CHECK** |
| `is_valve_closed` | boolean | YES | **never populated** (see H1) |
| `has_issue` | boolean | YES | **never populated** (see H1) |
| `issue_note` | text | YES | **never populated** (see H1) |
| `created_at` | timestamptz | YES | default now() |
| `updated_at` | timestamptz | YES | trigger-managed |

- **Constraints:** PK(`id`); FK `vehicle_id`→vehicles; FK `employee_id`→employees. **No CHECK constraints. No unique constraint** — `idx_inspections_shift_unique` is a separate **partial** index: `UNIQUE (shift_date, vehicle_id, employee_id, inspection_type) WHERE vehicle_id IS NOT NULL AND employee_id IS NOT NULL`.
- **RLS:** enabled, 2 policies. **Triggers:** `trg_inspections_updated_at` only — **no `audit.log_change` trigger**.
- **Data profile:** 287 rows — 112 PRE / 175 POST · 17 NULL `vehicle_id` · 0 NULL `employee_id` · **0 rows with `has_issue=true`** · **287/287 linked in `entity_source_links` (airtable)**.

The schema is sound and source-agnostic. Everything below is about **completeness + correctness of the intake**, not table shape.

---

## 2. Protocol-compliance audit

### HIGH

- **H1 — "Valve closed" + "Issue" are never synced.** `handleInspectionRecord` writes only `shift_date, inspection_type, submitted_at, sludge_gallons, water_gallons, gas_level, vehicle_id, employee_id`. Airtable carries `Valve is closed` (checkbox), `Report Issue`/`Issues` (text), but the handler never maps them → `is_valve_closed`/`has_issue`/`issue_note`. **All 287 rows have `has_issue=false`/valve `NULL`.** Both live consumers depend on these:
  - `customer.inspection_items` (Field Portal) → shows "No issues" + valve unknown on **every** work order.
  - `driver_inspection_status` (ops) → `has_open_issue` **never fires**.
  This is compliance-relevant customer-facing data silently dropped. **Fix:** map the fields in the handler + one-time backfill from AT.

### MEDIUM

- **M1 — `idx_inspections_shift_unique` over-constrains (the live failure).** A partial UNIQUE on the shift tuple. It blocks a legitimate 2nd same-day shift (night 8PM–6AM + day 10AM–4PM) and any redo submitted as a new AT record. It is **not in the v2 design** (added later; first seen in the 2026-04-27 audit). Airtable keeps both records; our identity is the source link — so this index is a heuristic business-key that doesn't belong. **Fix:** `DROP INDEX idx_inspections_shift_unique;` (identity stays guaranteed by `entity_source_links`). Then replay the blocked record.
- **M2 — Enums lack CHECK constraints.** `inspection_type` and `gas_level` are bare `text`. Protocol = `text` + CHECK (or enum type). **Fix:** `CHECK (inspection_type IN ('PRE','POST'))` and a `gas_level` CHECK.
- **M3 — 17 rows with NULL `vehicle_id`.** Truck-name `ilike` resolution fails for 17 (new/renamed trucks, e.g. mislabeled selects). These also escape the partial index entirely. **Fix:** log unresolved truck names; repair/align `vehicles.name`; consider a resolution fallback.
- **M4 — `customer.inspection_items` missing `visits.deleted_at IS NULL`.** Known pending item (CLAUDE.md). It matches inspections to visits but doesn't exclude soft-deleted visits → items can surface for orphaned visits. **Fix:** add the filter to the view's visit lookup.

### LOW

- **L1 — Audit opt-out undocumented (Rule 8).** No `audit.log_change` trigger and inspections isn't in the documented audited/excluded set. As a **sync-only** AT table, opt-out is defensible — but Rule 8 requires it be **documented** in a migration header. **When Admin Review becomes a human-write source, flip to opt-IN.**
- **L2 — `inspection_photos` table is ambiguous/legacy.** v2 defines it, but ADR 009 (unified photos) routes inspection photos through `photos` + `photo_links` (role-tagged), populated by `scripts/migrate/airtable_inspection_attachments.js` — not the handler. **Fix:** confirm `inspection_photos` is dead and drop it, or document its role.

---

## 3. Connection map

```
Airtable "PRE-POST insptection"  (flat records; no shift object; 100% trusted per ADR 011)
        │  AT automation: on create/update → POST {entity:'inspection', recordId, fields} (Bearer)
        ▼
webhook-airtable / handleInspectionRecord()      ← single writer
        │  resolve vehicle (Truck ilike, first word) + employee (Driver ilike)
        │  identity: entity_source_links(entity_type='inspection', source_system='airtable', source_id=recId)
        ▼
public.inspections  (287 rows, 287 AT-linked)
        ├──► public.driver_inspection_status   → Ops daily PRE/POST compliance (overnight-aware)
        ├──► customer.inspection_items         → Field Portal (fp.unclogme.app): POST valve/issue per visit
        │        (match POST → visit by vehicle_id + shift_date)
        └──► (future) Workorder app, Admin Review app
photos + photo_links (role-tagged)  ← inspection attachments via migration script (not the handler)
```

---

## 4. Identity model — why "mirror 1:1" is correct

An inspection's true identity is **its source record**, enforced by `entity_source_links.idx_esl_source_id` UNIQUE `(entity_type, source_system, source_id)` and `idx_esl_entity_source` UNIQUE `(entity_type, entity_id, source_system)` — strictly 1:1.

- Same record re-fires → handler finds the link → UPDATE (idempotent "replace").
- Different records → different rows (faithful mirror).

The `idx_inspections_shift_unique` business-key collides with this: it can't represent two AT records for one shift (only one links; the other re-merges forever — the awkward dance the DERM handler already has to do because DERM *does* have a real key, the manifest #). Inspections have **no** real-world unique key, so the shift tuple manufactures false collisions. → drop it; identity is the source link. A same-shift redo that should "replace" is handled when AT **edits** the record; a redo entered as a **new** record is an AT-form/data matter, not a DB guess.

---

## 5. Airtable field → DB column mapping

| Airtable field | type | → DB column | Status |
|---|---|---|---|
| `Date` | dateTime | `shift_date` + `submitted_at` | ✅ |
| `Pre/Post` | singleSelect | `inspection_type` | ✅ |
| `Driver` | singleSelect | `employee_id` (ilike full_name) | ✅ (0 null) |
| `Truck` | singleSelect | `vehicle_id` (ilike name, first word) | ⚠️ 17 null |
| `SLUDGE Tank level` | number | `sludge_gallons` | ✅ |
| `WATER Tank level` | number | `water_gallons` | ✅ |
| `Gas Level` | singleSelect | `gas_level` | ✅ |
| `Valve is closed` | checkbox | `is_valve_closed` | ❌ **unmapped (H1)** |
| `Report Issue` / `Issues` | text | `has_issue` + `issue_note` | ❌ **unmapped (H1)** |
| photo attachment fields | attachments | `photos` + `photo_links` | via migration script, not handler |

---

## 6. Future: Admin Review app as the source

Because `inspections` is **source-agnostic** (no `airtable_*` columns; identity in `entity_source_links`), the source swap is clean:

- Admin Review writes the **same canonical table**, tagged `source_system='admin-review'` in `entity_source_links` (or via the `X-App-Source` audit attribution). **No schema change.**
- At that point inspections become **human-authored in our stack** → **flip Rule 8 to opt-IN** (add `audit.log_change`), and review RLS so the app writes under an authenticated role (not anon).
- The Airtable webhook path can then be retired for inspections (like the Fillout→AT migration in 2026-04-29) without touching the table.

---

## 7. Recommended changes (prioritized, modular, non-breaking)

1. **H1** — Map `Valve is closed` → `is_valve_closed` and `Report Issue`/`Issues` → `has_issue`+`issue_note` in `handleInspectionRecord`; backfill the 287 existing rows from AT. *(This is the bulk of "complete the AT intake per protocols.")*
2. **M1** — `DROP INDEX idx_inspections_shift_unique`; replay the blocked record(s).
3. **M2** — Add CHECK constraints on `inspection_type` and `gas_level`.
4. **M4** — Patch `customer.inspection_items` with `visits.deleted_at IS NULL`.
5. **L1** — Document the audit opt-out (migration header); plan opt-IN for the Admin Review cutover.
6. **M3 / L2** — Repair truck-name resolution (17 nulls); confirm/drop legacy `inspection_photos`.

None requires a table redesign — the canonical shape is correct. Items 1–3 are the "intake from AT, keeping our protocols" work; item 6 in §6 is the Admin Review-as-source path.
