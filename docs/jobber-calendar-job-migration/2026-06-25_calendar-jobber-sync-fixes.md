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

## Issue A — Calendar delete of a Jobber-born visit didn't propagate  ✅ instance fixed · 🟡 gap open

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

### 🟡 Open architectural gap (decision pending)
Calendar deletes of **Jobber-born** visits silently don't reach Jobber. This will recur any
time someone deletes (in the Calendar) a visit that originated from Jobber.

**Why not just widen the trigger:** the delete-push path itself is source-agnostic, but the
trigger gate is intentional — internal processes (cross-source dedup, the SA-gen cleanup
sweep) soft-delete Jobber-born rows for *bookkeeping*, and we must NOT let those delete the
real Jobber visit. Blindly removing the source gate would cause unwanted Jobber deletions.

**Recommended fix (needs Fred's go-ahead):** add an **explicit intent** signal for
user-initiated Calendar deletes — e.g. a `cancel_calendar_visit(visit_id)` RPC the app calls
on delete, which pushes `op='delete'` to Jobber regardless of `source`, while ordinary
internal soft-deletes stay silent. This keeps "delete in the Calendar removes it from Jobber"
without letting dedup/cleanup nuke Jobber visits. Alternative (simpler, more restrictive):
have the Calendar refuse to delete Jobber-born visits and instead route the user to Jobber.

---

## Files touched
- `supabase/functions/jobber-push-visit/index.ts` — driver push (commit `9f4ce32`, deployed v14).
- DB: visit 5828 soft-deleted + Jobber visit deleted + ESL unlinked; visit 6804 re-pushed (Grecia assigned).
