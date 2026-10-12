# What the Moises tank sensors and truck signals give us

*Discovery report, 2026-10-12 (ET). Written for the owner first and for future agents second. It updates
[samsara-lm11-level-monitor.md](samsara-lm11-level-monitor.md) (2026-09-04), which is still the reference for the
sludge sensor's hardware; section 9 below lists what that document now gets wrong. This repo is public: no client and
no client code is named (geofence names in Samsara carry client codes and are masked everywhere below). The database
plan built on these findings: [../superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md](../superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md).*

**Method.** Everything was read-only: about 650 Samsara GET calls (0 HTTP 429), Prod SELECTs run as read-only
transactions, and local scripts over the pulled files. Nothing was written to Samsara, to Prod or to the repos.
Times are ET; stored values are UTC. Litres to US gallons uses x0.264172.

**Labels.** [O] observed, with the method in brackets. [I] inferred. [U] unverified.

**The owner's ask (voice note, 2026-10-12, his words):** *"we have two new devices which are sensors to get the water
tank level and to get the sludge tank level ... we need to know what kind of information we can get from it ... see how
that can be helpful later on"*, *"the location of the truck ... with a better precision where the truck has been going"*,
*"how long do they stayed on that client, how much water was used, how much sludge was pumped out"*, *"how much was used,
how much was recovered, and also how much sludge do we really pump out"*. Then: *"taking information about our
compliance ... because we need to know that it's compliance to what our architecture is for"*, *"three normal form ...
everything needs to be linked. No orphans."*

> Note on "compliance": in the recording it means **compliance with our database architecture rules** (the sentence
> continues "to what our architecture is for"), not regulatory compliance. The DB plan answers it with a rule-by-rule
> checklist. Regulatory uses are listed under "Later uses" (section 8) and need a separate decision.

The two devices (from the owner's message):

| Device in Samsara | Gateway serial | Samsara asset id | Where |
|---|---|---|---|
| Moises Sludge Sensor (LM11) | GZ8K-E8N-PVX | 281475005688801 | on the sludge (grease) tank, reporting since 2026-08-20 |
| Moises Water tank Sensor (LM11) | GN4X-6TM-7BS | 281475007025272 | on the fresh-water tank, reporting since 2026-10-02 |

Moises, Cloggy, David and Goliath are trucks, not people. Only Moises has these sensors.

---

## 1. The short answer

| What the owner wants to know | Can we know it today? | How sure | What it still needs |
|---|---|---|---|
| **Where the truck has been, more precisely** | Yes, from the **truck's** GPS, not the sensors' | High | Nothing. The sensors' own GPS is worse, see below |
| **How long the truck stayed at a client** | Yes, as a GPS "stop" matched to the visit | High for most visits | A wider overnight window (some routes end after the cut-off) |
| **How much sludge was pumped at a visit** | Yes, for Moises | Medium to high per visit; low for small traps and shared plazas | Nothing for Moises. Other trucks need their own sensor |
| **How much sludge was dumped, and does it match what we picked up** | Yes, every dump is visible | High for the dump; the cycle check agrees within 25% in most cycles | Records for the dumps that have no Dump Offload visit |
| **How much water was used and refilled** | In **percent of the tank**, yes. In gallons, **no** | Low until the tank size is known | The water tank's capacity or length (one value) |
| **How much water was "recovered"** | No | n/a | First: what "recovered" means (open question D15) |
| **Whether the pump was running** | Moises: by engine speed as a stand-in. David: yes (PTO). Cloggy: no | Medium | A wired pump signal on Moises would make it exact |

### 1.1 Location precision

- **The truck's own GPS is the precise source.** Median gap between fixes is **6 s** on all three trucks over 14 days
  [O, 14-day GPS pulls]. Moises sent **46,314** fixes in that period [O].
- **The sensors' GPS is worse, not better.** The LM11 units inherit a position: the sludge sensor sent 8,652 fixes and
  the water sensor 6,193 in the same period, their geofence events arrive a median **104 to 110 s after** the truck's,
  and they miss 59% of the truck's events [O, event pull matched by address id and direction within 30 min]. While the
  truck was parked with the engine off, the water sensor's position jumped **130 to 255 m** away from the yard and
  produced a false geofence entry [O, 2026-10-08 16:57 to 17:19 ET].
- So: **use the truck's GPS for location, and the sensors only for tank levels.**

### 1.2 Time at a client

- A "stop" is built from GPS: consecutive fixes within 100 m of the first one, lasting at least 3 minutes. Over
  2026-09-28 to 10-12 that gives **119 stops** for Moises [O, local anchor walk].
- **44 of 48** completed Pumping visits on Moises have a stop within 150 m of the property whose time window contains
  the driver's completion time. The median completion is **3 minutes before** the truck leaves (p10 -7 min, p90 0 min).
  The other 4 were marked complete 1.5 to 12 hours later, from the office [O].
- The database already stores a measured time on site (`visits.duration_minutes`) for **131 of 173** completed visits
  in the last 30 days (75.7%) [O, read-only count]. It leaves blank the routes that end after its window: **9** Pumping
  visits were found the next morning, 05:39 to 08:32 ET, 9 to 62 m from the property [O].
- On co-located plazas the database merges neighbouring visits into one cluster: two visits 9 m apart on consecutive
  nights both got the same 84-minute cluster [O].

### 1.3 Sludge pumped

- The sludge sensor measures the distance from the sensor to the surface. With the tank shape (a horizontal cylinder
  84 in across) that distance gives the fill level, and with the capacity (3,840 gal) it gives gallons [O, fit to
  0.0003 pp over every distinct distance value].
- **Resolution:** about **20 to 23 gal per cm** mid-tank, and a between-stop noise floor of about **40 gal** [O, 80
  consecutive non-dump stop pairs: p50 23 gal, p75 65 gal].
- **The sensor takes a fresh measurement about every 10 minutes.** Samsara sends a row every ~31 s, but the rows in
  between repeat the held value [O, see 3.6]. So a stop shorter than one measurement period can miss a change.
- With an operating window that runs to 10:00 ET the next day, **27 of 48** Moises Pumping visits get a confident
  figure (a stop, a measured rise, a pump signature, and no other visit sharing the stop) [O, discovery method].
  Confident rises: p10 / p50 / p90 = **97 / 366 / 1,527 gal**; the rise divided by the recorded trap size has a median
  of **0.69** [O].
- Why the other 21 are not "confident": 7 pumped with no measurable rise (mostly traps of 50 to 300 gal, below
  resolution), 5 rose more than 1.5 times the recorded trap size (a wrong trap size or a shared stop), 9 shared a stop
  with another visit, 1 had no usable readings [O].

### 1.4 Sludge dumped

- The **truck's own geofence events** at the dump site caught **9 of 9** dumps; each dropped 1,613 to 3,714 gal [O].
- **4 of the 9 dumps have no Dump Offload visit** in the database [O].
- Collected against dumped (sum of rises between two dumps, compared with the next dump): **5 of 7** readable cycles
  agree within 25% with the discovery method (for example 3,194 dumped against 3,495 summed) [O]. With the planned
  algorithm and the stuck 10-01 dump excluded, ratios are 1.30, 0.80, 0.88, 1.32, 1.08, 1.15 (4 of 6 inside 0.75 to
  1.25) [O, review replay].

### 1.5 Water used and refilled

- The water sensor reports **percent only**. Samsara has the tank shape but **no capacity**, so it cannot give gallons
  (section 4) [O].
- We can compute the percent ourselves from the raw distance exactly: a horizontal cylinder **84 in** across with the
  sensor **12 in** above the maximum fill level reproduces Samsara's percent to **0.0005 pp** over 2,431 matching
  pairs; a 2.0 m diameter control misses by 5.34 pp [O].
- **"Water went down while sludge went up" is not a reliable pattern.** At stops where sludge rose, net water fell in
  7, stayed flat in 10 and **rose in 13** [O]. The water tank is often refilled at client stops (10 refills of more than
  15 pp since it was fitted: 8 at client stops, 1 at the dump) [O]. So "water used" has to be measured as the falls
  inside a stop and "refilled" as the rises, never as the net change.
- Example: one stop rose **+48 pp** (a refill during the job) while sludge rose 790 gal [O, 10-09 05:54 to 06:44 ET].

### 1.6 Water recovered

Two sensors looking down from the top cannot tell rinse water from grease inside the sludge tank. The correlation
between sludge gained and the change in water is **0.22** over 33 stops [O]. If "recovered" means rinse water sucked
back into the sludge tank, it cannot be measured with this hardware. If it means "how much sludge was really
recovered", that is the collected-against-dumped check (1.4). Open question D15.

### 1.7 Is the pump running

- **Moises's PTO signal never reports "on"** (27 readings in 14 days, all off) and its digital input 1 is not wired
  (152 readings, all off) [O].
- **Engine speed is a working stand-in on Moises:** while parked, 43 of 48 stops with a sludge rise had at least 30% of
  their RPM samples at or above 900, against 8 of 26 flat stops [O]. Inferred: the vacuum pump runs at a governed engine
  speed.
- **David's PTO works:** on during 8 of his 9 pumping visits; his RPM with the PTO on sits at 1,094 to 1,111 [O].
- **Cloggy** returned 0 PTO readings [O]; whether its RPM is usable is [U].

---

## 2. What we cannot know yet, and why

| We cannot know | Why | What would fix it |
|---|---|---|
| Water used or refilled **in gallons** | No water capacity anywhere (Samsara or our DB) | The owner gives the capacity or the tank length (D1); or someone enters it in Samsara |
| Whether the water tank really is an 84 in cylinder | The shape was typed by a person in Samsara; it fits the readings exactly but nobody checked it on the truck | A look at the truck, or a strapping chart (D1) |
| Water "recovered" | Hardware cannot separate rinse water inside the sludge tank | Clarify the meaning (D15) |
| Sludge for **Cloggy and David** | No level sensor on those trucks | Fit sensors (D17) |
| Sludge at **very small traps** (75 gal or less) | Below the sensor's resolution and noise | Nothing; report "below resolution", never 0 |
| How sludge splits between **plaza neighbours** serviced in one stop | GPS cannot separate properties 9 to 150 m apart | An allocation rule (trap-size share, D11) |
| An exact **pump-on** signal on Moises | PTO and digital input are dead on that truck | Wire the vacuum pump switch to an input, or fix the ECU PTO (D16) |
| **Sensor battery** health | The LM11 reports battery temperature but not voltage or status (re-probed, 3.4) | Ask Samsara support how to see it (D13) |
| Where the **second dump site** shows up for Moises | Moises never went there in the 14-day pull | Nothing needed; David's visits there are visible by coordinates (5.5) |

---

## 3. Technical inventory

### 3.1 Sludge sensor (asset 281475005688801, GZ8K-E8N-PVX)

Data 2026-08-20 14:43Z to 2026-10-12 15:40Z (52.9 days), no gap over 40 minutes [O, full history pulled in 3-day
windows, deduplicated on time and value].

| Reading | Rows | Per day | Median gap | Range / note | Use |
|---|---|---|---|---|---|
| `remoteSensingDistance` (metres) | 104,806 (104,803 distinct timestamps) | 1,976 | 31 s | 0.05 to 2.13 m, 1 cm steps. **New value only about every 10 min** (3.6). 17.5% exact duplicate rows before dedup | **Primary raw signal** |
| `fillPercent` (%) | 18,304 | 346 | 288 s | 0.012 to 99.395 | Drift witness only |
| `fillVolume` (litres) | 18,304 | 346 | 288 s | equals fillPercent / 100 x capacity to 0.073 L | Not needed |
| `fillVolumeAvailableCapacity` (L) | 18,304 | 346 | 288 s | not exactly capacity minus volume (worst 536 L) | No |
| `totalCapacityVolume` (L) | 18,304 | 346 | 288 s | 14,535.981 L = 3,840 gal after 5 flips with 3,800 on 08-20 | No (we hold capacity ourselves) |
| `fillCriticality` (enum) | 18,304 | 346 | 288 s | normal / criticallyHigh, high cut about 96 to 97%, never criticallyLow | No |
| `daysUntilFull` (days) | 17,932 | 339 | 289 s | 0.015 to 13.9 | Later use (capacity before a route) |
| `daysUntilEmpty` | **0** | | | empty over the whole history (the September doc said it was populated) | n/a |
| `fillVolumeIngress` / `Egress` (L) | 1,270 each | 24 | 1 h | hourly net change of the smoothed series; **not a ledger** (see trap 6) | **Never** |
| `smoothedFillVolume` (L) | 1,270 | 24 | 1 h | may be revised after it is first published [U] | No |
| mass readings (6 kinds), `fluidLevelCriticallyLow*`, `lastCriticalLevelChange` | 0 each | | | no density configured | n/a |
| `gatewayBatteryTemperature` (°C) | latest 45.2 | | | re-probed 2026-10-12 | Later (health) |
| GPS, location, speed, altitude, address entry/exit | yes | | | inherited from the truck, sparser and late | **No** (use the truck) |

### 3.2 Water sensor (asset 281475007025272, GN4X-6TM-7BS)

First data 2026-10-02 17:09Z (13:09 ET) [O].

| Reading | Rows | Per day | Median gap | Range / note | Use |
|---|---|---|---|---|---|
| `remoteSensingDistance` (m) | 24,816 | 2,497 | 18 s | 0 to 2.43 m. 399 readings of exactly 0 ("no echo"), **all between 17:09 and 19:29Z on 10-02**, the setup window. A ghost echo at 1.14 m (shown as 63.712%) appears as isolated measurements. 24.5% duplicate rows before dedup | **Primary raw signal** |
| `fillPercent` (%) | 2,969 | 302 | 312 s | 0.042 to 97.905; first row 19:29Z on 10-02 | Drift witness only |
| `fillCriticality` | 2,969 | 302 | 312 s | high cut about 97%; stayed "normal" at **0.04%** (no low threshold set) | No |
| `daysUntilEmpty` (days) | 239 | | 312 s | only from 2026-10-11 19:59Z | No |
| `daysUntilFull` | 0 | | | | n/a |
| all six volume readings (`fillVolume`, capacity, ingress, egress, smoothed, available) | **0 over the whole history** | | | volume profile not configured (section 4) | n/a |
| mass readings | 0 | | | | n/a |
| `gatewayBatteryTemperature` (°C) | latest 41.3 | | | re-probed | Later (health) |

### 3.3 Truck Moises (asset 281474998706262, gateway GAY9-7TS-EC7): readings that matter here

The latest-values sweep found 59 non-empty readings on the truck [O, `/readings/latest`]. Verdicts:

| Reading | 14-day volume / note | Verdict |
|---|---|---|
| `gps` | 46,314 fixes, median gap 6 s | **Use** (already stored by the GPS job) |
| `addressEntry` / `addressExit` | 275 / 270 readings, 81 addresses; payload field is `addressEntries[]` (the definition says `addressIds`) | **Use** for dump and yard dwells |
| `engineRpm` | 3,743 readings, median gap 120 s | **Use** as the pump stand-in |
| `ecuPowerTakeoff` | 27 readings, all off | Ingest (works on David); dead on Moises |
| `digioInput1` | 152 readings, all off, hourly heartbeat | Not wired; would be the pump signal if wired (D16) |
| `engineState` | 361 (155 idling, 183 running, 23 off) | Later (RPM already tells running from off) |
| `engineLoadPercent` | 2,969 | Later; possibly a better pump signature than RPM [U] |
| `fuelLevelPerc` | latest 33% (re-probed) | Later (fuel per stop) |
| `fuelConsumptionRate`, `derivedFuelConsumed`, `idlingDuration`, engine hours, odometer | present | Later (cost per visit) |
| fault codes, DEF level, DPF soot, check-engine lamps, coolant, oil pressure | present | Maintenance, not this plan |
| `utilization*` | present | Already covered by `ops.v_truck_utilization` |

Other trucks: Cloggy sends GPS, address events and engine state, **0 PTO** readings; its RPM was not pulled [U].
David sends GPS (sparse per day: median 87 fixes a day, because it is driven less), address events, engine state,
**working PTO** and RPM [O].

### 3.4 Sweep coverage and the re-probe

The 2026-10-12 latest-values sweep asked for all 266 asset reading ids in batches of 5. Two batches returned HTTP 500
on all three assets, hiding 10 readings [O]. They were re-probed **one id per call** for this report, together with 42
other battery, temperature and signal readings [O, 156 GET calls]:

| Reading | Sludge sensor | Water sensor | Truck |
|---|---|---|---|
| `gatewayBatteryTemperature` (°C) | **45.161** | **41.29** | empty |
| `gatewayBatteryVoltage`, `gatewayBatteryStatus` | empty | empty | empty |
| `fuelLevelPerc` (%) | empty | empty | **33** |
| `batteryVoltage` (V) | empty | empty | **13.11** |
| `fuelSource`, `reeferPowerSource` | HTTP 500 | HTTP 500 | HTTP 500 |
| the other 46 | empty | empty | empty |

So the LM11 tells us its battery temperature but **not its battery voltage or a low-battery status**; the only way to
notice a dying sensor is that it stops reporting. `fuelSource` and `reeferPowerSource` fail even alone, a Samsara-side
error [O].

### 3.5 Units, pinned from `/readings/definitions`

| Reading | Unit or type as Samsara defines it [O] |
|---|---|
| `remoteSensingDistance` | Float, baseUnit `meter` |
| `fillPercent` | Float, baseUnit `percent` |
| `fillVolume` | Float, baseUnit `liter` |
| `engineRpm` | Integer, baseUnit `rpm` |
| `ecuPowerTakeoff` | enum `off`=0, `on`=1 |
| `engineState` | enum `off`=0, `running`=1, `idling`=2 |
| `addressEntry` / `addressExit` | Object, field named `addressIds` (the payload actually carries `addressEntries[]`) |
| `gatewayBatteryTemperature` | Float, baseUnit `celsius` |

### 3.6 The sensor measures about every 10 minutes (new finding)

Counting only the rows where the distance **changes** value [O, local script over both full distance pulls]:

| | Rows | Value changes | Gap between changes p25 / p50 / p75 | Changes at least 590 s apart |
|---|---|---|---|---|
| Sludge | 104,806 | 1,883 | 600 / 632 / 1,795 s | 86% |
| Water | 24,816 | 366 | 600 / 601 / 1,200 s | 89% |

A new value almost never arrives sooner than 600 s after the previous one, so the sensor takes **one measurement about
every 10 minutes** and the ~31 s rows repeat it. Consequences: a "median of the last 5 rows" is five copies of one
measurement; the last measurement before a truck leaves can be up to 10 minutes old; and a filter that compares a row
with its neighbours never sees an isolated bad measurement, because its neighbours are copies of it. The DB plan
measures on value changes instead of rows.

---

## 4. The water sensor's configuration gap, and exactly what to set in Samsara

**What is configured** [I, from the exact fit]: a horizontal-cylinder profile with diameter **84 in** and a **12 in**
"Height Offset", and **no maximum capacity**. Samsara's guide says a horizontal cylinder needs "diameter and maximum
capacity"; percent can be computed from the diameter alone, which is why percent works and volume does not.

**What to set** (Samsara Fleet App, by someone with admin rights on the org):

1. Open the asset **Moises Water tank Sensor** (gateway GN4X-6TM-7BS).
2. Choose **Add Tank Details** (or edit the existing tank details).
3. Keep **Horizontal cylinder**, keep **Diameter 84 in** and **Height Offset 12 in**, unless someone measures the truck
   and finds otherwise.
4. Enter **Maximum capacity** (the tank's real capacity). Rule of thumb: an 84 in horizontal cylinder holds about
   **288 gal per foot of length** [I, geometry]. Alternative: upload a strapping chart if the tank is not a plain
   cylinder.
5. Optional: set a **low critical percentage** (for example 15%) so Samsara can alert on low water; today it stays
   "normal" at 0.04% [O].

Notes:
- Whether Samsara then back-fills volume for 10-02 onward is [U]. The sludge sensor gives no sign of back-fill (its
  volume starts 4 hours after its first distance reading) [O].
- **Our plan does not depend on this.** It computes percent from the raw distance with its own copy of the geometry,
  and gallons appear for every past stop as soon as the owner gives the capacity (DB plan, step W1). Entering the
  capacity in Samsara is still useful for the Samsara app itself.
- The same is true for the sludge tank: its profile (84 in cylinder, offset 0, 3,840 gal) was edited 5 times on the
  day it was fitted [O], which is why the plan stores its own versioned copy and watches for drift.

---

## 5. Experiment results

### 5.1 Visit to stop attribution (Moises, 2026-09-28 to 10-12)

| Class (discovery method) | Window -4 h to +28 h (as the DB uses today) | Window to 10:00 ET next day |
|---|---|---|
| Confident | 20 | **27** |
| Pumping, no rise | 7 | 7 |
| Rise more than 1.5 x trap + 40 gal | 3 | 5 |
| Stop shared with another visit | 9 | 9 |
| No valid level samples | 1 | 1 |
| No stop | 14 | 5 (all Dump Offload) |

Completion anchoring, measured for the plan [O, local walk joined to the visits]:
- Moises: 44 of 48 Pumping visits anchored; 2 shared anchors are genuine same-night neighbours.
- David: **6 of 12** completed visits anchored (misses: 3 Pumping including one recorded on the wrong truck, 2 Dump
  Offload at the second dump site, 1 Labor).
- Cloggy: **21 of 23**.

Example rows (extended window) [O]:
- Visit 5901: 192-min stop, +2,746 gal (trap 4,000), 174 high-RPM minutes, DB 197 min.
- Visit 6727: 53 min, +431 gal (trap 1,000), DB 57 min.
- Visit 6619: 78 min, +949 gal (trap 1,400); the DB has no time on site for it (window cut).
- Visit 6052: 50 min, +790 gal (trap 640), water +48 pp (refilled during the stop).
- Visits 6634 and 5922 (properties 9 m apart, consecutive nights): the DB gives both the same cluster; anchoring on the
  completion time separates them (6634: +713 gal on the 10-05 02:21 stop; 5922: about +1,060 gal over its 10-05 22:56
  and 10-06 03:24 stops).
- **Work on the wrong truck:** a 158-min, +1,056 gal stop with 140 high-RPM minutes at a property whose visit (8743) is
  recorded on David; David's stop there lasted 6 minutes with no PTO.
- **A visit that cannot have a stop:** visit 8744 (Unclogging) was completed at 17:35 ET while Moises was parked 12.1 km
  away all day [O, last and first fixes around it 9 m apart].

### 5.2 Dumps (Moises, truck geofence dwells at the dump site)

| Dwell start (ET) | Duration | Level before to after | Dump Offload visit |
|---|---|---|---|
| 09-28 18:08 | 68 min | 3,212 to 50 gal | none |
| 10-01 18:11 | 28 min | unreadable (stuck readings) | none |
| 10-02 15:58 | 39 min | 3,558 to 1,279 gal | 8725 |
| 10-03 04:27 | 76 min | 3,116 to 50 gal | none |
| 10-06 01:28 | 63 min | 3,395 to 200 gal | 8740 |
| 10-07 04:21 | 67 min | 3,817 to 135 gal | 8745 |
| 10-07 19:02 | 40 min | 1,593 to 541 gal | 8756 |
| 10-08 03:32 | 74 min | 3,306 to 135 gal | 8754 |
| 10-09 17:32 | 43 min | 3,588 to 0 gal | none |

- For 4 of the 5 recorded dumps, the visit's completion time falls inside the dwell (plus a few minutes); the fifth
  (8756) was completed the next morning. Its scheduled start is a midnight placeholder, so matching by scheduled time
  links it to the wrong dump [O, review replay].
- GPS clustering alone splits a dump into several stops (the 10-06 dwell holds 3 GPS sub-stops) [O]. The dwell is the
  right unit.
- Manifest cross-check (one-time, read-only): `derm_manifests` carries dump-ticket dates on 09-28 (6), 10-01 (10),
  10-02 (11), 10-06 (7), 10-07 (7) and 10-08 (10), and none on 10-03 or 10-09 to 10-11 [O]. Manifests have no truck
  column, so they cannot be tied to a truck directly. Two of the four unrecorded dumps (10-03 and 10-09) fall on dates
  with no manifest yet [O]; whether tickets are still to be entered is [U].

### 5.3 Two nights, end to end (from the level discovery, levels cleaned)

```
Sun 10-05 into Mon 10-06
21:27-22:04  37m client stop (visit 6334)   sludge 2,278 -> 2,278 gal (0)     water 20 -> 21%
22:10-22:52  43m client stop (visit 5886)   sludge 2,255 -> 2,635 (+380)      water 21 -> 53% (+32)
22:56-23:37  41m client stop (visit 5922)   sludge 2,657 -> 3,412 (+755)      water 55 -> 96% (+41)
23:52-00:26  34m unmatched stop             sludge near full, unstable        water 76 -> 96%
01:34-02:25  50m dump site                  sludge 3,511 -> 417 (-3,094)      water 96%
03:24-03:51  27m client stop (5922)         sludge 200 -> 505 (+305)          water 86 -> 48% (-38)
04:03-04:19  16m client stop (visit 7029)   sludge 505 -> 505 (0)             water 26 -> 17%
04:45-05:40  55m client stop (visit 6753)   sludge 673 -> 934 (+262)          water 17% flat
05:46-07:03  77m client stop (visit 6619)   sludge 872 -> 1,821 (+949)        water 17 -> 37% (+20)
07:32 ->     yard, parked 13 h              sludge about 1,750-1,844          water 36% flat
```

The 03:24 stop shows the 10-minute trap: the last measurement before leaving read 47.7% water, the next one 2 minutes
after leaving read 26.2%, and the next stop arrived at 26%. About 21 pp of water use belongs to that stop but was taken
after the last in-stop measurement [O, review replay].

```
Wed 10-08 into Thu 10-09
03:55-04:38  43m dump site                  sludge 3,287 -> 135 (-3,152)      water 26% flat
05:54-06:44  50m client stop (visit 6052)   sludge 123 -> 914 (+790)          water 26 -> 74% (+48)
07:13-07:38  25m client stop (visit 6284)   sludge 914 flat                   water 74% flat
08:55-23:28  yard: 09:02-09:47 sludge 914 -> about 33 gal and water 74 -> 6%, both while parked
00:08-02:11 123m client stop (visit 8741)   sludge 26 -> 257 (+232)           water 6 -> 20% (+14)
03:38-04:44  65m client stop (two visits)   sludge 200 -> 417 (+217)          water 19 -> 5% (-14)
05:41-06:23  42m client stop (visit 7866)   sludge 384 -> 541 (+157)          water 5-6% flat
08:13-11:08 174m client stop (visit 6975)   sludge 505 -> 2,050 (+1,545)      water 6 -> 28% (+23)
11:17-15:39  yard: 11:10 -> 13:42 sludge 2,050 -> 3,588 (+1,538) while parked, water flat
17:40-18:10  30m dump site                  sludge 3,733 -> 19 (-3,714)
```

The two yard events (a drop while parked, and a +1,538 gal rise while parked) are unexplained (open question 5).

### 5.4 What replaying a naive algorithm showed (review, 2026-10-12)

- A row-level spike filter removed **3 of ~24,400** water rows and **0 of 797** rows at the 1.14 m ghost value [O]. On
  value changes, 17 isolated ghost measurements are visible, each repeated a median of 30 times. 5 of 78 water stops
  had an edge on a ghost; one would have credited about **58 pp** of water use to a visit where the truck actually
  arrived at about 6% [O].
- A "drop near-zero readings after a high level" rule (aimed at the sludge sensor's false empties) also dropped the
  **real** empty after the 10-09 dump, because a dump can go from about 70% to empty in one measurement. The dump would
  have read as unmeasurable and the next stop too [O]. The plan uses a look-ahead instead (a false empty recovers within
  3 hours without a dump in between).
- A dump-confidence rule without a sign check rated the stuck 10-01 dump "high" with a **negative** offload of
  -2,387 gal [O].
- A hysteresis walk that only commits a leg on a reversal reported **0 water used on 13 of 18** stops with a real fall
  of at least 5 pp [O]. The plan flushes the open leg at departure.

### 5.5 Where the trucks dump and park

- **Dump site in Miami-Dade** (client 365, property 98): the truck's dwell positions on all 9 dumps sit **0.60 to
  0.87 km** from the site's recorded tip coordinates and from property 98's geocode [O, median GPS position per dwell
  against the stored point]. So a 150 m rule on the stored point would miss every dump; the Samsara geofence (a
  1,414 m polygon, already linked to that client and property) catches all of them.
- **Dump site in Broward** (client 76, property 155): David's GPS came within **11 m** of its recorded tip points on
  10-02 and 10-08 (255 fixes within 150 m) [O]. Moises and Cloggy never came within 1.8 km in 14 days [O]. Its stored
  coordinates are good enough to detect dumps there without a Samsara geofence.
- **Where trucks park:** Moises parked at the Samsara address typed "yard" for **11 of 11** stretches of 3 hours or more
  (within 20 m) [O]. The depot configured in the database (`app_config.depot_property_id`, read by `ops.v_depot`) is
  about 13 km away and **0 of 72,901** fixes from the three trucks came within 150 m of it in 14 days [O]. Cloggy
  parks somewhere else (about 22 km from the yard) [O]; David showed no parked stretch of 3 hours in the pull.

---

## 6. Traps

1. **Use the asset id, never the name.** "Moises Sludge Sensor" is free text a person can edit.
2. **`remoteSensingDistance` comes with 17 to 25% exact duplicate rows.** Deduplicate on (asset, time).
3. **Three sludge timestamps carry two different values** (104,806 distinct time-value pairs, 104,803 distinct times).
   A table keyed on (sensor, time) holds 104,803.
4. **A new measurement only every ~10 minutes** (3.6). Work on value changes, not rows.
5. **False "empty" near full on the sludge sensor:** 45 episodes where distance jumps to exactly 2.13 m (0%) while the
   real level is above 40%, each recovering within 3 hours (inferred: a close-range blind spot). Do not confuse with a
   real post-dump empty.
6. **Ingress and egress are not "gallons pumped".** They are hourly net changes of the smoothed series
   (`ingress = max(0, smoothed[T] - smoothed[T-1h])`, exact in 997 of 1,270 hours). Over 53 days ingress totals
   99,091 gal and egress 107,810 gal while the level moved -1,901 gal. A pickup and a dump in the same hour cancel.
   One egress hour showed 2,953 gal at a client stop 43 km from the dump, during a dropout [O].
7. **Ghost echo on the water sensor at 1.14 m** (63.712%), and 0 m "no echo" during setup. Filter isolated measurements;
   drop 0 m.
8. **Sloshing:** percent swings 0 to 96% while driving. Only use measurements taken while parked at a stop, plus the
   first new measurement within one period after leaving.
9. **Capacity edits in Samsara are silent:** the sludge capacity flipped 5 times between 18:38 and 18:58Z on 08-20.
10. **`/readings/history` takes one `readingId`** (sending `readingIds` returns 400). `/readings/latest` accepts up to 5
    (the docs say 3; 6 returns 400). Batches can return HTTP 500 for one bad id: re-probe singly before concluding.
11. **The address payload field is `addressEntries`**, not `addressIds` as the definition says. Address ids may carry an
    `addr_` prefix in our link table.
12. **The sensors' own geofence events are an echo of the truck's**, later and sparser, with false events when parked.
13. **`completed_at` on a Dump Offload visit is not the dump time**, and its scheduled start can be a midnight
    placeholder.
14. **Scheduled times are not measurements.** `start_at`/`end_at` are planned slots; two ops views still present the
    slot as on-site time (`ops.v_truck_utilization.hours_onsite_30d`, the fallback in
    `ops.v_calendar_visit.duration_minutes`).
15. **The configured depot is not where the trucks park** (5.5), so "within 150 m of the depot" never fires.
16. **The Miami-Dade dump site's stored coordinates are 0.6 to 0.9 km off** the place the truck tips (5.5).
17. **A dormant writer of visit times exists:** `webhook-samsara` `handleGeofenceAlert` would write
    `visits.actual_arrival_at`, `actual_departure_at` and `is_gps_confirmed`, matching by client within 12 hours. It has
    never fired (Samsara sent 6 events in retention, all `AddressUpdated`) [O], but subscribing to Samsara geofence
    alerts would switch it on.
18. **kb.samsara.com returns 403 to the fetch tools**; the Zendesk Help Center API serves the same articles as JSON.

---

## 7. Open questions for the owner

1. **Water tank size:** is it really an 84 in horizontal cylinder with the sensor 12 in above the top? What is its
   capacity, or its length? (One value turns on water gallons for all history.)
2. **One barrel with two compartments, or two tanks?** Both read near full at the same moment (10-06 01:34: water 96%,
   sludge 91%), so the volumes are separate [I, strong].
3. **Where is the water tank refilled?** It rose at 10 of 33 client stops and at the dump. From the client's tap?
4. **What does "recovered" mean?** Rinse water sucked back into the sludge tank (not measurable), or sludge really
   pumped out (the collected-against-dumped check)?
5. **The two yard events** (10-08 09:02 to 09:47: sludge 914 to about 33 gal and water 74 to 6% while parked; 10-09
   11:10 to 13:42: sludge +1,538 gal while parked): a washout, a truck-to-truck transfer, or a sensor artefact?
6. **Low-water alert in Samsara?** None is set; it reads "normal" at 0.04%.
7. **Sludge sensor mounting:** 45 false-empty episodes near full; should Samsara support check the mounting and the
   offset (0 in today)? Samsara's guide says not to mount within 12 in of a sidewall or above internal bracing.
8. **Pump signal on Moises:** wire the vacuum pump switch to digital input 1, or fix the ECU PTO?
9. **Sensors for Cloggy and David?**
10. **Which truck yard is ours,** and should the depot setting point at it (5.5)?
11. **The Miami-Dade dump site's stored coordinates** look 0.6 to 0.9 km off; correct them?

---

## 8. Later uses (cheap once the data is stored)

- **Room left before a route:** `daysUntilFull` and the current level against tonight's total trap gallons.
- **Low-water and overfill alerts** for drivers.
- **Pumping frequency per property** from measured gallons against trap size and days between visits.
- **Trap sizes that look wrong** (rises far above the recorded trap size).
- **Fuel and idle cost per visit** from fuel level, consumption rate and idling at each stop.
- **Trips** (drive legs between stops with distance and drive time) as a view over stops and GPS.
- **Compliance cross-checks, read-only:** each manifest's dump-ticket date against a dump stop on that date; measured
  gallons against the trap-size gallons used today on Broward-offload LWT rows. Showing either to a regulator is a
  separate owner decision; nothing regulator-facing changes in the plan.
- **Sensor health:** battery temperature trend and silence detection.

---

## 9. Corrections for `samsara-lm11-level-monitor.md` (section update notes)

| Section | Today says | Should say |
|---|---|---|
| Section 7 | the water unit is expected, not fitted | fitted 2026-10-02 (GN4X-6TM-7BS, asset 281475007025272); percent only, no capacity configured (section 4 here) |
| Section 7, item 2 | populate a water capacity from `totalCapacityVolume` | that reading is empty for the water sensor; capacity must come from the owner or a measurement |
| Section 4 / cadence | 2,313 distance readings a day | about 1,970 a day after removing duplicate rows, and a **new value only about every 10 minutes** |
| Section 4 | `daysUntilEmpty` populated on sludge | 0 rows over the whole history on sludge; present on water from 10-11 |
| Section 8 | ingress and egress are the natural starting point | they are hourly net changes and do not balance; never use them as gallons pumped (trap 6) |
| Section 10 | the shift form stopped | live again through Fillout (71 rows since September, all Moises); values include an outlier (water 10,000) |
| Section 12, item 4 | one vessel or two is open | still open, but the near-full readings at the same moment point to two separate volumes |
| New | n/a | the 10-minute measurement period, the false empties near full, the ghost echo, and the yard and dump-site location facts (sections 3.6, 5.4, 5.5) |

---

## 10. Method

A multi-agent read-only pass on 2026-10-12: full `/readings/history` pulls of every level reading on both sensors,
14 days of truck and sensor address events, GPS, engine RPM, PTO and engine state on all three trucks, read-only Prod
SELECTs, and adversarial review of every number used in the plan. The raw pulls contain geofence names with client
codes, so they are kept outside the repo (workspace `backups/`, local only). To see what the fleet reports now:
`node scripts/probes/samsara_level_sensors.mjs` (discovers level sensors by `remoteSensingDistance`, so a sensor
without a volume profile still shows).
