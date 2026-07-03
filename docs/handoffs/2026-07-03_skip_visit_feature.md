# Handoff → Building Apps (Visit Calendar): "Skip a visit" UI

**Backend is LIVE + verified (2026-07-03, Supabase session).** This is the Calendar UI half.
Origin: Yannick (Slack) — *"I need to skip a visit for 202, the restaurant is not open yet."* Today the
only options are remove (loses the record) or reschedule to a fake date. A skipped visit now stays on the
Calendar (with its real date) but is removed from Jobber's schedule so the crew doesn't show up.

## RPCs (call via the `ops` schema, like create/edit_calendar_visit)

```
ops.skip_visit(p_visit_id bigint, p_reason text)   -> returns the updated visits row
ops.unskip_visit(p_visit_id bigint)                -> returns the updated visits row
```

- **skip_visit**: only works on a **`scheduled`** visit (errors otherwise: *"only a scheduled visit can be
  skipped"*). Sets `visit_status='skipped'` + `skip_reason`, keeps `deleted_at IS NULL` and the original
  `visit_date`, and pushes a **removal to Jobber** (reuses the cancel `op='delete'` path). `p_reason` is
  optional but please collect it (e.g. "restaurant not open yet") — it's stored in `visits.skip_reason`.
- **unskip_visit**: only works on a **`skipped`** visit. Restores `visit_status='scheduled'`, clears
  `skip_reason`, and **re-creates the visit in Jobber** (subject to the 60-day Jobber horizon — a
  far-future unskip re-adds via the nightly generator PROMOTE step rather than instantly; don't treat that
  as a failure).

## Finalized behavior (Fred decisions 2026-07-03)
- **Un-skip is the only door back.** A skipped visit's ONLY sanctioned transition is un-skip → scheduled.
  The backend now **blocks `skipped → completed`** (RAISE "un-skip first"). So the drawer for a skipped
  visit must offer **only Un-skip** — NOT Reschedule / Mark-complete / Edit (editing a skipped visit is
  also not guarded server-side yet, so the UI must not expose it — unskip first).
- **Single occurrence.** Skipping one visit skips only that cycle; the next visit stands and is **auto-
  pushed to Jobber** by the backend (the gap-fill), so the crew always keeps its next service. No UI work.
- **Warnings (both directions) — REQUIRED:**
  - On **Skip**: confirm *"This removes the visit from the crew's Jobber schedule — continue?"*
  - On **Un-skip**: confirm *"This re-adds the visit to the crew's Jobber schedule on {date} — continue?"*

## UI

1. **Visit drawer** (scheduled visit) → add a **"Skip visit"** action. Confirm modal (skip warning above) +
   a reason textarea → `ops.skip_visit(id, reason)`.
2. **Visit drawer** (skipped visit) → show the `skip_reason` + an **"Un-skip"** action (with the un-skip
   warning) → `ops.unskip_visit(id)`. Do NOT show Reschedule / Mark-complete / Edit on a skipped visit.
3. **Chip styling** — `ops.v_calendar_visit` passes `visit_status` through raw, so style a **skipped chip**
   client-side when `visit_status === 'skipped'` (e.g. muted/striped, a "Skipped" label + the reason on
   hover). The backend now sets `late_status = NULL` for a skipped visit (fixed 2026-07-03d), so it won't
   render a red/yellow late border — but still give it its own skipped style. (A "Completed & skipped"
   filter option can now be real.)
4. **Async Jobber sync** — skip/unskip use the same saga as reschedule/cancel: the row goes
   `sync_state='pending'` then `'confirmed'` (Jobber removal/recreate ok) or `'failed'`. Reuse the existing
   `pollVisitSyncState` pattern; on `'failed'` show needs-attention, not success (the removal/recreate
   didn't land in Jobber — it also surfaces in `ops.v_calendar_push_health`).

## Verified backend behavior (rollback smoke tests, 11/11)
skip sets status+reason & queues Jobber `op=delete`; unskip restores & queues `op=upsert`; guards reject
skipping a completed visit / unskipping a non-skipped visit / a missing id; a skipped visit is **excluded
from ripple** (won't be silently re-dated/un-skipped) and **occupies its cadence slot** so the SA generator
doesn't regenerate a replacement; `visits_with_status` labels it `skipped` not `late`.

Backend migration: `Supabase/docs/migrations/2026-07-03c_skip_visit_status.sql`. Edge fn
`jobber-push-visit` redeployed with the skipped delete guard.
