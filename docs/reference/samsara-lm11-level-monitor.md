# Samsara LM11 Level Monitor on truck Moises: what it is and what it gives us

*Measured live against Samsara org 6009037 and Prod `wbasvhvvismukaqdnouk` on 2026-09-04.
Read-only except for the one migration named below. Supersedes the conclusion in commit `01e2522`.*

Written because Fred asked what the new "unpowered sensor" on Moises can tell us, how it compares to
the powered vehicle gateways, and whether it can deliver the internal tank levels Yannick wants.

---

## 1. The one-line version

**It is a radar tank-level sensor, it is on the GREASE tank, and it has been working since the day it
was fitted.** The earlier finding that it reports "location only" was measuring **our API token**,
which lacked the `Readings` scope, not the hardware.

---

## 2. 🛑 The correction, and why the first answer was wrong

`01e2522` (2026-09-03) concluded the asset emits `latitude, longitude, location,
speedMilesPerHour, time` "and nothing else". That probe was careful and it carried a positive
control. **The control still could not save it**, and the reason is worth keeping:

- The control proved that **vehicle stats** came back for the powered trucks. That exercises a
  *different permission* from the one the question needed.
- Every `/readings/*` call was returning **`401 "Token requires Readings read permissions"`**, and
  `/readings/*` is the only surface carrying level data.
- So the instrument was blind to precisely the thing being asked about, while looking healthy.

**A positive control only licenses a zero if it exercises the same permission, endpoint family and
entity type as the claim.** A control on a neighbouring capability is not a control.

The 401 also could not have been read as "no data": an authorization decision is returned *before*
any lookup, so it cannot distinguish "there is level data we may not see" from "there is none".
The honest state until the scope was granted was **unknown**, not **absent**.

Fred granted all read permissions on the `CLAUDE - Dev Unclogme Slack` token mid-investigation and
the entire `levelMonitoring` family opened up.

## 3. The hardware

**Samsara LM11 Level Monitor**, HW-LM11, model `060-00010`. Gateway serial `GZ8K-E8N-PVX`,
Samsara asset `281475005688801`, created `2026-08-20T14:37:02Z`.

| Property | Value | Source |
|---|---|---|
| Sensing | Contactless **radar, 57-64 GHz**, distance from sensor face to material surface | datasheet |
| Measures | Fill level of liquids **and solids** | Samsara KB 360042725792 |
| Comms | 2.4 GHz ISM (BLE) only, **no cellular radio**, relays via a paired gateway | datasheet |
| Location | **Approximate**, from the GPS of nearby gateways that hear its advertisements | datasheet |
| Power | 2x lithium CR-AG, 7 years, **not replaceable** | datasheet |
| Enclosure | PVDF, 88 x 88 x 30 mm, 200 g, -40 to 70 C, IP67 + IP69K | datasheet |
| Hazloc | II 3 G Ex ic IIA T4 Gc; Class I, Zone 0 | datasheet |
| Mounting | VHB tape included; optional 2-inch NPT adapter, flat plate adapter | datasheet |
| Sensor I/O | **NONE.** No analog, digital or wired input; no expansion port | datasheet |

⚠ **The "no sensor I/O" claim carries its own positive control.** Samsara datasheets *do* print an
I/O table when the hardware has one: the IG21 Industrial Controller sheet specifies "4 isolated
channels with 0-12 V or 0-24 mA" analog in, 2 analog out and 6 digital. So the LM11 sheet's silence
is a real absence, not a thin document. **You cannot wire an external probe to an LM11.**

Compatible gateways per Samsara: AG24, AG26, AG52, AG53 and **VG34, VG54, VG55**. Moises carries a
**VG55NA**, so the pairing is supported.

**Rest of the estate, for context:** 3x VG55NA (one per truck, each with a CM34 dash cam as
`accessoryDevices`), 3x CM34, 3x AIM4, 1x LM11. Ten gateways, four assets.

## 4. What it actually reports

All `entityType=asset`, read via `GET /readings/latest` and `/readings/history`.

| Reading | Unit | 14-day range |
|---|---|---|
| `fillVolume` | **litre** | 0 to 14,289 (**0 to 3,775 gal**) |
| `fillPercent` | percent | 0 to 98.3 |
| `remoteSensingDistance` | **metre** | 0.1 to 2.13 |
| `fillVolumeIngress` / `fillVolumeEgress` | litre | 0 to 14,289 / 0 to 13,897 |
| `smoothedFillVolume` | litre | 0 to 14,289 |
| `totalCapacityVolume` | litre | 14,535.981 (**3,840.0 gal**) |
| `fillCriticality` | enum | `normal` / `criticallyHigh` / `criticallyLow` |
| `daysUntilFull`, `daysUntilEmpty` | day | populated |
| `fillMass*`, `totalCapacityMass` | kilogram | **all NULL** (no density configured) |

**Cadence:** `fillVolume` about 353/day (one per ~4 min). `remoteSensingDistance` about **2,313/day,
one per ~37 seconds**. Ingress/egress are hourly.

**⚠ Units are LITRES, not gallons.** Multiply by `0.264172` before showing anything to a human. The
sensor's own capacity of 14,535.981 L is exactly 3,840.0 US gal, which is a suspiciously round
number in gallons and confirms the vessel profile was entered in gallons.

**First reading `2026-08-20T18:38:12Z`**, about four hours after the asset was created. Verified a
real start and not a query-window edge by asking from 2026-08-15 and getting nothing before the 20th.
No day since has been missing.

## 5. Versus the powered vehicle gateways

| | Moises VG55NA | LM11 |
|---|---|---|
| Telemetry channels | **15 populated** of 34 valid stat types | 4 location fields + the level family |
| GPS cadence | 1 fix / 32 s, real speed | 1 fix / 145 s, speed is a constant placeholder |
| Position source | own GNSS | **inherited** from nearby gateways |

The 15 populated vehicle stats: `engineStates`, `fuelPercents`, `obdOdometerMeters`, `gps`,
`gpsDistanceMeters`, `defLevelMilliPercent`, `engineCoolantTemperatureMilliC`, `engineRpm`,
`engineLoadPercent`, `ambientAirTemperatureMilliC`, `barometricPressurePa`, `batteryMilliVolts`,
`intakeManifoldTemperatureMilliC`, `seatbeltDriver`, `faultCodes`.

**All 13 `auxInput` channels return no rows on every truck.** There is no existing analog or digital
body-function path into Samsara, so the LM11 is the only tank instrumentation we have.

**The LM11's location is redundant with the truck's own GPS, by design.** Measured over 3 days on
996 simultaneous pairs: median separation **28.6 m**, p90 103 m. The datasheet explains why: position
is the GPS of whichever gateway heard it, and on this truck that is usually Moises's own VG55NA.
Its one positional advantage is continuity: it covered **670 of 672** fifteen-minute slots over
7 days against the VG's 293, with zero slots the VG covered and it did not. Useful for recovery if
the truck is stolen with the ignition off; not useful as a second opinion on position.

## 6. Which tank, and what that settles

**Fred, 2026-09-04: it is on the GREASE tank.**

That makes `vehicles.grease_tank_capacity_gallons` the semantically correct home for the capacity,
and it makes `fillVolume` the automated successor to the manual `inspections.sludge_gallons`.

**Three independent sources agree on the size of that tank:**

| Source | Max observed |
|---|---|
| `inspections.sludge_gallons`, 105 driver readings | 3,800 gal |
| LM11 `fillVolume`, 15 days | 3,775 gal |
| `totalCapacityVolume` configured on the sensor | 3,840 gal |

Nothing ever approached the 9,000 the database held. Corrected in
`2026-09-04_1104_moises_grease_tank_capacity_3840.sql` (`505055c`), 9000 to 3840, which also
retroactively changed 446 `derm.v_lwt_monthly_rows` rows because that view reads the column live
rather than snapshotting it. See the migration header.

🛑 **THE WATER TANK IS NOT INSTRUMENTED YET.** A top-down radar reads one surface in one vessel,
so this unit can only ever report grease. **A second unit for water is EXPECTED and simply has not
been fitted yet** (Fred, 2026-09-04: *"they haven't installed the one for water yet."*). Until it is,
`inspections.water_gallons` has no live source at all, manual or automatic. **Do not let any
dashboard, report or total imply the truck is fully instrumented.** See §7 for what to do when the
water unit lands.

## 7. The water tank: expected, not yet fitted

**Status 2026-09-04: one sensor installed (grease). A second for water is expected. Not fitted.**

Written now so the day it appears nobody re-derives this. Run this first, which discovers level
sensors rather than hardcoding the known one, so a new unit shows up with no code change:

```bash
cd Supabase && node scripts/probes/samsara_level_sensors.mjs
```

Today it prints exactly one sensor and passes its own control. When it prints two, the following
need doing, and none of them are automatic.

**1. Identify it by ASSET ID, never by name.** The current one is named "Moises Sludge Sensor", which
is free text a person typed and a person can edit. A second unit arrives as its own **new unpowered
asset with its own id and its own LM11 gateway serial**. Key everything on the id.

**2. `vehicles` has no water capacity column.** There is `grease_tank_capacity_gallons` and
`fuel_tank_capacity_gallons`, and nothing for water. One is needed, and it must be populated from the
new sensor's `totalCapacityVolume` (litres, convert), not guessed. Note the precedent from the grease
side: the stored figure was wrong by a factor of 2.3 and nobody noticed for months, because nothing
ever checked it against reality.

**3. Do NOT reuse the grease sensor's numbers as a template.** The two vessels have different
capacities, so `totalCapacityVolume` will differ, and that is one weak way to tell them apart. It is
not a reliable discriminator on its own; use the asset id.

**4. One asset id maps to a vehicle AND a compartment.** Today that mapping is implicit, holding only
because there is exactly one sensor and it happens to be grease. With two it becomes ambiguous and
must be made explicit. `entity_source_links` already carries `entity_type='vehicle'` rows for the
three trucks keyed on the Samsara vehicle id; a sensor is a different entity and a different grain,
so decide deliberately whether it is a new `entity_type`, a column, or a small table. **Do not
silently overload the vehicle link.**

**5. `inspections.water_gallons` is the field the water sensor supersedes**, exactly as `fillVolume`
supersedes `sludge_gallons`. Both halves of that manual form died with Airtable on 2026-07-11.

**6. Anything that sums or displays "tank level" must state WHICH tank.** Once two sensors exist, a
single unlabelled number is wrong rather than merely incomplete. And while only one exists, a total
labelled "tank" is already misleading.

⚠ One open data question, noted while measuring: `inspections.water_gallons` has a max of 3,800,
exactly equal to the `sludge_gallons` max, across 69 readings. That looks like occasional
double-entry of the same figure rather than a real water capacity. **Do not use the historical
`water_gallons` values to size the water tank or to sanity-check the new sensor.** Take the capacity
from the sensor's own vessel profile and have someone confirm it against the truck.

## 8. "Per location, how much we pumped"

Fred, quoting a discussion with Andrew: *"We need to be able to see, per location, how much we
pumped so he is going to his engineer to try to find a way to get it hopefully through the API."*

**The API already carries it. No new Samsara work is required.** The daily curve is clean and reads
like an operations log. Moises, 2026-09-03 ET, from `fillVolume`:

```
00:00  2849 gal      00:30   345 gal  <- dump      03:30   566 gal  <- pickups begin
08:00  1945 gal      09:00-14:00 ~1930 flat        15:00  3535 gal
19:30  3359 gal      20:00     0 gal  <- dump at Homestead
```

Attribution is a real engineering task, and **every blocker is on our side**:

1. **`visits.start_at` / `end_at` are SCHEDULED slots.** Every visit is exactly 60 minutes, so
   differencing across them produces nonsense, including large negatives at client sites. Attribution
   must come from **GPS dwell**, which we already have at one fix per 32 s.
2. **Co-located clients collide.** A 150 m radius credits one pickup to every restaurant in the
   plaza. Measured: `Signor SASSI` and `Davinci` returned an identical window and an identical
   +1,227 gal; three separate South Beach clients likewise shared one window. Some sites may be
   genuinely unresolvable at GPS accuracy.
3. **The truck sloshes.** A top-down radar on a moving vehicle reads a moving surface, which is what
   the mid-afternoon transients are. Sample only while stationary, or use `smoothedFillVolume`.

`fillVolumeIngress` and `fillVolumeEgress` are Samsara's own throughput primitives and are the
natural starting point rather than differencing `fillVolume` by hand.

## 9. None of it reaches our database

- The LM11 has **zero rows in `entity_source_links`**. Only the three vehicles are linked, last
  synced 2026-04-29.
- Our Samsara ingest (`samsara-locations-history.yml`, `samsara-poll.yml`, `webhook-samsara`) calls
  only the **vehicle** endpoints. Nothing calls `/assets/*` or `/readings/*`.
- So every number in this document currently lives only inside Samsara.

## 10. Related: we used to capture this by hand, and it stopped

`public.inspections` is keyed on `vehicle_id` + `shift_date` and carries `sludge_gallons`,
`water_gallons`, `gas_level`, `is_valve_closed`. Moises has **112** PRE/POST shift forms.

**Last entry 2026-07-11; zero in the 30 days to 2026-09-04.** It arrived through the Airtable
PRE/POST shift form, the last remaining Airtable inbound feed, which went quiet around 2026-07-15
when Airtable was retired. Admin Review already logs the app symptom as known-issue #13, "Shift Forms
(inspections) feed NOT up to date". The LM11 replaces the sludge half of that form automatically.
The water half remains unsourced.

## 11. Traps for whoever works on this next

- **`GET /v1/sensors/list` returns `200 {"sensors":[]}` while POST on the same path returns 401.**
  That empty list is not evidence of anything. It is a POST route.
- **`readingsIngestionEnabled` is a red herring here.** It is the flag for gateway-less, software-only
  assets you push data into, and it must NOT be set on an asset that has a gateway. All four of our
  assets read `false`, correctly.
- **`connectionStatus.healthStatus` FLICKERS.** Measured blank on only the LM11 at 14:06Z and on
  three gateways at 14:15Z. It is not a health signal for this device.
- **`cellularDataUsageBytes = 0` does not mean "no cellular radio".** Six of ten gateways read 0,
  including all three CM34 dash cams. Use the datasheet.
- **`/v1/fleet/assets/{id}/locations` returns `time` as an epoch-ms INTEGER**, not an ISO string,
  unlike the v2 vehicle endpoints. Parsing it as a string yields silent `NaN`.
- **`kb.samsara.com` returns 403 to WebFetch and to the in-app browser.** `curl` worked. If a KB
  article is needed, do not report it as undocumented.
- **A workspace-root ripgrep obeys an allowlist `.gitignore` admitting 3 files.** Search inside
  `Supabase/` and `Building Apps/` directly. Separately, `--no-ignore` is a **ripgrep** flag and GNU
  grep is what is installed here; passing it with `2>/dev/null` produces a silent, confident zero.
  This bit both a research agent and me in the same session.

## 12. Open

1. Should we ingest `fillVolume` into the warehouse, and at what grain?
2. When is the water unit being fitted, and by whom? It is expected but not installed as of
   2026-09-04. §7 is the checklist for the day it lands.
3. Does any already-filed Miami-Dade LWT monthly report need amending, given 446 rows now render
   3,840 rather than 9,000?
4. `inspections.water_gallons` max is 3,800, exactly equal to the `sludge_gallons` max, which looks
   like occasional double-entry rather than a real water capacity. Not investigated.
