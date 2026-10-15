# Moises water balance: design (2026-10-15)

Status: design, measured on live data. Nothing built yet. No app shows water (Fred: "we don't have an icon for water,
but we need to have that logic").

## The ask

Fred, 2026-10-15 (voice note, paraphrased only where noted): only Moises separates the sludge into grease and water.
The water in the truck at the start of a visit, plus the water separated from the sludge, minus the water put back into
the client's tank, is what is left. Track the peak: for example 300 gal in the truck plus 300 from the sludge is a peak
of 600; put back 200 and 400 is left at the end. The sludge sensor may read water too, so we need readings that stop us
counting water as grease.

## The model

Per Moises visit, from the water tank (tank 2, 1,200 gal, owner confirmed) and the sludge tank (tank 1, 3,840 gal):

| value | meaning |
|---|---|
| water start | water tank at arrival |
| water separated | every rise of the water tank during the stop |
| water peak | the highest water level during the stop |
| water put back | every fall of the water tank during the stop (back into the client's trap) |
| water end | water tank at departure: start + separated - put back |
| grease kept | sludge tank, departure - arrival (what the Calendar's Grease pumped already uses) |
| pulled from the trap | grease kept + water separated |
| removed from the trap | grease kept + (water end - water start) |

## What the data says (45 client visits, Oct 2 to 14, ghosts removed)

- **A rise of the water tank is separated water, not a refill.** Visits with real pumping (sludge 200 gal or more, 26
  visits): median 739 gal separated, 708 put back. Visits with little sludge (under 150 gal, 15 visits): median 7 gal,
  never more than 26. The 2026-10-12 discovery read these rises as refills from the client's tap; the pattern says
  otherwise. Across the 26 visits, 83% of the separated water went back into the traps (18,058 separated, 14,981 back).
- **Example, visit 6619 (043-MIL):** start 207, falls to 52, peak 544, back to 424 at departure; sludge 914 to 1,844.
- **At the dump the water tank empties too** (000-DH: 863 and 990 gal out). That is dumped water, not water put back.
- **Water can be put back at a later stop:** visit 5922 (015-FLA) separated 488 at 22:55 with the tank nearly full
  (1,153) and put 491 back at its next stop at 03:24.

## Readings that cannot be trusted

- **The water ghost: exactly 1.140 m, read as 765 gal** (25 measurements since Oct 2). The stop pipeline does not reject
  it when it sits between plausible readings: on 6619 it made a false peak of 765 (real 544), so "risen" read 713 instead
  of 492. Readings of 5 gal or less are no-echo glitches. Both are removed in the numbers above.
- **The sludge tank can hold water that was not separated**, and the sensor cannot tell it from grease. Two signs:
  - the water tank was nearly full during the stop (peak 1,140 gal or more, 95%): separation was capped. 4 visits:
    004-BAO (sludge 1,514), 015-FLA (978), 318-CAP (1,659), 009-CN (1,022);
  - real pumping with almost no separated water: 014-JOY (326 sludge, 54 separated), 033-LG (252, 9),
    031-KRU (285, 63), 236-LOU (206, 0).
  On those visits the sludge number is grease plus water, so it is an upper bound for the grease.

## Proposed build (after Fred's answers)

1. `public.v_visit_water_balance`, service_role only, Moises visits from 2026-10-02: the eight values above, plus flags
   `water_tank_full`, `no_separation`, `ghost_readings_removed`, and a confidence. Built from `public.v_tank_levels`
   with the ghost filter and the stop edges of the existing pipeline. Additive: nothing that exists changes.
2. The stop pipeline (`fn_measure_vehicle_stop_tank_levels`) learns to reject the 1.140 m water ghost, so
   `v_visit_tank_service.water_used_gallons` / `water_refilled_gallons` stop counting it (an algorithm version bump,
   which re-measures every stop).
3. If Fred agrees: a visit flagged `water_tank_full` or `no_separation` stays out of the client's grease average used
   by the Calendar (it reads grease plus water).

## Questions for Fred

1. Is the water tank ever filled with clean water (a tap or a hydrant)? The data says a rise is separated water; if
   there are refills, where do they happen?
2. Is the water that leaves the water tank at the dump dumped with the sludge?
3. When the water tank fills up and the water goes back at the next stop, should it count for the visit that separated
   it (proposed) or the visit where it went back?
4. Should visits where the water tank was full, or where no water was separated, be left out of the client's grease
   average (proposed: yes)?
