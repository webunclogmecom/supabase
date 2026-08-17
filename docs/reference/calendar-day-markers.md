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

**`ops.calendar_day_markers`** — 8 columns: `id`, `marker_date` (date), `marker_type`
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
itself.** Escape hatch: `set local app.suppress_marker_push = 'on'`.

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

## What reaches Jobber

`jobber-push-task` creates a Jobber **Task** (not an Event, not a Visit — see its header for why):

- **Title** `Day Start (<Truck>)` / `Day End (<Truck>)` / `Dump (<Truck>) - <site>`
- **Description** `Route marker from the UnclogMe Visit Calendar. Edit it there, not here.`
- **Window** the marker minute, +30 minutes
- **`assignedTo`** — resolved from `ops.v_calendar_visit.driver_id` for that **(vehicle, date)**,
  mapped to Jobber user ids through `entity_source_links` (`entity_type='employee'`).
  🛑 **It is a LIST and it is often more than one person; it is also often NOBODY, which is normal**
  for a marker placed ahead of the crew being assigned. An empty result sends **no** `assignedTo` key
  at all, because sending `[]` on an edit would strip an assignment a dispatcher set by hand.

Measured the same day: both Tasks landed assigned to **Grecia**, who is the driver on truck David for
2026-08-17. Deleting each marker returned `{"op":"delete","verified_gone":true}` and both disappeared
from the Jobber schedule.

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
