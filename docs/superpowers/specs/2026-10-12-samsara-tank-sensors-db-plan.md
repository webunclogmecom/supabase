# Samsara tank sensors and truck telemetry: implementation plan (revision 2)

**Status.** Design only, 2026-10-12 (ET). Nothing applied. Every check behind this revision was read-only (catalog
and row SELECTs in read-only transactions, Samsara GETs, local scripts over the discovery pulls). Nothing was written
to Prod, Samsara or the repos.

**Labels.** [O] observed, method stated. [I] inferred. [U] unverified. Owner decisions are **[OWNER Dn]**, collected
in section 12. Public-repo hygiene: no client names or codes; clients, properties and visits by internal id only.

**Companion:** [../../reference/samsara-tank-sensors-2026-10-12.md](../../reference/samsara-tank-sensors-2026-10-12.md) (what the devices report, in plain language, with the measurements).

**How it was made:** discovery by four parallel read-only agents, three independent designs (raw-first, domain-first, minimal), three judges, a synthesis, four adversarial reviewers plus a completeness critic (50 findings, 2 blockers, all answered in Appendix A), then this revision. The owner's voice note of 2026-10-12 is the spec.

---

## 0. What changed in this revision

Revision 1 (the synthesized plan, base design B with grafts from A and C) was reviewed by a verification pass (50
findings: 2 blockers, 27 major, 21 minor) and a completeness critic (24 gaps). Every finding is answered in
**Appendix A** and every gap in **Appendix B**. The changes that reshape the design:

1. **Dump sites use the registry that already exists** (`public.dump_sites` + `public.non_customer_clients`, reached
   through the Samsara address's existing property link). The `disposal_facility` ESL type is gone; the CHECK widens
   by one value (`tank_sensor`). Site events and stops point at **properties** (rule 9), which also covers the truck
   yard. (Blocker V1.)
2. **Levels are measured on value changes, not rows.** The LM11 takes a new measurement about every 10 minutes and
   repeats it in between [O, 1,883 value changes in 52.9 days on sludge, median gap 632 s, 86% at least 590 s apart].
   Edges, spike filter, false-empty rule and hysteresis are redefined on measurements, with a look-ahead and an end
   flush. (Blocker V21 plus V22, V23, V29.)
3. **Measurement and linking are recompute-and-diff, not one-shot.** Level rows are recomputed over a 35-day horizon
   plus every row a provenance check flags; links are reconciled over the whole sensor era every hour. Late readings,
   corrections, rebuilds and visit edits heal themselves. (V2, V6, V8, V31, V32, V35, V36, V40.)
4. **Stops cannot overlap** (exclusion constraint), an open dump dwell is a barrier, and the stop builder never runs
   past the event feed's watermark. (V3, V30, V39.)
5. **Linking is anchored on completion time for every visit kind**, sludge is shared only among Pumping visits, the
   window fallback never uses the scheduled start, and dump visits link only to dump stops of their own site. (V25,
   V26, V27.)
6. **Corrections are expressible everywhere:** configurations and site events get a set-once `superseded_at`.
   (V4, V5, V41.)
7. **Security:** grants revoked from `service_role` too and asserted literally, TRUNCATE blocked, identity sequences
   revoked, the fill-fraction helper is SECURITY INVOKER, public views are owner-rights so the later ops wrappers can
   read them. (V14, V15, V16, V19, V20.)
8. **Health:** process failures and data findings go to separate `sync_log` sources, so one long-open data issue
   cannot hide a feed failure. (V37, V38, V45.)

---

## 1. Goals and non-goals

The owner's words are the spec (voice note, 2026-10-12).

| # | Goal |
|---|---|
| G1 | Store what the two LM11 sensors measure, keyed by Samsara asset id through ESL, never by name. *"we need to know what kind of information we can get from it"* |
| G2 | Per visit: time at the stop(s), sludge collected, water used and refilled, each with a confidence and a reason. *"how long they stayed on that client, how much water was used, how much sludge was pumped out"* |
| G3 | Per dump: gallons offloaded, and a check of collected against dumped. *"how much sludge did we really pump out"* |
| G4 | Compliant with our architecture rules: 3NF, real FKs, no orphans, gaps visible in both directions (a visit with no stop, work with no visit). *"compliance to what our architecture is for ... three normal form ... everything needs to be linked. No orphans."* |
| G5 | Trucks without sensors (Cloggy, David) still get stops, dwell, dump detection and visit links; David gets pump minutes from PTO. |
| G6 | Survive the known traps: no water capacity in Samsara [O], silent Samsara profile edits [O: 5 capacity flips on 2026-08-20], the 10-minute measurement period [O]. |

"Compliance" in the recording means compliance with the database architecture (section 13 is the answer). Regulatory
uses are non-goal N1.

**Non-goals (v1):**
- N1. No change to any regulator-facing object (`derm.*`, LWT, DERM sheets). A recurring boundary check proves it (Z8).
  Using measured gallons in a filing is [OWNER D8].
- N2. No change to `visits.actual_arrival_at`, `actual_departure_at`, `duration_minutes` or `fn_compute_time_on_site`
  in the core plan. Separate owner-gated step M8 [OWNER D4].
- N3. Not ingested: Samsara volume readings (`fillVolume`, ingress, egress, smoothed, capacity, available), `daysUntil*`,
  `fillCriticality`, mass readings, the sensors' own GPS and geofence events, and client-site geofence events. Reasons:
  ingress and egress do not balance (99,091 gal in, 107,810 gal out, level moved -1,901 gal over 53 days [O]);
  `fillVolume` equals percent x capacity to 0.073 L [O]; the sensors' position is an echo of the truck's [O];
  client-site events belong to `samsara-geofencing-plan.md` (see 9.1).
- N4. Not fixed here: the GPS writer's speed/heading bug, the stats collision, the telemetry FK CASCADE and its wide
  grants (TIMED_JOBS_PLAN 2.3, audit 2026-10-05). This plan only reads GPS rows.
- N5. No customer exposure; no app exposure until [OWNER D6].
- N6. No automatic correction of `visits.vehicle_id`, and no automatic Dump Offload records. Flagged only [OWNER D14].
- N7. No "water recovered" figure: two top-down sensors cannot separate rinse water inside the sludge tank
  (correlation 0.22 over 33 stops [O]). Meaning to confirm [OWNER D15].

---

## 2. Entities and tables

### 2.0 Map

```
vehicles 1--n vehicle_tanks 1--n vehicle_tank_configurations      (effective-dated, insert-only, set-once superseded_at)
              vehicle_tanks 1--n tank_sensor_installations n--1 tank_sensors
                                                             --ESL(tank_sensor, samsara)          -> Samsara asset id
                                                             --ESL(tank_sensor, samsara_gateway)  -> gateway serial
              tank_sensors 1--n tank_sensor_distance_readings, tank_sensor_fill_percent_readings
vehicles 1--n vehicle_engine_rpm_readings, vehicle_pto_readings
vehicles 1--n vehicle_site_events n--1 properties          (dump-site and yard properties; resolved through the
                                                             EXISTING ESL property link of the Samsara address)
vehicles 1--n vehicle_stops (site_property_id -> properties, nullable)
              vehicle_stops 1--n vehicle_stop_tank_levels   (composite FKs: same vehicle, same tank)
visits n--m vehicle_stops via visit_vehicle_stops
vehicle_telemetry_readings (exists, GPS)  -> read by fn_build_vehicle_stops
dump_sites, non_customer_clients, ops.v_dump_sites, ops.v_depot (exist) -> read for site resolution
```

**Conventions for the 12 new tables:**
- All in `public`, snake_case, FKs named `<table>_id bigint`, every FK indexed (an index counts when it leads with the
  FK columns), every FK `ON DELETE RESTRICT`.
- RLS enabled, no policies.
- **Privileges:** `revoke all on <t> from public, anon, authenticated, service_role;` then `grant select on <t> to
  service_role;` and, on the 5 raw tables only, `grant insert on <t> to service_role;`. `db_backup_reader` keeps its
  default `r`. Identity sequences: `revoke all ... from public, anon, authenticated, service_role` (loop over
  `pg_get_serial_sequence`, precedent `2026-09-25_1330_property_pages.sql`). Verified by asserting the **literal**
  ACL set (section 10, M2), not by comparing with a sibling.
- Identity `id bigint generated always as identity` on the 7 non-raw tables. The 5 raw tables use a composite natural
  primary key (no row references a single reading; saves an index on the largest tables; 11 composite-key precedents
  exist [O]); recorded in ADR 020.
- Every table carries both guard triggers from 2.1.

### 2.1 Append-only guard (one function, every table)

```sql
create function public.fn_append_only_guard() returns trigger
language plpgsql set search_path = '' as $$
declare v_old jsonb; v_new jsonb; v_col text;
begin
  if tg_op in ('DELETE','TRUNCATE') then
    raise exception 'blocker=append_only: % on %.%', tg_op, tg_table_schema, tg_table_name using errcode = '55000';
  end if;
  v_old := to_jsonb(old); v_new := to_jsonb(new);
  foreach v_col in array coalesce(tg_argv, '{}'::text[]) loop      -- columns allowed to go NULL -> value, once
    if v_old -> v_col <> 'null'::jsonb and (v_new -> v_col) is distinct from (v_old -> v_col) then
      raise exception 'blocker=append_only: %.% may be set once', tg_table_name, v_col using errcode = '55000';
    end if;
    v_old := v_old - v_col; v_new := v_new - v_col;
  end loop;
  if v_old is distinct from v_new then
    raise exception 'blocker=append_only: UPDATE on %.%', tg_table_schema, tg_table_name using errcode = '55000';
  end if;
  return new;
end $$;
revoke all on function public.fn_append_only_guard() from public, anon, authenticated, service_role;

-- on every table <t> (set-once columns listed per table below):
create trigger <t>_append_only before update or delete on public.<t>
  for each row execute function public.fn_append_only_guard(<set_once_cols>);
create trigger <t>_no_truncate before truncate on public.<t>
  for each statement execute function public.fn_append_only_guard();
```

Modelled on `fn_property_pages_append_only` and its statement-level `property_pages_no_truncate` [O]. One function
serves both trigger levels because the TRUNCATE branch raises before touching OLD/NEW. A trigger, not grants alone,
because migrations and SECDEF functions run as `postgres`. TRUNCATE writes no `audit.logs` row and fires no row
trigger, hence the second trigger. A DROP still bypasses both, so every rollback exports first (10.3).

### 2.2 Configuration tables (audited; written by migrations only in v1)

```sql
create table public.vehicle_tanks (
  id          bigint generated always as identity primary key,
  vehicle_id  bigint not null references public.vehicles(id) on delete restrict,
  contents    text   not null check (contents in ('sludge','fresh_water')),
  created_at  timestamptz not null default now(),
  deleted_at  timestamptz,
  unique (id, vehicle_id)                                        -- target of composite FKs
);
create unique index vehicle_tanks_one_live on public.vehicle_tanks (vehicle_id, contents) where deleted_at is null;
create index vehicle_tanks_vehicle_id_idx on public.vehicle_tanks (vehicle_id);
-- guard('deleted_at'); audit_vehicle_tanks

create table public.vehicle_tank_configurations (
  id                   bigint generated always as identity primary key,
  vehicle_tank_id      bigint not null references public.vehicle_tanks(id) on delete restrict,
  effective_from       timestamptz not null,
  shape                text not null check (shape = 'horizontal_cylinder'),   -- ponytail: widen when a strapping chart arrives (D1)
  diameter_meters      numeric(6,4) not null check (diameter_meters > 0),
  sensor_offset_meters numeric(6,4) not null check (sensor_offset_meters >= 0), -- sensor face to max fill (Samsara "Height Offset")
  capacity_gallons     numeric(8,1) check (capacity_gallons > 0),             -- NULL = unknown, never guessed
  basis                text not null check (basis in ('fitted_from_readings','vendor_profile','owner_confirmed','measured_on_truck')),
  notes                text,
  created_at           timestamptz not null default now(),
  superseded_at        timestamptz,                                           -- this row was WRONG; a corrected row replaces it
  unique (id, vehicle_tank_id)
);
create unique index vtc_live_effective on public.vehicle_tank_configurations (vehicle_tank_id, effective_from)
  where superseded_at is null;                                                -- also serves the FK
-- guard('superseded_at'); audit_vehicle_tank_configurations

create table public.tank_sensors (               -- one row per PHYSICAL LM11 device (stable: its gateway serial)
  id         bigint generated always as identity primary key,
  model      text not null check (model in ('LM11')),
  created_at timestamptz not null default now()
);
-- guard(); audit_tank_sensors

create extension if not exists btree_gist with schema extensions;
create table public.tank_sensor_installations (
  id              bigint generated always as identity primary key,
  tank_sensor_id  bigint not null references public.tank_sensors(id)  on delete restrict,
  vehicle_tank_id bigint not null references public.vehicle_tanks(id) on delete restrict,
  installed_at    timestamptz not null,
  removed_at      timestamptz,            -- physical removal or move
  superseded_at   timestamptz,            -- this row was WRONG (a correction)
  created_at      timestamptz not null default now(),
  check (removed_at is null or removed_at > installed_at),
  unique (id, vehicle_tank_id),
  exclude using gist (tank_sensor_id  with =, tstzrange(installed_at, removed_at) with &&) where (superseded_at is null),
  exclude using gist (vehicle_tank_id with =, tstzrange(installed_at, removed_at) with &&) where (superseded_at is null)
);
create index tank_sensor_installations_tank_idx on public.tank_sensor_installations (vehicle_tank_id);
-- the first GiST index leads with tank_sensor_id and serves that FK
-- guard('removed_at','superseded_at'); audit_tank_sensor_installations
```

**"In force" is always over live rows:** configuration C for tank T at time t = the row with `superseded_at is null`
and the largest `effective_from <= t`. Installation for tank T at t = the row with `superseded_at is null` and
`installed_at <= t < coalesce(removed_at, 'infinity')`, on a tank with `deleted_at is null`.

**Seeds** (same transaction as their ESL links, rule 8; ESL `source_name` NULL on every row, V17):

| Row | Values | Basis [O] |
|---|---|---|
| Moises sludge tank | vehicle 1, `sludge` | |
| Moises fresh-water tank | vehicle 1, `fresh_water` | |
| Sludge configuration | effective 2026-08-20 21:00Z, cylinder 2.1336 m (84.00 in), offset 0, 3,840.0 gal, `vendor_profile` | 12,510 of 12,526 same-timestamp pairs within 0.01 pp; all 16 misses fall in the 08-20 setup window |
| Water configuration | effective 2026-10-02 17:09Z, cylinder 2.1336 m, offset 0.3048 m (12.00 in), capacity NULL, `fitted_from_readings` | 2,431 pairs, worst error 0.0005 pp; a 2.0 m control misses by 5.34 pp |
| Sensors | 2 `tank_sensors` (LM11) | |
| Installations | sludge sensor on sludge tank from 2026-08-20 14:43Z; water sensor on water tank from **2026-10-02 19:29Z** | first readings; the water unit's 399 zero-distance rows all fall 17:09 to 19:29Z (setup) |

Cloggy and David get no tank rows until they get sensors; their capacity stays only in `vehicles` (one interim
duplicate, 3,840 on Moises, flagged by F8).

### 2.3 Corrections without rewriting history

| Event | Action |
|---|---|
| Sensor physically moved | set `removed_at` on the old installation, insert a new one |
| Wrong sensor-to-tank mapping | set `superseded_at` on the bad installation (insert the correct one if any); the next hourly measure supersedes every level row built on it |
| Wrong geometry or capacity | set `superseded_at` on the bad configuration and insert the corrected row **with the same `effective_from`** in one audited transaction; level rows re-measure |
| Wrong site resolution of address events | set `superseded_at` on the affected events; rebuild that vehicle's stops from the first affected time (one call, 5.5) |
| Samsara re-creates the asset for the same device | keep the `tank_sensors` row (it is the device); move the `samsara` asset link to the new id in a migration, writing a JSON backup of the old link first (ESL is unaudited, rule 6 note). Never add a second sensor row for the same serial |

### 2.4 Raw observation tables (append-only; service_role may INSERT)

```sql
create table public.tank_sensor_distance_readings (
  tank_sensor_id  bigint not null references public.tank_sensors(id) on delete restrict,
  recorded_at     timestamptz not null,                                   -- Samsara happenedAtTime
  distance_meters numeric(5,3) not null check (distance_meters >= 0 and distance_meters < 10),
  created_at      timestamptz not null default now(),                     -- arrival time (lateness)
  primary key (tank_sensor_id, recorded_at)
);
create table public.tank_sensor_fill_percent_readings (                   -- Samsara's own percent: drift witness only
  tank_sensor_id bigint not null references public.tank_sensors(id) on delete restrict,
  recorded_at    timestamptz not null,
  fill_percent   numeric(6,3) not null check (fill_percent between 0 and 100),
  created_at     timestamptz not null default now(),
  primary key (tank_sensor_id, recorded_at)
);
create table public.vehicle_engine_rpm_readings (
  vehicle_id  bigint not null references public.vehicles(id) on delete restrict,
  recorded_at timestamptz not null,
  engine_rpm  integer not null check (engine_rpm between 0 and 6000),
  created_at  timestamptz not null default now(),
  primary key (vehicle_id, recorded_at)
);
create table public.vehicle_pto_readings (
  vehicle_id  bigint not null references public.vehicles(id) on delete restrict,
  recorded_at timestamptz not null,
  pto_engaged boolean not null,
  created_at  timestamptz not null default now(),
  primary key (vehicle_id, recorded_at)
);
create table public.vehicle_site_events (
  vehicle_id    bigint not null references public.vehicles(id)   on delete restrict,
  property_id   bigint not null references public.properties(id) on delete restrict,   -- a dump-site or yard property
  recorded_at   timestamptz not null,
  event_kind    text not null check (event_kind in ('entry','exit')),
  created_at    timestamptz not null default now(),
  superseded_at timestamptz,
  primary key (vehicle_id, recorded_at, property_id, event_kind)
);
create index vehicle_site_events_property_idx on public.vehicle_site_events (property_id, recorded_at);
-- readings: guard(); site events: guard('superseded_at') + audit_vehicle_site_events (opt-in: ~2 to 10 rows a day,
-- corrections are human)
```

**One table per quantity:** the unit sits in the column name (rule 4); streams run on different clocks (sludge distance
median 31 s, percent 288 s [O]); a wide row would need a column-merging upsert, and the ignore-duplicates version of
that lost 76 of 100 stats samples on telemetry [O, TIMED_JOBS_PLAN 2.3].

**Not in `vehicle_telemetry_readings`:** the GPS writer resumes from the newest row whose odometer, fuel and engine
fields are null [O, `cron_samsara_locations_history.js` around line 116]; engine-only rows would move it.

**Known loss:** 3 of 104,806 sludge distance timestamps carry two values [O]; the key keeps the first.

**Why site events key on a property, not a facility or the address id:** the Samsara address is already linked in ESL
to the dump-site client (365) and to its property (98) [O]; rule 9 resolves address events to the service property;
dump-ness then comes from the existing registry (`non_customer_clients.kind = 'dump_site'`) through the property's
client, and the yard is a property too. No second identity, no vendor id in a business column, no new ESL type.

### 2.5 Derived tables (written only by the SECDEF functions in section 5)

```sql
create table public.vehicle_stops (
  id                bigint generated always as identity primary key,
  vehicle_id        bigint not null references public.vehicles(id) on delete restrict,
  arrived_at        timestamptz not null,
  departed_at       timestamptz not null,
  latitude          numeric(9,6) not null,           -- median of the stop's fixes
  longitude         numeric(9,6) not null,
  gps_fix_count     integer not null check (gps_fix_count >= 1),
  site_property_id  bigint references public.properties(id) on delete restrict,  -- set iff the stop is at a dump site or the yard
  formation         text not null check (formation in ('gps_walk','site_dwell')),
  algorithm_version smallint not null check (algorithm_version > 0),
  created_at        timestamptz not null default now(),
  superseded_at     timestamptz,
  check (departed_at > arrived_at),
  check (formation = 'gps_walk' or site_property_id is not null),
  unique (id, vehicle_id),
  exclude using gist (vehicle_id with =, tstzrange(arrived_at, departed_at) with &&) where (superseded_at is null)
);
create unique index vehicle_stops_live on public.vehicle_stops (vehicle_id, arrived_at) where superseded_at is null;
create index vehicle_stops_vehicle_time_idx on public.vehicle_stops (vehicle_id, arrived_at);
create index vehicle_stops_site_idx on public.vehicle_stops (site_property_id) where site_property_id is not null;
-- guard('superseded_at')

create table public.vehicle_stop_tank_levels (
  id                            bigint generated always as identity primary key,
  vehicle_stop_id               bigint not null,
  vehicle_id                    bigint not null,
  vehicle_tank_id               bigint not null,
  tank_sensor_installation_id   bigint not null,
  vehicle_tank_configuration_id bigint not null,
  arrival_fill_fraction         numeric(6,5) check (arrival_fill_fraction between 0 and 1),
  arrival_measured_at           timestamptz,     -- first-seen time of the measurement used for the arrival edge
  departure_fill_fraction       numeric(6,5) check (departure_fill_fraction between 0 and 1),
  departure_measured_at         timestamptz,
  fill_fraction_risen           numeric(6,5) check (fill_fraction_risen  >= 0),   -- NULL = not observable
  fill_fraction_fallen          numeric(6,5) check (fill_fraction_fallen >= 0),
  measurement_count             smallint not null check (measurement_count >= 0),
  rejected_measurement_count    smallint not null check (rejected_measurement_count >= 0),
  algorithm_version             smallint not null check (algorithm_version > 0),
  created_at                    timestamptz not null default now(),
  superseded_at                 timestamptz,
  check ((arrival_fill_fraction   is null) = (arrival_measured_at   is null)),
  check ((departure_fill_fraction is null) = (departure_measured_at is null)),
  check ((fill_fraction_risen is null) = (fill_fraction_fallen is null)),
  check (fill_fraction_risen is null or (arrival_fill_fraction is not null and departure_fill_fraction is not null)),
  foreign key (vehicle_stop_id, vehicle_id) references public.vehicle_stops (id, vehicle_id) on delete restrict,
  foreign key (vehicle_tank_id, vehicle_id) references public.vehicle_tanks (id, vehicle_id) on delete restrict,
  foreign key (tank_sensor_installation_id, vehicle_tank_id)
    references public.tank_sensor_installations (id, vehicle_tank_id) on delete restrict,
  foreign key (vehicle_tank_configuration_id, vehicle_tank_id)
    references public.vehicle_tank_configurations (id, vehicle_tank_id) on delete restrict
);
create unique index vstl_live on public.vehicle_stop_tank_levels (vehicle_stop_id, vehicle_tank_id) where superseded_at is null;
create index vstl_stop_idx          on public.vehicle_stop_tank_levels (vehicle_stop_id, vehicle_id);
create index vstl_tank_idx          on public.vehicle_stop_tank_levels (vehicle_tank_id, vehicle_id);
create index vstl_installation_idx  on public.vehicle_stop_tank_levels (tank_sensor_installation_id, vehicle_tank_id);
create index vstl_configuration_idx on public.vehicle_stop_tank_levels (vehicle_tank_configuration_id, vehicle_tank_id);
-- guard('superseded_at')

create table public.visit_vehicle_stops (
  id              bigint generated always as identity primary key,
  visit_id        bigint not null references public.visits(id) on delete restrict,
  vehicle_stop_id bigint not null references public.vehicle_stops(id) on delete restrict,
  match_basis     text not null check (match_basis in
                    ('completion','same_site_earlier','window','dump_completion','dump_window')),
  created_at      timestamptz not null default now(),
  deleted_at      timestamptz                       -- set by the linker when the match no longer holds
);
create unique index visit_vehicle_stops_live on public.visit_vehicle_stops (visit_id, vehicle_stop_id) where deleted_at is null;
create unique index visit_vehicle_stops_one_dump_visit on public.visit_vehicle_stops (vehicle_stop_id)
  where deleted_at is null and match_basis in ('dump_completion','dump_window');
create index visit_vehicle_stops_visit_idx on public.visit_vehicle_stops (visit_id);
create index visit_vehicle_stops_stop_idx  on public.visit_vehicle_stops (vehicle_stop_id);
-- guard('deleted_at'); audit_visit_vehicle_stops
```

**Why stored (rule 13):** a stop costs an anchor walk over about 3,700 fixes per truck-day [O: 36,911 Moises fixes in
10 days]; visits and measurements need a stable row to point at; `fn_compute_time_on_site` throws its clusters away
[O]. **Why fractions, not gallons:** a fraction needs geometry only (both tanks have it); gallons need capacity (water
has none). When a capacity arrives, gallons appear for every past stop with no re-run.

**Deferred:** manual links and share overrides wait for an app editor (D6). The wrong-truck fix is to correct
`visits.vehicle_id` through the existing app path; the next hourly reconcile re-links.

### 2.6 3NF justification (copied into each migration header, one line per column)

| Table | Key | Every non-key column depends on the whole key and nothing else |
|---|---|---|
| vehicle_tanks | id (natural: vehicle + contents among live rows) | `contents` describes the tank; capacity varies over time, so it lives on the configuration |
| vehicle_tank_configurations | id (natural: tank + effective_from among live rows) | geometry, capacity, basis describe the tank as of that instant; `effective_to` is derived with `lead()` |
| tank_sensors | id | `model` describes the device; vendor ids live in ESL |
| tank_sensor_installations | id (natural: sensor + range among live rows) | tank and range describe the installation |
| *_readings, vehicle_site_events | (entity, recorded_at[, property, kind]) | one observed value per key; percent and gallons are not stored |
| vehicle_stops | id (natural: vehicle + arrived_at among live rows) | times, position, fix count, site, formation describe how the stop was formed; duration, kind, pump minutes are view-only |
| vehicle_stop_tank_levels | id | measurement values, edge times, counts describe this measurement. **Stated honestly:** `vehicle_id` and `vehicle_tank_id` are functionally determined by `vehicle_stop_id` and by `tank_sensor_installation_id` respectively, so they are deliberate, constrained redundancy kept consistent by the four composite FKs (a row cannot attach one truck's tank to another truck's stop). This is a documented exception to rule 3, recorded in ADR 020 |
| visit_vehicle_stops | id (natural: visit + stop among live rows) | `match_basis` describes the pairing; shares are derived in a view |

---

## 3. Sensor and site mapping

### 3.1 ESL rows (seeded with the rows they describe; `source_name` NULL on all)

| entity_type | entity_id | source_system | source_id | note |
|---|---|---|---|---|
| tank_sensor | sludge sensor row | samsara | 281475005688801 | new type |
| tank_sensor | water sensor row | samsara | 281475007025272 | new type |
| tank_sensor | sludge sensor row | samsara_gateway | GZ8K-E8N-PVX | the serial people quote |
| tank_sensor | water sensor row | samsara_gateway | GN4X-6TM-7BS | same |
| client / property | 365 / 98 | samsara | 322485232 | **exist** [O]: the Miami-Dade dump site's Samsara address |
| vehicle | 1, 2, 3 | samsara | truck asset ids | exist [O] |

**Why one new type (15 to 16 values):** the unique index `(entity_type, entity_id, source_system)` allows one samsara
link per entity [O], and the vehicle's slot holds the truck gateway.

**Rule 7 pre-check (done, repeat at P1):** `'tank_sensor'` appears in 0 function and 0 view bodies [O]; control
`'calendar_task'` found in 2. **Generic-reader sweep (new, V9):** `client.entity_source_links` is an owner-rights view
over ESL with no `entity_type` filter, readable by `authenticated` [O]. The new rows (asset ids, serials, NULL names)
become readable there. Accepted for v1 because nothing sensitive is in them; narrowing that view is a separate Client
App change (follow-up task, D6 list). P1 lists every view or function reading ESL without an `entity_type` filter.

### 3.2 Resolution

- **A reading** with `entityId` E: ESL (`tank_sensor`, `samsara`, E) gives `tank_sensors.id`. Readings key on the
  sensor; the tank is resolved later, at measurement time, through the installation in force.
- **An address event:** strip a leading `addr_`, then look up `public.v_vehicle_site_addresses` (section 6). It lists,
  for each **site property**, the Samsara address ids linked to it through ESL (`property`, `samsara`, id or
  `addr_`||id). Site properties are: dump-site properties (`ops.v_dump_sites.property_id`, membership from
  `non_customer_clients.kind = 'dump_site'`) and the yard property (`ops.v_depot.property_id`). Today exactly one
  address resolves: 322485232 to property 98 [O]. Events at any other address are counted as `unresolved` and not
  stored (N3).
- **A dump site without a Samsara address** (the Broward site, property 155): detected from coordinates. A GPS stop
  whose centroid lies within `p_dump_radius_m` (150) of a `dump_sites` tip point (`lat/lng` or `lat2/lng2`) gets that
  site's property. Measured: David came within **11 m** of those tip points on 10-02 and 10-08 [O]. Not usable for the
  Miami-Dade site, whose stored point is **0.60 to 0.87 km** from where the truck tips on all 9 dumps [O]; its
  geofence covers it.
- **The yard:** the configured depot (`app_config.depot_property_id`) is about 13 km from where trucks park and no
  truck came within 150 m in 14 days [O]. Until [OWNER D3b] names the yard property and its Samsara address is linked,
  long unlinked stops read as `parked` (view rule, 5.8).
- **New sensors are not auto-linked.** The daily discovery call reports unlinked level assets (T3, section 8); a
  person decides the tank in a migration.

---

## 4. Ingestion

**Runtime:** new Railway cron service `samsara-readings` in "UnclogMe Timed Jobs" **[OWNER D5]**, schedule
`*/5 * * * *`, command `node scripts/sync/run_logged.js railway_samsara_readings scripts/sync/cron_samsara_tank_readings.js`,
`RUN_TIMEOUT_MIN=10`, variables `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `SAMSARA_API_TOKEN` via `set-secrets.js`.
Not GitHub (runs every 4 to 8 h [O]); not an edge function (2 s CPU, 277 MB; one history page reached 46,314 rows
[O]); not pg_net (token would sit in the DB); a separate service so a readings failure cannot stop the GPS feed that
time-on-site and DUMP depend on. The stop builder's watermark gate (5.2) removes the cross-service ordering risk.

**Calls per run (GET only; history takes one `readingId` per call, `readingIds` returns 400 [O]):**

| Call | Count |
|---|---|
| `GET /readings/definitions` (units guard, below) | 1 |
| Per linked sensor (2): `remoteSensingDistance`, `fillPercent` history, following `endCursor` while `hasNextPage` | 4 |
| Per linked truck (3): `engineRpm`, `ecuPowerTakeoff`, `addressEntry`, `addressExit` | 12 |
| Daily, on the deep-pass run only: `/readings/latest?readingIds=remoteSensingDistance&entityType=asset` with no entity filter (discovers level assets; the existing probe searches `fillVolume` and cannot see the water unit [O]) | 1 |

17 calls a run, about 4,900 a day, about 0.06 per second against 10/s on readings and 150/s per token [O, docs]. On a
429: honour Retry-After, 3 tries, then exit 1. P1 checks whether `entityIds` accepts several ids [U].

**Units guard, per stream (V38).** Compare each used reading's definition, normalised (lower-cased `baseUnit`, enum
symbol-to-number map, object field names), with the pinned map [O, read 2026-10-12]:
`remoteSensingDistance` = `meter`; `fillPercent` = `percent`; `engineRpm` = `rpm`; `ecuPowerTakeoff` = `{off:0, on:1}`;
`addressEntry` / `addressExit` = Object with field `addressIds`. A mismatch **skips that stream only**, records it in
the run summary (`skipped_streams`), and the other streams still ingest. The run still exits 0; the skip surfaces as
item T4 (section 8). Because resume has no floor, nothing is lost once the guard is updated.

**Resume (one cursor for the job, no floor; V32, V38).**
- Window start = `started_at` of the newest successful `railway_samsara_readings` runner row, minus 30 minutes. Window
  end = now. If the window is longer than 72 hours (an outage), pull it in 72-hour chunks, oldest first, and record
  the recovered span in the summary.
- No successful run yet: start at the backfill start (2026-08-20 14:00Z).
- **Deep pass:** once a day (no successful run with `summary.deep_pass = true` in the last 24 h) the overlap becomes
  48 hours. Inserted rows older than the normal window start are counted as `deep_pass_recovered`.
- Why one cursor and not one per entity (a change from revision 1): site events store a filtered subset, so a
  stored-row cursor cannot exist for a truck that never dumps; and every entity is pulled on every run, so a
  run-success cursor loses nothing a per-entity cursor would keep.
- `feed=true` (the docs' sync contract) is **not** switched automatically: item T5 asks a person to ship it when
  `deep_pass_recovered > 0` on 2 of the last 14 days (V46).

**Transform:** distance metres rounded to 3 places; percent to 3; RPM to integer; PTO `on` true, `off` false, other
values skipped and counted; address events: read `value.addressEntries[]` (the payload, not the definition's
`addressIds`), strip `addr_`, map through `v_vehicle_site_addresses`; one row per resolved element; the rest counted as
`unresolved_addresses`. Geofence names are never logged (they contain client codes). Values outside the CHECK ranges or
stamped more than 5 minutes in the future are skipped and counted. A runnable self-check (`*.test.js`, plain asserts)
covers: `addressEntries` versus `addressIds`, `addr_` stripping, the PTO map, poison skipping, unit normalisation.

**Write:** `POST /rest/v1/<table>?on_conflict=<pk cols>` with `Prefer: resolution=ignore-duplicates,return=representation`,
chunks of 1,000, identical key sets in every element (rule 44), header `X-App-Source: samsara-tank-readings`. The
returned row count is the inserted count.

**Run summary and exit codes (V37, V45).** The job prints one final stdout line `RUN_SUMMARY {json}` with per-stream
`received / inserted / skipped / unresolved`, `skipped_streams`, `unlinked_level_assets`, `deep_pass`,
`deep_pass_recovered`, `window_start`, `window_end`, and total `rows_inserted`. `run_logged.js` gains a small,
backwards-compatible change (step R1): it pipes stdout, re-emits it, and stores the parsed summary in
`details.summary` and `rows_inserted` on the runner row. One `sync_log` row per run (no second job row). Exit 0 when
every call and insert succeeded (even with skipped streams or data findings); exit 1 on any failed call, insert or
timeout. Data findings are evaluated in SQL (section 8), never by the exit code.

**Backfill:** same script, `--from=2026-08-20T14:00:00Z --window-hours=72`, sequential, 500 ms between calls. Expected
deduplicated rows to 2026-10-12 15:40Z [O]:

| Stream | Sludge | Water |
|---|---|---|
| distance | **104,803** (104,806 pairs, 3 timestamps carry two values) | 24,816 |
| percent | 18,304 | 2,969 |

Engine readings and site events from 2026-08-20 for the 3 trucks. Samsara's retention beyond the observed 53 days is
[U], so M0 backs up every discovery pull (levels, truck events with geofence names stripped, engine, PTO).

---

## 5. Derived facts

All writers are SECURITY DEFINER, `search_path = ''`, revoked from `public, anon, authenticated, service_role`, run by
pg_cron as the owner, with a documenting COMMENT. Thresholds are parameters with defaults; when `p_execute = true` and
any threshold differs from its default, the function raises `22023` ("thresholds differ from algorithm version N; bump
the version"), so stored rows always mean what their `algorithm_version` says (V12).

**Sensor era:** stops are built from 2026-08-20 00:00 ET for every vehicle with a samsara `vehicle` link (Cloggy and
David included). Extending to the start of GPS history (2026-01-01) is [OWNER D18].

### 5.1 `fn_tank_fill_fraction(p_distance_meters numeric, p_diameter_meters numeric, p_sensor_offset_meters numeric) returns numeric`

SQL, IMMUTABLE, PARALLEL SAFE, **SECURITY INVOKER**, `search_path = ''`, touches no table (so the planner can inline it
in views). EXECUTE to `service_role` in M4, to `authenticated` in M9 (V20).

```sql
select case when p_distance_meters is null or p_distance_meters <= 0 then null else
  ((g.r*g.r*acos((g.r-g.h)/g.r) - (g.r-g.h)*sqrt(greatest(2*g.r*g.h - g.h*g.h, 0))) / (pi()*g.r*g.r))::numeric end
from (select p_diameter_meters::float8/2 as r,
             least(greatest((p_sensor_offset_meters + p_diameter_meters - p_distance_meters)::float8, 0),
                   p_diameter_meters::float8) as h) g
```

Positive controls [O, reproduced by the judges]: water 1.34 m = 51.885%, 0.75 m = 84.873%, 1.83 m = 23.512%; sludge
1.14 m = 45.635%, 0.50 m = 82.157%. Negative control: water at offset 0 must miss by more than 1 pp.

### 5.2 Stops: `fn_build_vehicle_stops(p_vehicle_id bigint, p_until timestamptz, p_execute boolean, p_rebuild_from timestamptz default null, p_radius_m int default 100, p_min_minutes int default 3, p_dump_radius_m int default 150)`

1. **Effective end.** `p_until` passed by the caller is already `least(now() - 30 min, readings watermark - 15 min)`,
   where the watermark is `started_at` of the newest successful `railway_samsara_readings` runner row (V39). If the
   readings feed is down, stops stop advancing (and F1 grows), instead of being built without dump events.
2. **Resume point R** = the vehicle's latest live `departed_at`, else the sensor-era start. With `p_rebuild_from`:
   supersede the vehicle's live stops with `arrived_at >= p_rebuild_from`, their live level rows, and soft-delete their
   links; R = `p_rebuild_from`. (Measure and link heal everything else on the same refresh, 5.5.)
3. **Site dwells.** Read live (`superseded_at is null`) site events for the vehicle from R - 6 h. Pair each `entry`
   with the next event for the same (vehicle, property). A dwell is **closed** when that next event is an `exit` at or
   before the effective end; keep closed dwells of 5 minutes or more; merge overlapping dwells (13 readings list two
   geofences at once [O]), preferring a dump-site property over the yard.
4. **Open-dwell barrier (V3, V30).** If the vehicle has an `entry` with no `exit` by the effective end, the effective
   end becomes that entry's time for this run. GPS inside an open dwell is never walked.
5. **Fixes.** `vehicle_telemetry_readings` rows with `latitude is not null` and `R < recorded_at <= effective end`;
   fixes inside closed dwells removed; the walk breaks at every dwell boundary.
6. **Anchor walk.** First fix = anchor; later fixes within `p_radius_m` of the anchor (`ops.fn_haversine_km`) join the
   stop whatever the time gap (a parked truck with the engine off sends nothing [O]). The first fix beyond the radius
   closes the stop; if it lasted at least `p_min_minutes`, emit arrived = first fix, departed = last in-radius fix,
   median lat/long, fix count, `formation = 'gps_walk'`. That fix becomes the new anchor; the trailing open stop is
   never emitted. No speed needed (speed is 0.0% filled [O]).
7. **Coordinate dump detection.** A `gps_walk` stop whose centroid lies within `p_dump_radius_m` of a `dump_sites` tip
   point gets `site_property_id` = that dump site's property (`ops.v_dump_sites`).
8. **Each closed dwell becomes one stop**: `formation = 'site_dwell'`, `site_property_id` = the dwell's property, the
   median of the fixes inside (dwells with 0 fixes are skipped and counted as `dwell_without_fixes`).
9. Insert with `ON CONFLICT DO NOTHING` on the live unique index. The exclusion constraint makes any overlap an error,
   never a silent duplicate. Returns jsonb counts; dry run returns the rows.

### 5.3 Measurement on value changes: `fn_measure_vehicle_stop_tank_levels(p_from timestamptz, p_execute boolean, p_spike_agree_m numeric default 0.05, p_spike_jump_m numeric default 0.15, p_hyst_sludge numeric default 0.01, p_hyst_water numeric default 0.05, p_period interval default '10 minutes', p_lookahead interval default '3 hours')`

**Scope = recompute and diff (V6, V8, V31, V32, V36).** The set of (live stop, tank) pairs to compute is the union of:
(a) stops with `arrived_at >= p_from` (the hourly run passes `now() - 35 days`); (b) every live level row flagged by
Z3 (provenance no longer in force), whatever its age; (c) every pair flagged by Z2 (missing). For each pair, compute
the desired row; if no live row exists insert it; if a live row exists and any stored value, edge time, installation,
configuration or version differs, set `superseded_at` and insert the new row; if the tank no longer has an
installation or configuration in force at `arrived_at`, supersede the live row and insert nothing. Identical results
write nothing. **A pair is ready** when `now() >= departed_at + p_lookahead` (the false-empty look-ahead needs it).

**Inputs per pair:** installation I in force at `arrived_at` on a non-deleted tank; configuration C in force at
`arrived_at` (live rows only); next = the vehicle's next live stop.

**Steps:**
1. **Raw series:** I's sensor distance rows in `[arrived_at - 3 h, departed_at + p_lookahead]`, dropping `distance <= 0`
   ("no echo").
2. **Measurements:** collapse consecutive equal values; each measurement = (first-seen time, distance). This is what the
   sensor actually produces about every 10 minutes [O].
3. **Fraction** of each measurement with C (`fn_tank_fill_fraction`).
4. **Spike (V22):** drop measurement m(i) when its previous and next measurements agree within `p_spike_agree_m` and
   m(i) differs from both by more than `p_spike_jump_m`. Catches the isolated 1.14 m water ghost (17 isolated ghost
   measurements [O]) and isolated sloshing readings.
5. **False empty with look-ahead (V23):** a run of consecutive measurements with fraction <= 0.005 is rejected only if
   (a) the last accepted measurement before it was above 0.15, (b) a measurement above 0.15 appears within
   `p_lookahead` after the run starts, and (c) no dump stop of the vehicle lies between the run's start and that
   recovery. A real post-dump empty (no recovery, or a dump in between) is kept.
6. **Arrival edge:** the last accepted measurement first seen at or before `arrived_at` (within 3 h); if none, the first
   accepted measurement in `(arrived_at, arrived_at + 11 min]`; else NULL.
7. **Departure edge (V21):** the first accepted measurement first seen in
   `(departed_at, least(departed_at + 11 min, next.arrived_at)]`, if any (it captures pumping or water use after the
   last in-stop measurement); otherwise the last accepted measurement at or before `departed_at`; else NULL.
8. **Too short:** if `least(departed_at + 11 min, next.arrived_at) - arrived_at < p_period`, the stop may have missed a
   change: store both edges but leave `risen` and `fallen` NULL.
9. **Risen and fallen (zig-zag with end flush, V29)** over the accepted measurements from the arrival edge through the
   departure edge, in time order, threshold h (0.01 sludge, about 38 gal; 0.05 water):
   ```
   pivot := v0; ext := v0; dir := 0; risen := 0; fallen := 0
   for v in v1..vn:
     if dir = 0:  if v - pivot > h then dir := +1; ext := v  elsif pivot - v > h then dir := -1; ext := v  end
     elsif dir = +1: if v > ext then ext := v elsif ext - v > h then risen += ext - pivot; pivot := ext; ext := v; dir := -1 end
     else:           if v < ext then ext := v elsif v - ext > h then fallen += pivot - ext; pivot := ext; ext := v; dir := +1 end
   end
   flush: if dir = +1 then risen += ext - pivot elsif dir = -1 then fallen += pivot - ext end
   ```
   A monotone fall now reports its full size (the revision-1 walk reported 0 on 13 of 18 such water stops [O]).
10. Store fractions to 5 places, `measurement_count` (accepted measurements first seen between the two edge times,
    inclusive), `rejected_measurement_count`, I, C, version.

**Calibration step (M4):** re-derive the 40 gal noise floor and h on measurements (between consecutive non-dump stops);
keep the defaults if p50/p75 stay within 10 gal of 23/65 gal [U until run].

### 5.4 Visit linking: `fn_link_visit_vehicle_stops(p_execute boolean, p_radius_m int default 150, p_earlier_hours int default 12, p_volume_service_types text[] default '{Pumping}')`

**Candidates: the whole sensor era, every run (V2, V35, V40).** Completed live visits (`public.v_visits_live`,
`visit_status = 'completed'`) with `vehicle_id` set and `visit_date >= 2026-08-19`. About 170 completed visits a month
[O], so a full reconcile is cheap. ponytail: bound to a rolling 400 days when the run passes 30 s.

**Visit kinds:** *dump visit* = `fn_is_non_customer(client_id, array['dump_site'])` (catches Dump Offload and the 32
historical visits at dump-site clients typed Pumping, Cleaning, Labor or null [O]); *volume visit* = not a dump visit
and `service_type = any(p_volume_service_types)`; *other visit* = the rest (Unclogging, Cleaning, Labor, ...).

**Sets:** L(V) = live **non-site** stops of `V.vehicle_id` whose centroid is within `p_radius_m` of V's property
geocode. D(V) = live dump stops of `V.vehicle_id` whose site property's client = `V.client_id`. W(V) =
`[(visit_date - 4 h) ET, (visit_date + 1, 10:00) ET]` built with `at time zone 'America/New_York'` (the latest observed
pumping stop began 08:28 ET [O]).

**Steps, in order:**
1. **Dump completion anchor** (`dump_completion`, dump visits): the stop in D(V) whose `[arrived_at - 5 min,
   departed_at + 15 min]` contains `completed_at`; nearest `departed_at` wins. Measured on Moises: 4 of the 5 recorded
   dumps anchor this way [O].
2. **Dump elimination** (`dump_window`, unanchored dump visits): the stops in D(V) inside W(V) not linked to another
   dump visit. Exactly one: link it. Several: no link, flag F1b with reason `ambiguous`. None: F1b `none`. The partial
   unique index guarantees at most one dump visit per dump stop. (8756 lands on the 10-07 19:02 dump by elimination [O].)
3. **Completion anchor** (`completion`, volume and other visits): the stop in L(V) whose `[arrived_at - 5 min,
   departed_at + 15 min]` contains `completed_at`; nearest `departed_at` wins. 44 of 48 Moises Pumping visits [O].
4. **Window fallback** (`window`, **volume visits only**, unanchored): **every** stop in L(V) inside W(V) that is not a
   completion anchor of another visit. Never chosen by the scheduled start (V26). Other visits get no fallback (V27):
   an Unclogging visit completed while the truck was 12 km away stays unlinked [O, visit 8744].
5. **Earlier same-site stops** (`same_site_earlier`, **volume visits only**): stops in L(V) with `arrived_at` in
   `[anchor.arrived_at - p_earlier_hours, anchor.arrived_at)` that are not an anchor or window stop of any visit; a stop
   qualifying for several visits goes to the visit whose anchor is nearest after it (both on a tie). 12 such stops on
   10 visits [O].
6. **Reconcile:** insert desired links that are not live; set `deleted_at` on live links that are no longer desired
   (rescheduled, deleted or re-trucked visits, moved geocodes, superseded stops). Because the candidate set is the whole
   era, an old visit's anchor is never mistaken for a free stop.

**Default shares (views, never stored) [OWNER D11]:**
- **Sludge:** only among the stop's live links from **volume** visits. `share = trap_i / sum(trap)` when every such
  visit's property has `grease_trap_size_gallons > 0`, else `1/k`. A same-property Pumping visit and Cleaning visit 1
  minute apart: the Pumping visit gets 100% (V27).
- **Water:** equal split among the stop's live non-dump links (rinse water does not scale with trap size).
- **Time:** not divided; each linked visit shows the full stop minutes.

### 5.5 `fn_refresh_stop_facts(p_rebuild_vehicle_id bigint default null, p_rebuild_from timestamptz default null)`

The pg_cron entry (hourly at :35) and the only sanctioned way to rebuild (V40):
1. **Build** per vehicle with a samsara link (with the rebuild arguments for the named vehicle).
2. **Measure** with `p_from = least(now() - 35 days, p_rebuild_from)` plus the Z2/Z3 sets.
3. **Link** (whole era).
4. **Evaluate** the checks in section 8 and write four `sync_log` rows (`stop_facts_refresh`, `tank_feed_freshness`,
   `stop_facts_integrity`, `tank_geometry_drift`).

Each step runs in its own `begin ... exception` block; a step error is recorded in `stop_facts_refresh.error_details`
(`step`, SQLSTATE) and the later steps still run. A crash writes nothing, and the 2-hour staleness rule fires.
`set_config('request.headers', '{"x-app-source":"stop-facts"}', true)` labels audited writes; whether
`audit.log_change` sees it is checked in M4 [U] (fallback label `sql`, like pg_cron jobs 26 and 27 [O]).

### 5.6 Per-visit dwell (view)

`stop_minutes` = sum of linked stop durations (shared stops count fully per visit), shown beside
`visits.duration_minutes`, flag F7 when they differ by more than 15 minutes. Example: the DB gives visit 5922 84
minutes from its neighbour's cluster; its own stops total about 68 [O].

### 5.7 Sludge per visit (view)

- `sludge_collected_gallons` = sum over linked stops of share x (departure - arrival fraction) x capacity, capacity from
  the configuration on the level row (the in-force configuration, guaranteed by Z3).
- `sludge_gross_intake_gallons` = the same with `fill_fraction_risen`.
- **Pump signature:** at least 5 minutes of RPM >= 900 (sum of min(gap to next sample, 5 min) over samples >= 900), or
  at least 1 minute of PTO on, during the stop. 43 of 48 rise stops vs 8 of 26 flat stops had 30% or more of samples at
  900 or above; David's RPM with PTO on is 1,094 to 1,111 [O]. ponytail: one threshold for all trucks; per-vehicle when
  a second truck relies on RPM.

**Confidence (first failing check wins):**

| # | Condition | Confidence / reason |
|---|---|---|
| 1 | no sludge installation in force at arrival | none / `no_sensor` |
| 2 | no live link | none / `no_stop` |
| 3 | no configuration in force | none / `no_config` |
| 4 | a linked stop has a NULL edge | none / `edge_missing` |
| 5 | a linked stop is too short (risen NULL with both edges present) | low / `too_short` |
| 6 | trap 75 gal or less | low / `below_resolution` (about 20 to 23 gal per cm, 40 gal noise [O]) |
| 7 | a departure fraction of 0.98 or more | low / `tank_at_ceiling` |
| 8 | net above 1.5 x trap + 40 gal | low / `exceeds_trap_size` |
| 9 | volume visit, net under 40 gal, pump signature present | low / `pumped_no_rise` |
| 10 | net 40 gal or more, engine data present, no pump signature | low / `rise_without_pump` |
| 11 | trap size null | medium / `trap_size_unknown` |
| 12 | any `window` link | medium / `window_match` |
| 13 | a linked stop has more than one volume link | medium / `shared_stop_allocated` |
| 14 | no engine readings during the stops | medium / `no_pump_signal` |
| 15 | otherwise | high / `ok` |

### 5.8 Stop kind, water and dumps (views)

**Stop kind** (`v_vehicle_stop_facts`): `dump` (site property's client is a dump site), `yard` (site property = the yard
property), `client` (at least one live link), `parked` (none of the above and duration of 4 hours or more; fallback
until D3b, Moises's 11 of 11 parks of 3 h or more qualify [O]), else `other`.

**Water per visit:** `water_used_percent_points` = share-weighted sum of `fill_fraction_fallen` x 100;
`water_refilled_percent_points` over `fill_fraction_risen`. NULL propagates (never summed as 0, V11). Gallons =
fraction x capacity, NULL while capacity is NULL. Net change is never shown as "used" (net fell at 7, flat at 10, rose
at 13 rise stops [O]). Confidence `low / percent_only` in v1.

**Dumps (`v_vehicle_dumps`), one row per live dump stop (V24):**
- `offload_gallons` = (arrival - departure) x capacity.
- Confidence: `low / edge_missing` when an edge is NULL; `low / implausible_offload` when departure >= arrival, or
  departure >= 0.97, or offload <= 0 (the stuck 10-01 dump read -2,387 gal [O]); `medium / lower_bound` when arrival
  >= 0.97; else `high`.
- `collected_since_previous_dump_gallons` = sum of positive net sludge change at `client` and `other` stops between
  the previous dump's departure and this dump's arrival (`yard` and `parked` excluded: the parked 10-09 rise of 1,538
  gal is not a pickup [O]).
- `cycle_offsite_drop` = any non-dump stop in the cycle with a net fall of 300 gal or more.
- `ratio` = offload / collected; NULL when this dump or the previous one is `low`, or the cycle has an off-site drop;
  flagged (F4) outside 0.75 to 1.25.
- `dump_visit_id` from the dump links; NULL raises F3 (4 of 9 dumps [O]).

---

## 6. Exposure

**Base tables (12):** RLS on, no policies, privileges as in 2.0. Derived tables are written only by the SECDEF
functions; configuration only by migrations; raw tables only by the job.

**Public views (V16): owner-rights (no `security_invoker`), owned by `postgres`, revoked from `public, anon,
authenticated, service_role`, `SELECT` to `service_role` only.** Owner-rights so that M9's ops wrappers can select
from them (a security-invoker view reached through an owner-rights view still checks its base tables as the caller,
who has no grant). Function EXECUTE inside them is checked against the caller: `fn_tank_fill_fraction` (service_role
now, authenticated in M9) and `ops.fn_haversine_km` (authenticated already holds it [O]). Views join
`public.non_customer_clients` directly rather than calling `fn_is_non_customer`, to avoid a third EXECUTE dependency.

| View | Contents |
|---|---|
| `v_vehicle_site_addresses` | property_id, site_kind (`dump_site`/`yard`), samsara_address_id: the map the job reads |
| `v_tank_levels` | per distance reading: vehicle, contents, recorded_at, distance, `is_new_measurement`, configuration in force, fraction, percent, gallons (NULL without capacity), Samsara's percent at the same timestamp |
| `v_vehicle_stop_facts` | per live stop: duration, kind (5.8), RPM pump minutes, PTO minutes, engine data present, live link count, `nearest_property_id` for `other` stops (within 300 m, live service properties) |
| `v_vehicle_stop_tank_changes` | per live level row: arrival/departure percent and gallons, net, risen, fallen, `too_short`, `at_ceiling`, the configuration and installation ids |
| `v_visit_tank_service` | per completed live visit since 2026-08-20: link count and bases, stop minutes, pump minutes, sludge collected and gross with confidence and reason, water used/refilled (pp; gallons when known) with confidence, shared flag, official `duration_minutes`, F7 |
| `v_vehicle_dumps` | section 5.8 |
| `v_tank_data_quality_issues` | one row per open issue: `issue_code`, `severity` (`must_be_zero`/`feed`/`business_flag`), ids, `nearest_property_id` where relevant |

**Apps:** nothing until **[OWNER D6]**. Then M9: owner-rights `ops.v_visit_tank_service`, `ops.v_truck_dumps`,
`ops.v_truck_tank_levels_latest` selecting from the public views (fixed column lists, new columns only appended),
`authenticated=r`, `fn_tank_fill_fraction` EXECUTE to `authenticated`, `NOTIFY pgrst, 'reload schema'`. **Staff
sensitivity:** `parked` and `other` stops are where drivers stop for themselves; app views show their kind and duration
but not their coordinates [OWNER D6]. `anon`, `customer.*` and `derm.*` get nothing (N1, N5).

---

## 7. Audit, RLS, retention, volume, backup

| Table | Audit | Reason |
|---|---|---|
| vehicle_tanks, vehicle_tank_configurations, tank_sensors, tank_sensor_installations | opt-in | human-entered; every gallon depends on them |
| vehicle_site_events | opt-in | about 2 to 10 rows a day; corrections (`superseded_at`) are human |
| visit_vehicle_stops | opt-in | touches visits; about 10 rows a day [I] |
| 4 reading tables | opt-out | machine-written, append-only by trigger and grant; same class as `vehicle_telemetry_readings` |
| vehicle_stops, vehicle_stop_tank_levels | opt-out | machine-derived, append-only, supersede explicit; not DERM-facing in v1 (rule 27) |

The decision goes in each header and `COMMENT ON TABLE`. The generated rule-8 query should move from 65 [O] to **71**.
RLS on for all 12 (public has 9 RLS-off tables today [O]; none added).

**Volume** (rows a day from deduplicated discovery cadences [O]; bytes [I]):

| Table | Rows a day |
|---|---|
| distance readings | about 4,473 (sludge 1,976 + water 2,497) |
| fill percent readings | about 648 |
| engine RPM | up to about 800 (Moises 267 [O]; David present; Cloggy [U]) |
| PTO | about 7 |
| site events | about 2 to 6 (yard adds about 4 per truck once linked) |
| stops / levels / links | about 25 / 17 / 10, plus superseded rows when a measurement is revised (expected small) |
| `sync_log` | 288 runner rows (one per run, summary folded in) + 96 SQL rows (4 sources hourly) = about 384, i.e. +37% on about 1,042 a day [O] |

About 0.6 MB a day for the new tables and about 0.2 MB a day of `sync_log`, about 0.3 GB a year in all, against a
951 MB database [O]. Re-measure with `pg_total_relation_size` after 7 days. **Partitioning:** none (precedent:
telemetry at 1.5M rows); ponytail: pg_partman monthly on the distance table (5.3.1 installed [O]) past 1 GB or a third
sensor. **Retention:** keep everything; any delete or partition drop, and any trimming of `sync_log`, is a rule-6
exception **[OWNER D9]**.

**Backup (V47):** the 2-hourly Railway copy excludes the data of `vehicle_telemetry_readings`, `webhook_events_log` and
`sync_log` [O, services/db-backup README]. The 12 new tables are **included** (Samsara retention is unverified, and they
are small); recorded in the `services/db-backup` README.

---

## 8. Health monitoring

**Sources (all clean word `success`, failures `error`), added to the watched list of `log_jobber_sync_health` by an
md5-pinned splice of its live body (precedent `2026-10-08_1048`) in M7, after each source's first good run:**

| sync_source | Written by | Staleness | Means |
|---|---|---|---|
| `railway_samsara_readings` | `run_logged.js` | 30 min | the ingest process ran and every call and insert succeeded |
| `stop_facts_refresh` | `fn_refresh_stop_facts` | 2 h | the derivation ran; `error` only when a step raised. Carries the business-flag counts in `details` |
| `tank_feed_freshness` | `fn_refresh_stop_facts` | 2 h | data-level feed checks T1 to T5; `error` when any fires |
| `stop_facts_integrity` | `fn_refresh_stop_facts` | 2 h | must-be-zero checks Z1 to Z9 except Z6; `error` when any is above 0 |
| `tank_geometry_drift` | `fn_refresh_stop_facts` | 2 h | Z6 alone, because it can stay open for days waiting on an owner decision |

Separate sources give separate item kinds (`sync_failed:<source>`), so a long-open data finding cannot hide a later
process failure (V37). Known wart: the item's reason text says the runs "did not reconcile anything"; `details` carries
the real cause. Neither health view changes (the watched list feeds `jobber-sync-health`, already registered in both).
M7 also adds a **count-only observation line** for F1, F1b and F3 to the daily health email, copied from the billing
observation precedent [U on its exact shape until the live body is read], so record gaps reach a person before D6.

**Feed checks (T, `tank_feed_freshness`):**

| Code | Condition |
|---|---|
| T1 `stale_sensor` | a sensor with an installation in force has its newest distance reading more than 2 h old (LM11 units report while parked; observed max gaps 40 min sludge, 31 min water [O]) |
| T2 `gps_gap` | in the last 48 h, an hour where a vehicle has 5 or more RPM samples above 0 but no GPS fix (engine running, no position) |
| T3 `unlinked_level_asset` | the newest runner summary names a level asset with no `tank_sensor` link |
| T4 `skipped_stream` | a runner summary in the last 2 h lists a stream skipped by the units guard |
| T5 `feed_mode_needed` | `deep_pass_recovered > 0` on 2 of the last 14 days: ship `feed=true` |

**Must-be-zero checks (Z), each with a positive control in M4 on a synthetic `[TEST]` row inside a rollback:**

| Code | Condition |
|---|---|
| Z1 | a sensor with an installation in force lacks exactly one `samsara` and one `samsara_gateway` link, or a `tank_sensor` link points at no row |
| Z2 | a live stop older than `departed_at + 4 h`, on a vehicle with an installation in force at arrival (non-deleted tank) and a configuration in force, has no live level row for that tank |
| Z3 | a live level row whose installation is superseded or does not cover `arrived_at`, whose configuration is not the live one in force, whose tank is deleted, or whose version is older than the current one |
| Z4 | a live link to a superseded stop; to a visit not in `v_visits_live` or not completed; where stop and visit vehicles differ; a non-dump basis on a site stop or farther than `p_radius_m` from the visit's current property; a dump basis on a stop that is not a dump stop of the visit's own dump-site client, or from a visit that is not a dump visit; or a live stop whose `site_property_id` is neither a dump-site nor the yard property |
| Z6 | drift: per sensor, median abs(Samsara percent - our percent) at identical timestamps over the last 24 h above 0.5 pp with at least 20 pairs (baselines 0.0005 pp water, under 0.01 pp sludge [O]). Never adopted automatically |
| Z7 | a live installation on a soft-deleted tank (V13) |
| Z8 | **boundary (V43):** a function in `derm`, `customer` or `client` whose body names a new table or view, or a view in those schemas depending on one (`pg_depend`). Positive control: a function body must be found (`public.visits` in `derm.audit_pack`) |
| Z9 | a soft-deleted link whose stop was superseded while its visit has no live link but a live stop exists at the same place in W(V) (the linker failed to re-link after a rebuild) |

(Z5 of revision 1 became business flag F8, V42.)

**Business flags (F, expected non-zero; rows in `v_tank_data_quality_issues`, counts in `stop_facts_refresh`):**

| Code | Condition |
|---|---|
| F1 `pumping_visit_without_stop` | completed volume visit since 2026-08-20 on a GPS vehicle, no live link |
| F1b `dump_visit_without_dump_stop` | completed dump visit, no dump link (reason `none` or `ambiguous`) |
| F2 `unlinked_work` | `client`/`other` stop, net rise 40 gal or more with a pump signature, no volume link; with `nearest_property_id` |
| F3 `dump_without_record` | dump stop with no dump visit |
| F4 `dump_ratio_out_of_band` | ratio outside 0.75 to 1.25 |
| F5 `large_drop_not_at_dump` | net fall of 300 gal or more at a non-dump stop (yard decants, transfers, unknown sites); with `nearest_property_id` |
| F6 `possible_wrong_truck` | a visit with no link on its own vehicle while another vehicle has a stop within 150 m in W(V) with a rise or a pump signature (visit 8743 [O]) |
| F7 `time_on_site_disagreement` | `stop_minutes` and `duration_minutes` differ by more than 15 min |
| F8 `capacity_mismatch` | `vehicles.grease_tank_capacity_gallons` differs from the in-force sludge capacity. Text says: **resolving it by editing `vehicles` rewrites past LWT rows (`derm.v_lwt_monthly_rows` reads it live); needs owner approval (D10)** |

**Later, owner-gated (D6, M11):** a daily digest of business flags through the shared Slack bot (format per
`docs/reference/slack-notifications.md`) or a `log_tank_data_health` check registered in BOTH `ops.v_health_items` and
`ops.v_health_status` (source list and CASE arm), md5-pinned, `SET LOCAL lock_timeout = '3s'`, revoked by name and
asserted with `has_function_privilege`.

---

## 9. Data quality guards

| Risk | Guard |
|---|---|
| Units | stored as observed (metres, percent, RPM); capacity in gallons; gallons only in views; no litres anywhere; per-stream definitions guard |
| Duplicate rows (17.5% sludge, 24.5% water [O]) | natural primary keys, ignore-duplicates |
| 10-minute measurement period [O] | measurements = value changes; departure edge from the first new measurement within one period after leaving; `too_short` |
| Sloshing while driving | only stop-window measurements plus one post-departure measurement; spike filter on measurements |
| False empties near full (45 episodes [O]) | look-ahead rule; a real post-dump empty survives |
| Ghost echo and 0 m (water) | spike filter on measurements; 0 m dropped; water installation starts after the setup window |
| Pinned at the top | `tank_at_ceiling`; dumps `lower_bound` |
| No water capacity | gallons NULL, `percent_only`; never the grease capacity (sludge plus water exceeded 3,840 in 23 of 66 old form rows [O]) |
| Geometry typed by a person | `basis = fitted_from_readings`; drift Z6; corrections by superseding the configuration (same `effective_from`) |
| Wrong sensor mapping | supersede the installation; recompute-and-diff cleans every level row |
| Late vendor rows | 30-minute overlap, daily 48 h deep pass, no floor, 35-day recompute horizon |
| Event feed behind the GPS feed | build capped at the readings watermark; open-dwell barrier; exclusion constraint |
| Co-located visits, one night | shared anchor; sludge shares among Pumping visits only |
| Co-located visits, consecutive nights | completion anchor; same-site-earlier goes to the nearest-after anchor |
| Overnight route past +28 h | W(V) to 10:00 ET next day |
| Small traps | `below_resolution`, never 0 |
| Wrong trap sizes | `exceeds_trap_size`, `trap_size_unknown` |
| Wrong truck on the visit | F6; no automatic correction (N6) |
| Miami-Dade dump site's stored point 0.6 to 0.9 km off [O] | dumps there come from the geofence dwell (9 of 9 [O]) |
| A dump split by GPS clustering (10-06 [O]) | one stop per dwell |
| Yard rises and decants | `yard`/`parked` excluded from collected totals and F2; F5 shows drops |
| Poison values | skipped and counted at ingest |
| Manual shift form (an entry of water = 10,000 [O]) | `inspections` untouched, never merged with sensor data (D12) |
| Scheduled slot shown as on-site time in two ops views [O] | our figures key only on measured stops |

### 9.1 Relation to `samsara-geofencing-plan.md`

That plan (agreed 2026-08-07, not built) manages client-site geofences two-way with the Client App and explicitly leaves
arrival/departure detection out. This plan uses GPS stops for client time on site and stores address events only for
site properties (dump sites, yard). If client-site events are wanted later, `vehicle_site_events` already has the right
shape (keyed on a property); widening the resolver's filter plus a backfill is the change. The dormant visit writer in
`webhook-samsara` (`handleGeofenceAlert`, writes `visits.actual_*` and `is_gps_confirmed`) must be neutralised before
anyone subscribes to geofence alerts (M8, D4). Both docs get a reciprocal note (D1).

---

## 10. Migration plan (ordered)

### 10.1 File and header rules

- `Supabase/docs/migrations/YYYY-MM-DD_HHMM_<name>_STAGED.sql` (ET, matching the neighbours), renamed on apply.
- Header: WHAT; WHY quoting the voice note; one 3NF line per column (2.6); rule-8 decision; intended grants (literal
  ACL); volume, retention, partitioning; VERIFY with a positive control; rollback (export first); for any replaced body,
  the live text copied (never retyped) with an md5 pin.
- One transaction per file, no inner COMMIT; `cron.schedule` in its own file; `SET LOCAL lock_timeout = '3s'` on M1, M7,
  M9, M10.
- **Hygiene check before every commit:** grep the staged migrations and docs for `\b\d{3}-[A-Z0-9]{2,6}\b` (client
  codes) and for any Samsara geofence or address name; fail on a hit. ESL seeds carry `source_name` NULL (V17).

### 10.2 Steps

**M0. Coordinate and back up (no DB writes).**
- Read the other session's claim; append ours to `WORKING-NOW.md` and commit in the same breath. Claim: the ESL CHECK,
  the 12 tables, `fn_append_only_guard`, the derivation functions, `log_jobber_sync_health`,
  `services/timed-jobs/services.json`, `scripts/sync/run_logged.js`, `scripts/sync/cron_samsara_tank_readings.js`,
  ADR 020.
- Copy to `backups\2026-10-12_lm11_discovery\`: the 4 level pulls (distance and percent, both sensors), the truck and
  sensor address-event pulls **with geofence names stripped** (keep id, lat, long, time), engine RPM, PTO, engine
  state. Confirm by grep that no geofence name survives.
- **GPS coverage check:** Moises has GPS on 51 of the 55 days 08-19 to 10-12 vs David 55 [O]; confirm the 4 missing
  days were not driven (no RPM, no events) before the derivation backfill.

**P1. Read-only probes.**
- Samsara: (done 2026-10-12) definitions units pinned (4); re-probe of the 10 batch-hidden readings singly (only
  `gatewayBatteryTemperature` reports on the LM11; voltage and status empty; `fuelSource`/`reeferPowerSource` 500 even
  alone) [O]. Still to do: several `entityIds` in one history call; the no-filter discovery call returns both LM11
  assets; Cloggy `engineRpm` history (14 days).
- Prod: repeat the rule-7 grep (`'tank_sensor'` expected 0; control `'calendar_task'` 2); list every view and function
  reading `entity_source_links` without an `entity_type` filter (expected to include `client.entity_source_links`, the
  positive control); confirm the `extensions` schema exists and that a rolled-back test table with a btree_gist
  exclusion constraint creates with btree_gist in `extensions`; re-read `ops.v_depot`, `ops.v_dump_sites`,
  `dump_sites` (tip coordinates for property 98 and 155) and the ESL links of address 322485232.

**M1. `..._esl_allow_tank_sensor`.** `SET LOCAL lock_timeout = '3s'`; re-read the live list; DROP and ADD
`entity_source_links_entity_type_chk` with all 15 values plus `tank_sensor`, without `NOT VALID`. Rolled-back probe: a
`tank_sensor` row inserts; `bogus_type` fails 23514 (positive control); no residue beyond a sequence gap.

**M2. `..._tank_configuration`.** btree_gist in `extensions`; `fn_append_only_guard`; the 4 configuration tables with
both triggers, RLS, revokes, grants, sequence revokes, comments; seeds; 4 `tank_sensor` ESL rows.
- **Rolled-back probe** (as `postgres`, then `SET LOCAL ROLE service_role / authenticated / anon` with
  `request.jwt.claims`): `fn_tank_fill_fraction` controls (it is created in M4; call the SQL inline here); **mapping
  check** (each sensor's discovery distance pairs fit only its own configuration; a swapped seed fails); an overlapping
  installation raises 23P01; UPDATE of a configuration's geometry raises 55000; setting `superseded_at` succeeds once
  and a second change raises; a corrected configuration with the **same `effective_from`** inserts after the seed is
  superseded (V4); `UPDATE vehicle_tanks SET contents` raises while `SET deleted_at` succeeds; `TRUNCATE` raises 55000
  on each table, and a trigger-less copy truncates (control); an INSERT writes an `audit.logs` row.
- **Verify after apply:** the literal ACL of each table is exactly
  `{postgres: arwdDxtm, service_role: r, db_backup_reader: r}` (compared as an `aclexplode` set);
  `has_table_privilege` false for `anon` and `authenticated` on every privilege, and false for `service_role` on
  INSERT/UPDATE/DELETE/TRUNCATE; `has_sequence_privilege('authenticated', seq, 'USAGE')` false; every FK has
  `confdeltype = 'r'`; 0 columns match `^(samsara|jobber|airtable|fillout|odoo)_`; the generated rule-8 query lists the
  4 tables; ESL orphan sweep for `tank_sensor` returns 0 and the control count is 4.
- **Rollback:** back up and delete the ESL rows created here, drop the objects, restore the 15-value CHECK.

**M3. `..._tank_and_engine_readings`.** The 5 raw tables (including `vehicle_site_events` with its audit trigger).
Rolled-back probe as `SET LOCAL ROLE service_role`: the same row twice with ON CONFLICT DO NOTHING leaves 1; UPDATE
gives **42501** (no grant), and as `postgres` the guard gives 55000; setting `superseded_at` on a site event succeeds
once; SELECT as `authenticated` and `anon` gives 42501; TRUNCATE as `postgres` raises 55000; literal ACL
`{postgres: arwdDxtm, service_role: ar, db_backup_reader: r}`; 0 rows after rollback.
**Rollback after J1 has run:** export the 5 tables to `backups\` and check counts against Prod before any DROP.

**R1. `run_logged.js` summary capture (repo only).** Pipe the child's stdout, re-emit it, parse the last
`RUN_SUMMARY {json}` line into `details.summary` and `rows_inserted`. Extend `run_logged.test.js`: a child printing a
summary sets both; a child printing none leaves today's row shape unchanged; a malformed line is ignored, not fatal.

**J1. Job, Railway service, backfill.** Add `cron_samsara_tank_readings.js` and its self-check. Dry run against live
Samsara printing per-stream counts. Run the backfill. **Positive controls:** per sensor and stream, counts equal the
inventory to 10-12 15:40Z (sludge distance **104,803**, percent 18,304; water 24,816 / 2,969) plus whatever arrived
since; site events: 9 Moises dump dwells 09-28 to 10-12 pair cleanly. If 08-20 data no longer comes back, load the M0
backup through the same transform. Add `samsara-readings` to `services.json`, run `node services/timed-jobs/apply.js`
(drift) then `--apply`; the owner sets the secrets. Regenerate the inventory (`node
scripts/checks/timed-jobs-inventory.mjs --write`). **First 24 h:** rows per day per stream within 10% of the discovery
cadence; runner rows carry `rows_inserted > 0`; the first deep pass's `deep_pass_recovered` recorded.

**M4. `..._vehicle_stop_facts`.** `fn_tank_fill_fraction`; the 3 derived tables; build, measure, link and
`fn_refresh_stop_facts` (SECDEF, revoked by name, COMMENTs). No cron. **Rolled-back probe that executes every PL/pgSQL
body** (they are not parsed at CREATE). Acceptance on 2026-09-28 to 10-12:

| Check | Expected |
|---|---|
| Moises stop count | 100 to 125 (the anchor walk gave 119 including dump sub-stops; dwell merging removes some) [I]; record the exact figure |
| **Hour-by-hour build** across 10-06 00:35 to 03:35 ET (one call per hour with that hour's watermark) | exactly **one** stop for the 01:28 dwell, **0** overlap errors, 0 phantom sub-stops (V30) |
| 10-06 dump | one `site_dwell` stop entered near 01:28 ET; offload 3,150 ±200 gal |
| Dump stops (Moises) | 9; the 10-01 dump `low / implausible_offload` (**must be low**) |
| 10-09 dump | at least 3,400 gal (**must pass**: real empty survives the false-empty rule) |
| Dump links | 8725 to 10-02 15:58, 8740 to 10-06 01:28, 8745 to 10-07 04:21, 8754 to 10-08 03:32 by `dump_completion`; 8756 to 10-07 19:02 by `dump_window`; **5 of 5**; 4 dump stops raise F3 |
| David's dump visits at the Broward site | each links to a coordinate-detected dump stop (property 155) [I] |
| 6634 | `completion` to the 10-05 02:21 stop only; sludge +713 ±40 |
| 5922 | 10-06 03:24 (`completion`) + 10-05 22:56 (`same_site_earlier`); about +1,060 ±80; no share with 6634 |
| 6619 | net +949 ±60; gross intake >= net |
| 6334 | 0 ±40 |
| 6075 | `window` links to **both** 10-01 stops (03:58 and 04:06); net about +490 ±60 (V26) |
| 6087 / 6582 (shared anchor) | departure edge **not NULL**; both get a value split by trap size |
| 8744 (Unclogging, truck elsewhere) | **no link** (V27) |
| A same-property Pumping + Cleaning pair 1 min apart | Pumping gets 100% of sludge |
| 10-09 08:12 stop (6975's earlier stop) | water fallen **under 10 pp** (**must fail** the old ghost result of about 58 pp, V22) |
| 10-06 03:24 stop | water fallen of at least 35 pp (post-departure measurement plus end flush, V21/V29) |
| 6052 | water risen about +48 pp (at least 40) |
| Anchoring rate per vehicle | reported: Moises 44 of 48 Pumping by `completion`; David and Cloggy figures recorded (6 of 12 and 21 of 23 in discovery [O]) |
| David PTO | pump minutes on 8 of his 9 pumping visits |
| Moises overnight parking | 11 of 11 parks of 3 h or more classify `parked` (or `yard` after D3b) |
| Collected vs dumped | at least 4 readable cycles inside 0.75 to 1.25, 10-01 excluded |
| Configuration correction | supersede the water seed and insert a corrected one with the **same** `effective_from` (diameter + 0.01 m): the affected level rows are superseded and replaced on refresh; Z3 = 0 |
| Installation correction | supersede the water installation with no replacement: its level rows are superseded, none inserted; Z3 = 0 |
| Late reading | insert a synthetic distance reading inside an old stop's window: the next measure supersedes that level row |
| Rebuild | `fn_refresh_stop_facts(1, '2026-09-01')`: links of rebuilt stops are re-created; Z9 = 0 |
| Thresholds | `p_execute = true` with a non-default threshold raises 22023 |
| Z1 to Z9, T1 to T5 | each fires on a synthetic `[TEST]` row (positive controls) |
| Audit label | an audited link INSERT carries `app_source` `stop-facts` (or `sql`, recorded) |
| Noise floor | between-stop drift on measurements: p50 and p75 recorded; defaults kept or a version 2 proposed |

Then apply, run `fn_refresh_stop_facts()` once as the derivation backfill (from 2026-08-20, in weekly `p_rebuild_from`
chunks if it runs long). **Verify:** Z1 to Z9 = 0.

**M5. `..._schedule_vehicle_stop_facts`** (own file): `cron.schedule('vehicle-stop-facts', '35 * * * *', 'select
public.fn_refresh_stop_facts()')`. Verify: the four sources appear hourly with non-zero counts. Regenerate the inventory.

**M6. `..._tank_views`.** The 7 public views, owner-rights, revoked, service_role SELECT. **Verify:** 0 rows carry water
gallons while capacity is NULL; Z8 returns 0 with its function control found; `pg_depend` from `derm.*`, `customer.*`,
`client.*` to any new object is 0 (control: `derm.v_lwt_monthly_rows` depends on `vehicles` [O]); one-time repo grep of
`supabase/functions/` (especially `rpa-derm-monthly`) for the new names returns 0.

**M7. `..._watch_tank_feeds`.** Splice the five sources and the count-only line into `log_jobber_sync_health` from its
live text (md5 pin, `lock_timeout 3s`), after each source's first good run. Rolled-back probe: a fake old row reads as
stale and a fresh one does not; an `error` row on `tank_geometry_drift` opens its own item while `stop_facts_integrity`
stays clean (V37). Revoke by name and assert with `has_function_privilege` if any chain function is touched.

**D1. Docs, same cycle.**
- ADR 020: stored derived facts, composite keys, the constrained redundancy on level rows, the public-schema choice for
  raw tables, recompute-and-diff, completion anchoring, the interim capacity duplicate.
- `docs/schema.md`; `Supabase/CLAUDE.md` "Tank sensors" section (objects, the 10-minute rule, the yard and dump-site
  facts, "do not let `rpa-derm-monthly` read these without D8", the dormant webhook writer) and the rule-8 count fixed.
- `samsara-lm11-level-monitor.md` section update from `samsara-tank-sensors-2026-10-12.md` (its section 9 lists the corrections; a status banner was added 2026-10-12).
- `samsara-integration-state.md` section 2 corrections; ADR 007 note (time on site is SQL now); the stale header in
  `cron_samsara_locations_history.js`; the probe script discovers sensors by `remoteSensingDistance`.
- `samsara-geofencing-plan.md` reciprocal note (9.1).
- TIMED_JOBS_PLAN 2.3, `services/timed-jobs/README` "Planned next" and `docs/audits/2026-10-07_timed_jobs_move.md`:
  record the D5 outcome. `services/db-backup` README: the new tables are included.
- The "THE HEALTH WATCHDOG" section's source list.
- A short runbook for the business flags: who acts on each, how.
- Root `CLAUDE.md` section 6 pointer; memory note "LM11 = grease-tank radar, LITRES" corrected (we store no litres).
- Supabase commits: Co-Authored-By footer, explicit paths only.

**Owner-gated, each separate:**

| Step | Content |
|---|---|
| **Y1** [OWNER D3b] | Yard: link the Samsara yard address (id from P1) through ESL to the yard property, and point `ops.v_depot`'s config at it (or add a separate yard setting if the depot means something else to other readers [U]); rebuild stops from 2026-08-20 for affected trucks |
| **W1** [OWNER D1] | Water capacity: in one audited transaction, supersede the water configuration and insert the same geometry with `capacity_gallons` set, basis `owner_confirmed`, **same `effective_from` (2026-10-02 17:09Z)**; gallons switch on for all history with no re-measure |
| **M8** [OWNER D4] | Time-on-site window: copy the live `fn_compute_time_on_site` body (md5 pin), change +28 h to +34 h with the guard that the extra 6 h count only when the same truck has no completed live visit at the same property dated `visit_date + 1`; rolled-back dry run 08-01 to today with the old body as control (expected about +41 resolved, 1 changed, at most 3 double claims [O, design C]). Same step: neutralise `webhook-samsara` `handleGeofenceAlert`'s visit write (it has never fired [O]). Docs: Visit Calendar, Client App (`client.visits`, `client.v_visits_live`) and whoever owns `ops.v_route_today` changelogs (all read these columns [O]). Later option: compute `actual_*` from `visit_vehicle_stops` (one clustering implementation) |
| **M9** [OWNER D6] | ops views (section 6); mockups of the real page first; probe as `authenticated` with JWT claims: each ops view's row count over a fixed past window equals the postgres count and is above 0; public objects 42501; `anon` 42501 everywhere; `fn_tank_fill_fraction` EXECUTE present. App docs in the same cycle |
| **M10** [OWNER D10] | Single home for capacity: move the 7 readers of `vehicles.grease_tank_capacity_gallons` [O] to the configuration in force at the visit date; make `derm.v_lwt_monthly_rows` read capacity in force at `visit_date` (freezes past LWT rows); then drop the column. F8 disappears |
| **M11** [OWNER D6] | Business-flag digest (Slack shared bot) or email check (section 8, later) |
| **M12** [OWNER D8] | If measured gallons go to a regulator: an audited, append-only `derm` snapshot table written by a month-close pg_cron job or a staff "close month" RPC **before** `rpa-derm-monthly` may serve that month; the endpoint answers 409 for a month with no snapshot (V50) |

### 10.3 Rollback rule

Every rollback after J1 exports the raw and derived tables to `backups\` and checks counts against Prod before any
DROP (a DROP bypasses the append-only guard, and Samsara retention is [U]).

---

## 11. Explicit answers

**(a) What if the water tank profile is never configured in Samsara?** Nothing here depends on it. We hold the geometry
(84 in cylinder, 12 in offset, fitted to 0.0005 pp [O]). Water percent, water used and refilled in percentage points,
per stop and per visit, are complete from 2026-10-02. Only gallons stay NULL (`percent_only`). The owner turns gallons
on without touching Samsara by giving the capacity or the tank length (about 288 gal per foot at 84 in [I]); W1
inserts one row and gallons appear for every past stop. If Samsara is configured too, nothing changes for us (we do not
ingest Samsara volume) and Z6 keeps watching the geometry. If the tank is not an 84 in cylinder, the percent itself is
wrong and a strapping chart is needed (a new `shape` value plus a child table, deferred until D1).

**(b) Cloggy and David, with no sensors?** Their GPS builds stops; their visits link by completion anchor (Cloggy 21 of
23, David 6 of 12 in discovery [O]); their dump dwells become dump stops (David's Broward dumps by coordinates, 11 m
from the stored point [O]); `stop_minutes` and F1 to F8 work for them; David's PTO gives pump minutes (on during 8 of 9
pumping visits [O]); Cloggy has 0 PTO readings and its RPM is [U]. No tank rows, so sludge confidence is `none /
no_sensor`; their LWT gallons keep coming from trap size. Fitting a sensor later is data, not schema: one tank, one
configuration, one sensor, one installation, two ESL links, then `fn_refresh_stop_facts(vehicle, install date)`.

**(c) How are LWT and regulator-facing figures protected?**
1. No regulator object reads anything new: Z8 checks function bodies and view dependencies every hour, with a function
   as its positive control; M6 adds a one-time repo grep of the edge functions.
2. Inputs cannot change silently: readings are append-only by trigger and grant, TRUNCATE is blocked; configurations,
   installations and site events change only by audited set-once supersede; stops and levels only by explicit,
   versioned supersede; links are audited.
3. Gallons are recomputed from the configuration in force, so a backdated configuration changes history. That is
   allowed only as an audited supersede-and-insert, and Z3 lists every affected row until re-measured. Acceptable for
   operations, not for anything filed.
4. If D8 says yes: the filed number is written once, at month close, into an audited append-only `derm` snapshot
   (visit, gallons, configuration id, installation id, level row ids, version, filing reference), and the endpoint
   refuses a month without one (M12).
5. Existing hazard, flagged: `derm.v_lwt_monthly_rows.truck_capacity_gallons` reads `vehicles.grease_tank_capacity_gallons`
   live [O], so a capacity edit already rewrites past LWT rows. F8 says so instead of pushing anyone to edit it; M10
   (D10) fixes it.

---

## 12. Owner decisions

| # | Decision | Default if unanswered |
|---|---|---|
| D1 | **Water tank:** confirm the 84 in horizontal cylinder and 12 in sensor offset; give the capacity in gallons, or the tank length, or a strapping chart | Percent only |
| D2 | One barrel with two compartments, or two tanks? (near full at the same moment, so separate volumes [I]) | Two tanks either way |
| D3 | **Dump sites:** (a) the Miami-Dade site's stored tip point and property 98's geocode sit 0.6 to 0.9 km from where the truck tips [O]: correct them? (b) optional Samsara address for the Broward site (its stored point already works, 11 m [O]); (c) which regulator disposal facility each site delivers to (an attribute of the site, for later) | Geofence for Miami-Dade, coordinates for Broward; nothing else changes |
| D3b | **Yard:** which property is the truck yard? Moises parks at the Samsara "yard" address (11 of 11 parks within 20 m [O]); the configured depot is 13 km away and no truck came within 150 m [O]; Cloggy parks elsewhere | Long unlinked stops read as `parked` |
| D4 | Extend `fn_compute_time_on_site` to 10:00 ET next day with the next-day guard (Calendar-visible; about +41 visits resolved [O]), and neutralise the dormant webhook visit writer | Recommend yes |
| D5 | Separate `samsara-readings` Railway service, or fold into `samsara-gps` (TIMED_JOBS_PLAN 2.3's "one Samsara job")? | Separate, with the watermark gate |
| D6 | Which app shows this (Visit Calendar or Admin Review), after mockups of the real page; a daily business-flag digest (Slack) or email; how app views limit `parked`/`other` stops; narrowing `client.entity_source_links` | SQL only, count-only line in the daily health email |
| D7 | Show measured volumes to customers? | No |
| D8 | Use measured gallons in LWT or DERM filings? Capture WWTP receipt gallons (0 of 863 manifests carry a receipt number [O, critic q6])? | No |
| D9 | Retention: keep raw data for ever (about 0.3 GB a year) or archive; any `sync_log` trimming (rule-6 exceptions) | Keep |
| D10 | One home for capacity (effective-dated configuration) and an LWT capacity freeze | Interim duplicate, flagged by F8 |
| D11 | Shared-stop split: sludge by trap size among Pumping visits only; water equally among linked visits; which service types count as volume visits (default `Pumping`) | As stated |
| D12 | Field questions: where water is refilled; whether rinse water goes back into the sludge tank; the two yard events (10-08, 10-09); what the shift-form numbers mean and whether the form stays | Open; water confidence stays low |
| D13 | Samsara support: sludge sensor mounting (45 false-empty episodes [O]); a low-water threshold; how to see LM11 battery voltage (only temperature is reported [O]); enter the water tank details | Open |
| D14 | Wrong-truck visits (8743) and dumps with no Dump Offload record (4 of 9): flag only, or create and correct records? | Flag only |
| D15 | What "recovered" means: rinse water recovered (not measurable) or sludge really pumped out (collected vs dumped)? | Treated as collected vs dumped |
| D16 | Wire Moises's vacuum pump switch to digital input 1 (or fix the ECU PTO) for an exact pump signal | RPM stand-in |
| D17 | Fit level sensors on Cloggy and David? | No |
| D18 | Build stops back to the start of GPS history (2026-01-01) for time-on-site and dump history? | From 2026-08-20 |

---

## 13. Rules checklist compliance

| # | Rule | How this plan meets it |
|---|---|---|
| 1 | No vendor-prefixed columns | none; M2 runs the `information_schema` regex test (expect 0) |
| 2 | ADR 014 exception limited | not used; sensors, tanks and sites are canonical |
| 3 | Naming and key shape | snake_case, identity ALWAYS, `<table>_id` FKs; composite natural keys on the 5 raw tables and the constrained redundancy on level rows are stated deviations in ADR 020 |
| 4 | Unit in the column name | `distance_meters`, `fill_percent`, `engine_rpm`, `capacity_gallons`, `diameter_meters`, `*_fill_fraction`, `*_percent_points` |
| 5 | Samsara ids only in ESL | asset ids and serials in ESL; address ids resolved through existing ESL property links and never stored; `v_vehicle_site_addresses` is an ESL projection, not a business column |
| 6 | CHECK widening | M1: live list re-read, 15 kept, 1 added, DROP then ADD without NOT VALID, positive control |
| 7 | Grep before widening | `'tank_sensor'` 0 [O], control 2; plus the generic ESL reader sweep (P1) |
| 8 | Link write atomic with entity | ESL rows seeded with their sensor rows; the job never creates links; asset-link moves back up first |
| 9 | addressEntry resolution | `addr_` stripped; resolved through ESL `property` links to service properties; only site properties kept |
| 10 | 3NF per column in header | section 2.6 copied into each header, including the honest exception |
| 11 | No stored derived values | gallons, percent, durations, kinds, shares, pump minutes view-only; stored stops and fractions justified under 13 |
| 12 | No repeating groups | tanks are rows with `contents`; readings are rows |
| 13 | Stored derived facts justified | ADR 020; `fn_compute_time_on_site` shape (SECDEF, pg_cron, dry run, NULL over a guess, never scheduled times) |
| 14 | Reuse what exists | GPS rows, `v_visits_live`, `duration_minutes` (shown), `dump_sites`, `non_customer_clients`, `fn_is_non_customer`, `ops.v_dump_sites`, `ops.v_depot`, `ops.fn_haversine_km`, `audit.log_change`, `run_logged.js`, `sync_log`, `log_jobber_sync_health`; `inspections` untouched |
| 15 | Denormalisation only by ADR | the 3,840 duplicate is named, flagged by F8, removed in M10; levels reference configurations by FK |
| 16 | Real FKs, each indexed | every FK a `REFERENCES` with a leading index (GiST and unique indexes counted) |
| 17 | No hard deletes | soft states only; DELETE and TRUNCATE raise 55000 on all 12 tables; retention is D9 |
| 18 | ON DELETE | RESTRICT everywhere, composite FKs included |
| 19 | Readers respect soft deletes | `v_visits_live`; `properties.deleted_at is null`; superseded and deleted rows filtered |
| 20 | Orphan sweep for FK-less references | ESL only: Z1 with a positive control; Z4 covers links |
| 21 | Timestamps | timestamptz UTC; `recorded_at` = Samsara time; no editable non-state columns, so no `updated_at` |
| 22 | ET day | W(V) built with `at time zone 'America/New_York'` |
| 23 | v1 epoch-ms trap | only v2 `/readings` with ISO times |
| 24 | One unit per quantity | metres, percent, RPM, gallons; no litres; numeric, never float |
| 25 | Audit stated per table | section 7, in headers and `COMMENT ON TABLE` |
| 26 | Audit defaults | human-entered and visit-touching tables opt in; machine append-only tables opt out |
| 27 | Compliance tables audited | nothing DERM-facing in v1; the D8 snapshot is audited and append-only |
| 28 | Generated rule-8 query | expected 71 (65 today [O]) |
| 29 | Writers label themselves | job sends `X-App-Source`; SQL sets `request.headers` (probe), fallback `sql` |
| 30 | Audit silence proves nothing | health uses sync_log counts, Z/T checks and sweeps |
| 31 | Default privileges | revoke by name from public, anon, authenticated **and service_role**; explicit grants; sequences and functions revoked |
| 32 | relacl checked | literal ACL sets asserted per table; `has_*_privilege` matrix incl. service_role UPDATE/DELETE/TRUNCATE false |
| 33 | Never grant anon | none |
| 34 | SECDEF hygiene | writers SECDEF, `search_path=''`, revoked by name; `fn_tank_fill_fraction` INVOKER IMMUTABLE |
| 35 | Probe as the real role | `SET LOCAL ROLE` service_role / authenticated / anon in M2, M3, M9 |
| 36 | RLS on new tables | all 12, no policies |
| 37 | Canonical in public, apps via own schema | facts and views in `public`; apps only through `ops` wrappers (M9) |
| 38 | Lock discipline | `lock_timeout 3s` on M1, M7, M9, M10; heavy VERIFY outside the transaction |
| 39 | raw.* rules | not used: payloads reduce to typed rows with natural keys at ingest |
| 40 | sync.* rules | not used: raw tables in `public` for the PostgREST write path, closed by literal ACL assertions; reason in ADR 020 |
| 41 | Telemetry precedent | natural keys end in the time column |
| 42 | ON CONFLICT on natural keys | readings, events, stops (live unique), links (live unique) |
| 43 | One writer per table | the job writes raw tables; each SQL function writes one derived table |
| 44 | supabase-js array NULL trap | identical key sets per chunk; no nullable columns written by the job |
| 45 | Resume from last stored state | run-success cursor, 30-min overlap, daily 48 h deep pass, no floor; non-zero exit on failure |
| 46 | Where jobs run | Railway for HTTP pulls; pg_cron for SQL; no GitHub schedule |
| 47 | Volume, retention, partitioning stated | section 7 incl. sync_log growth and backup |
| 48 | Health chain | five watched sources by md5 splice; separate kinds; later checks register in both health views |
| 49 | File naming | `_STAGED` suffix, renamed on apply |
| 50 | Header contents | section 10.1 |
| 51 | One transaction per body | no inner COMMIT; `cron.schedule` alone |
| 52 | Public repo hygiene | client-code and geofence-name grep before commit; `source_name` NULL; names never logged |
| 53 | Rolled-back proof | every PL/pgSQL body executed in M4; guards tested both ways; must-fail controls; zero residue |
| 54 | Zero-run loop | M4 to M6 repeat until Z = 0; smoke rows `[TEST]`, only inside rollbacks |
| 55 | Compliance boundary | N1, recurring Z8, one-time repo grep, M12 path; F8 warns about the existing LWT hazard |
| 56 | Samsara canonical for telemetry | `vehicles` is the fleet authority; tanks and sensors hang off it |
| 57 | Docs in the same cycle | D1; app docs with M8 and M9 |
| 58 | Coordination | M0 claim (append and commit together); explicit-path staging |

---

## Appendix A. Verification findings: resolution

| # | Sev | Finding (short) | Resolution |
|---|---|---|---|
| V1 | blocker | Parallel dump-site identity; FK to the regulator facility table; new ESL type; D3 default unused by manifests; Broward site called invisible; dump links ignore the site | **Fixed, with a variation.** Site events and stops point at **properties** (rule 9), reached through the existing ESL property link of the Samsara address; dump-ness from `non_customer_clients` via `fn_is_non_customer`; the yard is a property too. `disposal_facility` ESL type dropped (M1 adds only `tank_sensor`). Dump visits = `fn_is_non_customer(client_id, '{dump_site}')`, linked only to dump stops of their own client; partial unique index, one dump visit per dump stop. Broward dumps detected from `dump_sites` tip points (David within 11 m [O]). The regulator facility becomes a site attribute later (D3c), not a second identity |
| V2 | major | Links reconciled only for a 10-day window; Z4 never re-checks the predicate | **Fixed.** Whole-era reconcile every hour (5.4); Z4 re-checks vehicle, distance to the current property, basis vs stop kind |
| V3 | major | Overlapping live stops possible | **Fixed.** Exclusion constraint on live stops; open-dwell barrier; watermark gate (5.2) |
| V4 | major | Configurations cannot be corrected from their own instant; W1 collides | **Fixed.** `superseded_at` (set-once), partial unique on live rows, "in force" over live rows; W1 rewritten; M2 and M4 test same-instant correction |
| V5 | major | Disposal events resolved at ingest with no correction path | **Fixed.** Events key on the stable site property and carry set-once `superseded_at`; the stop builder reads live events; correction = supersede + rebuild (2.3) |
| V6 | major | Re-measure misses ended or superseded installations; 3-day horizon | **Fixed.** Recompute-and-diff over 35 days plus every Z2/Z3-flagged row; a pair with no installation in force supersedes its row and inserts nothing (5.3) |
| V7 | minor | Tank not tied to the stop's vehicle; 3NF claim wrong | **Fixed.** `vehicle_id` with composite FKs to stops and tanks; section 2.6 states the constrained redundancy honestly |
| V8 | minor | Capacity provenance differs from the level row's configuration | **Fixed.** Any change of the in-force configuration id re-measures; Z3 requires the FK = in-force configuration |
| V9 | minor | `client.entity_source_links` exposes new ESL rows; rule-7 grep missed generic readers | **Partly fixed.** P1 lists every ESL reader without an `entity_type` filter; `source_name` NULL; exposure documented and accepted for v1 (asset ids and serials are not sensitive). **Narrowing the view is deferred** to a separate Client App change (D6), because it alters a Client App surface |
| V10 | minor | Sensor identity vs gateway serial | **Fixed.** `tank_sensors` = one row per physical device; a re-created asset moves the asset link (backup first), never a second sensor row |
| V11 | minor | Stored zeros for unmeasured legs | **Fixed.** `risen`/`fallen` nullable, CHECKs tie them to both edges; NULL when too short; views propagate NULL |
| V12 | minor | `algorithm_version` ignores non-default parameters | **Fixed.** Executing with non-default thresholds raises 22023 |
| V13 | minor | Measuring a soft-deleted tank | **Fixed.** Installations in force require a non-deleted tank; Z7 flags a live installation on a deleted tank |
| V14 | major | `service_role` keeps default `arwdDxtm`; sibling comparison certifies it | **Fixed.** Revoke from service_role too, exact grants, literal ACL assertions, service_role UPDATE/DELETE/TRUNCATE asserted false; M3 now expects 42501 on UPDATE |
| V15 | major | TRUNCATE bypasses the row guard | **Fixed.** Statement-level `BEFORE TRUNCATE` trigger on all 12 tables (same guard function); probes with a must-truncate control |
| V16 | major | Security-invoker public views cannot be wrapped by owner-rights ops views | **Fixed (option a).** Public views owner-rights, service_role-only; M9 probes row counts as `authenticated` |
| V17 | major | ESL seed `source_name` could leak a client code | **Fixed.** `source_name` NULL on every seeded row (and no address link is seeded at all now); pre-commit client-code and geofence-name grep |
| V18 | minor | Put raw tables in `sync` (fails closed) | **Rejected, with the finding's own alternative accepted.** `sync` is not exposed to PostgREST, so the job would need a DB connection or an insert RPC; keeping `public` with literal ACL assertions (V14) closes the same gap with less code. The reason goes in ADR 020 |
| V19 | minor | Identity sequences keep default grants | **Fixed.** Revoke loop per identity sequence; `has_sequence_privilege` asserted |
| V20 | minor | SECDEF and EXECUTE contradiction on `fn_tank_fill_fraction` | **Fixed.** SECURITY INVOKER, IMMUTABLE, PARALLEL SAFE; EXECUTE service_role now, authenticated in M9; SECDEF only on writers |
| V21 | blocker | LM11 measures every ~10 min; row-based edges and counts are wrong | **Fixed, and independently confirmed** [O: 1,883 value changes in 52.9 days on sludge, median gap 632 s, 86% at least 590 s apart; water median 601 s]. Measurements = value changes; arrival and departure edges redefined (first new measurement within one period after leaving); `too_short` |
| V22 | major | Row-level spike filter never fires on repeated ghosts | **Fixed.** Spike test on measurements; 10-09 08:12 must-fail control |
| V23 | major | False-empty rule rejects real dumps | **Fixed.** Look-ahead (recovery within 3 h, no dump between); 10-09 dump and the 6087/6582 anchor as must-pass controls |
| V24 | major | Dump confidence without a sign check | **Fixed.** `implausible_offload` rule; excluded from the ratio; 10-01 must be low |
| V25 | major | Dump Offload linked by scheduled start | **Fixed.** Completion anchor on dump stops first, then elimination; ambiguity flagged, not guessed; 5 of 5 acceptance |
| V26 | major | Window fallback picks the stop nearest the scheduled start | **Fixed.** All unanchored stops in L(V) inside W(V); never by start time; 6075 acceptance |
| V27 | major | Non-pumping visits take or halve Pumping sludge | **Fixed.** Sludge shares only among Pumping visits; other visits get completion links only; 8744 and a same-property pair as controls |
| V28 | major | `ops.v_depot` is not where trucks park | **Partly fixed.** Yard modelled as a site property with Samsara address events; `parked` fallback (4 h) until then; M4 control on Moises's 11 parks. **Linking the yard is owner-gated (D3b, Y1)** because the configured depot points 13 km away and other readers of `ops.v_depot` may depend on it [U] |
| V29 | major | Hysteresis has no end flush | **Fixed.** Zig-zag with end flush (5.3); water and gross-intake acceptance rows |
| V30 | major | Incremental build emits phantom stops inside open dwells; 6 h event lookback | **Fixed.** Open-dwell barrier, watermark gate, exclusion constraint; hour-by-hour M4 test |
| V31 | minor | W1 same instant; 3-day measure horizon; water install time | **Fixed.** Superseded configurations; Z3-flagged rows re-measured at any age; water installation from 19:29Z |
| V32 | minor | 48 h resume floor; late readings never re-measured | **Fixed.** No floor (chunked catch-up); recompute-and-diff over 35 days |
| V33 | minor | J1 control count 104,806 | **Fixed.** 104,803, the 3 colliding timestamps noted |
| V34 | minor | Coverage outside Moises; F1 is Pumping-only | **Fixed.** Anchoring rate per vehicle in M4; F1b for dump visits; Broward dumps now detectable |
| V35 | minor | Out-of-range anchors look free | **Fixed.** Whole-era candidate set |
| V36 | major | Late data frozen once measured | **Fixed.** Recompute-and-diff picks up late readings within 35 days; M4 late-reading control |
| V37 | major | Business assertions alias process failures in one health item | **Fixed.** Exit 1 only for process failures; data findings in separate sources (`tank_feed_freshness`, `stop_facts_integrity`, `tank_geometry_drift`) |
| V38 | major | Units guard stops every stream; 48 h floor loses data | **Fixed.** Per-stream guard with normalised units; no floor |
| V39 | major | GPS and events from two services; builder runs ahead of events | **Fixed.** Build capped at the readings watermark; exclusion constraint. D5 still open |
| V40 | major | Old rebuilds orphan links; levels never re-measured | **Fixed.** One entry point `fn_refresh_stop_facts(vehicle, from)`; whole-era link reconcile; Z9 |
| V41 | major | W1 unique violation; seed uncorrectable | **Fixed** (same as V4) |
| V42 | major | Z5 pushes operators into the LWT rewrite | **Fixed.** Z5 became business flag F8 with the LWT consequence in its text; M10 is the real fix |
| V43 | major | `pg_depend` cannot see function bodies or edge functions | **Fixed for the DB** (recurring Z8 prosrc sweep with a function control) **and one-time for edge functions** (M6 grep). A recurring repo check is **deferred**: nothing runs repo checks on a schedule today, and the edge-function rule is written into `Supabase/CLAUDE.md` (D1) |
| V44 | major | D3 ordering; event history not backed up | **Fixed.** The Miami-Dade address already resolves (no D3 dependency); M0 backs up the truck event pulls with names stripped |
| V45 | major | Empty output reads healthy | **Fixed.** T1 to T5 (including engine-on-without-GPS), runner `rows_inserted` from the summary |
| V46 | minor | `feed=true` switch described as automatic | **Fixed.** It is item T5 asking a person to ship it |
| V47 | minor | sync_log growth, backup and rollback not stated | **Fixed.** Section 7 (one row per run, about +37%), backup includes the new tables, rollback exports first |
| V48 | minor | Doc duties incomplete | **Fixed.** D1 list extended (inventory regen, TIMED_JOBS_PLAN, watchdog list, Client App and route owners for M8) |
| V49 | minor | F3 reaches nobody | **Partly fixed.** Count-only line in the daily health email (M7); manifest cross-check measured once (none on 10-03 or 10-09 to 10-11 [O]). **Full alerting deferred to D6** |
| V50 | minor | D8 snapshot has no writer | **Fixed.** Month-close writer before the endpoint may serve the month; 409 otherwise (M12) |

Also changed without a finding: resume moved from per-entity cursors to one run-success cursor (section 4 explains why).

---

## Appendix B. Completeness critic: resolution

| # | Gap | Resolution |
|---|---|---|
| C1 | No plain-language inventory; 20 readings never checked | **Added.** Discovery report sections 1 and 3; the 10 batch-hidden readings (not 20: two batches of 5) re-probed singly with 42 more [O] |
| C2 | "Recovered" may mean sludge recovered | **Added** D15 |
| C3 | No "later uses" | **Added** (discovery report section 8) |
| C4 | No trips | **Deferred.** No consumer yet, a GPS-summing view is heavy, and `ops.v_truck_utilization` exists; add with D6 |
| C5 | Compliance left out | **Reinterpreted.** The recording says "compliance to what our architecture is for": section 13 answers it. Regulatory cross-checks listed under later uses (read-only), behind D8 |
| C6 | `engineState` not ingested | **Deferred.** RPM already distinguishes running from off on trucks that report it; revisit if P1 shows Cloggy has no RPM |
| C7 | PTO and digital input dead on Moises | **Added** to the inventory; D16 |
| C8 | Other engine readings | **Added** verdict table (discovery report 3.3): later or never in v1 |
| C9 | Sensor battery not monitored | **Measured and deferred.** Only `gatewayBatteryTemperature` reports; voltage and status empty [O]. T1 (silence) is the only signal; D13 asks Samsara |
| C10 | Client geofence events excluded without reason; relation to the geofencing plan | **Added** section 9.1; client-site events stay out of v1 (that plan's scope); yard handled as a site property |
| C11 | Dormant `webhook-samsara` writer of `visits.actual_*` | **Added.** Confirmed in code (lines 436 to 498) and never fired [O]; documented in D1, neutralised in M8 (D4) |
| C12 | Manifest dump dates vs GPS | **Measured once, flag deferred.** Manifests have no truck column; two unrecorded dumps fall on dates with no manifest [O]; a flag needs visit links and an owner use (later uses) |
| C13 | Receipt gallons absent | **Added** to D8 (0 of 863 manifests carry a receipt number [O, critic]) |
| C14 | Measured vs reported comparison view | **Deferred** to D6/D8 (staff-only view, compare without merging) |
| C15 | No tests for Cloggy and David | **Added** to M4 (per-vehicle anchoring, David PTO, Broward dump links) |
| C16 | Cloggy RPM never pulled; sensors for other trucks | **Added** to P1; D17 |
| C17 | Yard decants and transfers break the cycle ratio | **Added** `cycle_offsite_drop`, ratio NULL; `nearest_property_id` on F2 and F5 |
| C18 | Anchor walk merges visits across a GPS outage | **Deferred.** No observed case, and driving cannot be told from pumping during a gap without speed, which the GPS writer does not store (N4); revisit when it does |
| C19 | Late exit events create overlapping stops | **Added** (watermark gate, open-dwell barrier, exclusion constraint) |
| C20 | M0 backs up only level pulls; GPS coverage check | **Added** to M0 |
| C21 | No one sees business flags before D6; personal stops | **Added** count-only health line; D6 digest; app views hide `parked`/`other` coordinates |
| C22 | No page design | **Added** to D6 and M9 (mockups of the real page first) |
| C23 | Doc work missing | **Added** to D1 (memory note, root CLAUDE.md pointer, geofencing note, webhook writer, flag runbook) |
| C24 | No transform self-check | **Added** (`*.test.js` with plain asserts, section 4) |

---

## Appendix C. Evidence gathered for this revision (read-only)

| Fact | Method | Result |
|---|---|---|
| Measurement period | value changes over the full distance pulls (`final\cadence.js`) | sludge 1,883 changes, p25/p50 600/632 s, 86% at least 590 s apart; water 366 changes, 600/601 s, 89% |
| Batch-hidden readings | `/readings/latest` one id per call, 52 ids x 3 assets (`final\reprobe.mjs`) | LM11: battery temperature only; truck: fuel level 33%, battery 13.11 V; 2 ids return 500 even alone |
| Units | `/readings/definitions` | meter, percent, rpm, enum off/on, Object `addressIds` |
| Dump-site registry | catalog and row reads (`norm\q7`, `q8`, `final\f1`) | `dump_sites` (PK client_id, tip points), clients 365 and 76; address 322485232 linked to client 365 and property 98; client 76 / property 155 have no Samsara link |
| Miami-Dade dump position | median truck fix per dwell vs stored tip point (`final\dumppos.js`) | 0.603 to 0.873 km on all 9 dwells |
| Broward dump position | truck fixes vs stored tip points (`final\dp.js`) | David min 11 m, 255 fixes within 150 m, on 10-02 and 10-08; Moises and Cloggy never within 1.8 km |
| Truck parking | parked stretches of 3 h or more vs the Samsara yard address (`final\yard.js`) | Moises 11 of 11 within 20 m; Cloggy 7, all about 21.8 km away; David none |
| Depot | `ops.v_depot` definition, properties near the yard (`final\f1`, `f2`) | depot from `app_config.depot_property_id`; properties near the yard address are a test client's and one with 0 visits |
| Visit kinds at dump sites | count by `service_type` (`final\f2`) | Dump Offload 37, null 13, Pumping 10, Cleaning 8, Labor 1 (all history) |
| Completed service mix since 08-20 | count (`final\f2`) | Pumping 211, Unclogging 50, Labor 30, Dump Offload 24, Cleaning 10, others 10 |
| Manifests near the dumps | `derm_manifests` by `dump_ticket_date` (`final\f3`) | 09-28: 6, 10-01: 10, 10-02: 11, 10-06: 7, 10-07: 7, 10-08: 10; none 10-03, 10-09 to 10-11; no truck column |
| Dormant visit writer | code read, `webhook-samsara/index.ts` | `handleGeofenceAlert` at line 436 writes `is_gps_confirmed` and `actual_*` (lines 492 to 498) |
| `run_logged.js` shape | code read | one `sync_log` row per run, stdout inherited, no summary capture today |

Files: the check scripts and outputs of this pass were kept outside the repo (raw pulls carry geofence names); the level pulls are backed up in the workspace `backups/2026-10-12_lm11_discovery/` (local only).
