# Reference — Calendar Day Start / Day End / Dump markers

*Written 2026-08-17 by @Building Apps, after an end-to-end smoke test on real data.*

**Why this file exists.** Everything below was already true and already correct, but it was spread
across **four migration headers** and the Visit Calendar's own docs. Asked "how are the Day Start/End
points documented?", the honest answer was "in five places, none of which is the DB-side reference a
Supabase reader would open." This is that reference. The **app-facing** contract stays where it
belongs, in `Building Apps/Visit Calendar/` (root `CLAUDE.md` §4b) — do not duplicate it here, link it.

| where | what it covers |
|---|---|
| [`Building Apps/Visit Calendar/CLAUDE.md`](../../../Building%20Apps/Visit%20Calendar/CLAUDE.md) | the app rules (per-truck, never call the edge fn, `marker_value` not `label`, marker-row-before-visit) |
| [`.../docs/02-architecture.md`](../../../Building%20Apps/Visit%20Calendar/docs/02-architecture.md) | the write surface |
| [`.../docs/04-connections.md`](../../../Building%20Apps/Visit%20Calendar/docs/04-connections.md) | the two push paths, drawn out |
| [`.../docs/06-features-and-routes.md`](../../../Building%20Apps/Visit%20Calendar/docs/06-features-and-routes.md) | the feature description |
| migrations `2026-07-28_calendar_day_markers`, `2026-08-05_1530_dump_sites_marker_value`, `2026-08-06_0007_..._per_truck`, `2026-08-06_0035_esl_allow_calendar_day_marker`, `2026-08-06_0404_..._jobber_trigger` | the reasoning, per change |

---

## The objects

> **🟢 A MARKER IS SAVED JOBBER-FIRST SINCE 2026-09-24** (`2026-09-24_2100_jobber_first_day_markers`,
> Supabase `ada5a53` + `ac0083b`; design `Building Apps/Visit Calendar/docs/specs/2026-09-24-jobber-first-day-markers-design.md`).
> Fred: *"I was thinking that we do like with the visits, that it first confirms the data was changed in jobber
> being reflected in the app/db"*. A person's change and the Start healer's are pushed to Jobber, READ BACK, and
> only then committed. If Jobber refuses, nothing changes and the person is told why.
> - **The door: edge fn `save-day-marker`** (browser; `verify_jwt = false` + `auth.getUser()` + the staff-domain
>   gate, like `save-calendar-task`). `{op:'create', marker}`, `{op:'update', marker_id, patch}`,
>   `{op:'delete', marker_id}`, optional `replace_marker_id`. Real HTTP statuses with `{ok:false, code, message}`;
>   `message` is a sentence for staff. Codes: `invalid_input` 400, `not_found` 404, `already_exists` 409 (with
>   `blocking_marker_id`), `changed_elsewhere` 409, `busy` 409, `jobber_rejected` / `jobber_unavailable` /
>   `jobber_unverified` 502, `lookup_failed` 503, `db_error` / `partly_moved` / `unexpected` 500.
> - **ONE definition: `supabase/functions/_shared/day-marker-task.ts`**, the Task (title, window, assignees, the
>   read-back, unchanged from `jobber-push-task` v18) and the saga, imported by `save-day-marker`,
>   `heal-day-starts` and `jobber-push-task`. Its `etToUtcISO` is `save-calendar-task`'s DST-correct copy: a
>   marker minute inside the spring-forward gap is refused (the old copy moved minutes 0-119 of that date to the
>   previous day). `scripts/probes/calendar_task_helpers_verbatim.mjs` asserts the seven helpers stay identical.
> - **🛑 ONE WRITER PER MARKER.** Every change to an existing marker first claims it:
>   `ops.claim_day_marker(ids, holder, seconds)` writes `ops.marker_jobber_claims` (ZZ004 `busy` while another
>   writer holds it; an expired claim is taken over). The commit, **`ops.save_day_marker(op, id, token, expect,
>   values, task, heal)`**, writes the row, its `entity_source_links` row and removes the claim in ONE transaction,
>   with the trigger push suppressed and `app.marker_push_verified` stamping `push_changed_at` = the link's
>   `synced_at`. It refuses ZZ005 (claim lost), ZZ002 (a Jobber-visible column or the linked Task changed since
>   the caller read it), ZZ003 (a Jobber-visible change without its verified Task: that would never reach Jobber),
>   P0002 (gone), 23505 (slot taken). A new marker needs no claim. service_role only; the body
>   `ops.save_day_marker_step` is callable by nobody but the wrapper.
> - **A claim left behind = Jobber may differ from the row.** A save that dies, a Jobber call with no answer, or a
>   compensation that fails releases its claim DIRTY (`ops.release_day_marker(token, true)`: kept, expired).
>   `ops.retry_marker_pushes` arm (c) then hands the marker to `jobber-push-task`, which takes the claim over and
>   makes the Task match the row; `public.log_start_flags_health` reports a claim still there after 20 minutes
>   (item 4b, `marker_sync_interrupted`). Empty `ops.marker_jobber_claims` is the healthy state.
> - **Compensation.** A commit that fails after a Task CREATE deletes that Task (read back gone). After an EDIT,
>   or after a DELETE whose commit was refused (a heal re-check: a visit came back), the saga makes the Task match
>   the committed row again, creating it if it is gone. A Task deleted by hand in Jobber is created again on the
>   next save or net push, with a new link.
> - **Replace** (`replace_marker_id`, the marker a 409 named): a create updates that marker IN PLACE (same row,
>   same Task); a move onto an occupied slot updates the blocker with the mover's values, then deletes the mover
>   (in that order, so a failure half-way loses nothing: `partly_moved`).
> - **The healer** goes through the same saga. `ops.fn_judge_starts` only flags now (its SQL delete and driver
>   swap are gone); `ops.start_heal_candidates()` returns `kind` = remove / driver / recompute and skips a claimed
>   marker; `heal-day-starts` v2 plans a recompute with `ops.apply_start_heal(..., p_dry_run => true)`, and
>   `ops.save_day_marker` re-runs that plan under the row lock. A Jobber refusal is recorded as `jobber_failed`
>   (`ops.note_start_heal_attempt`, retried after 10 minutes). The kick gate is 15 s. A removal now lands 2-3 s
>   after the Calendar's `refresh_start_flags` call (a Jobber delete and read-back come first).
> - **The net, `jobber-push-task` v19**, still serves `trg_push_marker_to_jobber` (any SQL writer) and
>   `start-push-retry`: it claims, then `upsert` = edit the Task (or create it: no link, or deleted by hand) and
>   commit the link through `ops.save_day_marker('relink')`; `delete` = `taskDelete`, read back gone, drop the
>   link. A claimed marker answers `{ok:false, busy:true}`; the holder's commit or the next retry covers it.
> - **Superseded below:** the phase-2 "Known limit (1)" (two pushes of one marker landing out of order) is CLOSED
>   by the claim; the Calendar's 3 s / 10 s "placed a moment ago" lock is no longer needed (the link is written
>   with the row). The 10-second link-age guards in the candidates stay, harmless.
> - **Verified live** (2027-01-13 fixtures, every Task read back from Jobber, all removed after):
>   `node scripts/probes/day_marker_saga_e2e.js human` (auth, input refusals, create, move, driver change, slot
>   conflict, replace in place, move onto an occupied slot, busy, the net for a SQL write, a Task deleted by hand,
>   a change Jobber cannot see, dump, delete, idempotent delete), `... heal` (remove, driver, recompute, remove
>   after the visit is deleted), and `node scripts/probes/day_marker_saga_net_e2e.js` (a SQL-created marker, a
>   crashed save repaired by the retry, a SQL delete). The migration's own VERIFY has 17 checks and was run
>   against 10 deliberate breakages, each refused by its own check.

> **🟡 A TRUCK START IS JUDGED FOR FRESHNESS SINCE 2026-09-24** (`2026-09-24_0715_start_freshness_phase1`,
> Supabase `d81b69a`; plan `Building Apps/Visit Calendar/docs/specs/2026-09-23-start-freshness-design.md`).
> A truck Start (`marker_type='start'`, `vehicle_id` AND `employee_id` set) is a snapshot of its truck's
> first visit, so the database now flags it when that first visit changes. Phase 1 itself never recomputes and
> never deletes anything; since phase 2 (the block below) the Start heals itself when healing is switched on. The objects:
> - **`stale_reason`** / **`stale_since`** on this table. `stale_reason` is `'no timed visit'` (red),
>   `'first visit changed'` or `'driver changed'` (amber), NULL = fresh. **A caller can never set or clear
>   them**: the BEFORE trigger `trg_aa_start_judge` replaces whatever a write sends with the verdict, and
>   only `ops.fn_judge_starts` (under the transaction GUC `app.start_judge_write`) writes them directly.
>   A frozen Start (its own minute has passed, ET: `public.fn_start_frozen`) carries no flag.
> - **The rule is `public.fn_start_verdict`.** The first visit comes from **`public.fn_start_first_visit`
>   (date, truck)**, the one SQL copy of 13p's selection, on the ASSIGNED truck only (`visits.vehicle_id`;
>   Fred: "go by assigned trucks only") and timed visits only. A DERIVED Start is stale when that visit is
>   not its `source_visit_id`, or when the start its OWN minute implies (`marker_date + minutes +
>   eta_minutes + fn_start_block_minutes()` at ET) is not that visit's start. 🛑 **Not a stored snapshot**:
>   the app computes the minute when the truck is picked and writes it later, so a snapshot stamped at
>   write time called a stale Recompute fresh (the review's must-fix #5). `fn_start_block_minutes()` = 30
>   must equal the app's `START_BLOCK_MINUTES`; changing one alone flags every derived Start, which is the
>   correct outcome of a block change. A hand-edited Start is never judged on its minute.
> - **The write path only notes the DAY.** `trg_zz_queue_start_recheck` on `public.visits` (UPDATE OF
>   visit_date, start_at, end_at, vehicle_id, visit_status, deleted_at, property_id, client_id,
>   assigned_driver_id), `public.visit_assignments` and `public.inspections` (shift_date +/- 1) inserts into
>   **`ops.start_recheck_queue`** only when a truck Start exists on that day (one probe on
>   `calendar_day_markers_start_truck_uniq`). The queue is append-only on purpose: no insert can wait on
>   another transaction, and an uncommitted writer's note is invisible to a drain, so no change is lost.
> - **`ops.refresh_start_flags()`** drains and judges. The app calls it after its own visit writes; cron
>   `start-flags-drain` runs it every 2 minutes; `start-flags-sweep` (08:00 UTC) re-judges every truck
>   Start from today, covering what is not instrumented (a re-geocode, an employee going INACTIVE).
>   `ops.start_first_visit(date, truck)` is the app's read-only wrapper. Both are `authenticated` +
>   `service_role`; every other new function has no API grant.
> - **`zzz_broadcast_inval` on this table** sends `inval:calendar_day_markers`, so a flag the cron sets
>   reaches an open Calendar.
> - **Kill switch:** `public.app_config` `start_recheck_enabled` (anything but `'true'` is off; a missing
>   row is on). Off stops queueing and draining, and every marker write then clears its flags. Bulk jobs:
>   `set local app.suppress_start_recheck = 'on'`. Rollback order is in the migration header (app first).
> - Errors never abort a visit write and never stay silent: `sync_log` sources `start-recheck-queue` and
>   `start-flags-judge`. Watch them.

> **🟢 A TRUCK START HEALS ITSELF SINCE 2026-09-24 (phase 2)** (`2026-09-24_0845_start_freshness_phase2`,
> Supabase `292800a`; edge fn `heal-day-starts`). Fred, verbatim: *"if it's changed by Jobber and our App
> adopts ... then we don't need any warning or whatsoever just remove the Start Point if there are no more
> visits (or they're anytime) or recalculate if there are any other visit with scheduled time ... and we
> need to actually check if there are errors because of it."*
> 🛑 **Gated by `public.app_config` `start_heal_enabled`**, which shipped `'false'` and is switched on in the
> same hour as the Calendar's "last timed visit is leaving" dialog. Missing row = OFF (fail closed; the
> opposite of the judge's switch). Bulk jobs: `set local app.suppress_start_heal = 'on'`.
> What each verdict does when it is on, whoever changed the visits:
> - **`'no timed visit'`: the Start is DELETED** by `ops.fn_judge_starts` (the push trigger then deletes its
>   Task). Only when its Jobber link is older than 10 s (a create push takes 0.5 to 1.3 s), or it has no
>   link and is older than 10 minutes. Anytime visits do not keep a Start (Fred's decision 3).
> - **`'driver changed'`: `employee_id` becomes the first visit's driver**, only when that visit is still
>   the Start's `source_visit_id`. 🛑 A hand-typed Start's minute is never judged, so on it 'driver changed'
>   can hide a DIFFERENT first visit; the review reproduced it being handed to that visit's driver and
>   marked fresh. It now stays flagged for a person. A first visit with no driver also stays flagged.
> - **`'first visit changed'` (derived only): RECOMPUTED** by the edge fn `heal-day-starts`, kicked by
>   `public.fn_request_start_heal()` from `ops.refresh_start_flags` (so within 2 minutes, or at once after
>   the Calendar's own write), at most once a minute, only when `ops.start_heal_candidates()` has a row.
>   It asks `calculate-driving-time` for the ETA (traffic:false, the dispatch budget of 300 a day) and
>   `ops.apply_start_heal` writes minute = the first visit's ET minute - ETA - 30, its driver, its id, the
>   ETA, under a row lock, refusing when the first visit is not exactly the one the ETA was computed for.
>   Refusals are stored per first visit in `ops.start_heal_attempts` and back off by cause: no driver
>   10 minutes, unknown or implausible drive time 1 hour, before midnight / already passed / a verdict the
>   write cannot clear until the first visit changes.
> - **Frozen means frozen:** a Start whose minute has passed is never healed (`apply_start_heal` returns
>   `'frozen'`). A Start still flagged when its minute passes is logged as an ERROR under
>   `start-flags-judge` (`details.action = 'froze_while_stale'`): the crew started from a wrong Task.
>   `ops.refresh_start_flags` now re-judges every day that still carries a flag, so this is caught within
>   2 minutes and a skipped heal is retried.
> - Every heal is journalled in `sync_log` source **`start-flags-heal`** (`action` removed, driver_updated,
>   recompute_run with per-marker outcomes), with the before and after values.
> - **`fn_start_verdict` compares ET wall-clock minutes** since phase 2. It used to convert
>   `marker_date + minutes` back to an instant, and on the repeated 01:xx hour of the November clock change
>   that picked EST for an EDT visit, so a correct Start read 'first visit changed' for ever.
> - **The dialog's pre-check** is `ops.preview_start_impact(p_changes jsonb)` (read-only, `authenticated`).
>   The app passes one object per visit the gesture writes (`visit_id` + the changed keys among
>   `visit_date`, `start_at`, `end_at`, `vehicle_id`, `visit_status`, `deleted`); on a ripple-routed write
>   it passes the rows of a `ripple_reschedule_visit` dry run too (the pre-check deliberately does not copy
>   the chain rule). Returns each unfrozen truck Start whose day has a timed visit now and would have none.
>   A date move without `start_at` keeps the ET time (as the ripple does); a `start_at` without a date moves
>   the date with it (as `trg_aa_reconcile_operating_date` does).
> - **`push_changed_at`** + `trg_ab_marker_push_stamp`: when a Jobber-visible column last changed (the six
>   `fn_push_marker_to_jobber` tests). A caller cannot set it; a write under `app.suppress_marker_push` is
>   not stamped. `updated_at` could not be used: every flag write bumps it.
> - **`ops.retry_marker_pushes()`, cron `start-push-retry` (1-59/5)**, all marker types: re-sends a Task
>   DELETE whose link outlived its marker, and a Task EDIT whose `push_changed_at` is later than the link's
>   `synced_at` (today or later, settled 2 minutes, its minute not yet passed). 3 tries 5 minutes apart,
>   then one every 6 hours. **Never a create** (not idempotent: a create that reached Jobber unlinked would
>   make a second Task). Ledger `ops.marker_push_retries`; a row per run with a re-send under
>   `start-flags-push-retry`.
> - **`public.log_start_flags_health()`, cron `start-flags-health` 13:20 UTC**, registered in BOTH
>   `ops.v_health_items` and `ops.v_health_status`, so `health-escalate` (13:30) emails: a Start out of date
>   for 30+ minutes (with why it did not heal), a marker with no Task after 10 minutes, a Task not deleted
>   after a failed retry, a Task not updated after 20 minutes, each Start that began out of date (one item
>   per incident), other errors in 26 hours (one per source), the judge switched off, the retry cron not
>   running, a marker Task imported as a Calendar Task (a duplicate). Healthy = silence.
> - **Known limits, kept on purpose:** (1) [CLOSED 2026-09-24_2100 by the one-writer claim, see the block above] the edit retry compares `push_changed_at` (DB clock, start of the
>   writing transaction) with `synced_at` (edge clock, end of the push); two pushes of ONE marker in flight
>   at once that land out of order can leave Jobber one version behind unseen (the exact fix is
>   `jobber-push-task` recording the version it pushed). (2) The check runs once a day before 13:30 UTC, so
>   an evening failure is emailed the next morning; an evening escalation would change every check's
>   cadence, Fred's call. (3) The whole day is one Start, so a timed stop after midnight IS the truck's first
>   visit and the recompute follows it.

> **🚚 -> 🧑 MARKERS BELONG TO A DRIVER SINCE 2026-09-16** (`2026-09-16_1000_calendar_day_markers_per_driver`,
> Fred, voice: *"the task needs to be assigned to a driver instead, for it to be actually the driver to
> see this task"*). What changed, and what the paragraphs below still describe correctly:
> - **`employee_id bigint NULL REFERENCES public.employees(id)`** is the marker's owner. NULL = **Unassigned**,
>   a supported value. `vehicle_id` STAYS on the table for the five rows placed before that date (74, 75,
>   77, 79, 80, all Moises) and the app no longer writes it.
> - **Uniqueness is per (marker_date, employee_id, marker_type) NULLS NOT DISTINCT, Start/End only**
>   (`calendar_day_markers_start_end_driver_uniq`); the old truck index is gone. Dump stays repeatable.
> - **`updated_at` is trigger-managed** (`trg_calendar_day_markers_updated_at` -> `public.set_updated_at()`).
>   Before this it froze at insert; the app never issued an UPDATE until this change (a "move" was
>   delete-then-insert, which is still what a NEW pill dropped on an occupied day does).
> - **The app now issues UPDATEs** of `marker_date`, `minutes` and `employee_id` (drag an existing chip,
>   or its popover), so `trg_push_marker_to_jobber` sends `upsert` and the edge fn does `taskEdit` on the
>   SAME Task GID. The UPDATE guard in `fn_push_marker_to_jobber` gained `employee_id` (a driver change is
>   a Jobber-visible change: title and assignee).
> - **Jobber:** title `Day Start (<driver full name>)`, assigned to that ONE person via
>   `entity_source_links` (employee, jobber). The driver is authoritative: on an EDIT `assignedTo` is
>   always sent, an empty list strips the previous driver when the marker became Unassigned; on a CREATE
>   an empty list is omitted. The read-back verifies the assignees too, and a failed verify on the create
>   path now deletes the Task it just made (it used to leave it untracked). Legacy truck rows keep the
>   everyone-on-that-truck rule below. All 9 ACTIVE employees carry a Jobber link (measured 2026-09-16).
> - **The stored minute is the user's.** The app used to overwrite a dropped Start/End time with a
>   drive-time back-solve (first stop minus drive minus 30 / last stop plus drive); it no longer does. The
>   route is shown inside the chip ("ETA to next visit: N min", computed from the driver's next stop at or
>   after the marker) and never applied to the row.
> - Applied with two rolled-back pg_net probes (old body: an `employee_id`-only UPDATE enqueues nothing;
>   new body: exactly one request) and `relacl` asserted unchanged before and after. The table is still
>   audit opt-out.

> **🚚 A START CAN BE PLACED BY TRUCK SINCE 2026-09-21** (`2026-09-21_1225_calendar_day_markers_start_by_truck`,
> comment fix `2026-09-21_1520`; Fred: *"select between trucks ... the first visit of that truck that
> day ... an ETA between the yard and that first visit ... the task on Jobber assigned to the person who
> is assigned to that visit"*). App rule: `Building Apps/Visit Calendar/CLAUDE.md` 13p; plan:
> `.../docs/specs/2026-09-21-start-pill-by-truck-plan.md`. DB facts:
> - **Three new nullable columns**: `source_visit_id bigint REFERENCES public.visits(id) ON DELETE SET
>   NULL` (the visit the Start was derived from), `eta_minutes integer CHECK (>= 0)` (the free-flow Doral
>   Yard to that visit ETA that set the minute), `eta_computed_at timestamptz`. All NULL on End, Dump,
>   driver-placed and legacy rows. On a hand edit of the time the app NULLs the two eta columns and
>   KEEPS `source_visit_id` (DERIVED = `eta_minutes IS NOT NULL`).
> - **A truck-placed Start carries BOTH `vehicle_id` and `employee_id`** (the driver read off the first
>   visit's `driver_id`). 🛑 The edge fn decides the assignment model per row with
>   `driverModel = employee_id != null || vehicle_id == null`, so a row with a truck and NO driver falls
>   into the 2026-08-06 everyone-on-the-truck branch; the app refuses to place one (an uncrewed first
>   visit is a refusal) and never writes `employee_id` NULL on a row that has a `vehicle_id`.
> - **Two unique indexes now.** `calendar_day_markers_start_end_driver_uniq` is
>   `(marker_date, employee_id, marker_type) NULLS NOT DISTINCT WHERE marker_type IN ('start','end') AND
>   vehicle_id IS NULL` (every End, the driver-placed Starts); `calendar_day_markers_start_truck_uniq` is
>   `(marker_date, vehicle_id) WHERE marker_type = 'start' AND vehicle_id IS NOT NULL` (one Start per
>   TRUCK per day; the three legacy truck rows sit on distinct dates). So one person can hold two truck
>   Starts on one day (two Jobber Tasks), and a 23505 on a truck-placed Start can only come from the
>   truck index: the app's Replace dialog looks the blocking row up by (day, truck), never by driver.
> - **The push guard is unchanged and must stay so**: `fn_push_marker_to_jobber` compares
>   `marker_date, marker_type, minutes, vehicle_id, employee_id, dump_site`; an UPDATE that changes only
>   the three new columns is NOT a Jobber change (a Recompute that lands on the same minute and driver
>   pushes nothing, on purpose).
> - **`jobber-push-task` v14**: a row carrying both ids is titled `Day Start (<truck>, <driver>)`, truck
>   first, and assigned to the driver alone; a driver-placed row still reads `Day Start (<driver>)`
>   (control 2026-09-21: marker 108 for Fred pushed as `Day Start (Fred)`).
> - **`calculate-driving-time` v8** accepts `traffic: false` in the body and then reads/writes the
>   `traffic_aware = false` bucket of `ops.route_leg_cache` (24 h TTL) with `TRAFFIC_UNAWARE`, whatever
>   the clock says; the reply echoes `traffic_aware`. Only the literal `false` forces it. Measured on
>   depot to property 162 at 14:11 ET: 41 min free-flow vs 47 min traffic-aware. That is the number a
>   truck-placed Start stores, so the same Start placed at noon and at 9 PM lands on the same minute.
> - Grants unchanged (`authenticated` INSERT/UPDATE/DELETE cover the new columns), audit still opt-out,
>   `relacl` asserted equal in the migration's VERIFY.

**`ops.calendar_day_markers`**: 8 columns (11 since 2026-09-21, see the block above): `id`, `marker_date` (date), `marker_type`
(`start` / `end` / `dump`), `minutes` (smallint, **minutes past ET midnight, the exact minute, not a
snapped slot**), `dump_site` (text, required iff `marker_type='dump'`), `vehicle_id` (bigint,
**nullable and NULL is a supported value meaning "whole day, no truck"**), `created_at`, `updated_at`.

Uniqueness is per **(marker_date, vehicle_id, marker_type)** with `NULLS NOT DISTINCT`, so the
whole-day marker is its own slot alongside each truck's. The app **deletes then inserts** on a
re-drop, which is why an id is never reused and the sequence runs ahead of the row count.

**No audit trigger.** Deliberate (it is dispatch state, not business data), and it means
`audit.logs` silence proves nothing about whether the table is used. Same for `ops.route_leg_cache`
and `ops.dispatch_routing_usage`. 🛑 **Do not revoke the `authenticated` grants as "unused".**

**`trg_push_marker_to_jobber` → `public.fn_request_marker_push`** — the only trigger on the table.
It `pg_net`-POSTs to the `jobber-push-task` edge function. It is on the **TABLE** on purpose, so a
script or a future app is covered, not just the Calendar. **The app must never call the edge function
itself.** Escape hatch: `set local app.suppress_marker_push = 'on'`. ⚠ Since 2026-09-24 (phase 2) that
keeps an EDIT away from Jobber for good (it is not stamped in `push_changed_at`, so `start-push-retry`
never re-sends it), but a suppressed DELETE of a marker that has a Jobber link leaves the link behind,
and the retry then deletes that Task 2 to 7 minutes later. A backfill that must delete markers without
touching Jobber has to remove their links in the same transaction.

**`entity_source_links`** — `entity_type = 'calendar_day_marker'`, `entity_id` = the marker id,
`source_id` = the Jobber Task GID, `source_name` = the Task title. **This row is the only thing that
decides create-vs-edit**; there is no `jobber_task_id` column (rule #1). `entity_type` carries a CHECK
whitelist, so this value needed its own migration.

---

## What the points actually compute (measured 2026-08-17, not inferred)

This is the half Fred asked about and the half that was least written down.

A Start or End marker triggers a **live, traffic-aware routing call** and caches the leg in
`ops.route_leg_cache` (keyed on origin/dest lat/lng **rounded to 2 decimals**), counting the spend in
`ops.dispatch_routing_usage`. The depot is `ops.v_depot` (Doral Yard, property 80).

| marker | leg computed | rendered on the chip |
|---|---|---|
| **Start** | depot → **first** stop of that truck-day | `Doral Yard, 17 min to first stop` |
| **End** | **last** stop of that truck-day → depot | `20 min back to Doral Yard` |

Measured on truck **David**, 2026-08-17, whose only stop was 077-TCE at 20:30 ET:

```
route_leg_cache  25.82,-80.34 -> 25.69,-80.31   11.4 mi   17 min   traffic_aware
route_leg_cache  25.69,-80.31 -> 25.82,-80.34   11.2 mi   20 min   traffic_aware
dispatch_routing_usage  2026-08-17  calls 2
```
Cache went **8 → 10 rows**; neither pair was cached beforehand, so both were real calls, not replays.

⚠ **"Calculates the day's route" means the two DEPOT legs, not a leg-by-leg optimisation of the
stops.** The markers bracket the day and price the drive in and out of it. There is no inter-stop
routing today and nothing here reorders the stops.

⚠ **A null drive time renders nothing, never an estimate.** So a blank is "not computed", which is
different from "zero".

⚠ **The week/day header's drive-hours figure is a DIFFERENT metric and the markers do not feed it.**
It still read `-` for Monday with both legs computed and cached. Not a defect of this feature; noted
so nobody uses that number to check whether the markers worked.

---

## Dump markers — the third type, and the only one that writes a VISIT

Smoke-tested 2026-08-17 on truck David, site Homestead, alongside the Start/End test above.

A Dump marker does everything a Start/End marker does **and** calls `public.create_dump_visit`
(client/job/property ids read from `ops.v_dump_sites`, service line item **28**). Order is
**marker row first, visit second** — the reverse leaves a real Dump Offload visit with nothing on
the calendar.

**`dump_site` must be the decorated `marker_value`, never the bare `label`.** The table's CHECK is
`dump_site = ANY (ARRAY['Homestead (000-DH)','Pompano (000-DP)'])`; writing `Homestead` fails `23514`.
Measured value written: `Homestead (000-DH)`.

### 🛑 The created visit is deliberately INERT to Jobber — and that is the assertion to test

The app passes `p_push_to_jobber = false`. `create_dump_visit` then suppresses the push for the
transaction **and** stamps the row `source = 'manual'`, `sync_state = 'confirmed'`, which makes it
permanently invisible to the trigger, the cron and the push gate. Measured on visit 7772:

| check | result |
|---|---|
| `source` / `sync_state` | `manual` / `confirmed` ✅ |
| `entity_source_links` rows of `entity_type='visit'` for it | **0** ✅ |
| Jobber's Mon 17 visit count, before and after | **2 → 2**, unchanged ✅ |
| the marker's Jobber **Task** | created, assigned to Grecia ✅ |

⇒ **The marker reaches Jobber; the visit deliberately does not.** If you ever see a dump visit in
Jobber that came from this path, something has changed — check `p_push_to_jobber` first.

### Third leg type: last stop → dump site

Start computes depot→first, End computes last→depot, and **Dump computes last stop → the dump site**.
Measured: `25.69,-80.31` (077-TCE Kendall) → `25.55,-80.34` (Homestead), **16.1 mi / 25 min**,
traffic-aware. The chip renders `25 min in from The carrot express Kendall`.

### `dump_site_status` warns on after-hours arrivals, with the callout number

Placing the marker at 22:30 produced, on the chip:
`Homestead is after hours (last intake 22:00 ET) · 786-268-5623`. Real, useful, and it means a
late-evening dump time is a supported case rather than a mistake to prevent.

### ✅ FIXED 2026-08-17 — `dump_visit_id` + `trg_zz_dump_visit_cleanup`

Both defects below were fixed the same day (Fred: *"fix the vehicle_id and make marker delete remove
the orphan visit"*). **The two paragraphs after this one are the PRE-FIX record — keep them, they
explain why the column and the trigger exist.**

`ops.calendar_day_markers` gained **`dump_visit_id bigint`** (FK → `public.visits(id)`,
`ON DELETE SET NULL`), written by the app when it places a Dump marker. An AFTER DELETE trigger
**`trg_zz_dump_visit_cleanup`** → `ops.fn_cleanup_dump_visit_on_marker_delete()` soft-deletes that
visit when the marker goes.

🛑 **The guard is the whole point, and it fails SAFE.** It soft-deletes only when the linked visit is
`visit_status='scheduled'` **and** `source='manual'` **and** `deleted_at IS NULL`. A completed dump is
a real business record and is left alone; anything Jobber-sourced is out of scope by construction; a
second delete is a no-op rather than an error. Every excluded case leaves the visit **alive** — the
failure direction is "an orphan survives", never "a real record was destroyed".

**Why a stored link and not a match on (date, site, minute):** two trucks may legally dump at the same
site in the same minute (the unique index on this table covers only start/end markers), so a
heuristic's failure mode is deleting *the other truck's* visit. The id makes that impossible.

⚠ **It does NOT call `public.delete_calendar_visit`** — that function RAISES when it finds no
undeleted row, and "correctly do nothing" must not abort the user's marker delete.

⚠ **It is SECURITY DEFINER on purpose.** `authenticated` cannot write the visit lifecycle directly
(Phase 3), which is exactly why the cleanup cannot live in the app; the guard above is the control on
that widening.

⚠ **A dump marker placed BEFORE 2026-08-17 has `dump_visit_id = NULL`**, so the trigger no-ops and its
visit must be cleaned up by hand. There were **0** markers in existence when the column was added, so
in practice there is no backlog — but do not assume a NULL link means "no visit was created".

✅ Migration: `docs/migrations/2026-08-17_1200_dump_marker_visit_link_and_cleanup.sql`. Verified by a
6-case guard matrix in a rolled-back probe **plus a positive control** (the trigger dropped, case A
re-run, visit survives) — without that control the 6 passes would be an untested instrument.

### ⚠ Deleting the marker used to leave the visit behind. FIXED 2026-08-17 (`d3ad027`)

> 🛑 **The heading below is the SMOKE-TEST FINDING, not current behaviour.** Removing a
> marker now also removes the visit it created: `2026-08-17_1200_dump_marker_visit_link_and_cleanup.sql`
> links the marker to its visit and cleans it up on delete. The measurement that follows is kept
> because it is the record of the defect, and because the reasoning about what "defensible"
> would have meant is still worth reading. Do not read it as a description of today.

Measured: removing the marker deleted the marker row, the `entity_source_links` row and the Jobber
Task (`verified_gone: true`) — and left `public.visits` row 7772 alive and `scheduled`. Defensible
(the visit is a business record, the marker is a calendar pin), but it means **a mis-placed Dump
marker leaves an orphan Dump Offload visit behind**, and under a truck filter there is nothing on the
board to reveal it (see the next item). Clean up with `public.delete_calendar_visit(<id>)`, which
soft-deletes.

### ✅ FIXED 2026-08-17 — the app now sends the truck

The app calls `create_dump_visit` with **`p_vehicle_id: e.vehicleId ?? null`** (the marker's own
truck). **Keep the `?? null`** — a whole-day marker has no truck and that is a supported value.

Proven on the DB *before* the app was touched, so the edit was made against a known-good chain:
`p_vehicle_id => 3` reaches `visits.vehicle_id = 3`, `null` stays null, inertness contract intact.
Verified live afterwards on the side that used to hide it: with the **David** filter Monday went
`1 visit` → **`2 visits`** and the dump renders with a **`D`** badge instead of `–`.

⚠ **The pre-fix write-up below is kept deliberately** — it is the trap, not just history.

### 🛑 (PRE-FIX RECORD) THE APP HARDCODED `p_vehicle_id: null`, SO A DUMP VISIT NEVER CARRIED ITS TRUCK

Read straight out of the live bundle (`/assets/index-*.js`, 3-chunk recursive walk):

```js
Ht.rpc("create_dump_visit",{ p_client_id:…, p_job_id:…, p_property_id:…,
  p_service_line_item_ids:[28], p_visit_date:…, p_start_at:…, p_end_at:…,
  p_title:`Dump Offload - ${e.site.label}`, p_notes:null,
  p_driver_id:null, p_team_ids:null, p_vehicle_id:null, p_push_to_jobber:!1 })
```

The DB function is fine — it forwards `p_vehicle_id` positionally as `create_calendar_visit`'s 11th
argument, and its own comment says the hardcoded NULL was *"fixed 2026-07-27"*. **That fix landed on
the DB side only.** The app has never sent a vehicle, so the marker knows it is David's dump and the
visit it creates cannot.

**Measured consequence, both sides of the partition:**

| truck filter | Monday header | the dump visit |
|---|---|---|
| **David** | `1 visit` | **not rendered** |
| **All trucks** | `3 visits` | rendered, truck badge shows **`–`** |

⇒ A dump visit is invisible on the very truck board it was created from. ⚠ Five older app-created
dump visits (7059, 7123, 7280, 7580, 7682) *do* carry a truck; I did not chase how they got it, and
this path cannot be the explanation. Do not read those rows as evidence the app sets it.

### ⚠ The marker's "Remove marker" × versus the visit chip — and how fix 1 made it worse

The × is `opacity: 0` (hover-reveal) and the created dump visit chip is absolutely positioned at
`z-index: 10` over the marker's top-right corner, so a click at the ×'s exact centre lands on the
visit chip. Before fix 1 this only bit at "All trucks" — a truck filter hid the visit, so the × was
clear. **The two defects were cancelling each other out.**

🛑 **Fix 1 removed that accident.** Once the dump visit carried its truck it rendered in the same
filtered column as its marker, so the overlap became permanent: measured **60 of 64 sampled points
inside the 16×16 button returned the visit chip**, leaving a 2px strip. Raised in the same session —
an unreachable delete control would defeat the cleanup fix entirely.

⇒ **Worth carrying: fixing one of two interacting defects can expose the other.** Nothing about the
× changed; what changed is that the thing covering it started always being there.

## What reaches Jobber

`jobber-push-task` creates a Jobber **Task** (not an Event, not a Visit — see its header for why):

- **Title** `Day Start (<Driver>)` / `Day End (<Driver>)` / `Dump - <site> (<Driver>)` (the owner in
  parentheses is the driver since 2026-09-16, the truck on the legacy rows; measured 2026-08-17 as
  `Dump - Homestead (000-DH) (David)`, site before owner)
- **Description** `Route marker from the UnclogMe Visit Calendar. Edit it there, not here.`
- **Window** the marker minute, +30 minutes
- **`assignedTo`** — since 2026-09-16 the marker's own driver (`employee_id`, see the box at the top;
  the rules in this bullet are the LEGACY truck rows'); resolved from `ops.v_calendar_visit.driver_id` for that **(vehicle, date)**,
  mapped to Jobber user ids through `entity_source_links` (`entity_type='employee'`).
  🛑 **It is a LIST and it is often more than one person; it is also often NOBODY, which is normal**
  for a marker placed ahead of the crew being assigned. An empty result sends **no** `assignedTo` key
  at all, because sending `[]` on an edit would strip an assignment a dispatcher set by hand.

Measured the same day: both Tasks landed assigned to **Grecia**, who is the driver on truck David for
2026-08-17. Deleting each marker returned `{"op":"delete","verified_gone":true}` and both disappeared
from the Jobber schedule.

### ✅ FIXED 2026-09-23 (v16): a lookup that FAILS stops the push; it is never read as "nobody"

Until v15, `assigneeForEmployee` returned `[]` both when the driver has no Jobber link (legitimate:
push the Task unassigned) and when the link lookup itself ERRORED. On an edit of a driver-model row
`assignedSent` is true whenever a link exists, so `assignedTo: []` went to Jobber and **stripped the
driver from their Day Start**, and the read-back passed because it compares against the same `[]`.
Any transient database error during a drag or a Recompute could do it, silently, with `ok:true`.
The truck-name and driver-name lookups had the same shape: an error silently retitled the Task
(e.g. `Day Start (Grecia)` with the truck missing).

Now all four lookups (truck name, driver name, the driver's link, the legacy truck's crew) return
`null` on an error, and the handler answers `{ok:false, error:"<what> lookup failed; nothing pushed,
Task and link untouched"}` without calling Jobber. A missing link still pushes unassigned, as before.
⚠ Until 2026-09-24 nothing retried a failed push. Since phase 2, `start-push-retry` re-sends a failed
edit or delete (never a create); see the phase-2 block at the top.
Proof: `node scripts/probes/push_task_assignee_guard_test.mjs` extracts the helper from the working
tree AND from `fb9f761` (the pre-fix body) and requires the old one to FAIL the error case. Live
happy path on v16: marker 121 re-pushed, `{"ok":true,"op":"edit","assigned":["Grecia "]}`, Task
unchanged. Found by the adversarial audit of `Building Apps/Visit Calendar/docs/specs/2026-09-23-start-freshness-design.md` (§7.1).

### ✅ HARDENED 2026-09-24 (v18, Supabase `589c7c1`): three holes an automatic healer would hit

Found by the read-only investigation for Start freshness phase 2, fixed before any healing existed:
- **The link read ignored its error.** A failed read was taken as "no link", so an upsert ran
  `taskCreate` a second time and the link upsert orphaned the first Task. It now stops the push
  (`lookupFailed`), like the other lookups since v16.
- **A delete returned on any `taskDelete` error BEFORE reading the Task back**, so deleting a Task that was
  already gone wedged every retry for ever. It now reads back whatever the mutation said (the
  `deleteAndVerify` shape from `save-calendar-task`) and treats "errored but absent" as done
  (`already_gone: true`).
- **The link removal after a verified delete ignored its error** and still reported `verified_gone`. It
  now returns `{ok:false, task_gone:true, error:"the task is gone in Jobber but the link could not be
  removed: ..."}`.
A failed `taskEdit` also reports `task_gone`, so a Task deleted by hand in Jobber can be told from a
transient refusal. Live on v18: marker 121 re-pushed through the real trigger path, `ok:true` edit, same
Task, same time and driver.

---

## Verifying a push — the traps

- **`pg_net` is fire-and-forget.** The push result is in **`net._http_response`**, NOT in
  `cron.job_run_details` and not in the transaction that wrote the marker. Read the `content` column:
  a successful create looks like
  `{"ok":true,"op":"create","task":"<gid>","title":"Day Start (David)","startAt":"...","assigned":["Grecia"],"assigned_count":1}`.
- **A Jobber deletion check needs a control.** Assert the page LOADED and that **other** tasks and
  visits still render — an empty schedule looks identical to a successful delete.
- **A re-drop is a delete + insert**, so the Task GID changes. Do not treat a new GID as a duplicate.
- **Jobber can shed load with an HTML "waiting room" at HTTP 200.** `jobber-push-task` is one of the
  three functions that already inspects the response content-type; do not remove that check.

## The UI surface — **Week view only**

Measured 2026-08-17 with a positive control (the same detector returns `true` in Week view):

| view | DAY START/END POINTS card |
|---|---|
| Month | **absent** |
| Week | **present** |
| Day | **absent** |

So a reader told "drop a Day Start marker" who is sitting in Day view will not find the control. This
is behaviour, not a bug report — recorded because nothing said it anywhere.
