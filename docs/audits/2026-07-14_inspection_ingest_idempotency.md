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

## Issue 2 — NOT a bug: the Airtable inspection source is retired (Building Apps + Fred, 2026-07-14)

Follow-up with the Building Apps session corrected the framing. Verified independently: **max
`automation_inspection` payload `shift_date` ever = 2026-07-11; ZERO events for 07-12/13** (the only
recent event activity is this fix's own 29-event replay of old shifts, 06-24→07-09). New shifts have
no existing row, so a plain INSERT would have *succeeded* — they'd have landed if submitted. They
didn't. **Per Fred ("we don't use Airtable anymore"): the Airtable inspection form is retired**;
drivers stopped filling it, so the Shift-Forms feed dried up because the SOURCE moved, not because of
a delivery/pipeline error.

**So this idempotency fix is a HARDENING fix** — it recovers the 4 old dropped edits and makes the
ingest correct (Rule 5) — **but it does NOT and cannot bring in 07-12/13+ inspections; that data
doesn't exist in Airtable.** "Admin Review missing recent shifts" resolves only when inspections get
a **new source** (pending Fred's decision on where inspections come from now).

⚠ **Doc drift:** `CLAUDE.md` still states "PRE-POST inspections are now the ONLY live Airtable feed."
If Airtable is now fully retired for inspections too, that line is stale — confirm with Fred and
update `CLAUDE.md` + `docs/architecture.md`.

**Separate signal (Building Apps FYI, not inspection-related):** `jobber` `CLIENT_UPDATE` events show
~966 errors / 5378 (18%) over the last 12d — a pipeline-health flag worth its own look.
