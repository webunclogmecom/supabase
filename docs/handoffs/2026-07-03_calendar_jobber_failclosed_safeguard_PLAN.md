# PLAN — Calendar↔Jobber "fail-closed" safeguard (a failed push must not persist locally)

**Status: PLAN ONLY — nothing built. Do NOT implement until Fred green-lights AND the other Supabase
session's Calendar↔Jobber work has landed** (they hold the sync lane: skip-visit feature +
operating-date rule, both touching the exact objects below). Authored by **Supabase 2**, 2026-07-03,
at Fred's request so he can hand it to whoever implements.

**Owner when built:** whichever session owns the Calendar↔Jobber sync lane at implementation time
(today that's the other Supabase session). This is *their* lane; this doc is the spec, not a claim.

---

## 1. What Fred asked

> "When doing a CRUD on the calendar, if it fails in Jobber it still works locally (our DB). I don't
> want that — if it fails in Jobber it should also fail in our DB. I need both to share the data …
> build a safeguard so this can't happen again."

I.e. the Calendar (our DB) and Jobber must not silently diverge. A calendar create/edit/delete/skip
that **fails to reach Jobber** must not be left as a live local row pretending it succeeded.

Trigger case (already fixed, 2026-07-03): **visit 7013** (112-YA Service Call #99900535, 07-02) — a
calendar visit whose Jobber visit was deleted upstream, left `sync_state='failed'`, still shown on the
calendar for a day as a phantom "overdue" visit. Soft-deleted manually; a read-only tripwire was added
(see §8). This plan is the permanent prevention.

---

## 2. How the sync works TODAY (verified live 2026-07-03)

Local-first + async push:

1. A calendar write to `public.visits` (INSERT/UPDATE) fires:
   - `trg_mark_visit_sync_pending` (BEFORE) → sets `sync_state='pending'` when a synced field changes
     (source ∈ `visit-calendar`/`supabase_cron`).
   - `trg_push_visit_insert` / `trg_push_visit_update` (AFTER) → `fn_push_visit_to_jobber()` →
     `net.http_post` to the **`jobber-push-visit`** edge function (`op` = upsert/delete).
2. `jobber-push-visit` calls Jobber. On success → sets `sync_state='confirmed'` and stores the Jobber
   visit GID in `entity_source_links` (`entity_type='visit'`). On failure → sets `sync_state='failed'`.
3. **cron jobid 9** (`*/3`) retries: `SELECT fn_request_jobber_push(id,'upsert') FROM visits WHERE
   sync_state='pending' AND source IN ('visit-calendar','supabase_cron') AND deleted_at IS NULL AND
   visit_status='scheduled' AND updated_at < now()-'3 min'`.
4. **cron jobid 8** (`*/30`) `sync-jobber-visit-drift` reconciles *date/time DRIFT on confirmed
   visits* (adopt Jobber→DB / heal DB→Jobber). It does NOT clean failed pushes.

`sync_state` values in use: `confirmed`, `pending`, `failed`. There is **no attempt counter and no
error text** on `visits` today — only `sync_state`.

### The gap
When a push **permanently fails**, the row stays `sync_state='failed'`, `deleted_at IS NULL`, and keeps
showing. Nothing rolls it back or reconciles it to Jobber. Two divergence classes:
- **Orphan** — the Jobber visit was deleted upstream (GID → "Visit not found"); local row lingers.
- **Failed create/edit** — the push never succeeded; local row shows a change Jobber never got.

---

## 3. Design decision — compensating self-heal (recommended), NOT synchronous

**Considered & rejected: synchronous transactional push** (RPC pushes to Jobber and only commits
locally on success). Rejected because: (a) a DB function calling external HTTP inside the write txn is
an anti-pattern (holds locks, Jobber latency/timeouts block the user), (b) it kills the fast
local-first UX the Calendar depends on (and the `pollVisitSyncState` model BA just shipped), (c) it
forces a frontend rewrite. It does give the strongest consistency but at too high a cost.

**Recommended: eventual consistency with auto-compensation.** Keep local-first + async push, but add a
**push-failure reconciler** that makes the DB re-converge to Jobber (the source of truth) whenever a
push is *permanently* failed. Same end-state Fred wants ("both share the data") without the UX/architecture cost, and it reuses the existing drift-reconciler pattern.

---

## 4. Detailed design

### 4.1 Prerequisite — attempt/error tracking (additive, no behavior change)
Add to `public.visits` (additive; audited automatically):
- `sync_attempts int NOT NULL DEFAULT 0` — incremented by `jobber-push-visit` on every push result.
- `last_sync_error text` — last Jobber error message (for triage + the tripwire).
- `last_sync_attempt_at timestamptz` — when the last push was attempted.

`jobber-push-visit` (edge fn) updates these on each result. This lets the reconciler tell a
**transient** failure (few attempts, keep retrying via cron-9) from a **permanent** one (attempts ≥ K,
e.g. 5, or `sync_state='failed'` for > Y minutes with no confirm).

### 4.2 The push-failure reconciler (new; mirrors `sync-jobber-visit-drift`)
A new SQL function + edge fn, run by a **new cron (`*/15`)**, `SURFACE`-only first, then compensating
behind a flag. For each **live** (`deleted_at IS NULL`) visit that is **permanently failed**
(`sync_state='failed'` AND (`sync_attempts >= K` OR failed > Y min)) and `source IN
('visit-calendar','supabase_cron')` and `visit_status IN ('scheduled')` (never touch completed history):

1. **Look up Jobber** for the visit's stored GID (if any) AND for a matching visit under the job
   (job GID + same date/time window) — this is the safety step that prevents deleting a real visit.
2. Classify + compensate:
   - **No local GID AND no matching Jobber visit** → **CREATE that never landed** → **soft-delete**
     the local visit (set `deleted_at`), push-suppressed (`app_source='jobber'`).
   - **No local GID BUT a matching Jobber visit exists** → **partial success** (Jobber created it, the
     confirm callback was lost) → **heal forward**: adopt the Jobber visit's GID into
     `entity_source_links` + set `sync_state='confirmed'`. NEVER soft-delete this case.
   - **Has GID, Jobber returns "Visit not found"** → **orphan / failed delete** → **finalize
     soft-delete** (this is the 7013 class).
   - **Has GID, Jobber visit EXISTS but differs (failed edit)** → **adopt Jobber → DB**: overwrite the
     local schedule/line-items/status from Jobber via `adopt_visit_schedule_from_jobber(...)` (the
     other session's existing push-suppressed, audited helper) so both reconverge to Jobber's truth.
3. Every compensation writes a `sync_log` row and appends to a review surface (see §4.4).

### 4.3 Must-not-fight rules (coexistence with existing machinery)
- Act **only on `failed`**, never `pending` — let **cron-9** exhaust its retries first (set K/Y so
  cron-9 runs several times before the reconciler acts).
- All compensating writes are **push-suppressed** (adopt source→`jobber`, `app_source='jobber'`) so
  they don't re-fire `trg_push_visit_*` and loop. Reuse the exact pattern `adopt_visit_schedule_from_jobber`
  already uses.
- Domain-disjoint from **cron-8 drift** (that's date/time drift on *confirmed* visits; this is *failed*
  visits) — but they share `adopt_visit_schedule_from_jobber` and the "Visit not found → soft-delete"
  idea, so **build both under one owner** to keep them coherent.
- Scope: `scheduled` only. **Never auto-delete `completed`** visits (history). Consider excluding
  `app_source='sql'` (deliberate human DB edits) from auto-compensation.

### 4.4 Visibility (important UX safeguard)
Fred wants fail-closed, but a visit that silently *vanishes* would confuse a dispatcher who just created
it. So every auto-compensation must be **visible**:
- `sync_log` row per action (source `calendar_push_failure_reconcile`).
- A review surface `ops.v_calendar_sync_divergence` (like `ops.v_derm_human_override_conflict`) listing
  what was auto-reverted/removed and why, for ops to glance at.
- Frontend note (BA): the Calendar already polls `sync_state`; on `failed`, show "couldn't sync to
  Jobber — will be reconciled" so the user isn't surprised when it's cleaned. (BA task, coordinate.)

---

## 5. Objects this will touch (collision surface — for the owner to claim)
- `public.visits` — ADD COLUMNS `sync_attempts`, `last_sync_error`, `last_sync_attempt_at` (additive).
- **`jobber-push-visit`** edge fn — write the attempt/error columns on each result. *(other session's
  active object — skip-visit feature; sequence after.)*
- NEW SQL fn `public.reconcile_failed_visit_pushes()` + NEW edge fn `reconcile-visit-push-failures`
  (or fold into `sync-jobber-visit-drift`).
- Reuse (no change): `adopt_visit_schedule_from_jobber`, `entity_source_links`, `sync_log`.
- NEW cron (`*/15`) for the reconciler.
- NEW `ops.v_calendar_sync_divergence` review surface.
- Coordinate: cron-9 (jobid 9), cron-8 (jobid 8), `fn_push_visit_to_jobber`, `trg_mark_visit_sync_pending`,
  `trg_push_visit_*` — all in the other session's active Calendar-sync lane.

---

## 6. Rollout (safe order)
1. Additive columns + `jobber-push-visit` writes them (no behavior change).
2. Build reconciler in **SURFACE-only** mode (report what it *would* compensate; write nothing) + the
   review surface. Review against real `failed` visits for a few days.
3. Enable compensation **behind a flag** (`reconcile_enabled`), one class at a time (start with the
   safe orphan/"Visit not found" → finalize-soft-delete class; then partial-success heal-forward; then
   failed-edit adopt; then failed-create soft-delete last, since it deletes).
4. Backup before the first live compensating run (`backups/`). Verify per §7.

---

## 7. Verification plan (when built)
Rolled-back-txn tests + a controlled live case per class:
- **Failed create, never in Jobber** → reconciler soft-deletes; calendar drops it; Jobber unchanged.
- **Partial success** (simulate: create in Jobber, drop the local GID) → reconciler heals forward
  (adopts GID, `confirmed`), does NOT delete. **This is the critical safety test.**
- **Orphan** (GID → "Visit not found", the 7013 shape) → finalize soft-delete.
- **Failed edit** (local diverges from Jobber) → adopt Jobber→DB; DB == Jobber after.
- **Transient failure** (fail once, succeed on cron-9 retry) → reconciler does NOT act prematurely.
- **Completed visit** → never touched.
- Re-run the tripwire (`check_calendar_jobber_divergence.js`) → clean.

---

## 8. Already done (2026-07-03, Supabase 2)
- **Soft-deleted phantom visit 7013** (verified: out of `v_visits_live`; delete propagated to Jobber →
  `sync_state='confirmed'`; cron-9 skips it; real visit 7027 untouched).
- **Read-only tripwire** `scripts/probes/check_calendar_jobber_divergence.js` (commit `0475c04`) —
  flags live `sync_state='failed'` or stuck `pending>30min` visits; `--verify-jobber` splits orphans
  from transient errors; exit 1 on findings. This is *detection*; §4 is the *prevention*. The tripwire
  naturally feeds the reconciler (same population).

---

## 9. Open questions for Fred / the implementing session
1. Threshold K (attempts) / Y (minutes) before a failure is "permanent" — proposal: K=5 or Y=20 min
   (after cron-9 has retried ~6×). Confirm.
2. Auto-compensate silently, or require a human "confirm cleanup" on the review surface for the
   *delete* class (safest) while auto-doing the heal/adopt classes? Proposal: auto for heal/adopt/orphan,
   surface-for-review for failed-create-delete initially.
3. Fold the reconciler INTO `sync-jobber-visit-drift` (one Calendar reconciler) or keep separate?
   Proposal: separate fn, same owner, can share the cron.
4. Exclude `app_source='sql'` (manual DB edits) from auto-compensation? Proposal: yes.
