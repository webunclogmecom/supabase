# Inspection ingest idempotency fix — webhook-airtable (2026-07-14)

**Trigger:** Fred asked to check whether the Admin Review app (grease-buddy-dash /
review.unclogme.app — the PRE-POST inspection review surface) has all its data up to date.

## Findings (Prod)

The `public.inspections` feed (webhook-airtable, Path B `automation_inspection`) was **not**
fully current:

1. **Non-idempotent insert → 29 dropped events.** `handleInspectionRecord` looked up the row by
   Airtable `recordId` (`entity_source_links`) and, when no match, did a **plain INSERT**. When the
   SAME physical inspection arrived under a *different* recordId (an AT record deleted+recreated, or
   a duplicate row), the insert hit `duplicate key value violates unique constraint
   "idx_inspections_shift_unique"` (unique on `shift_date, vehicle_id, employee_id, inspection_type`
   WHERE both ids NOT NULL) and the event was logged `failed`. **29 such failures, 2026-06-24 →
   07-10.** Violated Rule 5 (idempotent upserts only). Impact: re-submitted/edited inspections did
   not update the existing row → stale values in Admin Review.

2. **Inspection feed silent since 07-11.** No `automation_inspection` events since 2026-07-11 03:00,
   while `automation_client` / `automation_derm_manifest` AT events kept flowing (last 07-14 03:48).
   `inspections` stops at `shift_date` 07-11 despite routes running 07-12/07-13. **Flagged to the
   Building Apps session for an Airtable-side look** — the Airtable inspection automation may have
   stalled (Airtable is a hard-no for the Supabase session unless Fred says otherwise, so not
   diagnosed here).

## Fix (issue 1)

`supabase/functions/webhook-airtable/index.ts` — `handleInspectionRecord` else-branch: before the
plain INSERT, fall back to the **natural key** (`shift_date, vehicle_id, employee_id,
inspection_type`, only when both ids present) and UPDATE the existing row if found, else INSERT. The
shift-unique index is **partial** (`WHERE vehicle_id/employee_id NOT NULL`), so PostgREST `.upsert()`
can't target it — the lookup-then-update is done in code. Idempotent (Rule 5): a new recordId for an
existing shift now updates + links, and subsequent re-sends take the existing-source-id update path.

**Deployed** to Prod (`wbasvhvvismukaqdnouk`), verify_jwt per config.toml unchanged.

**Backfill:** replayed the 29 failed events through the fixed endpoint (stored payloads, Bearer
`AIRTABLE_WEBHOOK_TOKEN`, no Airtable fetch) → **29/29 processed, 0 failed; 4 inspection rows
corrected** (had real edits previously dropped; the other 25 were identical re-sends). 0 new failures.

## Residual

Issue 2 (feed silent since 07-11) is unresolved and Airtable-side — with Building Apps / Fred.
