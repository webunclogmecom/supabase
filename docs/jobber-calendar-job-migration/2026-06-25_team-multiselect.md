# Team multi-select (Driver → Team) — Calendar

*2026-06-25. Status: **SHIPPED + live-verified** on `calendar.unclogme.app`.*

## What changed

The Calendar's single **"Driver"** picker (New Visit form + visit drawer) became a
**"Team"** multi-select that is **optional** — a visit can have **0, 1, or many** crew
members, and the selection can be cleared back to empty. The team is pushed to the
Jobber visit's **assigned users**.

This replaces the prior model where a visit had exactly one `assigned_driver_id` and the
UI forced a driver once one was picked.

## Data model (3NF)

| Object | Role |
|---|---|
| `public.visit_team(visit_id, employee_id)` | join table, PK `(visit_id, employee_id)`, FKs to `visits`/`employees` `ON DELETE CASCADE`, RLS + `audit_visit_team` trigger |
| `public.visits.assigned_driver_id` | kept as the **derived primary** = `visit_team[0]` (first member). Lets existing consumers/reports keep working unchanged. |
| `public.visits.team_rev` | bumps on any team change → fires `trg_push_visit_update` so the team syncs to Jobber |
| `ops.v_visit_team(visit_id, employee_id, full_name)` | the app reads the current team from here (never the base table) |
| `ops.v_calendar_driver(id, full_name)` | the multi-select options = the 6 active crew (unchanged source) |

## RPC wiring (app calls these; never writes the table directly)

- **Create** — `create_calendar_visit(..., p_team_ids bigint[])` (14th arg). Sets
  `assigned_driver_id = COALESCE(p_team_ids[1], p_driver_id)` and inserts the
  `visit_team` rows. The form passes `p_team_ids` and `p_driver_id = null`.
- **Edit** — `edit_calendar_visit(p_visit_id, p_patch)` with `p_patch = {"team_ids":[…]}`.
  DELETE+INSERT `visit_team`, set `assigned_driver_id = team_ids[0]` (or null when empty),
  `team_rev = team_rev + 1`. An empty array clears the team.

## Jobber push (`jobber-push-visit` edge fn)

Resolves the whole team from `visit_team` (fallback to `assigned_driver_id`), maps each
employee → Jobber GID, and:
- **create** → `teamMemberIdsToAssign: [gids]` on `visitCreate`
- **update** → `visitEditAssignedUsers({assignedUserIds: [gids]})` — supports **clearing**
  all (empty array unassigns everyone)

## Verification

- **Backend smoke (DB-direct):** created a 170-PV visit with team [Grecia, Aaron] →
  edited to [Diego] → to [] (empty). Jobber `assignedUsers` tracked every transition
  (`["Grecia","Aaron Driver"]` → `["Diego HERNANDEZ COLLA"]` → `[]`). `verify_jwt` stayed
  true on deploy.
- **UI end-to-end (live published app):** New Visit form for 170-PV, services 12 + 22,
  Team = Aaron + Grecia → **Create**. Visit 6813: `visit_team = [Aaron, Grecia]`,
  `assigned_driver_id = 26` (Aaron = team[0]), Jobber `assignedUsers = ["Aaron Driver",
  "Grecia "]`. The multi-select kept the dropdown open, showed checks + a "Clear
  selection" entry, and rendered "Aaron, Grecia". (Same test also confirmed the SC
  line-item push fix — Jobber showed both `12 …` and `22 - Service Call - Labor`.)
  Test visit soft-deleted afterward.

## Backfill

`2026-06-25_visit_team_backfill_from_driver.sql` — one-time idempotent backfill of
`visit_team` from `assigned_driver_id` for the 4 pre-feature visits (6805-6808) that had a
driver but no team row, so the drawer shows their crew. Non-recurring (the Jobber inbound
doesn't set drivers — only 4 of 1414 active visits ever had one).

## Files

- `docs/migrations/2026-06-25_visit_team.sql` (table, RPCs, view, trigger)
- `docs/migrations/2026-06-25_visit_team_backfill_from_driver.sql`
- `supabase/functions/jobber-push-visit/index.ts` (team resolution + push)
- Lovable project `6533c3ee-94f5-499c-96d1-c8847a729a8f` (`TeamMultiSelect`)
