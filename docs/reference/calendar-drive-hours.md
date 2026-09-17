# Calendar "Hours driven": yard to visits to yard, timed by Google, per truck per day

*Shipped 2026-09-17 (migrations `2026-09-17_1830`, `_1835`, `_1850`; edge function `plan-drive-fill`;
cron `plan-drive-warm`). App side: `Building Apps/Visit Calendar/docs/08-changelog.md` 2026-09-17 (e)
and its CLAUDE.md rule 8 day-header bullet.*

Fred, 2026-09-17: *"the logic for it, is to use the Google API to have a time it takes coming out of the
YARD, up to the 1st visit, from the 1st visit to the 2nd visit, and so on and so forth, up to the last
visit then to YARD back again, all on the same day at the calendar."* And: *"No need to use Samsara for
that today ... we need to use Google API for knowing how much time we will drive that day for future
visits and so on."*

## What it replaced

The Calendar's day header computed the number in the browser: the day's COMPLETED visits sorted by
start, summing `next.start_at - previous.completed_at` capped at 120 minutes per gap, all trucks mixed
into one chain, no yard, no map. On 2026-09-16 that read **2.0 h**; the route was **6.8 h**.

## The objects, in the order a read goes through them

| object | role |
|---|---|
| `ops.fn_drive_chain(p_from, p_to)` | THE chain builder. Per (visit_date, grain `truck` or `driver`, group) it emits a header row (`seq 0`) and one row per leg (`seq 1..n`): yard, the stops in order, yard. INVOKER, service_role only. |
| `ops.route_leg_cache` | the leg cache shared with `calculate-driving-time`. The planner reads and writes only `traffic_aware = false` rows and uses the new `duration_seconds` column (falls back to `duration_minutes * 60` on rows the sibling wrote). Cells are `round(lat, 2)` / `round(lng, 2)`, computed in SQL only. 30-day retention. |
| `ops.route_leg_fail` | pairs Google refused (`no_route` / `bad_request`). Blocked after 3 failures for 7 days / 24 hours. A success deletes the row. |
| `ops.calendar_drive_days(p_from, p_to)` | THE read the app makes (SECURITY DEFINER, `authenticated` + `service_role`). One row per chain: `drive_seconds` (NULL unless EVERY leg is known), `complete`, `pending`, `blocked_reason`, the `chain` for the tooltip, `visit_ids`. |
| `ops.fn_drive_missing_pairs(p_from, p_to)` | the miss detector: distinct cell pairs with no fresh cache row and no active block. service_role only. |
| `ops.request_drive_fill(p_from, p_to, p_retry_failed)` | the Calendar's kick (SECURITY DEFINER): throttled 10 s globally and 30 s per intersecting range, refuses while a run is in flight, posts to the edge function with the vault key, never raises on the browser path. `p_retry_failed` clears the ledger for the range first (the Refresh drive times button). |
| `public.fn_request_plan_drive_fill()` | the cron wrapper (postgres only): today -7 .. +21 ET, limit 240. |
| cron `plan-drive-warm` | `15 9 * * *` (05:15 EDT / 04:15 EST), after `vehicle-gps-reconcile-nightly` (07:05 UTC). |
| edge fn `plan-drive-fill` | buys the missing legs. `verify_jwt = true` AND `role = service_role` in the handler. Single flight through `ops.plan_fill_run`; budget through `ops.plan_routing_take_tokens` (cap `ops.plan_routing_cap()` = 300 attempts per ET day, a third fail-closed bucket, never shared with the day markers' or the DUMP app's). One `public.sync_log` row per run (`sync_source = 'plan-drive-fill'`). |
| `supabase/functions/_shared/google-routes.ts` | one Routes v2 leg, classified: `key_rejected` / `quota` / `transient` stop the run and ledger nothing; `no_route` / `bad_request` ledger the pair, but only when the run also saw a success. TRAFFIC_UNAWARE; `duration` must equal `staticDuration` (a mismatch counts as `sku_mismatch`, `attention`). |
| `ops.plan_routing_usage`, `ops.plan_fill_request`, `ops.plan_fill_run` | the spend counter, the kick throttle, the single-flight latch. All four new tables are audit OPT-OUT (derived, transient). |

## The rules encoded in `fn_drive_chain`

- **Stops** = visits with `visit_status in (scheduled, completed)`; skipped and cancelled never drive.
  On a PAST day a stop that was never completed is left out and counted (`not_completed_stops`), so a
  past-day number is what was driven. Today and the future route the plan.
- **Order** = `completed_at` when completed, else `start_at` when timed; untimed (all-day) stops are
  appended after the timed ones by nearest neighbour from the previous stop (from the yard when there
  is none), ties by id. `ordered_by` = `measured` | `scheduled` | `assumed`.
- **Yard return**: two consecutive COMPLETED stops more than 4 hours apart split the chain with a trip
  back to the yard (`yard_returns` lists them). A return adds ONE leg: the trip back; the trip out
  replaces the direct leg. So `legs = stops + 1 + yard_returns`, which the migration's VERIFY asserts.
- **Truck** = `ops.v_calendar_visit.vehicle_id`, the EFFECTIVE truck (assigned, else the service-type
  default; `vehicle_source` says which and `default_stops` counts the defaults). A visit with no truck
  at all lands on a `No truck` row (`grain = 'truck'`, `group_id NULL`, no legs). `grain = 'driver'`
  chains the same visits per `driver_id` for the Day view lanes.
- **Dump Offload visits are ordinary stops**; a stop without coordinates is dropped and counted
  (`stops_without_location`), never estimated; a leg over 250 km great-circle is `implausible`, never
  bought, never printed.
- **The day value is a sum only when every leg is known** (`bool_and` guard). NULL renders `-` in the
  app with a plain sentence. A plain `sum(seconds)` would print a partial figure as X.Xh.

## `blocked_reason`, first match wins

`no_depot` (no `ops.v_depot` row) → `implausible` (a leg over 250 km or a cached leg over 300 min) →
`failed` (a missing leg's pair is blocked in the ledger; `blocked_code` / `blocked_from_code` carry the
client codes or the word `yard`) → `key_rejected` / `quota` / `outage` / `no_key` (the latest
`plan-drive-fill` sync_log row within 24 h says so) → `budget` (today's usage at the cap) → `stalled`
(a kick older than 120 s with no run after it, or the latest run errored) → NULL. `pending` is true
only when a leg is simply not fetched yet and nothing above applies: it is the ONLY condition the app
polls or kicks on.

## Measured at ship (2026-09-17 18:41 ET)

- First warm-up run: 146 pairs needed over today -7 .. +21, **146 routed in 10.6 s, 0 failed, 0
  duration/staticDuration mismatches**, budget 146 of 300, cache 29 → 175 rows. Re-run: 0 needed
  (idempotent). Reader over the window: 56 chains, all complete, 53 with hours (3 are legless).
- Control day 2026-09-16 (all stops completed, `ordered_by = measured`): **Moises** yard → 000-DH
  (34 min) → back to the yard (the 5-hour gap) → 290-PER (31) → 071-TCE (24) → 099-PV (8) → 068-TCE
  (20) → 032-LG (18) → 052-PV (9) → 249-LOU (7) → yard (26) = **210 min**; **Cloggy** 235-LOU (83) →
  328-SEB (78) → 332-MCM (11) → yard (27) = **199 min**; day **6.8 h** (old formula: 2.0 h).
- Week Sep 13 to 19 by truck: Sun none; Mon Cloggy 62 + Moises 127; Tue Cloggy 92 + Moises 84; Wed
  Cloggy 199 + Moises 210; Thu Cloggy 155 + Moises 133; Fri Cloggy 227 + Moises 132; Sat Moises 77.

## Cost

TRAFFIC_UNAWARE is the Essentials SKU: 10,000 free calls a month, then $5 per 1,000. A cold month is
about 146 calls and steady state re-buys the window's pairs once every 30 days. The cap of 300 attempts
per ET day bounds the worst case at $1.50 (Essentials) or $3.00 if someone flips the routing preference
to TRAFFIC_AWARE (Pro rate; re-derive from $0.01 per call before changing it).

## Traps, so they are not re-learned

- **Cells are computed in SQL only.** `plan-drive-fill` upserts the four cells exactly as
  `fn_drive_missing_pairs` returned them. JS `toFixed(2)` on a binary double and Postgres
  `round(numeric, 2)` disagree at `.xx5`, and a pair written under a key the reader never joins on is
  bought on every run for ever.
- **`pending` must never be NULL** (`_1850`): before the first run there is no sync_log row, and a chain
  with no legs has a `bool_or` over one NULL. Both are coalesced. The app polls on `pending === true`.
- **`fn_drive_chain` is plpgsql and reads `ops.v_calendar_visit` by column name at call time**
  (`id, visit_date, visit_status, start_at, completed_at, is_all_day, latitude, longitude, vehicle_id,
  vehicle_source, driver_id, client_code, truck_name, truck_color, driver_name, driver_color`). A rename
  there is not dependency-tracked; it surfaces as a `plan-drive-fill` sync_log row with status `error`
  and `rpc_error` in details, never as a quiet `routed 0`.
- **Supabase's default ACL on `ops` hands `authenticated` SELECT to every new table.** The migration
  revokes by name and reads `relacl` back; do the same for any table added beside these.
- **Google DRIVE routing is passenger-car routing.** A vacuum truck on weight-restricted roads runs
  longer; the figure is Google's and is never adjusted with a factor.
- `calculate-driving-time` (the DUMP ETA and the day markers) is NOT ported onto the shared module and
  is not redeployed by this change; porting it is a behaviour change on its error path and its own
  later task.
