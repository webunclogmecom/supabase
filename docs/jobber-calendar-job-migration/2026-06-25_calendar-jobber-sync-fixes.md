# 2026-06-25 — Calendar ↔ Jobber sync fixes (driver push + delete propagation)

Two symptoms reported by Fred on **099-PV (Pura Vida Dadeland)**, June 26 Service Call:

- **(A)** A visit deleted in the Calendar App still showed in Jobber.
- **(B)** A visit re-created in the Calendar with driver **Grecia** assigned did not show the
  driver in Jobber.

Both root-caused, the live instances fixed + verified directly against Jobber, and the
systemic fix for (B) deployed. (A) leaves one **open architectural gap** flagged below.

---

## Issue B — assigned driver not pushed to Jobber  ✅ FIXED + DEPLOYED

### Root cause
The Calendar form writes the planned driver to `visits.assigned_driver_id` (the dropdown =
`ops.v_calendar_driver`, the 6 crew). But the outbound Edge Function
`supabase/functions/jobber-push-visit/index.ts` never sent it:

- **CREATE** path hardcoded `schedule.teamMemberIdsToAssign: []`.
- **UPDATE** path called `visitEditSchedule` (whose `VisitEditScheduleInput` carries only
  `startAt`/`endAt`) and `visitEdit` (title/instructions) — neither touches assignment.

So no code path ever told Jobber who the driver was.

### Fix (commit `9f4ce32`)
Resolve `assigned_driver_id` → Jobber **user GID** via `entity_source_links`
(`entity_type='employee'`, `source_system='jobber'`) and:

- **CREATE:** pass it in `schedule.teamMemberIdsToAssign`.
- **UPDATE:** call the dedicated mutation
  `visitEditAssignedUsers(visitId, input:{ assignedUserIds:[gid] })` — assignment is a
  separate mutation from scheduling in Jobber's API.

```ts
const driverGid = visit.assigned_driver_id
  ? await jobberGid("employee", visit.assigned_driver_id) : null;
// update path, after editSchedule/edit:
if (driverGid) {
  const a = await gql(token, M_ASSIGN, { id: existingGid, input: { assignedUserIds: [driverGid] } });
  ...
}
// create path:
teamMemberIdsToAssign: driverGid ? [driverGid] : []
```

Deployed to Prod (`jobber-push-visit` v14, `verify_jwt` stays **true** per
`supabase/config.toml` — confirmed post-deploy). Re-pushed the live visit (id 6804).

### Verification (direct Jobber read)
Jobber job **#99900734** (the NEW Service Call), visit `…Mjk0OTI3MzA=` "Service Call" now
shows **drivers: Grecia**. From now on any driver picked on the Calendar form is pushed on
both create and update.

**Crew → Jobber user GIDs** (for reference; `entity_source_links` entity_type `employee`):
Grecia=1, Fred=2, Aaron=26, Yannick=27, Diego=28, Mark=35 — all linked.

---

## Issue A — Calendar delete of a Jobber-born visit didn't propagate  ✅ instance fixed · ✅ systemic fix shipped

### What happened
The June-26 Service Call shown in the image (visit id **5828**, title
`099-PV … Service Call [OLD]`) lived on the **OLD** Service-Call job (#10000519). Fred deleted
it in the Calendar and re-created the visit on the **NEW** Service-Call job (#99900734, visit
6804). The OLD one persisted in Jobber → a duplicate.

### Root cause
Visit 5828 is **`source='jobber'`** (it was born from the Jobber inbound poll, not the
Calendar). The outbound push is **source-gated**: `trg_push_visit_update` only fires when
`source IN ('visit-calendar','supabase_cron')`. For a Jobber-born visit the trigger never
fires, so a Calendar soft-delete (`deleted_at`) is **not** pushed to Jobber — and the inbound
poll can even re-assert the row. This is the "ownership by birthplace" model: Jobber-born =
Jobber-mastered.

### Instance fix
Invoked `jobber-push-visit` directly with `op='delete'` for visit 5828 → `visitDelete` in
Jobber + `entity_source_links` unlinked, then soft-deleted the row in our DB
(`visits.deleted_at`). Verified: Jobber job #10000519 now has **0 visits**; the duplicate is
gone. The NEW Service Call (6804, with Grecia) is the single remaining June-26 visit for 099-PV.

### Systemic fix — shipped 2026-06-25 (migration `2026-06-25_propagate_calendar_deletes_to_jobber.sql`)
Two parts, so Calendar deletes propagate while internal sync never echoes:

1. **Widened `trg_push_visit_update`** to also fire `fn_push_visit_to_jobber` on a
   soft-delete / cancel of **any** source (so Jobber-born deletes now reach the push).
   Edits/reschedules of Jobber-born visits stay Jobber-mastered (only the delete branch
   crosses the source gate).
2. **Fail-safe Origin gate in `fn_push_visit_to_jobber`:** a Jobber-born visit
   (`source` not Calendar/cron) is only deleted in Jobber when the request carries a
   **browser Origin** (`http%`) — i.e. a human deleted it in an app. Service/sync calls
   (no Origin) never echo a `visitDelete` back to Jobber.

**Why the gate was required:** `cron_jobber_reconcile_anomalies.js` soft-deletes
Jobber-sourced visits that are **orphaned** (already removed in Jobber) to keep our DB in
sync. Without the gate, the widened trigger would echo a `visitDelete` for every orphan
(failed "not found" calls = noise) and would be a data-loss footgun for any future reconcile
that soft-deletes a still-live Jobber visit. Verified against `audit.logs`: Calendar writes
carry `origin=https://calendar.unclogme.app` (44/47); `app_source='jobber-reconcile'`/`sql`/
`service-agreement-cron` = 0 origin — so the gate cleanly separates human from sync.

**Verification:** trigger WHEN logic evaluated on real rows (jobber: delete fires=T,
edit=F; calendar: both=T); the Origin gate parses + decides correctly both ways
(`https://calendar.unclogme.app` → allow; no header → block); the push path itself was
already proven live (visit 5828). DB-only change — no edge-fn redeploy.

---

## Files touched
- `supabase/functions/jobber-push-visit/index.ts` — driver push (commit `9f4ce32`, deployed v14).
- DB: visit 5828 soft-deleted + Jobber visit deleted + ESL unlinked; visit 6804 re-pushed (Grecia assigned).
