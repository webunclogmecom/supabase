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
