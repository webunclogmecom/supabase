# Samsara: what we actually have — the state before any geofencing work

*Measured against Prod `wbasvhvvismukaqdnouk` on 2026-08-07. Read-only; nothing was written to
Prod or to Samsara to produce this document.*

Written because Fred asked to represent **client geolocations and geofencing** in the Client App the
way we already represent Jobber data, and wanted the ground truth documented **before** any planning.

> **How to read this.** Every number here is measured unless labelled. Statements sourced from the
> **Samsara Assistant** (the vendor AI in the dashboard) are marked `[vendor]` and are NOT
> independently verified — it answers from Samsara's side only, and §7 records where that made it
> wrong about us. Where a sweep's own instrument failed, that is recorded rather than hidden.

---

## 1. The one-line version

**Samsara is a GPS breadcrumb feed with a thin engine/fuel sidecar, and its highest-leverage use is
not telematics at all** — an hourly Haversine match against property coordinates is the dominant
writer of `visits.vehicle_id`, which is what puts a truck name and a DERM decal on a customer's work
order. Its Address Book has seeded coordinates and a geofence *label* onto about a third of
properties. **There is no geofencing feature in our data**, and the half that would deliver
arrival/departure is wired but structurally incapable of firing (§5).

---

## 2. Inbound

### Live

| Path | Mechanism | Writes | Reality |
|---|---|---|---|
| **GPS track** | GH Actions `samsara-locations-history.yml` → `GET /fleet/vehicles/locations/history` | `vehicle_telemetry_readings` | `*/15` configured, **11 runs in 24h** (expect 96). Each run pulls a ~90-min window, so rows are **bursty**: median gap 6s, daily totals 1,086–14,585. Self-heals via `AUTO_LOOKBACK_H=24`. |
| **Engine/fuel** | `samsara-poll.yml` → `GET /fleet/vehicles/stats` | same table | `*/10` configured, **12 runs in 24h** (expect 144). **No self-heal** — one instantaneous sample per run, so ~92% of intended samples are permanently lost. |
| **Address Book webhook** | edge fn `webhook-samsara`, HMAC-SHA256 | `properties` geo columns + `entity_source_links` | **Silent since 2026-07-23 16:15:52Z.** 19 processed / 5 skipped (no client match) in the 30-day log. |
| **Driver webhook** | `handleDriver` | `employees`, `entity_source_links` | **1 event ever** (`DriverCreated`, 2026-07-08). `DriverUpdated` has never fired. |
| **Weekly geo backfill** | `weekly-geo-backfill.yml` Sundays 13:00 | `properties` geo, **NULL-only, never overwrites** | Last success 2026-08-02. |

Auth is a static `SAMSARA_API_TOKEN` bearer. **No API version header is sent anywhere.**

### Dead

- **`handleVehicleStats`** — 0 events ever, **dead by design**: Samsara exposes no such webhook type.
- **`handleGeofenceAlert`** — 0 events ever, has never written a row. See §5.
- **Samsara tier in `geocode_missing_properties.js`** — `trySamsara()` is an unconditional-null stub
  that reads like an ingest path and is not one.
- **No pg_cron job touches Samsara** (0 of 17). Everything is GitHub Actions.
- **`sync_log` has no Samsara source** (0 of 16). Samsara pipeline health is observable only from
  `max(recorded_at)` or GitHub run history.

---

## 3. What we store

| Object | Rows | Freshness |
|---|---|---|
| `vehicle_telemetry_readings` | **1,270,928** (GPS 1,263,689 / stats 7,239) | live, max `2026-08-07 10:10:43Z` |
| — by truck | Moises 432,138 · Cloggy 443,368 · David 395,422 · **Goliath 0** | Goliath is INACTIVE, no Samsara mapping |
| — column fill | lat/lng **100%** · heading 34.8% · fuel 0.56% · odometer 0.56% · engine_state 0.54% · **speed 0%** · **engine_hours 0%** | |
| `properties` geo | 855 rows: lat/lng **853 (99.8%)**, `geofence_type` **295 (34.5%)** (circle 167 / polygon 128), `geofence_radius_meters` **229 (26.8%)** | frozen since 2026-07-23 |
| `entity_source_links` (samsara) | **498** — client 208, property 282, employee 5, vehicle 3 | max `synced_at` 2026-07-23 |
| `visits.is_gps_confirmed` / `actual_arrival_at` / `actual_departure_at` | **0 / 0 / 0 populated** across all 2,426 visits | never written; read by 9 objects |

**Zero `samsara_*` columns exist on any business table** — rule #1 holds. **No PostGIS, no spatial
type anywhere.** All proximity maths is hand-rolled JS Haversine or a flat `/111` degree approximation.

⚠ `properties` has **no per-row provenance column**, so a Samsara-sourced coordinate is
indistinguishable from a Google-geocoded one.

---

## 4. How Samsara connects to a client or property

Everything routes through `entity_source_links`. There is no FK, no geofence table, no Samsara id on
any business table.

```
Samsara Address --(source_id)-------> esl[client]   --> clients.id
Samsara Address --(addr_<id>)-------> esl[property] --> properties.id
Samsara Vehicle --(2814749987062xx)-> esl[vehicle]  --> vehicles.id --> telemetry.vehicle_id
Samsara Driver  --(8-digit id)------> esl[employee] --> employees.id
```

🛑 **A GPS reading joins to `vehicle_id` and nothing else. There is no join path from a telemetry row
to a client, a property, or a visit.** The only bridge is indirect and computed:
`derive_visit_vehicle_id.js` (hourly) Haversine-matches telemetry against
`properties.latitude/longitude` at 150/300/500m tiers. **It uses property coordinates, not geofences.**

**Coverage:** clients **208 / 442 (47.1%)** — RECURRING 118/144 (81.9%), ACTIVE 82/283 (29.0%).
Properties **282 / 855 (33.0%)** across 249 distinct clients.

⚠ **`source_id` uses TWO namespaces for `property`**: 224 bare numeric, **58 prefixed `addr_<id>`**
(written by `backfill_geo_from_samsara.js:136` and the webhook's new-property branch). A naive join on
raw `source_id` finds 204 pairs; normalising `^addr_` finds **232**. **A join that skips the
normalisation is blind to 21% of property links** — and the sweep that found this hit exactly that bug
before adding the normaliser.

---

## 5. 🛑 Geofencing: the honest answer is "we have a label, not a feature"

**What exists:** two columns on `properties` — a type word and a radius — on a minority of rows, plus
a centroid. That is all.

**What does not exist:** no geofence table, no geofence id, no enter/exit event store, no spatial
index, no polygon vertices, no event history.

**Polygon shapes are DISCARDED at ingest.** Both `backfill_geo_from_samsara.js:94` and
`webhook-samsara/index.ts` do `geofence?.polygon ? 'polygon' : geofence?.circle ? 'circle' : null`
and take the radius **only** from `geofence.circle.radiusMeters`. For a polygon we keep the *word*
"polygon" and a centroid; **the vertices never enter the database.** Samsara's `/addresses` does
return the real shape today — we throw it away.

**Nothing reads the geofence columns.** `derive_visit_vehicle_id.js`, `dump_investigate` and
`dump_resolve_truck` all do their own distance maths and **none of them reads
`properties.geofence_radius_meters`.**

### The concrete wiring defect

The 6 hooks actually registered at Samsara are `AddressCreated`, `AddressUpdated`, `AddressDeleted`,
`DriverCreated`, `DriverUpdated`, and `["AlertIncident","AlertObjectEvent"]`.

`routeEvent` (`webhook-samsara/index.ts:437-440`) has cases only for `AlertTriggered`,
`GeofenceEntry`, `GeofenceExit`. **The strings `AlertIncident` and `AlertObjectEvent` appear nowhere
in `supabase/functions/`.**

⇒ Any alert Samsara sends falls to `default:`, is logged `status='skipped'`, and returns HTTP 200.
**Even a correctly configured, correctly firing geofence alert would not be processed today.**

And `integration.md:212` instructs registering `GeofenceEntry` / `GeofenceExit` — **Samsara does not
expose those as subscribable event types** (`register-samsara.js` ~line 100). That instruction cannot
be followed by anyone who tries.

---

## 6. The Samsara side `[vendor]`

From the dashboard Assistant on 2026-08-07. **Its org numbers are plausible and it was explicit about
what it could not see, but none of this is independently verified.**

- **Address and Geofence are ONE object.** An Address (a.k.a. Place) has name, street address,
  lat/lon, category, tags, notes and **`externalIds`**, and *contains* exactly one geofence. Samsara
  draws a default circle if none is given. Geometry: circle, rectangle, or **polygon up to 2048
  vertices**. There is no independent "create a geofence" call.
- **`externalIds` is addressable**: `GET /addresses/{id}` accepts `externalIds:<namespace>:<value>`,
  not just the numeric id. The Assistant recommended keeping the rich record in our DB and using
  `externalIds` purely as the join key, rather than stuffing JSON into `notes`.
- **Endpoints:** `POST/GET /addresses`, `GET /addresses/{id}`, `PATCH /addresses/{id}`,
  `POST/GET /tags`, `GET /fleet/vehicles/locations`, `GET /fleet/trips`. Base `https://api.samsara.com`,
  bearer token. Reference: <https://developers.samsara.com/reference>.
- **Org state claimed:** 249 Addresses, **193 (~77%)** matching our `NNN-XXX ClientName` pattern,
  **56 non-conforming** (e.g. `Sakura Sushi`, `Krudo Warehouse`, `Le Prestige`); **zero** Addresses
  carry `externalIds`; exactly **one tag** exists (`Admin`, on one driver) and **zero Addresses are
  tagged**.
- **It could NOT inspect webhooks** and said so plainly, guessing none are wired and telling us to
  confirm. ⚠ **Its guess is wrong** — see §7.
- Arrival/departure would come from a **Geofence Entry/Exit alert webhook**, or by polling
  `GET /fleet/trips`, which annotates entered/exited addresses per trip.
- Suggested tag taxonomy: `Client:<code>`, `ServiceFrequency:<Weekly|Biweekly|Monthly|Quarterly>`,
  `Region:<zone>`, optionally `Priority:High`, `AccessType:Rear`. ⚠ Note `Region:` and
  `ServiceFrequency:` would duplicate our `zones` table and `frequency_days` — a second source of
  truth for something we already own.

---

## 7. 🛑 Where the vendor AI was wrong about us, and where our own docs are wrong

**The vendor's central claim — *"no structured join back to your DB"* — is false from our side.** It
can only see Samsara, where no `externalIds` are set. We hold **498 links in
`entity_source_links`**, including 282 property links. The join exists; it simply lives in our
database rather than in theirs. Any plan built on "there is no join today" would be solving a problem
we do not have.

Its guess that **no webhooks are wired is also wrong**: `AddressCreated/Updated/Deleted` and
`DriverCreated/Updated` are registered and delivering (25 events since the log began 2026-07-08).

**⚠ Unreconciled:** the vendor counts **249 Addresses**; we hold **282 property links**. More links
than addresses means stale links, deleted addresses, or duplicates. **This is not explained, and it
decides whether the first step is a backfill or a cleanup.**

### Stale docs (measurement wins in every row)

| Doc | Says | Measured |
|---|---|---|
| `ADR 007` | geofence enter/exit events justify Samsara being permanent; GPS enrichment "continues to work" | **0 of 2,426 visits** ever enriched |
| `integration.md:212` | register `GeofenceEntry`/`GeofenceExit` | those event types do not exist |
| `architecture.md:74` | Samsara owns harsh events and DVIR | **neither exists as a table or column** |
| `CLAUDE.md:27`, `ADR 011:30` | Samsara owns "geofences" | nothing owns them |
| `schema.md:538,692` | `vehicle_telemetry_readings` has 0 rows | **1,270,928** |
| `v_vehicle_telemetry_latest` | exposes `speed_mph`, `engine_hours` | can never be non-null |

### Instrument failures declared during this survey

- A repo-wide ripgrep started at the **workspace root obeys an allowlist `.gitignore` admitting only
  3 files** — the first geofence sweep returned 1 result and was worthless. Use `--no-ignore`.
- A regex test for whether `customer.get_work_order` exposes `truck` returned false — **so did its
  positive control**, so the instrument was wrong. Reading the body reversed the answer: it **does**
  expose truck and decal to customers (the function uses `to_jsonb(w)` and names no columns).
- `webhook_events_log` only reaches back to **2026-07-08**, so no "never happened" claim may rest on
  it. The load-bearing evidence for "geofence alerts never fired" is the retention-independent
  **0 / 2,426** column measurement.
- Three different `visits.vehicle_id` coverage figures exist (≈20%, 91.4%, 926/1,745) because they
  count **different populations** (all visits vs completed-only). **Never quote them interchangeably.**

---

## 8. Open questions

### Answerable from Samsara without Fred

1. Does the Address Book hold **polygon vertices** for all 295 typed properties, and how many of the
   560 untyped ones have a geofence there we never ingested?
2. Are any **alert rules** configured at all? The DB cannot distinguish "no rules" from "alerts fire
   and are dropped by the missing `routeEvent` case" — both yield 0 rows.
3. What is the real payload of `AlertIncident` / `AlertObjectEvent`, and does it carry geofence id and
   enter/exit semantics?
4. Does `/fleet/vehicles/locations/history` return speed at all, or is our 0% a Samsara limitation?
5. Why did the address webhook go silent on 2026-07-23 — no edits, or a broken registration?
6. Is there a stable `geofence_id` we could key a bridge on, rather than the `addr_` string we invented?

### Only Fred or Yannick can answer

1. **Who owns the geofence definition of a client site** — Samsara's Address Book, our `properties`
   row, or Jobber? The trust hierarchy says Samsara; today nothing does.
2. Are the **13 `gps_100m` client/property mismatches** wrong, or legitimate shared-address chains?
3. What are the **58 `addr_`-prefixed link ids** meant to be, and should the namespaces be reconciled?
4. Is **47% client / 33% property coverage** acceptable, or are the 234 unlinked clients an omission?
5. Should `visits.is_gps_confirmed` / `actual_arrival_at` / `actual_departure_at` be **revived or
   retired**? Read by 9 objects, never held a value.
6. **May a customer see a truck name and DERM decal derived from a GPS guess?** 609/629 work orders
   show a truck; `vehicle_source='assigned'` does not distinguish machine attribution from a
   dispatcher's.
7. Is the **~hourly effective GPS cadence** acceptable, given `dump-visit-create` rejects a fix older
   than 10 minutes and therefore falls back to the phone for most of every hour?

---

## Files worth opening first

- `supabase/functions/webhook-samsara/index.ts` — routing 414-443, `handleGeofenceAlert` 335
- `scripts/webhooks/register-samsara.js` ~line 100 — contradicts `integration.md:210-214`
- `scripts/sync/backfill_geo_from_samsara.js` — line 94 discards polygons, line 136 writes `addr_` ids
- `scripts/sync/derive_visit_vehicle_id.js` — the real GPS enrichment
- `scripts/probes/link_properties_to_samsara.js:99` — the `dist <= 100` matcher behind the bad links
- `.github/workflows/samsara-locations-history.yml` — the undocumented high-frequency feed
- `docs/runbook.md` 208-227 — the section most likely to cause harm if followed
