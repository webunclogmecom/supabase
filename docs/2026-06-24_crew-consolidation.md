# 2026-06-24 — Crew consolidation (driver list dedup + re-attribution)

The "Select a driver" dropdown on the Calendar form was showing **34 employees** (all
active rows — test/random/duplicate/inactive included). Reconciled across **Jobber teams,
Airtable Drivers & Team, and our DB** down to the **6 real current crew** (per Fred).

## The driver list
`Calendar dropdown = ops.v_calendar_driver = public.employees WHERE status='ACTIVE'`
(simple status filter — no `is_crew` flag needed).

**The 6 crew (ACTIVE, renamed to first names; Jobber name in parens):**
| Display | id | Jobber name / email | Visits |
|---|---|---|---|
| Grecia | 1 | "Grecia" (greciacuestas@gmail.com) | 473 |
| Fred | 2 | "Fred" (fred@ayache.com) | 3 |
| Aaron | 26 | **"Aaron Driver"** (aaron@unclogme.com) | 72 |
| Yannick | 27 | **"Yannick Ayache"** (yannick@ayache.com) | 2 |
| Diego | 28 | **"Diego HERNANDEZ COLLA"** | 8 |
| Mark | 35 | **"Mark Noltion"** (marknoltion872@gmail.com) — synced 2026-06-24 | 0 (new) |

## Former drivers — kept INACTIVE (real history preserved, out of the dropdown)
Kevis Bell (371 refs), Steven (198), Ishad Knight (184), Jeffry (177), Andres (106 insp),
Donald Barron (78), Diego Martin Sarachaga (12 insp), Raymond Lee (10), A Azoulay (5).
Their `visit_assignments` / inspections stay — they really did that work; they're simply
not offered for new assignments.

## Deleted (20 — zero history anywhere)
Test/random/office-never-active rows + the 5 fake first-name dup "app accounts"
(Yannick 29 / Aaron 30 / Diego 31 / Keyon 32 / Ishad 34). All had 0 visit_assignments,
0 inspections, 0 photos/notes/reviews. Backup: `../../backups/employees_removed_2026-06-24.json`
(also in `audit.logs`).

## Mechanics + gotchas
- **Clobber-safe:** `webhook-jobber` only *maps* Jobber `assignedUsers` → existing employees
  (never creates/updates employee rows), so status/name edits stick. No recurring employee sync.
- **Unique constraint on `employees.full_name`:** rename the crew to first names *after*
  deleting the name-colliding dups (renaming "Aaron Driver"→"Aaron" fails while fake "Aaron" 30 exists).
- **Attribution stays true:** former drivers keep the visits they drove; we never re-point
  history to a crew member. The `visit_assignments` backfill filled 1 gap (Steven); 5 completed
  visits genuinely have no Jobber driver.
- Driver concepts: actual = Samsara via `visit_assignments` → `v_calendar_visit.driver_id`;
  planned = `visits.assigned_driver_id` (Calendar form). See `jobs-visits-calendar-workflow.md`.
