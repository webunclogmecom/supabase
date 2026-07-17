# Driver attribution + service taxonomy — audit & fix (2026-07-17)

*Triggered by Fred, from Yannick's TCE/PV Miami-Dade DERM export. Two reported issues; a third surfaced
during the "is this happening to others" sweep. Root-caused (systematic-debugging), cross-checked against
Jobber, remediated DB-wide, and verified. Plan was red-teamed by an independent agent before execution.*

## Reported

1. **Wrong driver** — 186-PV, Jun 30 (visit 5843) showed Driver **Aaron**; Jobber says only **Mark**;
   "Diego never put Aaron." → audit.
2. **Service shows "GT"/"CL"** — is that old Airtable data? The services we use now are the
   `service_line_items.service_kind` list (Pumping, Cleaning, Warranty of Drainage, Unclogging, Camera
   Inspection, Dye Test, Assessment, Labor, Parts, Labor BUS).

## ① Wrong driver — ROOT CAUSE + FIX

**Two compounding defects.**
- **Append-only vs replace.** `public.visit_team` is a DELETE+INSERT of Jobber's *current* `assignedUsers`
  (`webhook-jobber.syncVisitTeamFromJobber`, ~L514-531). `public.visit_assignments` — which every driver
  consumer reads (Calendar avatar, Admin Review "Driver", FP work orders, `ops.v_driver_kpi`,
  `ops.v_route_today`, exports) — was **upsert-only, "never deletes"** (handleVisit ~L851). So when
  186-PV's crew was corrected to just Mark, Aaron **fossilized** in `visit_assignments`.
- **min(employee_id) pick.** `ops.v_calendar_visit.first_assignment` picked
  `DISTINCT ON (visit_id) ... ORDER BY visit_id, employee_id` = the lowest id, so the stale ghost won
  (Aaron 26 < Mark 35; inactive Jeffry 25 / Grecia 1 beat everyone).

**Cross-check (Jobber API):** visit 5843 `assignedUsers` = only **Mark Noltion** — confirmed. `visit_team`
(the clean mirror) already = {Mark}; only `visit_assignments` carried the ghost.

**Blast radius:** 41 ghost rows across 36 visits (the ghost was *always* the min-id); 24 surfaced as the
view's driver (20 in last 45d, 6 pending).

**Fix (all DB, no app/webhook code change):**
- **One-time reconcile** `visit_assignments` == current `visit_team` for every team-backed visit: removed
  41 ghosts, added 27 missing current-crew rows → **0 mismatches**. Backup
  `backups/2026-07-17_visit_assignments_before_ghost_reconcile.json`.
- **Durable** `2026-07-17_reconcile_visit_assignments_to_team.sql`: changed
  `fn_mirror_visit_team_to_assignments` (trigger `trg_zz_mirror_team_to_assignments` on `visit_team`)
  from **FILL-EMPTY** to **FULL-SYNC** — on any crew write it makes `visit_assignments` exactly equal
  `visit_team`. Since handleVisit upserts assignments then re-syncs the team, the trigger reconciles away
  any ghost the upsert just added. Smoke-tested (rolled back): injected Aaron ghost on 5843, re-fired the
  team, `va` → {Mark}. Old body backed up `backups/2026-07-17_fn_mirror_visit_team_to_assignments_before.sql`.
- **Result:** 5843 → Mark #F43F5E; view driver-not-in-crew = 0. No view logic change needed for this part.

**Residual (documented):** if Jobber returns NO crew, `syncVisitTeamFromJobber` empties `visit_team` with
no INSERT, so the trigger doesn't fire and prior assignments are retained (keep-historical-driver) — rare,
intentional. One no-team cancelled visit (5801) is unreconcilable and left as-is.

## ② Service "GT"/"CL" — ROOT CAUSE + FIX

**Not Airtable.** `visits.service_type` (GT/CL/WD/LS) is our own **legacy coarse** classifier;
[ADR 018](../decisions/) already declares it unreliable (handleVisit defaults GT). The canonical taxonomy
is **`service_line_items.service_kind`** — exactly Fred's list. 5843 was even `service_type='CL'` while its
line items are codes 02+04 = **Pumping**.

- `visits.service_line_item_id` is unusable (83/1999 populated). Canonical derivation = `line_items.name`
  code-prefix → `service_line_items` (the pattern the view already uses), **visit-scoped first, then the
  job template** (`job_id, visit_id IS NULL, invoice_id IS NULL`). Coverage 1161/1591 live; on the DERM
  sheet, `derm_required` rows with no derivable line item are definitionally **Pumping**.

**Fix:**
- **Export** now derives Service from line items → all 25 DERM rows = **Pumping** (0 GT/CL).
- **DB** `2026-07-17_service_type_cl_to_gt_pure_pumping.sql`: corrected 9 pure-pumping visits `CL→GT`
  (incl. 5843). No Jobber push (service_type isn't a watched column); lateness re-bucketing verified as
  corrections only. **Flagged, not flipped** (ambiguous, Fred's call): 5854 (Lift Station → LS), 5127 /
  5125 (co-service), 6989 (one-off). The 281 GT-default visits with non-pumping lines are left as-is —
  service_type is deprecated; apps/reports should read line-item `service_kind`. Backup
  `backups/2026-07-17_service_type_CL_to_GT_before.json`.

## ③ "Ishad Knight" as driver — DISCOVERED in the sweep, RECOVERED

The sweep found **Ishad Knight** (employee 8, role=Office, **INACTIVE**) as Jobber's sole assignee on 39
recent visits (8 in the export). `employees.role` is unreliable (Grecia/Aaron/Diego are real drivers tagged
Office/Admin), so the signal is **status** — but "suppress all inactive" is wrong: 154 other inactive-driver
visits are *former field drivers* on historical visits (correct).

**Recovery (Fred: "recover the real driver"), via PRE/POST shift `inspections`** (the driver fills them AT
the truck, recording `vehicle_id + employee_id + shift_date`):
- **Ishad is a REAL former driver** — 55 inspections over a year, 3 trucks; he personally drove the Moises
  truck (vehicle 1) Jun 8-19 (his own inspections), then went inactive. His Jun 8-19 attributions are
  **correct**.
- **Jun 1-4 were actually Aaron** — the Moises inspections those days are Aaron (ACTIVE). **Donald Barron
  (also a Jobber name-tag on these) has 0 inspections ever — he never operated a truck.** So Aaron was the
  real Moises driver late-May..Jun-4; Jobber's Donald/Ishad tags didn't drive.

**Fix** `2026-07-17_calendar_effective_driver_inspection_fallback.sql`: the view's effective driver is now a
COALESCE ladder — (1) active Jobber-assigned crew (min id, the normal case, **unchanged** — 699 visits);
(2) when the crew has NO active member, the operator of the **GPS-confirmed truck** (`v.vehicle_id`) from
that day's inspection (same-day first, then active, then nearest date — recovers Aaron, and keeps a genuine
same-day former driver like Kevis); (3) any crew member; (4) `assigned_driver_id`. Conservative: no
line-item-default-vehicle guessing (visits with no GPS truck fall through to crew/NULL, not a false name).
Backup `backups/2026-07-17_v_calendar_visit_before_inspection_driver.sql`.

**Export result:** Aaron 8 (was 5), Ishad 5 (4 correct Jun 8-18 + **1**, 234-PV Jun 4, with no GPS truck to
recover so it shows its Jobber crew), Mark 6, Grecia 2, Anthony 4. 24/25 cleanly attributed.

## Consumers affected (all read-through the fixes; no app republish required)
`ops.v_calendar_visit` (Visit Calendar), `ops.v_driver_kpi` (attribution/revenue — ghost removal reduces
over-crediting), `ops.v_route_today`, `customer.work_orders` (Field Portal), Admin Review "Driver", and the
TCE/PV export.

## Verification (post-fix full audit)
- `visit_assignments` == `visit_team` for all team-backed visits: **0 mismatches**.
- FULL-SYNC trigger present + is delete+insert; smoke-tested rolled back.
- 9 service_type flipped, derm_required intact; 4 edge cases correctly left flagged.
- View: 0 real ghosts (active driver mismatching an active crew); the 25 "active-not-in-crew" are the
  intended inspection recoveries (all-inactive Jobber crew); common active-crew path (699) unchanged.
- 5843 → Mark / GT; export Service all Pumping, Driver 186-PV = Mark.

## Migrations / backups
- `docs/migrations/2026-07-17_reconcile_visit_assignments_to_team.sql`
- `docs/migrations/2026-07-17_service_type_cl_to_gt_pure_pumping.sql`
- `docs/migrations/2026-07-17_calendar_effective_driver_inspection_fallback.sql`
- backups: `2026-07-17_visit_assignments_before_ghost_reconcile.json`,
  `2026-07-17_fn_mirror_visit_team_to_assignments_before.sql`,
  `2026-07-17_service_type_CL_to_GT_before.json`,
  `2026-07-17_v_calendar_visit_before_inspection_driver.sql`

## Open for Fred
- **Ishad Knight / Donald Barron employee records**: both are marked role='Office'/'Technician' but the data
  shows Ishad was a real driver (now former) and Donald never drove. Consider correcting their roles.
- **234-PV Jun 4** (and 2 other no-GPS Jun-4 visits): real driver almost certainly Aaron but no GPS truck to
  prove it; shown as their Jobber crew. Could be resolved if `derive_visit_vehicle_id` later matches telemetry.
- **4 flagged service_type edge cases** (5854 Lift Station; 5127/5125/6989 co-service) — flip or leave?
- **service_type is deprecated** — recommend exposing line-item `service_kind` on `ops.v_calendar_visit` so
  apps stop showing GT/CL; separate task.
