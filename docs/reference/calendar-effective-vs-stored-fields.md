# `ops.v_calendar_visit`: EFFECTIVE values vs what is STORED

*Written 2026-07-30 after a wrong revert on `public.visits` 6041. All numbers measured against Prod,
not inferred. App-side companion:
`Building Apps/Visit Calendar/docs/09-known-issues.md` §0000(a), which covers what a reader of the grid
sees and what not to infer from it. This file owns the view definition and the COALESCE order.*

---

## The rule

> **`ops.v_calendar_visit` reports EFFECTIVE values. `public.visits` holds STORED values. They diverge
> precisely when nothing is assigned, which is the case you are most likely to be inspecting.**
>
> **🛑 NEVER read the truck or driver off the Calendar UI, or off `ops.v_calendar_visit`, to learn what
> is in `public.visits`.**

This is not a bug and there is nothing to fix. Both fallbacks are deliberate features. The trap is that
the **display is `COALESCE`d and the column is not**, so a populated-looking field can sit on top of a
NULL column.

## Measured divergence, and it is not an edge case

```
live visits (deleted_at IS NULL)                                     1,652
stored vehicle_id IS NULL                                              780
  ...of those, the view still shows a truck                            740   (45% of ALL live visits)
stored assigned_driver_id IS NULL but the view shows a driver           728
  ...of those, with a stored vehicle_id (so the inspection path can fire) 680
view driver CONTRADICTS a stored assigned_driver_id                       0   <- see the warning below
```

## Truck: the effective-vehicle chain

```sql
LEFT JOIN LATERAL (
  SELECT COALESCE(v.vehicle_id,                                      -- 1. explicitly assigned
                  (SELECT min(sli.default_vehicle_id) ...            -- 2. this VISIT's line items
                     WHERE li2.visit_id = v.id),
                  (SELECT min(sli.default_vehicle_id) ...            -- 3. the JOB's line items
                     WHERE li2.job_id = v.job_id AND li2.visit_id IS NULL AND li2.invoice_id IS NULL))
         AS vehicle_id
) effv ON true
LEFT JOIN vehicles veh ON veh.id = effv.vehicle_id     -- veh.name AS truck_name
```

Steps 2 and 3 are the `default_vehicle_id` feature
(`docs/migrations/2026-06-27_default_trucks_by_line_item.sql`).

⚠ **`truck_name` joins `vehicles`, so it can NEVER be a person.** Recorded because the opposite was
believed, twice, on 2026-07-30: a displayed "Moises" on a NULL-vehicle visit was read as *"the driver is
rendering in the truck slot"*. It is not. Moises is **truck id 1**, arriving as the line-item default.
Verified on 6041: stored vehicle NULL, effective vehicle 1, displayed truck "Moises", and **stored driver
NULL displaying as NULL** — nothing leaks between the slots. The misreading is easy because trucks here
are named like people (see `CLAUDE.md` "Truck names are NOT people": Moises, David, Goliath, Cloggy).

## Driver: the effective-driver chain, and it PREFERS THE DERIVED VALUE

```sql
COALESCE(emp.id, asg.id) AS driver_id      -- emp = DERIVED (fa), asg = v.assigned_driver_id
```

where `fa.employee_id` is itself:

```sql
COALESCE( (SELECT min(va.employee_id) FROM visit_assignments va JOIN employees e ...
             WHERE va.visit_id = v.id AND e.status = 'ACTIVE'),   -- 1. active crew on this visit
          (SELECT min(va.employee_id) FROM visit_assignments va
             WHERE va.visit_id = v.id),                           -- 2. any crew on this visit
          (SELECT e.id FROM inspections i JOIN employees e ...     -- 3. who inspected THAT TRUCK
             WHERE i.vehicle_id = v.vehicle_id
               AND i.shift_date BETWEEN v.visit_date - 1 AND v.visit_date + 1
             ORDER BY (i.shift_date = v.visit_date) DESC, (e.status='ACTIVE') DESC,
                      abs(i.shift_date - v.visit_date), e.id LIMIT 1) )
```

Step 3 is `docs/migrations/2026-07-17_calendar_effective_driver_inspection_fallback.sql`.

**⚠⚠ NOTE THE COALESCE ORDER: `emp` (derived) comes BEFORE `asg` (stored).** So if the derived value ever
resolves to a *different* person than `assigned_driver_id`, **the view shows the derived one and hides the
explicitly stored one.** Measured today: **0** such rows, so this is currently latent, not live.

**Do not treat that 0 as an invariant.** It is exactly the shape of
`reference_clean_data_is_not_proof_of_an_invariant`: it holds because crew and assignment happen to agree
today, not because anything enforces it.

**✅ DECIDED 2026-07-30: Fred chose to KEEP derived-first. Do not re-open this as a finding.**
The full trail, so the next auditor starts here instead of re-deriving it:
- A stored-first reversal was staged, proven by constructed test, and **retired unapplied**
  (`2026-07-30_0350_calendar_driver_stored_first_STAGED.sql`, created `a5ef1d1`, premise overturned
  `9da7cb5`, removed after the decision — git holds the body if it is ever wanted).
- **Derived-first is documented design, not an accident**: Building Apps `CLAUDE.md` rule #4 — the
  actual (GPS-attributed) driver of a completed visit beats the plan, per the trust hierarchy
  (Samsara = 100%). A blanket flip would have made a completed visit where GPS disagreed with the
  plan display the plan.
- The drawer CANNOT create the crew-vs-stored divergence anyway: both edit RPCs co-write
  `assigned_driver_id = team_ids[0]` in the same statement, and the deployed bundle hardcodes
  `p_driver_id: null`. Only raw `sql` writes can desync the pair (@Building Apps, measured from the
  live bundle; each claim re-verified against Prod).
- ⚠ The divergence class that DOES exist is inverted: the drawer writes `visit_team`, the view's
  derived driver reads `visit_assignments` (zero mentions of `visit_team` in the view body), so a
  team edit on a visit carrying a `visit_assignments` row (940/945 completed, 32/703 scheduled)
  updates the stored driver while the view keeps showing the old derived person. **Accepted as-is
  with the decision**; on completed visits that display is the GPS truth, which is the point.
- A status-scoped variant (stored-first for `scheduled` only) was considered and **declined** with
  the same decision. If circumstances change, that variant — and the 4-site edit machinery (3
  COALESCEs + the `driver_color` CASE) with its rolled-back TEMP-view test protocol — is in the git
  history of the retired file. Re-opening still needs Fred, per rule #4.

⚠ Step 3 keys on `i.vehicle_id = v.vehicle_id`, the **STORED** vehicle, not the effective one. So a visit
with no stored truck cannot reach the inspection fallback, which is why 680 of the 728 driver divergences
have a stored `vehicle_id`.

## What this cost, once

On 2026-07-30 a truck test on visit 6041 was reverted to `vehicle_id = 2` because the drawer displayed a
truck name and it was read as the stored value. **The true original was NULL**, unbroken back to
2026-06-24. Sequence, all in `audit.logs`: `NULL -> 3` (test), `3 -> 2` (wrong restore), `2 -> NULL`
(corrected). Recoverable only because `visits` is audited.

Two independently minor things composed into it: a Visit Calendar dirty-check bug (one direction of a
truck change fails to re-enable Save) forced a fallback to raw SQL, and this display trap made that SQL
wrong.

## How to read the real values

| Question | Read this |
|---|---|
| What truck is **stored** on this visit? | `public.visits.vehicle_id` |
| What driver is **stored**? | `public.visits.assigned_driver_id` (⚠ NOT `driver_id`, see below) |
| What does the Calendar **show**? | `ops.v_calendar_visit.vehicle_id` / `.driver_id` / `.truck_name` |
| What **was** a value before a change? | `audit.logs.old_row->>'vehicle_id'` of the first write in your own sequence |

⚠ **`public.visits` has no `driver_id` column.** The column is `assigned_driver_id`. `driver_id` is a
deliberate **patch-key alias**: `edit_calendar_visit` accepts `driver_id` and writes
`assigned_driver_id`. Send `driver_id`, read `assigned_driver_id`. Querying the key you just sent raises
`42703`, which at least fails loudly. Note `ops.v_calendar_visit` also exposes a `driver_id` column, and
that one is the EFFECTIVE value, so the same name means three different things depending on where you
are.

⚠ `audit.logs.record_pk` is **JSONB** (`{"id":6041}`). Match `record_pk->>'id'`. `record_pk = '6041'`
returns zero rows and looks exactly like a missing audit trail.

## Before a test write on a real visit

Record a pre-state block with the exact values, then verify each field after restoring. That is what made
the 7318 revert provable rather than approximate on the same night this went wrong for 6041:

```sql
SELECT id, vehicle_id, assigned_driver_id, start_at, end_at, length(notes) AS notes_len,
       visit_status, sync_state, deleted_at
  FROM public.visits WHERE id = <id>;
```

## See also

- `Building Apps/Visit Calendar/docs/09-known-issues.md` §0000(a) — the app-side half.
- `docs/migrations/2026-06-27_default_trucks_by_line_item.sql` — the truck fallback.
- `docs/migrations/2026-07-17_calendar_effective_driver_inspection_fallback.sql` — the driver fallback.
- `CLAUDE.md` "Truck names are NOT people" and "Column-name gotchas".
