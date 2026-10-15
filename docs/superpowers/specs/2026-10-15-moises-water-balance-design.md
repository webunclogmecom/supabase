# Moises water balance: design (2026-10-15, measured 2026-10-16)

Status: design, measured on live data and checked by adversarial reviewers. Nothing built yet. No app shows water
(Fred: "we don't have an icon for water, but we need to have that logic").

## The ask and Fred's answers

Fred, 2026-10-15: only Moises separates the sludge into grease and water. The water in the truck at the start of a
visit, plus the water separated from the sludge, is the peak; minus the water put back into the client's trap, it is
the water at the end. The sludge sensor may read water too, so the readings must not count water as grease.

His answers the same evening, verbatim:
- Clean-water refills: "Yes usually at the office".
- At the dump: "No, we only dump the grease".
- Visits where the water tank was full or no water was separated: "No, still count it. I just need to know that after
  leaving the geofencing of the client it might have a change in the water and sludge level you know? because of the
  transformation of sludge into grease into grease tank (sludge sensor) and water into the water tank (water sensor)".
- Question 3 (water put back at a later stop) was unclear to him; it is answered below from the data.

## The model

| value | meaning |
|---|---|
| water start | water tank at arrival |
| water separated | the SUM of every rise of the water tank during the visit (many visits run several cycles: 181-PV on Oct 5 went 473, 1,063, 644, 551, 1,053, 250) |
| water peak | the highest valid water level during the visit |
| water put back | the sum of every fall during the visit (into the client's trap) |
| water end | water tank at departure = start + separated - put back |
| grease kept | sludge tank, departure - arrival |

Separated and put back are LOWER BOUNDS: a new level arrives only every 10 minutes, so a fill and a pump-back inside
one interval is invisible (199-STK, Oct 15: 189, 1,063, 328 in 20 minutes).

## What the data shows (verified)

Measured by four read-only investigations, each re-measured independently by a reviewer told to refute it. Files:
`scratchpad/water/` of session 0ad89c91 (SQL and scripts, local only).

1. **Separation happens at the client, not on the road.** 97% of the water tank's rises happen inside client stops.
   After the truck leaves, the water tank does not move (largest change 12.6 gal across 45 departures); on the yard right
   after the last client it stays within 7 gal for 3 hours; no stop shows sludge falling while water rises after
   departure (0 of 62). Sludge readings taken while driving swing by up to 2,000 gal and come back once the truck parks
   (sloshing): they are never a level.
2. **Fred's "change after leaving" is real, and its cause is the 10-minute sensor schedule.** When pumping or water
   pump-back ends in the last minutes of a visit, the first reading that shows it is the one taken just after the truck
   leaves, and the pipeline never reads after departure. 233-AH (visit 7029, Oct 6) pumped about 207 gal of grease the
   pipeline records as 0; 7872 (+250); possibly 015-FLA water (-258). Rare (2 to 3 of 172 visits), sometimes large.
3. **Question 3, answered by the data: water does go into a different client's trap.** About 53 to 70% of the
   separated water goes back into the same client's trap during the visit (the share depends on the bookkeeping rule).
   At least 4,821 gal left clients still in the truck (Oct 2 to 15). Of the water carried out, roughly a third went into
   other clients' traps and about 45% left at the dump or the yard. 015-FLA (visit 5922, Oct 5/6) got about 748 gal back
   against 487 separated, so at least about 260 gal came from another client (most likely 003-BC earlier that night).
4. **No clean-water refill shows since the water sensor started (Oct 2).** The one candidate is the yard on Oct 7
   17:23 to 17:33 ET (+546 gal, vacuum engine setting), undetermined. The first reading (Oct 2 15:29 ET, about 97% full
   right after a long yard stay) fits a refill before the sensor existed.
5. **Water leaves the truck at the dump and at the yard.** The water tank fell at 4 of 9 dumps, exactly the 4 where it
   arrived with 840 gal or more (falls of about 121 to 863 gal), and the falls are permanent (not a sensor effect). At the
   yard it fell on Oct 7 (about 300 gal) and Oct 8 (900 to 69). In 4 of the 6 falls the engine ran at about 1,200 rpm,
   the setting that at client stops goes with pumping water back into a trap. Where the water went is not in the data.
6. **The yard moves grease both ways.** Grease emptied at the yard on Oct 8 (about 870 gal), Oct 12 (about 1,340) and
   Oct 14 (about 1,290); loaded at the yard on Oct 9 (+1,560) and Oct 13 (+1,588), each time with the vacuum engine
   setting and followed by a dump at 000-DH. `v_vehicle_dumps` does not see the yard.
7. **Moises's engine is a second signal** (his PTO is dead; rpm sampled every 2 minutes): idle about 600, dump offload
   about 1,000, water pump-back about 1,200 (in 20 of 32 client water falls, 2 of 67 flat intervals), vacuum about 1,525
   (in 29 of 29 client water rises).

## Readings that cannot be trusted (verified)

Distances are stored to the centimetre, so a ghost is an exact distance that repeats far more than its neighbours.

| sensor | ghost | readings | note |
|---|---|---|---|
| water | 1.13 to 1.15 m (about 765 gal) | 27 | only while the real level is below about 545 gal; passes the pipeline whenever the level is moving |
| water | 2.40 m or more (no echo, about 0 gal) | 7 | mostly while the tank is high |
| water | 2.12 to 2.14 m (102 to 112 gal) | 3 | one inflated 010-CS by about 206 gal each way |
| sludge | 0.11 m or less (false full) | 45 | |
| sludge | 1.71 to 1.73 m (505 to 559 gal) | 118 | appears when the real tank is near empty |
| sludge | 1.35 m | 17 | weak, low confidence (1.34 m shows no excess) |
| sludge | 2.09 m or more (false empty) | 238 | many are real empties; keep the existing false-empty rule, not a neighbour test |

Proposed rule (both sensors): a reading at a listed distance is unreliable when it lies more than 0.15 m outside the
range of its nearest earlier and later readings that are not on the list (up to 24 h each way, never across a dump or a
yard offload); a removed reading means "level unknown", never "unchanged". Then the existing false-empty and spike
rules. Measured: removes 168 readings (61 the pipeline accepts today), about 2 to 4 of them possibly real.

## Defects found in the stop pipeline (`fn_measure_vehicle_stop_tank_levels` v2)

1. The 1.14 m water ghost is accepted (6619: water risen 713 instead of 492; 6 visits' water inflated; 7029's water
   arrival edge IS the ghost, so 563 gal put back is recorded where 114 happened).
2. An arrival edge can come from before an intervening stop: 082-TFC (stop 1246, visit 6218, Oct 6) took its water
   arrival from 21:44 ET at an earlier stop, across the whole 182-PAL stop, so PAL's 605 / 792 gal is counted twice.
   2 water and 7 sludge client stops are like this.
3. A held value is timed at the first row of the stop's window, not when it was first seen (6569, 8134).
4. Sludge ghost edges: 6 visits change, two of them high confidence feeding the Calendar's grease averages:
   010-CS 2,746 to about 3,287 gal, and 009-CN's Sep 21 reading 957 to about 1,438. 8085 (-508) is a ghost arrival the
   rule above still misses (its neighbour search crosses a dump).
5. The end of a visit is never read after departure (finding 2).

## Proposed build (waiting for Fred's go-ahead)

1. **Pipeline v3:** the ghost rule above, no arrival edge before an intervening stop, held values timed when first seen,
   and the end-of-visit correction (take the first reading after departure when it comes before the next stop's
   arrival and the next parked reading agrees; otherwise flag the visit). Re-measures every stop; moves the Calendar
   averages of the clients above for today and later (past days are frozen).
2. **`public.v_visit_water_balance`** (service_role only, Moises, from 2026-10-02): start, peak, end, separated (sum of
   rises), put back (sum of falls), counted at the visit whose trap the water went into, with a separate labelled line
   for water brought in from earlier stops (bounds only, never a split that depends on a bookkeeping rule). Water that
   leaves at a dump or the yard is "pumped out at the dump / yard", never "put back". A rise at the yard is a refill.
3. **Health:** the per-distance excess check goes into `v_tank_data_quality_issues`, so a sensor remount shows up.

## Questions for Fred

1. At the dump, when the water tank is fuller than about 840 gal, it loses 120 to 860 gal while the engine runs at the
   pump-back setting. Where does that water go: into the grease side, into the dump, or somewhere else?
2. What happens at the office yard? The truck empties grease there (about 870 to 1,340 gal on Oct 8, 12, 14) and loads
   grease there (about 1,560 on Oct 9 and Oct 13), and the water tank was emptied there on Oct 7 and Oct 8.
3. When was the water tank last filled with clean water? No refill shows since Oct 2.
