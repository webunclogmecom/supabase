# Calendar / Jobber fixes — 2026-06-29

Four tasks from Fred's day list. Investigated (read-only, 4-agent fan-out) → planned → executed one by one. **Guardrail (Fred): only touch PENDING visits — never completed.** Verified via `audit.logs`: 670 title + 30 ripple changes were all `scheduled`; 0 completed touched. See [[feedback_only_touch_pending_visits]].

## Task 4 — `service_kind` mislabels (line-item-code class)  ✅
`ops.v_calendar_visit.service_kind` ignored line-item codes, so 11 visits with generic job titles fell through to `SC` while carrying real SA items (01/02/04). Added a code tiebreaker **after** the title regex, **before** the frequency fallback (narrow rule): SA-codes-only → SA, SC-codes-only → SC. 11 fixed; visit 5830 (job literally "Service Call" + an SA item) left SC for office review. Migration `2026-06-29_calendar_view_servicekind_frequency.sql`.
> NOTE: the code tiebreaker was **superseded same day** by Task 5 (below) — service_kind is now purely frequency-based per Fred's confirmed rule. Migration `2026-06-29d`.

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

## Task 5 — frequency-based `service_kind` (Fred-queued)  ✅
`service_kind` was mislabeling ~562 recurring visits as SC. Confirmed `service_kind` is **view-only** (no stored `public.visits.service_kind`; no writer sets it — visit-gen/handleVisit write `service_type`, not `service_kind`), so the fix is the view, not a backfill/writer. Replaced the derivation with Fred's pure rule: `service_kind = CASE WHEN COALESCE(NULLIF(jb.frequency_days,0), sc.frequency_days, oc.median_gap_days) > 0 THEN 'SA' ELSE 'SC' END` — the **same** frequency the view displays. Title regex + Task-4 code tiebreaker removed.
- **Used the displayed frequency, NOT `jobs.frequency_days` alone:** the 562 have `jobs.frequency_days=0/null` (the JOBS-poll sync gap — never fetches the Frequency customField) but a real sc/median cadence. Job-freq-only flips 0 of them; displayed-freq flips the 559 correctly.
- **Impact (verified):** all visits SA 733→1289 / SC 692→137 / nulls 1→0; completed SA 54→606 / SC 682→131. 559 SC→SA, 133 true one-offs stay SC, 4 SA→SC (line-item-SA but zero recurrence). 63 cols unchanged, 0 dependents.
- Migration `2026-06-29d_calendar_view_service_kind_frequency_based.sql`. The Calendar app's interim client-side `frequency_days` derivation now matches the backend (redundant, harmless). Not touched: `v_calendar_visit_detail.service_kind` (separate title-based field).
- **Root cause remains** the `jobs.frequency_days` sync gap (see [[reference_jobs_sync_gaps]]); this view rule is the pragmatic correction. A robust fix = make the JOBS poll fetch the Frequency customField, then key off `jobs.frequency_days`.

## All 5 tasks complete. Open follow-ups (not today): jobs.frequency_days sync-gap root fix; office to confirm the drawer cascade on first use + to start assigning drivers at scheduling (so chip person-avatars populate); visit 5830 SC/SA office review.
