# 2026-08-19 · Time on site at 150 m, audited, and what Samsara's geofences actually add

**Fred:** *"go with 150m instead and do an audit about it, remember to take the geofencing from
samsara too that might help."*

Both done. The radius is back to 150 m (`2026-08-19_0210`), the year is recomputed, and the
geofence question has a measured answer: **it does not help, and the reason is worth knowing.**

## 1. The radius change

| | 75 m | **150 m** |
|---|---|---|
| resolved, full year | 760 of 969 | **822 of 969** |
| resolved, August | 95 of 114 (83%) | **101 of 114 (89%)** |
| August average | 51 min | 52 min |
| August median | — | 44 min |
| August maximum | 176 min | 178 min |
| August over 3 h | 0 | 0 |

**+62 visits resolved, and the durations barely move.** This is the same result measured before
the 75 m default was chosen: tightening the circle never curbed the long readings, it only
produced blanks. Full year at 150 m: average 64 min, median 50.5, 27 visits over 3 h, and
**0 impossible orderings, 0 half-populated rows**.

The nightly cron takes the new default automatically (it calls the function without a radius).

## 2. Samsara geofences: measured, and they do NOT help

We already hold the mapping: **282 `property → samsara` links, 222 matching a live address**.
Samsara has **249 addresses, 117 polygon and 132 circle** geofences. Their effective radius
(circle radius, or centroid-to-farthest-vertex for polygons):

```
min 11 m | p25 25 m | median 37 m | p75 59 m | p90 93 m | max 1620 m
242 of 249 geofences are SMALLER than our 150 m circle; only 6 are larger.
```

🛑 **So adopting Samsara's geofences as the dwell boundary would CUT coverage, not raise it.**
Their median is 37 m, which is tighter than the 75 m we just abandoned for being too tight.
That makes sense once stated: a Samsara geofence is drawn around the **site**, while a service
truck parks on the street or in a shared lot. The geofence answers "is the vehicle at the
address", not "is the crew working here".

The one place they would genuinely help is the **6 oversized sites** (up to 1,620 m — plazas and
condo complexes) where our fixed 150 m circle is too small. That is a real but narrow gain: see
below for exactly how narrow.

## 3. Why the remaining blanks are blank — and it is not the geometry

For the 43 visits still unresolved in July–August, how close did the **assigned** truck get?

| | |
|---|---|
| blank visits | 43 |
| **truck over 1 km away** | **23** |
| median closest approach | **1,618 m** |
| would be rescued by a bigger radius (150–500 m) | **5** |
| have a Samsara geofence available | 33 |

⇒ **The binding constraint is `visits.vehicle_id`, not the radius and not the geofence.** More
than half these visits were done by a truck other than the one recorded, so no boundary of any
shape can find them. Widening the radius or importing all 249 geofences buys **at most 5 of 43**.

**If Fred wants better coverage, the lever is vehicle assignment accuracy.** That is a different
piece of work, and it would also improve the photo attribution tie-break, which uses the same
column.

## 4. Independent cross-check: photo EXIF timestamps

A photo is taken on site, so its capture time should fall inside a GPS window that is real. This
signal was never used by the computation, which is what makes it worth running.

```
3,878 photos across 511 visits
71.7% fall inside [arrival - 10 min, departure + 10 min]
   75 land BEFORE arrival
1,022 land AFTER departure
```

⚠ **The lopsided miss (1,022 late vs 75 early) is NOT a clock offset.** That was the obvious
suspect — EXIF stored as local time would shift everything by exactly 4 hours — so it was tested:
only 45 of 1,022 sit near 4 h and 40 near 5 h, with a median of 1.55 h and p75 of 8.7 h. There is
no fixed offset, so the spread is real.

⚠ **And this check measures TWO things at once, so do not read 71.7% as the window's accuracy.**
A photo attached to the visit but taken at a *different* stop also lands outside, and the note
importer deliberately accepts a ±2-day window. The late tail is therefore consistent with both
crew activity after the truck repositions **and** known photo-attribution slack. 71.7% is a
**lower bound** on window quality, not a measurement of it.

## 5. What was deliberately not built

**Per-property geofence radii.** Cost: importing and refreshing 249 geofences plus point-in-polygon
work. Measured benefit: 5 visits. At the agreed purpose for this number — internal ops insight,
nobody paid or billed on it — that is not worth the moving parts. Revisit only if the number ever
starts driving money, and at that point the honest answer is a different source entirely, because
GPS measures the **truck, not the crew**.
