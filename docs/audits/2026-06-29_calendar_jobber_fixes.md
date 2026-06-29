# Calendar / Jobber fixes — 2026-06-29

Four tasks from Fred's day list. Investigated (read-only, 4-agent fan-out) → planned → executed one by one. **Guardrail (Fred): only touch PENDING visits — never completed.** Verified via `audit.logs`: 670 title + 30 ripple changes were all `scheduled`; 0 completed touched. See [[feedback_only_touch_pending_visits]].

## Task 4 — `service_kind` mislabels (line-item-code class)  ✅
`ops.v_calendar_visit.service_kind` ignored line-item codes, so 11 visits with generic job titles fell through to `SC` while carrying real SA items (01/02/04). Added a code tiebreaker **after** the title regex, **before** the frequency fallback (narrow rule): SA-codes-only → SA, SC-codes-only → SC. 11 fixed; visit 5830 (job literally "Service Call" + an SA item) left SC for office review. Migration `2026-06-29_calendar_view_servicekind_frequency.sql`.
> NOTE: superseded in scope by the queued **frequency-based** service_kind task (below) — that rule is broader (~562 visits) and Fred-confirmed.

## Task 2 — frequency / next-visit cascade  ✅
Two distinct defects:
- **View mislabel (5 series):** the view computed `frequency_days` from service-config/median, not the job's Frequency field, so Maison Ostrow etc. only *looked* mis-spaced. Fixed: `COALESCE(NULLIF(jb.frequency_days,0), sc.frequency_days, oc.median_gap_days)` (job wins; `NULLIF(,0)` so one-off jobs' `0` falls through — without it 225 rows wrongly collapsed to 0). 95 rows corrected (147-OST 56→60, 083-SHUL 45→30, 099-PV 60→90, 195-MYK 60→30, 70 null-freq filled). Same migration as Task 4.
- **Real drawer bug (6 of 7 series):** a drawer date-move didn't cascade the downstream chain (drag-n-drop does). Re-spaced 017-FIA/019-G7/025-GRO/042-MT/051-PV/127-PC via `public.ripple_reschedule_visit` (called on the first downstream visit at anchor+freq). All gaps now exact; in-scope visits pushed to Jobber cleanly, 0 errors. Migration `2026-06-29b_respace_sa_series_backfill.sql`.
- **214-MYK left as-is** (Fred): its only off-gap is a missing weekly slot ~5 months out (Dec 10) in the auto-generated projection — a non-issue, and rippling would pull visits earlier / end the series a week early.
- Clarification: the named "G7 Kitchen 35" is **215-G7** ("Kitchen 35" — no "G7" in the name); it's healthy (freq 30, clean downstream). 186-PV was a false alarm (a CL visit beside the GT chain).

## Task 3 — Jobber chip titles (client prefix)  ✅
Generated SA visits used `title = bare job.title`, so Jobber showed a generic chip (vs native visits' "Client - Job"). Generator now emits `${client_code} ${client_name} - ${job.title}` (dedup is by date, not title — safe). Backfilled 670 future scheduled visits (442 out-of-scope DB-only + 228 in-scope paced → live Jobber relabel, **verified 5/5 in Jobber**). Migration `2026-06-29c_visit_title_client_prefix.sql`.

## Task 1 + 2-drawer-cascade — Calendar app (Lovable `6533c3ee`, calendar.unclogme.app)  ✅ PUBLISHED
Shipped + published 2026-06-29. The Calendar app code lives in its own Lovable repo (not here); recorded for cross-reference:
1. **Truck badge on chips:** added a `TruckBadge` (slate-700 rounded square, distinct from the colorful round `DriverAvatar`) on all four chip variants, showing the truck initial from `ops.v_calendar_visit.truck_name` (Moises→M, Cloggy→C, David→D); hidden when `truck_name` is empty. The existing `refetch()` invalidates `v_calendar_visit` on save, so both the driver avatar and truck badge re-read live (the "not dynamic" fix). Truck is sourced from the line-item-code → `service_line_items.default_vehicle_id` map (already populated for ~610/680 future visits) — NOT GPS. Team-member is assigned on only ~21/680, so driver avatars stay sparse until the office assigns at scheduling (flagged).
2. **Drawer date cascade:** the drawer's `saveMutation` now calls `public.ripple_reschedule_visit` when `visit_date` changes (passing new start/end only when the time also changed), then strips date/time keys before the remaining `edit_calendar_visit` patch. So a drawer date-move now re-spaces the forward SA chain exactly like drag-n-drop. **The `ripple_reschedule_visit` RPC (2026-06-25) is no longer "inert" — it is now wired into the drawer.** Behavior change to flag to the office: moving one visit's date in the drawer now shifts its later same-job visits.

> Couldn't safely test a real drawer date-move (it mutates a real client's schedule + pushes to Jobber). The RPC itself is proven (used for the Task 2 backfill); the drawer wiring should be confirmed on the office's next date-edit. One-click revert in Lovable if needed.

## Committed
`243c017` on `main`: generator + the 3 DB migrations. Calendar-app changes are in the Lovable repo. This audit doc + the frequency-based service_kind task remain.

## STILL PENDING
- **Frequency-based `service_kind` rule** (Fred-queued): `SA = frequency_days > 0, else SC` — broader (~562) than Task 4's code rule. Reconcile: is `service_kind` a stored column or view-only (scout: view-only)? does the pure-frequency rule override the 11 code-based SA's (they have no job frequency → would flip back to SC)? The Calendar app already derives SA/SC from `frequency_days` client-side as an interim.
