# Driver & Truck Attribution Lag — Root Cause + Fix (2026-07-14)

*Building-Apps-routed (Fred). Admin Review's "Daily Job Review Queue" showed recent visits as
"Unassigned / Not recorded." Coverage had degraded for RECENT visits: **driver** 90% all-time → 53% (28d)
→ 24% (7d); **truck** 88% → 60% → 48%. Investigated root-cause-first (systematic-debugging), fixed the
driver side end-to-end, diagnosed the truck side as an upstream Samsara issue.*

## TL;DR

**Two distinct causes wearing one costume.** All three crons are deployed, green, and completing — nothing
stalled. **Driver** was a webhook bug (a DB-mastered early-return skips the `visit_assignments` upsert) —
fully fixed (backfill + durable trigger). **Truck** is telemetry-starved upstream (Samsara GPS volume
~halved) — not fixable in the DB lane; escalated.

## Investigation

- Crons: `samsara-poll` (*/10), `samsara-locations-history` (*/15), `derive-visit-vehicle-id` (hourly :17,
  7-day lookback) — all succeeding, completing in 2–4 min. The KI#11c "90 minutes" is the *lookback window*,
  not the cadence. **Not a stall.**
- The driver drop is a **cliff** (100% through 06-15 → 31% by 06-29); truck is a **gradual decline** →
  different causes.

## Root cause 1 — DRIVER: webhook early-return, NOT GPS

`public.visit_assignments` (feeds the Calendar driver avatar + Admin Review "Driver") is populated from
**Jobber `assignedUsers`** by `webhook-jobber/index.ts` handleVisit (~L839; comment L648 "Driver attribution
lives in visit_assignments via assignedUsers") — **not Samsara GPS** (correcting the prior team assumption).
The only writers are the webhook + `backfill_visit_assignments_from_jobber.js`; it is **96% identical** to
`visit_team` (718/751 visits-with-both have the same crew).

On **2026-06-27** a "Stage 2" change added a DB-mastered early-return: for `source IN ('supabase_cron',
'visit-calendar')`, handleVisit calls `syncVisitTeamFromJobber` (→ `visit_team`) then **RETURNS at L712 —
before the L839 `visit_assignments` upsert**. So DB-generated visits get `visit_team` but blank
`visit_assignments`. As visit-gen moved DB-side, those visits became the majority of recent completions
(July: 46 `supabase_cron` + 24 `visit-calendar` vs 18 `jobber`) → the driver cliff. Source breakdown:
`jobber` driver 94–100%; **`supabase_cron` 0%**; `visit-calendar` 17%.

## Root cause 2 — TRUCK: telemetry sparsity (upstream Samsara)

`visits.vehicle_id` comes from `derive_visit_vehicle_id.js` (GPS proximity match, tiered 150/300/500 m within
the start→completed window). **Samsara GPS volume ~halved since May** (25k→13k `vehicle_telemetry_readings`/wk,
steady 3 vehicles; cron cadence unchanged */15 → Samsara returning fewer readings per truck-hour despite
stable visit counts). `derive --since=2026-06-15 --execute` matched only **4**, with **105/112 candidates
having NO telemetry in-window** → genuinely telemetry-limited, below ADR-012's ~77–90% floor. Secondary: the
derive cron's **7-day fixed lookback** ages out still-NULL visits (`selfheal_lookback` gap).

## Fixes shipped

| Fix | What | Result |
|---|---|---|
| **Driver backfill** | Copied `visit_team`→`visit_assignments` for 76 recent driverless (fill-empty; backup `backups/2026-07-14_visit_assignments_backfill_from_team.json`) | driver 7d **24%→100%**, 28d **53%→100%** |
| **Driver durable** | Trigger `trg_zz_mirror_team_to_assignments` (`2026-07-14_mirror_visit_team_to_assignments.sql`, commit `bc3c9d1`) — AFTER INSERT STATEMENT on `visit_team`, fill-empty mirror into `visit_assignments`. Path-independent (transition table; catches webhook, backfill, any writer), never overwrites. 5/5 rolled-back smoke. | New DB-gen visits auto-get a driver — cliff won't recur |
| **Truck backfill** | `derive --since=2026-06-15 --execute` re-attempted the aged-out window | +4 matched; truck 28d **60%→62%** (telemetry-limited ceiling) |

Independently corroborated by Building Apps post-fix: driver 98% (7d) / 99% (28d); Admin Review queue shows drivers again.

## Open items

- **⚠ Samsara GPS volume halved → console check** (Fred's action; outside the DB lane). Building Apps did the
  per-truck drill-down (`Building Apps/Admin Review/docs/samsara-telemetry-drop-2026-07-14.md`): **Moises ~32k→~9k/wk,
  Cloggy ~12k→~3–4k/wk, David chronically low/erratic** — but all 3 units are **ONLINE and reporting within hours**, so
  it's **not dead hardware** — it's a **frequency/plan change**. Top suspect for Fred: the Samsara **location-update-frequency
  setting**. This is the real truck ceiling; no DB/derive fix raises it.
- **derive 7-day lookback → self-healing** — retry still-NULL visits as late telemetry lands. Low value while
  telemetry is this sparse; **parked** until the feed is healthy.

## References

- Code: `supabase/functions/webhook-jobber/index.ts` L648 / L707–712 (early-return) / L839 (visit_assignments upsert);
  `scripts/sync/derive_visit_vehicle_id.js`; `scripts/sync/backfill_visit_assignments_from_jobber.js`;
  workflows `samsara-poll.yml` / `samsara-locations-history.yml` / `derive-visit-vehicle-id.yml`.
- Migration: `docs/migrations/2026-07-14_mirror_visit_team_to_assignments.sql`. Commit `bc3c9d1`.
- Memory corrected: `project_visit_crew_tables` (visit_assignments is Jobber-`assignedUsers`-sourced, not GPS).
