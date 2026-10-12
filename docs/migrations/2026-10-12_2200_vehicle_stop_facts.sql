-- 2026-10-12 22:00 ET · Vehicle stop facts: stops, tank levels per stop, visit links, and the hourly refresh (M4)
-- APPLIED to Prod 2026-10-12 ~18:45 ET after a rolled-back run; backfill select public.fn_refresh_stop_facts() ran at once: 854 stops, 491 levels, 324 links, Z1-Z9 = 0.
-- Plan: docs/superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md (sections 2.5, 2.6, 3, 5.1 to 5.8, 7, 8, 9,
-- 10.2 M4). Builds on the APPLIED 2026-10-12_1501 (ESL tank_sensor), _1502 (tanks, configurations, sensors,
-- installations, public.fn_append_only_guard) and _1503 (raw readings and site events).
--
-- WHAT
--   public.fn_tank_fill_fraction(distance, diameter, offset)   fill fraction of a horizontal cylinder from the radar
--       distance (SQL, IMMUTABLE, PARALLEL SAFE, SECURITY INVOKER). EXECUTE to service_role only (authenticated in M9).
--   public.vehicle_stops             one row per place a truck stayed: a GPS anchor walk, or a dwell at a site
--                                    property (dump site or the yard) from Samsara address events
--   public.vehicle_stop_tank_levels  per (stop, tank): the fill fraction at arrival and departure, and how much the
--                                    level rose and fell during the stop (measured on value changes, 10-minute LM11)
--   public.visit_vehicle_stops       which stops served which completed visit, and on what basis
--   public.fn_build_vehicle_stops(vehicle, until, execute, rebuild_from, radius_m, min_minutes, dump_radius_m)
--   public.fn_measure_vehicle_stop_tank_levels(from, execute, spike_agree_m, spike_jump_m, hyst_sludge, hyst_water,
--                                              period, lookahead)
--   public.fn_link_visit_vehicle_stops(execute, radius_m, earlier_hours, volume_service_types)
--   public.fn_stop_facts_checks()    the section 8 checks (Z, T, business flag counts) as one jsonb, read-only
--   public.fn_refresh_stop_facts(rebuild_vehicle_id, rebuild_from)   the one entry point: build, measure, link,
--                                    checks, four sync_log rows. The pg_cron job of M5 calls it hourly.
--   All writers are SECURITY DEFINER, search_path '', revoked BY NAME from public, anon, authenticated, service_role.
--   Thresholds are parameters; with p_execute = true a non-default threshold raises 22023, so a stored row always
--   means what its algorithm_version (1) says.
--
-- WHY
--   Owner voice note, 2026-10-12: "how long they stayed on that client, how much water was used, how much sludge was
--   pumped out", "how much sludge did we really pump out", "compliance to what our architecture is for ... three
--   normal form ... everything needs to be linked. No orphans." Owner, 2026-10-12: "Before showing it on an app,
--   let's work on it to be correct everything in the DB". Stored, not view-only (rule 13): a stop costs an anchor
--   walk over about 3,700 fixes per truck-day, visits and level rows need a stable row to point at, and
--   fn_compute_time_on_site throws its clusters away. Fractions, not gallons: a fraction needs geometry only, gallons
--   come from the configuration's capacity in the M6 views.
--
-- THE YARD (owner decision D3b, answered 2026-10-12): the yard is property 1194 (client 000-YD, kind 'yard' in
--   public.non_customer_clients) and ops.v_depot resolves to it. Its Samsara address is linked in ESL but the
--   collector stores address events for dump-site properties only (site_resolver esl_dump_site_properties), so no
--   yard event exists. A GPS stop whose centroid lies within p_dump_radius_m (150 m) of ops.v_depot's point gets
--   site_property_id = the yard property, exactly like the Broward dump site, whose tip point already works
--   (measured: the three trucks' fixes at the yard sit within 50 m of the property's geocode). If yard address
--   events are collected later, the dwell path picks them up with no change here.
--   Dump sites: 000-DH (property 98) from its Samsara address events (its stored tip point is 0.6 to 0.9 km from where
--   trucks tip); 000-DP (property 155) from its tip points (David within 11 m), and from events once they arrive.
--
-- 3NF (key; each column depends on the whole key and nothing else)
--   vehicle_stops (key id; natural key vehicle_id + arrived_at among live rows)
--     vehicle_id         the truck that stopped: a fact of the stop
--     arrived_at         first fix of the walk, or the site entry event
--     departed_at        last in-radius fix, or the site exit event
--     latitude, longitude  median of the stop's own fixes (not derivable without re-walking the GPS)
--     gps_fix_count      number of fixes in the stop
--     site_property_id   the dump-site or yard property the stop is at (NULL elsewhere)
--     formation          how the stop was formed (gps_walk or site_dwell)
--     algorithm_version  which rules built it
--     created_at         when the row was written;  superseded_at  this row was replaced by a rebuild (set once)
--     Duration, kind (dump, yard, client, parked, other), pump minutes: view-only (M6), never stored.
--   vehicle_stop_tank_levels (key id; natural key vehicle_stop_id + vehicle_tank_id among live rows)
--     vehicle_stop_id, vehicle_tank_id   which stop, which tank
--     vehicle_id         STATED HONESTLY: determined by vehicle_stop_id (and by vehicle_tank_id). Deliberate,
--                        constrained redundancy: the composite FKs (stop, vehicle) and (tank, vehicle) make it
--                        impossible to attach one truck's tank to another truck's stop. Documented exception to
--                        rule 3 (ADR 020).
--     tank_sensor_installation_id, vehicle_tank_configuration_id   provenance: the installation and configuration
--                        in force at arrived_at that this measurement used. vehicle_tank_id is also determined by
--                        each of them; the composite FKs (installation, tank) and (configuration, tank) keep them
--                        consistent (same documented exception).
--     arrival_fill_fraction, arrival_measured_at, departure_fill_fraction, departure_measured_at   the two edge
--                        measurements and the first-seen time of each
--     fill_fraction_risen, fill_fraction_fallen   zig-zag totals between the edges (NULL = not observable)
--     measurement_count, rejected_measurement_count   accepted and rejected measurements between the edges
--     algorithm_version, created_at, superseded_at (set once)
--     Gallons, percent, net change: view-only (M6).
--   visit_vehicle_stops (key id; natural key visit_id + vehicle_stop_id among live rows)
--     visit_id, vehicle_stop_id   the pairing;  match_basis  why they were paired
--     created_at;  deleted_at  the linker found the match no longer holds (set once)
--     Shares of sludge, water and time: view-only (M6).
--
-- RULE 8, AUDIT
--   visit_vehicle_stops OPTS IN (audit_visit_vehicle_stops): it touches visits, about 10 rows a day. Its writes carry
--   app_source 'stop-facts' (fn_refresh_stop_facts sets request.headers x-app-source, which audit.log_change reads).
--   vehicle_stops and vehicle_stop_tank_levels OPT OUT: machine-derived from raw feeds, append-only by trigger and
--   grant, every change an explicit versioned supersede; not regulator-facing in v1 (plan section 7). The generated
--   rule-8 query moves from 70 (after M3) to 71.
--
-- GRANTS, intended literal ACL of each table (asserted below as an aclexplode set):
--   {postgres=arwdDxtm/postgres, service_role=r/postgres, db_backup_reader=r/postgres}
--   CREATE TABLE in public hands authenticated and service_role everything by default, so each table is revoked BY
--   NAME from public, anon, authenticated and service_role, then service_role gets SELECT. Only the SECURITY DEFINER
--   functions (owner postgres) write. Identity sequences revoked from the same four roles. RLS on, no policies.
--   Functions: the five writers and fn_stop_facts_checks have EXECUTE revoked from public, anon, authenticated,
--   service_role (pg_cron runs them as the owner). fn_tank_fill_fraction: EXECUTE to service_role only.
-- FKs: all ON DELETE RESTRICT, each served by a NON-partial index leading with its columns. (Deviation from the plan
--   text: vehicle_stops_site_idx is not partial, so the check a properties DELETE runs is served without relying on
--   predicate proof. A handful of rows a day.)
-- LOCKS: CREATE TABLE ... REFERENCES takes SHARE ROW EXCLUSIVE on public.vehicles, public.properties and
--   public.visits until COMMIT, which queues every writer of those tables (Calendar, Client App, Jobber poll) behind
--   this file. SET LOCAL lock_timeout = '3s': on 55P03 the whole file rolls back; retry it. Keep the transaction short:
--   no backfill in this file. The backfill is one call after commit: select public.fn_refresh_stop_facts();
-- VOLUME / RETENTION: about 25 stops, 17 level rows and 10 links a day, plus superseded rows when a measurement is
--   revised. Keep everything (rule 6; D9). No partitioning.
-- NOT IN THIS FILE: the seven public views (M6), the cron (M5), the health wiring (M7). Business flags F2, F4 and F6
--   need the view logic (pump signature, dump cycles, other trucks' stops) and are counted from
--   v_tank_data_quality_issues once M6 lands; fn_stop_facts_checks counts F1, F1b, F3, F5, F7 and F8 now.
--
-- DEVIATIONS FROM THE PLAN TEXT (each measured or explained in the M4 probe report of 2026-10-12)
--   1. The yard is detected by coordinates (see THE YARD above), not by address events: none are collected for it.
--   2. An open site entry older than 12 hours is counted as stale_open_entries and is not a barrier, so one lost exit
--      event cannot freeze a truck's stops for ever (plan 5.2 step 4 has no limit).
--   3. A rebuild resumes at greatest(p_rebuild_from, the latest departed_at of the stops it keeps), so a kept stop that
--      straddles p_rebuild_from cannot be overlapped.
--   4. A kept dwell after the last GPS fix also closes the open walk stop (otherwise that stop would be lost behind
--      the dwell on the next run).
--   5. The anchor walk computes the haversine inline with ops.fn_haversine_km's formula and radius (6371.0088 km);
--      every other distance uses ops.fn_haversine_km.
--   6. fn_stop_facts_checks is a separate read-only helper (the refresh calls it; the Z/T positive controls call it).
--      Z3 also flags a live level row on a superseded stop.
--   7. vehicle_stops_site_idx is not partial (see FKs below). fn_tank_fill_fraction cannot be inlined (see section 1).
--
-- VERIFY (below): literal ACL per table; anon/authenticated hold nothing; service_role SELECT only; sequences closed;
--   RLS on; each table carries both guard triggers; only visit_vehicle_stops audited; every FK confdeltype 'r' and
--   served by a non-partial leading index; 0 vendor-prefixed columns; every writer SECURITY DEFINER with
--   search_path '' and no EXECUTE for public/anon/authenticated/service_role; fn_tank_fill_fraction is INVOKER,
--   IMMUTABLE, executable by service_role and not by anon/authenticated; fill-fraction controls (water 1.34 m =
--   51.885 %, 0.75 m = 84.873 %, 1.83 m = 23.512 %, sludge 1.14 m = 45.635 %, 0.50 m = 82.157 %), and the water reading
--   on a zero offset misses by more than 1 pp (negative control).
--   Behaviour (every PL/pgSQL body executed, the M4 acceptance table of plan 10.2 against real data, the Z and T
--   positive controls) was proven by rolled-back probes before apply; see the M4 probe report of 2026-10-12.
-- ROLLBACK (export first: a DROP bypasses the append-only guard and writes no audit row):
--   copy the three tables to backups\ as JSON, then
--   drop function public.fn_refresh_stop_facts(bigint, timestamptz), public.fn_stop_facts_checks(),
--     public.fn_link_visit_vehicle_stops(boolean, integer, integer, text[]),
--     public.fn_measure_vehicle_stop_tank_levels(timestamptz, boolean, numeric, numeric, numeric, numeric, interval, interval),
--     public.fn_build_vehicle_stops(bigint, timestamptz, boolean, timestamptz, integer, integer, integer),
--     public.fn_tank_fill_fraction(numeric, numeric, numeric);
--   drop table public.visit_vehicle_stops, public.vehicle_stop_tank_levels, public.vehicle_stops;

begin;
set local lock_timeout = '3s';

-- ============================================================ 1. FILL FRACTION (plan 5.1)
-- Note: a SQL function with a SET clause is never inlined by the planner, so "inline in views" (plan 5.1) does not
-- hold with search_path pinned. Kept pinned (rule 34); a call costs microseconds.
create function public.fn_tank_fill_fraction(p_distance_meters numeric, p_diameter_meters numeric,
                                             p_sensor_offset_meters numeric)
returns numeric language sql immutable parallel safe security invoker set search_path = '' as $$
select case when p_distance_meters is null or p_distance_meters <= 0 then null else
  ((g.r*g.r*acos((g.r-g.h)/g.r) - (g.r-g.h)*sqrt(greatest(2*g.r*g.h - g.h*g.h, 0))) / (pi()*g.r*g.r))::numeric end
from (select p_diameter_meters::float8/2 as r,
             least(greatest((p_sensor_offset_meters + p_diameter_meters - p_distance_meters)::float8, 0),
                   p_diameter_meters::float8) as h) g
$$;
revoke all on function public.fn_tank_fill_fraction(numeric, numeric, numeric) from public, anon, authenticated, service_role;
grant execute on function public.fn_tank_fill_fraction(numeric, numeric, numeric) to service_role;
comment on function public.fn_tank_fill_fraction(numeric, numeric, numeric) is
  'Fill fraction (0..1) of a horizontal cylinder from the LM11 radar distance: h = offset + diameter - distance, '
  'clamped to [0, diameter]; NULL for a distance <= 0 (no echo). Touches no table. Tank sensors plan 5.1. '
  'EXECUTE: service_role (authenticated in M9).';

-- ============================================================ 2. TABLES (plan 2.5)
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
  constraint vehicle_stops_no_overlap exclude using gist
    (vehicle_id with =, tstzrange(arrived_at, departed_at) with &&) where (superseded_at is null)
);
create unique index vehicle_stops_live on public.vehicle_stops (vehicle_id, arrived_at) where superseded_at is null;
create index vehicle_stops_vehicle_time_idx on public.vehicle_stops (vehicle_id, arrived_at);   -- the FK
create index vehicle_stops_site_idx on public.vehicle_stops (site_property_id);                -- the FK

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

-- ---------------------------------------------------------------- guards and audit
create trigger vehicle_stops_append_only before update or delete on public.vehicle_stops
  for each row execute function public.fn_append_only_guard('superseded_at');
create trigger vehicle_stops_no_truncate before truncate on public.vehicle_stops
  for each statement execute function public.fn_append_only_guard();

create trigger vehicle_stop_tank_levels_append_only before update or delete on public.vehicle_stop_tank_levels
  for each row execute function public.fn_append_only_guard('superseded_at');
create trigger vehicle_stop_tank_levels_no_truncate before truncate on public.vehicle_stop_tank_levels
  for each statement execute function public.fn_append_only_guard();

create trigger visit_vehicle_stops_append_only before update or delete on public.visit_vehicle_stops
  for each row execute function public.fn_append_only_guard('deleted_at');
create trigger visit_vehicle_stops_no_truncate before truncate on public.visit_vehicle_stops
  for each statement execute function public.fn_append_only_guard();
create trigger audit_visit_vehicle_stops after insert or update or delete on public.visit_vehicle_stops
  for each row execute function audit.log_change();

-- ---------------------------------------------------------------- RLS + grants
alter table public.vehicle_stops            enable row level security;
alter table public.vehicle_stop_tank_levels enable row level security;
alter table public.visit_vehicle_stops      enable row level security;

revoke all on public.vehicle_stops, public.vehicle_stop_tank_levels, public.visit_vehicle_stops
  from public, anon, authenticated, service_role;
grant select on public.vehicle_stops, public.vehicle_stop_tank_levels, public.visit_vehicle_stops to service_role;
do $g$
declare s text;
begin
  foreach s in array array[pg_get_serial_sequence('public.vehicle_stops','id'),
                           pg_get_serial_sequence('public.vehicle_stop_tank_levels','id'),
                           pg_get_serial_sequence('public.visit_vehicle_stops','id')] loop
    execute format('revoke all on sequence %s from public, anon, authenticated, service_role', s);
  end loop;
end $g$;

comment on table public.vehicle_stops is
  'A place a truck stayed: a GPS anchor walk (formation gps_walk) or a dwell at a site property from Samsara address '
  'events (site_dwell). site_property_id is set iff the stop is at a dump site or the yard. Written only by '
  'fn_build_vehicle_stops (via fn_refresh_stop_facts). Live stops never overlap (exclusion constraint). Append-only; '
  'superseded_at set once by a rebuild. Rule 8: NOT audited (opt-out): machine-derived, versioned supersede. '
  'Tank sensors plan 2026-10-12.';
comment on table public.vehicle_stop_tank_levels is
  'Per (stop, tank): fill fraction at the arrival and departure edges and the risen/fallen totals, measured on LM11 '
  'value changes (about every 10 minutes). Provenance: the installation and configuration in force at arrived_at. '
  'vehicle_id is constrained redundancy kept consistent by composite FKs (ADR 020). Written only by '
  'fn_measure_vehicle_stop_tank_levels; recompute-and-diff supersedes a row whose inputs changed. Rule 8: NOT '
  'audited (opt-out): machine-derived, versioned supersede.';
comment on table public.visit_vehicle_stops is
  'Which stops served a completed visit (match_basis completion, same_site_earlier, window, dump_completion, '
  'dump_window). Reconciled over the whole sensor era every refresh by fn_link_visit_vehicle_stops; a link that no '
  'longer holds gets deleted_at (set once). Rule 8: AUDITED (opt-in): touches visits; writes labelled stop-facts.';

-- ============================================================ 3. STOP BUILDER (plan 5.2)
create function public.fn_build_vehicle_stops(
  p_vehicle_id     bigint,
  p_until          timestamptz,
  p_execute        boolean,
  p_rebuild_from   timestamptz default null,
  p_radius_m       integer default 100,
  p_min_minutes    integer default 3,
  p_dump_radius_m  integer default 150)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_version   constant smallint    := 1;
  c_era_start constant timestamptz := '2026-08-20 00:00:00 America/New_York';
  v_end       timestamptz := p_until;
  v_r         timestamptz;
  v_barrier   timestamptz;
  v_unpaired  int := 0;  v_stale_open int := 0;  v_before_r int := 0;  v_no_fix int := 0;
  v_sup_stops int := 0;  v_sup_levels int := 0;  v_del_links int := 0;  v_ins int := 0;
  -- dwells (sorted by entry)
  v_da timestamptz[];  v_db timestamptz[];  v_dp bigint[];  v_nd int := 0;
  -- fixes
  v_t  timestamptz[];  v_lat float8[];  v_lng float8[];  v_n int := 0;
  -- walk output (index ranges into the fix arrays)
  v_ga int[] := '{}';  v_gb int[] := '{}';
  i int;  v_di int := 1;  v_anchor int;  v_last int;  v_break boolean;  v_dist float8;
  v_min interval := make_interval(mins => p_min_minutes);
  -- result rows
  v_sa timestamptz[];  v_sd timestamptz[];  v_slat numeric[];  v_slng numeric[];  v_sn int[];  v_ss bigint[];
  v_sf text[];
  v_rows jsonb;
begin
  if p_vehicle_id is null or p_until is null or p_execute is null then
    raise exception 'fn_build_vehicle_stops: vehicle, until and execute are required' using errcode = '22023';
  end if;
  if p_execute and (p_radius_m <> 100 or p_min_minutes <> 3 or p_dump_radius_m <> 150) then
    raise exception 'thresholds differ from algorithm version %; bump the version', c_version using errcode = '22023';
  end if;

  -- 2. resume point (with a rebuild: supersede from p_rebuild_from, then resume after what remains)
  if p_rebuild_from is not null and p_execute then
    update public.visit_vehicle_stops l set deleted_at = now()
      from public.vehicle_stops s
     where l.vehicle_stop_id = s.id and l.deleted_at is null and s.vehicle_id = p_vehicle_id
       and s.superseded_at is null and s.arrived_at >= p_rebuild_from;
    get diagnostics v_del_links = row_count;
    update public.vehicle_stop_tank_levels l set superseded_at = now()
      from public.vehicle_stops s
     where l.vehicle_stop_id = s.id and l.superseded_at is null and s.vehicle_id = p_vehicle_id
       and s.superseded_at is null and s.arrived_at >= p_rebuild_from;
    get diagnostics v_sup_levels = row_count;
    update public.vehicle_stops set superseded_at = now()
     where vehicle_id = p_vehicle_id and superseded_at is null and arrived_at >= p_rebuild_from;
    get diagnostics v_sup_stops = row_count;
  end if;
  select max(departed_at) into v_r from public.vehicle_stops
   where vehicle_id = p_vehicle_id and superseded_at is null
     and (p_rebuild_from is null or arrived_at < p_rebuild_from);
  v_r := greatest(coalesce(v_r, '-infinity'), coalesce(p_rebuild_from, c_era_start), c_era_start);

  -- 3/4. site events: unpaired entries, open-dwell barrier (an open entry older than 12 h is stale, not a barrier)
  with ev as (
    select e.property_id, e.recorded_at, e.event_kind,
           lead(e.event_kind) over w as next_kind
      from public.vehicle_site_events e
     where e.vehicle_id = p_vehicle_id and e.superseded_at is null
       and e.recorded_at >= v_r - interval '6 hours' and e.recorded_at <= v_end
    window w as (partition by e.property_id order by e.recorded_at, e.event_kind))
  select count(*) filter (where event_kind = 'entry' and next_kind = 'entry'),
         min(recorded_at) filter (where event_kind = 'entry' and next_kind is null and recorded_at > v_end - interval '12 hours'),
         count(*) filter (where event_kind = 'entry' and next_kind is null and recorded_at <= v_end - interval '12 hours')
    into v_unpaired, v_barrier, v_stale_open
    from ev;
  if v_barrier is not null then v_end := least(v_end, v_barrier); end if;

  if v_end > v_r then
    -- closed dwells of 5 minutes or more, merged where they overlap (a dump site wins over the yard)
    with ev as (
      select e.property_id, e.recorded_at, e.event_kind,
             lead(e.event_kind)  over w as next_kind,
             lead(e.recorded_at) over w as next_at
        from public.vehicle_site_events e
       where e.vehicle_id = p_vehicle_id and e.superseded_at is null
         and e.recorded_at >= v_r - interval '6 hours' and e.recorded_at <= v_end
      window w as (partition by e.property_id order by e.recorded_at, e.event_kind)),
    dw as (
      select ev.property_id, ev.recorded_at as a, ev.next_at as b,
             case when exists (select 1 from public.properties p join public.non_customer_clients n on n.client_id = p.client_id
                                where p.id = ev.property_id and n.kind = 'dump_site') then 1
                  when exists (select 1 from ops.v_depot d where d.property_id = ev.property_id) then 2
                  else 3 end as pref
        from ev
       where ev.event_kind = 'entry' and ev.next_kind = 'exit' and ev.next_at <= v_end
         and ev.next_at - ev.recorded_at >= interval '5 minutes'),
    lagged as (
      select dw.*, max(dw.b) over (order by dw.a, dw.b rows between unbounded preceding and 1 preceding) as prev_b from dw),
    isl as (
      select lagged.*, sum(case when lagged.a > lagged.prev_b then 1 else 0 end) over (order by lagged.a, lagged.b) as grp from lagged),
    merged as (
      select min(a) as a, max(b) as b, (array_agg(property_id order by pref, a))[1] as property_id from isl group by grp),
    counted as (
      select m.*, (select count(*) from public.vehicle_telemetry_readings t
                    where t.vehicle_id = p_vehicle_id and t.latitude is not null and t.longitude is not null
                      and t.recorded_at between m.a and m.b) as n_fix
        from merged m)
    select array_agg(a order by a) filter (where a >= v_r and n_fix > 0),
           array_agg(b order by a) filter (where a >= v_r and n_fix > 0),
           array_agg(property_id order by a) filter (where a >= v_r and n_fix > 0),
           count(*) filter (where a < v_r),
           count(*) filter (where a >= v_r and n_fix = 0)
      into v_da, v_db, v_dp, v_before_r, v_no_fix
      from counted;
    v_nd := coalesce(cardinality(v_da), 0);

    -- 5. fixes after the resume point, outside the kept dwells
    select array_agg(t.recorded_at order by t.recorded_at),
           array_agg(t.latitude::float8 order by t.recorded_at),
           array_agg(t.longitude::float8 order by t.recorded_at)
      into v_t, v_lat, v_lng
      from public.vehicle_telemetry_readings t
     where t.vehicle_id = p_vehicle_id and t.latitude is not null and t.longitude is not null
       and t.recorded_at > v_r and t.recorded_at <= v_end
       and not exists (select 1 from unnest(coalesce(v_da, '{}'), coalesce(v_db, '{}')) d(a, b)
                        where t.recorded_at between d.a and d.b);
    v_n := coalesce(cardinality(v_t), 0);

    -- 6. anchor walk; the walk breaks at every kept dwell; the trailing open stop is never emitted
    for i in 1 .. v_n loop
      v_break := false;
      while v_di <= v_nd and v_t[i] > v_da[v_di] loop v_break := true; v_di := v_di + 1; end loop;
      if v_anchor is null then v_anchor := i; v_last := i; continue; end if;
      if not v_break then
        v_dist := 2 * 6371008.8 * asin(sqrt(
                    power(sin(radians(v_lat[i] - v_lat[v_anchor]) / 2), 2)
                  + cos(radians(v_lat[v_anchor])) * cos(radians(v_lat[i]))
                  * power(sin(radians(v_lng[i] - v_lng[v_anchor]) / 2), 2)));
        if v_dist <= p_radius_m then v_last := i; continue; end if;
      end if;
      if v_t[v_last] - v_t[v_anchor] >= v_min then v_ga := v_ga || v_anchor; v_gb := v_gb || v_last; end if;
      v_anchor := i; v_last := i;
    end loop;
    -- a kept dwell after the last fix closes the open stop too (otherwise it would be lost behind the dwell)
    if v_anchor is not null and v_di <= v_nd and v_t[v_last] - v_t[v_anchor] >= v_min then
      v_ga := v_ga || v_anchor; v_gb := v_gb || v_last;
    end if;

    -- 7/8. rows: walk stops (coordinate site detection) and dwell stops
    with g as (
      select v_t[x.a] as arrived_at, v_t[x.b] as departed_at, x.b - x.a + 1 as n,
             (select percentile_cont(0.5) within group (order by y) from unnest(v_lat[x.a:x.b]) y) as lat,
             (select percentile_cont(0.5) within group (order by y) from unnest(v_lng[x.a:x.b]) y) as lng
        from unnest(v_ga, v_gb) x(a, b)),
    gs as (
      select g.*, (select s.property_id from (
                     select vd.property_id, ops.fn_haversine_km(g.lat::numeric, g.lng::numeric, ds.lat::numeric, ds.lng::numeric) as km
                       from public.dump_sites ds join ops.v_dump_sites vd on vd.client_id = ds.client_id
                      where ds.is_active and ds.lat is not null and ds.lng is not null
                     union all
                     select vd.property_id, ops.fn_haversine_km(g.lat::numeric, g.lng::numeric, ds.lat2::numeric, ds.lng2::numeric)
                       from public.dump_sites ds join ops.v_dump_sites vd on vd.client_id = ds.client_id
                      where ds.is_active and ds.lat2 is not null and ds.lng2 is not null
                     union all
                     select d.property_id, ops.fn_haversine_km(g.lat::numeric, g.lng::numeric, d.latitude, d.longitude)
                       from ops.v_depot d) s
                    where s.km * 1000 <= p_dump_radius_m order by s.km limit 1) as site
        from g),
    dws as (
      select d.a as arrived_at, d.b as departed_at, f.n, f.lat, f.lng, d.p as site
        from unnest(coalesce(v_da, '{}'), coalesce(v_db, '{}'), coalesce(v_dp, '{}')) d(a, b, p)
        cross join lateral (
          select count(*)::int as n,
                 percentile_cont(0.5) within group (order by t.latitude::float8)  as lat,
                 percentile_cont(0.5) within group (order by t.longitude::float8) as lng
            from public.vehicle_telemetry_readings t
           where t.vehicle_id = p_vehicle_id and t.latitude is not null and t.longitude is not null
             and t.recorded_at between d.a and d.b) f),
    allr as (
      select arrived_at, departed_at, n, lat, lng, site, 'gps_walk'::text as formation from gs
      union all
      select arrived_at, departed_at, n, lat, lng, site, 'site_dwell' from dws)
    select array_agg(arrived_at order by arrived_at), array_agg(departed_at order by arrived_at),
           array_agg(round(lat::numeric, 6) order by arrived_at), array_agg(round(lng::numeric, 6) order by arrived_at),
           array_agg(n order by arrived_at), array_agg(site order by arrived_at), array_agg(formation order by arrived_at)
      into v_sa, v_sd, v_slat, v_slng, v_sn, v_ss, v_sf
      from allr;

    -- 9. write (ON CONFLICT on the live unique index; an overlap is an exclusion error, never a silent duplicate)
    if p_execute then
      insert into public.vehicle_stops (vehicle_id, arrived_at, departed_at, latitude, longitude, gps_fix_count,
                                        site_property_id, formation, algorithm_version)
      select p_vehicle_id, x.a, x.d, x.lat, x.lng, x.n, x.s, x.f, c_version
        from unnest(coalesce(v_sa, '{}'), coalesce(v_sd, '{}'), coalesce(v_slat, '{}'), coalesce(v_slng, '{}'),
                    coalesce(v_sn, '{}'), coalesce(v_ss, '{}'), coalesce(v_sf, '{}')) x(a, d, lat, lng, n, s, f)
      on conflict (vehicle_id, arrived_at) where superseded_at is null do nothing;
      get diagnostics v_ins = row_count;
    else
      select jsonb_agg(jsonb_build_object('arrived_at', x.a, 'departed_at', x.d, 'latitude', x.lat, 'longitude', x.lng,
                                          'gps_fix_count', x.n, 'site_property_id', x.s, 'formation', x.f) order by x.a)
        into v_rows
        from unnest(coalesce(v_sa, '{}'), coalesce(v_sd, '{}'), coalesce(v_slat, '{}'), coalesce(v_slng, '{}'),
                    coalesce(v_sn, '{}'), coalesce(v_ss, '{}'), coalesce(v_sf, '{}')) x(a, d, lat, lng, n, s, f);
    end if;
  end if;

  return jsonb_build_object(
    'vehicle_id', p_vehicle_id, 'execute', p_execute, 'resume_from', v_r, 'effective_end', v_end,
    'open_dwell_barrier', v_barrier, 'fixes', v_n, 'dwells', v_nd,
    'gps_walk', coalesce((select count(*) from unnest(v_sf) f where f = 'gps_walk'), 0),
    'site_dwell', coalesce((select count(*) from unnest(v_sf) f where f = 'site_dwell'), 0),
    'inserted', v_ins, 'dwell_without_fixes', v_no_fix, 'unpaired_entries', v_unpaired,
    'stale_open_entries', v_stale_open, 'dwells_before_resume', v_before_r,
    'superseded_stops', v_sup_stops, 'superseded_levels', v_sup_levels, 'deleted_links', v_del_links,
    'rows', v_rows);
end $$;

-- ============================================================ 4. MEASUREMENT (plan 5.3)
create function public.fn_measure_vehicle_stop_tank_levels(
  p_from          timestamptz,
  p_execute       boolean,
  p_spike_agree_m numeric  default 0.05,
  p_spike_jump_m  numeric  default 0.15,
  p_hyst_sludge   numeric  default 0.01,
  p_hyst_water    numeric  default 0.05,
  p_period        interval default '10 minutes',
  p_lookahead     interval default '3 hours')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_version constant smallint := 1;
  c_back    constant interval := '3 hours';
  v_edge    interval := p_period + interval '1 minute';          -- 11 minutes with the defaults
  p record;
  v_mt timestamptz[];  v_md float8[];  v_mf float8[];  v_rej int[];  n int;
  k int;  j int;  m int;  v_last float8;  v_rec timestamptz;
  v_dump_a timestamptz[];  v_dump_b timestamptz[];
  v_ai int;  v_di int;  v_dend timestamptz;  v_short boolean;
  v_h float8;  v_pivot float8;  v_ext float8;  v_dir int;  v_risen float8;  v_fallen float8;  v_v float8;
  v_lo timestamptz;  v_hi timestamptz;  v_cnt int;  v_rcnt int;
  d_af numeric;  d_at timestamptz;  d_df numeric;  d_dt timestamptz;  d_ri numeric;  d_fa numeric;
  v_pairs int := 0;  v_not_ready int := 0;  v_same int := 0;  v_ins int := 0;  v_sup int := 0;  v_drop int := 0;
begin
  if p_from is null or p_execute is null then
    raise exception 'fn_measure_vehicle_stop_tank_levels: from and execute are required' using errcode = '22023';
  end if;
  if p_execute and (p_spike_agree_m <> 0.05 or p_spike_jump_m <> 0.15 or p_hyst_sludge <> 0.01 or p_hyst_water <> 0.05
                    or p_period <> interval '10 minutes' or p_lookahead <> interval '3 hours') then
    raise exception 'thresholds differ from algorithm version %; bump the version', c_version using errcode = '22023';
  end if;

  for p in
    with pairs as (
      select s.id as stop_id, s.vehicle_id, s.arrived_at, s.departed_at, t.id as tank_id, t.contents,
             t.deleted_at as tank_deleted_at,
             (select min(s2.arrived_at) from public.vehicle_stops s2
               where s2.vehicle_id = s.vehicle_id and s2.superseded_at is null and s2.arrived_at > s.arrived_at) as next_arrived
        from public.vehicle_stops s
        join public.vehicle_tanks t on t.vehicle_id = s.vehicle_id
       where s.superseded_at is null),
    prov as (
      select pr.*, i.id as inst_id, i.tank_sensor_id, i.installed_at, i.removed_at,
             c.id as cfg_id, c.diameter_meters, c.sensor_offset_meters,
             l.id as live_id, l.tank_sensor_installation_id as l_inst, l.vehicle_tank_configuration_id as l_cfg,
             l.algorithm_version as l_ver, l.arrival_fill_fraction as l_af, l.arrival_measured_at as l_at,
             l.departure_fill_fraction as l_df, l.departure_measured_at as l_dt, l.fill_fraction_risen as l_ri,
             l.fill_fraction_fallen as l_fa, l.measurement_count as l_cnt, l.rejected_measurement_count as l_rcnt
        from pairs pr
        left join lateral (
          select i.* from public.tank_sensor_installations i
           where i.vehicle_tank_id = pr.tank_id and i.superseded_at is null and pr.tank_deleted_at is null
             and i.installed_at <= pr.arrived_at and pr.arrived_at < coalesce(i.removed_at, 'infinity')
           order by i.installed_at desc limit 1) i on true
        left join lateral (
          select c.* from public.vehicle_tank_configurations c
           where c.vehicle_tank_id = pr.tank_id and c.superseded_at is null and c.effective_from <= pr.arrived_at
           order by c.effective_from desc limit 1) c on true
        left join public.vehicle_stop_tank_levels l
          on l.vehicle_stop_id = pr.stop_id and l.vehicle_tank_id = pr.tank_id and l.superseded_at is null)
    select * from prov
     where (arrived_at >= p_from and (live_id is not null or (inst_id is not null and cfg_id is not null)))  -- (a) horizon
        or (live_id is not null and (inst_id is distinct from l_inst or cfg_id is distinct from l_cfg       -- (b) Z3
                                     or l_ver < c_version or tank_deleted_at is not null))
        or (live_id is null and inst_id is not null and cfg_id is not null                                  -- (c) Z2
            and departed_at + interval '4 hours' < now())
     order by vehicle_id, arrived_at, tank_id
  loop
    v_pairs := v_pairs + 1;

    -- no installation or configuration in force: supersede the live row, insert nothing
    if p.inst_id is null or p.cfg_id is null then
      if p.live_id is not null then
        if p_execute then
          update public.vehicle_stop_tank_levels set superseded_at = now() where id = p.live_id;
        end if;
        v_drop := v_drop + 1;
      end if;
      continue;
    end if;
    if now() < p.departed_at + p_lookahead then v_not_ready := v_not_ready + 1; continue; end if;

    -- 1-3. raw series -> measurements (value changes, first-seen time) -> fractions
    select array_agg(x.t order by x.t), array_agg(x.d::float8 order by x.t),
           array_agg(public.fn_tank_fill_fraction(x.d, p.diameter_meters, p.sensor_offset_meters)::float8 order by x.t)
      into v_mt, v_md, v_mf
      from (select r.recorded_at as t, r.distance_meters as d,
                   lag(r.distance_meters) over (order by r.recorded_at) as pd
              from public.tank_sensor_distance_readings r
             where r.tank_sensor_id = p.tank_sensor_id
               and r.recorded_at >= greatest(p.arrived_at - c_back, p.installed_at)
               and r.recorded_at <= p.departed_at + p_lookahead
               and r.recorded_at <  coalesce(p.removed_at, 'infinity')
               and r.distance_meters > 0) x
     where x.pd is distinct from x.d;
    n := coalesce(cardinality(v_mt), 0);
    v_rej := array_fill(0, array[greatest(n, 1)]);

    -- 4. spike: neighbours agree, this one jumps away from both
    for k in 2 .. n - 1 loop
      if abs(v_md[k-1] - v_md[k+1]) <= p_spike_agree_m
         and abs(v_md[k] - v_md[k-1]) > p_spike_jump_m and abs(v_md[k] - v_md[k+1]) > p_spike_jump_m then
        v_rej[k] := 1;
      end if;
    end loop;

    -- 5. false empty with look-ahead (a real post-dump empty survives)
    select coalesce(array_agg(s.arrived_at), '{}'), coalesce(array_agg(s.departed_at), '{}')
      into v_dump_a, v_dump_b
      from public.vehicle_stops s
      join public.properties sp on sp.id = s.site_property_id
      join public.non_customer_clients nc on nc.client_id = sp.client_id and nc.kind = 'dump_site'
     where s.vehicle_id = p.vehicle_id and s.superseded_at is null
       and s.departed_at >= p.arrived_at - c_back and s.arrived_at <= p.departed_at + 2 * p_lookahead;
    v_last := null;  k := 1;
    while k <= n loop
      if v_rej[k] <> 0 then k := k + 1; continue; end if;
      if v_mf[k] is not null and v_mf[k] <= 0.005 then
        j := k;
        m := k + 1;
        while m <= n loop                                      -- extend the run over accepted measurements
          if v_rej[m] <> 0 then m := m + 1; continue; end if;
          exit when v_mf[m] > 0.005;
          j := m;  m := m + 1;
        end loop;
        v_rec := null;
        if v_last is not null and v_last > 0.15 then
          for m in j + 1 .. n loop
            exit when v_mt[m] > v_mt[k] + p_lookahead;
            if v_rej[m] = 0 and v_mf[m] > 0.15 then v_rec := v_mt[m]; exit; end if;
          end loop;
        end if;
        if v_rec is not null and not exists (select 1 from unnest(v_dump_a, v_dump_b) dd(a, b)
                                              where dd.a <= v_rec and dd.b >= v_mt[k]) then
          for m in k .. j loop if v_rej[m] = 0 then v_rej[m] := 2; end if; end loop;
        else
          v_last := v_mf[j];
        end if;
        k := j + 1;
      else
        v_last := v_mf[k];  k := k + 1;
      end if;
    end loop;

    -- 6. arrival edge
    v_ai := null;
    for k in reverse n .. 1 loop
      if v_rej[k] = 0 and v_mt[k] <= p.arrived_at and v_mt[k] >= p.arrived_at - c_back then v_ai := k; exit; end if;
    end loop;
    if v_ai is null then
      for k in 1 .. n loop
        if v_rej[k] = 0 and v_mt[k] > p.arrived_at and v_mt[k] <= p.arrived_at + v_edge then v_ai := k; exit; end if;
      end loop;
    end if;
    -- 7. departure edge
    v_dend := least(p.departed_at + v_edge, coalesce(p.next_arrived, 'infinity'));
    v_di := null;
    for k in 1 .. n loop
      if v_rej[k] = 0 and v_mt[k] > p.departed_at and v_mt[k] <= v_dend then v_di := k; exit; end if;
    end loop;
    if v_di is null then
      for k in reverse n .. 1 loop
        if v_rej[k] = 0 and v_mt[k] <= p.departed_at then v_di := k; exit; end if;
      end loop;
    end if;
    -- 8. too short
    v_short := v_dend - p.arrived_at < p_period;

    -- 9. risen and fallen: zig-zag with end flush over the accepted measurements between the edges
    v_risen := null;  v_fallen := null;
    if v_ai is not null and v_di is not null and not v_short then
      v_h := case when p.contents = 'sludge' then p_hyst_sludge else p_hyst_water end;
      v_pivot := v_mf[least(v_ai, v_di)];  v_ext := v_pivot;  v_dir := 0;  v_risen := 0;  v_fallen := 0;
      for k in least(v_ai, v_di) + 1 .. greatest(v_ai, v_di) loop
        continue when v_rej[k] <> 0;
        v_v := v_mf[k];
        if v_dir = 0 then
          if v_v - v_pivot > v_h then v_dir := 1; v_ext := v_v;
          elsif v_pivot - v_v > v_h then v_dir := -1; v_ext := v_v; end if;
        elsif v_dir = 1 then
          if v_v > v_ext then v_ext := v_v;
          elsif v_ext - v_v > v_h then v_risen := v_risen + (v_ext - v_pivot); v_pivot := v_ext; v_ext := v_v; v_dir := -1; end if;
        else
          if v_v < v_ext then v_ext := v_v;
          elsif v_v - v_ext > v_h then v_fallen := v_fallen + (v_pivot - v_ext); v_pivot := v_ext; v_ext := v_v; v_dir := 1; end if;
        end if;
      end loop;
      if v_dir = 1 then v_risen := v_risen + (v_ext - v_pivot);
      elsif v_dir = -1 then v_fallen := v_fallen + (v_pivot - v_ext); end if;
    end if;

    -- 10. counts between the edges (inclusive), rounding, diff, write
    v_lo := coalesce(v_mt[v_ai], p.arrived_at);  v_hi := coalesce(v_mt[v_di], p.departed_at);
    if v_lo > v_hi then v_lo := v_hi; v_hi := coalesce(v_mt[v_ai], p.arrived_at); end if;
    v_cnt := 0;  v_rcnt := 0;
    for k in 1 .. n loop
      if v_mt[k] between v_lo and v_hi then
        if v_rej[k] = 0 then v_cnt := v_cnt + 1; else v_rcnt := v_rcnt + 1; end if;
      end if;
    end loop;
    d_af := round(v_mf[v_ai]::numeric, 5);  d_at := v_mt[v_ai];
    d_df := round(v_mf[v_di]::numeric, 5);  d_dt := v_mt[v_di];
    d_ri := round(v_risen::numeric, 5);     d_fa := round(v_fallen::numeric, 5);

    if p.live_id is not null
       and p.l_inst = p.inst_id and p.l_cfg = p.cfg_id and p.l_ver = c_version
       and p.l_af is not distinct from d_af and p.l_at is not distinct from d_at
       and p.l_df is not distinct from d_df and p.l_dt is not distinct from d_dt
       and p.l_ri is not distinct from d_ri and p.l_fa is not distinct from d_fa
       and p.l_cnt = v_cnt and p.l_rcnt = v_rcnt then
      v_same := v_same + 1;
      continue;
    end if;
    if p_execute then
      if p.live_id is not null then
        update public.vehicle_stop_tank_levels set superseded_at = now() where id = p.live_id;
      end if;
      insert into public.vehicle_stop_tank_levels
        (vehicle_stop_id, vehicle_id, vehicle_tank_id, tank_sensor_installation_id, vehicle_tank_configuration_id,
         arrival_fill_fraction, arrival_measured_at, departure_fill_fraction, departure_measured_at,
         fill_fraction_risen, fill_fraction_fallen, measurement_count, rejected_measurement_count, algorithm_version)
      values (p.stop_id, p.vehicle_id, p.tank_id, p.inst_id, p.cfg_id, d_af, d_at, d_df, d_dt, d_ri, d_fa,
              v_cnt, v_rcnt, c_version);
    end if;
    if p.live_id is not null then v_sup := v_sup + 1; end if;
    v_ins := v_ins + 1;
  end loop;

  return jsonb_build_object('execute', p_execute, 'from', p_from, 'pairs', v_pairs, 'not_ready', v_not_ready,
                            'unchanged', v_same, 'inserted', v_ins, 'superseded_and_replaced', v_sup,
                            'superseded_no_provenance', v_drop);
end $$;

-- ============================================================ 5. VISIT LINKING (plan 5.4)
create function public.fn_link_visit_vehicle_stops(
  p_execute              boolean,
  p_radius_m             integer default 150,
  p_earlier_hours        integer default 12,
  p_volume_service_types text[]  default '{Pumping}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_dv bigint[];  v_ds bigint[];  v_db text[];
  v_del int := 0;  v_ins int := 0;  v_by_basis jsonb;
begin
  if p_execute is null then raise exception 'fn_link_visit_vehicle_stops: execute is required' using errcode = '22023'; end if;
  if p_execute and (p_radius_m <> 150 or p_earlier_hours <> 12
                    or p_volume_service_types is distinct from '{Pumping}'::text[]) then
    raise exception 'thresholds differ from algorithm version 1; bump the version' using errcode = '22023';
  end if;

  with v as (     -- candidates: the whole sensor era, every run
    select vl.id as visit_id, vl.client_id, vl.vehicle_id, vl.completed_at, vl.service_type,
           public.fn_is_non_customer(vl.client_id, array['dump_site']) as is_dump,
           pp.latitude as plat, pp.longitude as plng,
           (vl.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours' as w0,
           ((vl.visit_date + 1)::timestamp + interval '10 hours') at time zone 'America/New_York' as w1
      from public.v_visits_live vl
      left join public.properties pp on pp.id = vl.property_id
     where vl.visit_status = 'completed' and vl.vehicle_id is not null and vl.visit_date >= date '2026-08-19'),
  vv as (select v.*, (not v.is_dump and v.service_type = any (p_volume_service_types)) as is_volume from v),
  st as (
    select s.id as stop_id, s.vehicle_id, s.arrived_at, s.departed_at, s.latitude, s.longitude, s.site_property_id,
           sp.client_id as site_client_id,
           exists (select 1 from public.non_customer_clients n where n.client_id = sp.client_id and n.kind = 'dump_site') as is_dump_stop
      from public.vehicle_stops s
      left join public.properties sp on sp.id = s.site_property_id
     where s.superseded_at is null),
  l as (          -- L(V): live non-site stops of the visit's truck within p_radius_m of its property
    select vv.visit_id, st.stop_id, st.arrived_at, st.departed_at
      from vv join st on st.vehicle_id = vv.vehicle_id and st.site_property_id is null
     where not vv.is_dump and vv.plat is not null
       and ops.fn_haversine_km(vv.plat, vv.plng, st.latitude, st.longitude) * 1000 <= p_radius_m),
  d as (          -- D(V): live dump stops of the visit's truck at the visit's own dump-site client
    select vv.visit_id, st.stop_id, st.arrived_at, st.departed_at
      from vv join st on st.vehicle_id = vv.vehicle_id and st.is_dump_stop and st.site_client_id = vv.client_id
     where vv.is_dump),
  dc0 as (        -- 1. dump completion anchor: nearest departed_at wins
    select distinct on (vv.visit_id) vv.visit_id, d.stop_id,
           abs(extract(epoch from d.departed_at - vv.completed_at)) as gap
      from vv join d using (visit_id)
     where vv.completed_at between d.arrived_at - interval '5 minutes' and d.departed_at + interval '15 minutes'
     order by vv.visit_id, abs(extract(epoch from d.departed_at - vv.completed_at)), d.stop_id),
  dc as (         -- one dump visit per dump stop (the nearest completion keeps it)
    select visit_id, stop_id from (
      select dc0.*, row_number() over (partition by stop_id order by gap, visit_id) as rn from dc0) x where rn = 1),
  dw0 as (        -- 2. dump elimination inside W(V)
    select vv.visit_id, d.stop_id
      from vv join d using (visit_id)
     where vv.visit_id not in (select visit_id from dc)
       and d.stop_id not in (select stop_id from dc)
       and d.arrived_at >= vv.w0 and d.arrived_at < vv.w1),
  dw as (         -- exactly one candidate, and no other unanchored dump visit wants it (else ambiguous: F1b)
    select x.visit_id, x.stop_id from dw0 x
     where (select count(*) from dw0 y where y.visit_id = x.visit_id) = 1
       and (select count(*) from dw0 y where y.stop_id = x.stop_id) = 1),
  c as (          -- 3. completion anchor (volume and other visits)
    select distinct on (vv.visit_id) vv.visit_id, l.stop_id, l.arrived_at
      from vv join l using (visit_id)
     where vv.completed_at between l.arrived_at - interval '5 minutes' and l.departed_at + interval '15 minutes'
     order by vv.visit_id, abs(extract(epoch from l.departed_at - vv.completed_at)), l.stop_id),
  w as (          -- 4. window fallback: volume visits only, unanchored, never by scheduled start
    select vv.visit_id, l.stop_id
      from vv join l using (visit_id)
     where vv.is_volume and vv.visit_id not in (select visit_id from c)
       and l.arrived_at >= vv.w0 and l.arrived_at < vv.w1
       and not exists (select 1 from c where c.stop_id = l.stop_id and c.visit_id <> vv.visit_id)),
  e0 as (         -- 5. earlier same-site stops: volume visits with a completion anchor
    select vv.visit_id, l.stop_id, c.arrived_at - l.arrived_at as gap
      from vv join c using (visit_id) join l on l.visit_id = vv.visit_id
     where vv.is_volume
       and l.arrived_at >= c.arrived_at - make_interval(hours => p_earlier_hours) and l.arrived_at < c.arrived_at
       and l.stop_id not in (select stop_id from c union select stop_id from w
                             union select stop_id from dc union select stop_id from dw)),
  e as (          -- a stop wanted by several visits goes to the nearest anchor after it (both on a tie)
    select visit_id, stop_id from (select e0.*, rank() over (partition by stop_id order by gap) as rk from e0) x where rk = 1),
  desired as (
    select visit_id, stop_id, 'dump_completion'::text as basis from dc
    union all select visit_id, stop_id, 'dump_window' from dw
    union all select visit_id, stop_id, 'completion' from c
    union all select visit_id, stop_id, 'window' from w
    union all select visit_id, stop_id, 'same_site_earlier' from e)
  select coalesce(array_agg(visit_id), '{}'), coalesce(array_agg(stop_id), '{}'), coalesce(array_agg(basis), '{}')
    into v_dv, v_ds, v_db
    from desired;

  -- 6. reconcile (whole era): soft-delete live links no longer desired, insert desired links not live
  if p_execute then
    update public.visit_vehicle_stops l set deleted_at = now()
     where l.deleted_at is null
       and not exists (select 1 from unnest(v_dv, v_ds, v_db) x(visit_id, stop_id, basis)
                        where x.visit_id = l.visit_id and x.stop_id = l.vehicle_stop_id and x.basis = l.match_basis);
    get diagnostics v_del = row_count;
    insert into public.visit_vehicle_stops (visit_id, vehicle_stop_id, match_basis)
    select x.visit_id, x.stop_id, x.basis from unnest(v_dv, v_ds, v_db) x(visit_id, stop_id, basis)
     where not exists (select 1 from public.visit_vehicle_stops l
                        where l.deleted_at is null and l.visit_id = x.visit_id and l.vehicle_stop_id = x.stop_id);
    get diagnostics v_ins = row_count;
  else
    select count(*) into v_del from public.visit_vehicle_stops l
     where l.deleted_at is null
       and not exists (select 1 from unnest(v_dv, v_ds, v_db) x(visit_id, stop_id, basis)
                        where x.visit_id = l.visit_id and x.stop_id = l.vehicle_stop_id and x.basis = l.match_basis);
    select count(*) into v_ins from unnest(v_dv, v_ds, v_db) x(visit_id, stop_id, basis)
     where not exists (select 1 from public.visit_vehicle_stops l
                        where l.deleted_at is null and l.visit_id = x.visit_id and l.vehicle_stop_id = x.stop_id
                          and l.match_basis = x.basis);
  end if;
  select coalesce(jsonb_object_agg(b, n), '{}') into v_by_basis
    from (select x.b, count(*) as n from unnest(v_db) x(b) group by x.b) y;

  return jsonb_build_object('execute', p_execute, 'desired', cardinality(v_dv), 'by_basis', v_by_basis,
                            (case when p_execute then 'inserted' else 'would_insert' end), v_ins,
                            (case when p_execute then 'deleted' else 'would_delete' end), v_del);
end $$;

-- ============================================================ 6. CHECKS (plan section 8), read-only
create function public.fn_stop_facts_checks()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_yard bigint := (select property_id from ops.v_depot limit 1);
  v_new_names text := 'vehicle_tanks|vehicle_tank_configurations|tank_sensors|tank_sensor_installations|'
                   || 'tank_sensor_distance_readings|tank_sensor_fill_percent_readings|vehicle_engine_rpm_readings|'
                   || 'vehicle_pto_readings|vehicle_site_events|vehicle_stops|vehicle_stop_tank_levels|'
                   || 'visit_vehicle_stops|v_vehicle_site_addresses|v_tank_levels|v_vehicle_stop_facts|'
                   || 'v_vehicle_stop_tank_changes|v_visit_tank_service|v_vehicle_dumps|v_tank_data_quality_issues';
  z jsonb;  t jsonb;  f jsonb;  v_z8_control boolean;  v_z6 jsonb;
begin
  -- Z8 positive control: the body sweep must find a known reference (public.visits in derm.audit_pack)
  select exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'derm' and p.proname = 'audit_pack'
                    and p.prosrc ~ '[[:<:]]visits[[:>:]]')
    into v_z8_control;

  select jsonb_agg(jsonb_build_object('tank_sensor_id', x.tank_sensor_id, 'pairs', x.n, 'median_pp', round(x.med::numeric, 4)))
    into v_z6
    from (select pr.tank_sensor_id, count(*) as n, percentile_cont(0.5) within group (order by pr.diff) as med
            from (select d.tank_sensor_id,
                         abs(fp.fill_percent - 100 * public.fn_tank_fill_fraction(d.distance_meters, c.diameter_meters, c.sensor_offset_meters))::float8 as diff
                    from public.tank_sensor_distance_readings d
                    join public.tank_sensor_fill_percent_readings fp
                      on fp.tank_sensor_id = d.tank_sensor_id and fp.recorded_at = d.recorded_at
                    join lateral (select i.vehicle_tank_id from public.tank_sensor_installations i
                                   where i.tank_sensor_id = d.tank_sensor_id and i.superseded_at is null
                                     and i.installed_at <= d.recorded_at and d.recorded_at < coalesce(i.removed_at, 'infinity')
                                   limit 1) i on true
                    join lateral (select c.* from public.vehicle_tank_configurations c
                                   where c.vehicle_tank_id = i.vehicle_tank_id and c.superseded_at is null
                                     and c.effective_from <= d.recorded_at
                                   order by c.effective_from desc limit 1) c on true
                   where d.recorded_at > now() - interval '24 hours' and d.distance_meters > 0) pr
           group by pr.tank_sensor_id) x;

  z := jsonb_build_object(
    'Z1', (select count(*) from (
             select s.id from public.tank_sensors s
              where exists (select 1 from public.tank_sensor_installations i join public.vehicle_tanks vt on vt.id = i.vehicle_tank_id
                             where i.tank_sensor_id = s.id and i.superseded_at is null and vt.deleted_at is null
                               and i.installed_at <= now() and now() < coalesce(i.removed_at, 'infinity'))
                and ((select count(*) from public.entity_source_links e where e.entity_type = 'tank_sensor'
                        and e.entity_id = s.id and e.source_system = 'samsara') <> 1
                  or (select count(*) from public.entity_source_links e where e.entity_type = 'tank_sensor'
                        and e.entity_id = s.id and e.source_system = 'samsara_gateway') <> 1)
             union all
             select e.id from public.entity_source_links e
              where e.entity_type = 'tank_sensor' and not exists (select 1 from public.tank_sensors s where s.id = e.entity_id)) x),
    'Z2', (select count(*) from public.vehicle_stops s
             join public.vehicle_tanks vt on vt.vehicle_id = s.vehicle_id and vt.deleted_at is null
            where s.superseded_at is null and s.departed_at + interval '4 hours' < now()
              and exists (select 1 from public.tank_sensor_installations i where i.vehicle_tank_id = vt.id and i.superseded_at is null
                            and i.installed_at <= s.arrived_at and s.arrived_at < coalesce(i.removed_at, 'infinity'))
              and exists (select 1 from public.vehicle_tank_configurations c where c.vehicle_tank_id = vt.id
                            and c.superseded_at is null and c.effective_from <= s.arrived_at)
              and not exists (select 1 from public.vehicle_stop_tank_levels l where l.vehicle_stop_id = s.id
                                and l.vehicle_tank_id = vt.id and l.superseded_at is null)),
    'Z3', (select count(*) from public.vehicle_stop_tank_levels l
             join public.vehicle_stops s on s.id = l.vehicle_stop_id
             join public.vehicle_tanks vt on vt.id = l.vehicle_tank_id
            where l.superseded_at is null
              and (s.superseded_at is not null or vt.deleted_at is not null or l.algorithm_version < 1
                   or l.tank_sensor_installation_id is distinct from (
                        select i.id from public.tank_sensor_installations i where i.vehicle_tank_id = vt.id and i.superseded_at is null
                           and i.installed_at <= s.arrived_at and s.arrived_at < coalesce(i.removed_at, 'infinity')
                         order by i.installed_at desc limit 1)
                   or l.vehicle_tank_configuration_id is distinct from (
                        select c.id from public.vehicle_tank_configurations c where c.vehicle_tank_id = vt.id
                           and c.superseded_at is null and c.effective_from <= s.arrived_at
                         order by c.effective_from desc limit 1))),
    'Z4', (select count(*) from public.visit_vehicle_stops l
             join public.vehicle_stops s on s.id = l.vehicle_stop_id
             left join public.v_visits_live vl on vl.id = l.visit_id
             left join public.properties vp on vp.id = vl.property_id
             left join public.properties sp on sp.id = s.site_property_id
            where l.deleted_at is null
              and (s.superseded_at is not null or vl.id is null or vl.visit_status <> 'completed'
                   or vl.vehicle_id is distinct from s.vehicle_id
                   or (l.match_basis not in ('dump_completion','dump_window')
                       and (s.site_property_id is not null or vp.latitude is null
                            or ops.fn_haversine_km(vp.latitude, vp.longitude, s.latitude, s.longitude) * 1000 > 150))
                   or (l.match_basis in ('dump_completion','dump_window')
                       and (not public.fn_is_non_customer(vl.client_id, array['dump_site'])
                            or sp.client_id is distinct from vl.client_id
                            or not exists (select 1 from public.non_customer_clients n
                                            where n.client_id = sp.client_id and n.kind = 'dump_site')))))
        + (select count(*) from public.vehicle_stops s
             join public.properties sp on sp.id = s.site_property_id
            where s.superseded_at is null
              and s.site_property_id is distinct from v_yard
              and not exists (select 1 from public.non_customer_clients n where n.client_id = sp.client_id and n.kind = 'dump_site')),
    'Z6', (select count(*) from jsonb_array_elements(coalesce(v_z6, '[]')) x
            where (x->>'pairs')::int >= 20 and (x->>'median_pp')::numeric > 0.5),
    'Z7', (select count(*) from public.tank_sensor_installations i join public.vehicle_tanks vt on vt.id = i.vehicle_tank_id
            where i.superseded_at is null and i.removed_at is null and vt.deleted_at is not null),
    'Z8', (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname in ('derm','customer','client') and p.prosrc ~ ('[[:<:]](' || v_new_names || ')[[:>:]]'))
        + (select count(distinct v.oid) from pg_class v join pg_namespace n on n.oid = v.relnamespace
             join pg_rewrite rw on rw.ev_class = v.oid
             join pg_depend dp on dp.objid = rw.oid and dp.classid = 'pg_rewrite'::regclass
             join pg_class t on t.oid = dp.refobjid
             join pg_namespace tn on tn.oid = t.relnamespace
            where n.nspname in ('derm','customer','client') and v.relkind in ('v','m')
              and tn.nspname = 'public' and t.relname ~ ('^(' || v_new_names || ')$')),
    'Z8_control_found', v_z8_control,
    'Z9', (select count(distinct l.visit_id) from public.visit_vehicle_stops l
             join public.vehicle_stops s on s.id = l.vehicle_stop_id and s.superseded_at is not null
             join public.v_visits_live vl on vl.id = l.visit_id and vl.visit_status = 'completed' and vl.vehicle_id = s.vehicle_id
            where l.deleted_at is not null
              and not exists (select 1 from public.visit_vehicle_stops l2 where l2.visit_id = l.visit_id and l2.deleted_at is null)
              and exists (select 1 from public.vehicle_stops s2
                           where s2.superseded_at is null and s2.vehicle_id = s.vehicle_id
                             and ops.fn_haversine_km(s2.latitude, s2.longitude, s.latitude, s.longitude) * 1000 <= 150
                             and s2.arrived_at >= (vl.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
                             and s2.arrived_at < ((vl.visit_date + 1)::timestamp + interval '10 hours') at time zone 'America/New_York')),
    'Z6_detail', coalesce(v_z6, '[]'));

  t := jsonb_build_object(
    'T1', (select count(*) from public.tank_sensors s
            where exists (select 1 from public.tank_sensor_installations i join public.vehicle_tanks vt on vt.id = i.vehicle_tank_id
                           where i.tank_sensor_id = s.id and i.superseded_at is null and vt.deleted_at is null
                             and i.installed_at <= now() and now() < coalesce(i.removed_at, 'infinity'))
              and coalesce((select max(r.recorded_at) from public.tank_sensor_distance_readings r where r.tank_sensor_id = s.id),
                           '-infinity') < now() - interval '2 hours'),
    'T2', (select count(*) from (
             select r.vehicle_id, date_trunc('hour', r.recorded_at) as h
               from public.vehicle_engine_rpm_readings r
              where r.recorded_at > now() - interval '48 hours' and r.engine_rpm > 0
              group by 1, 2 having count(*) >= 5) x
            where x.h + interval '1 hour' <= (select max(g.recorded_at) from public.vehicle_telemetry_readings g
                                                where g.vehicle_id = x.vehicle_id and g.latitude is not null)
              and not exists (select 1 from public.vehicle_telemetry_readings g
                               where g.vehicle_id = x.vehicle_id and g.latitude is not null
                                 and g.recorded_at >= x.h and g.recorded_at < x.h + interval '1 hour')),
    'T3', (select count(*) from (
             select sl.details->'summary'->'unlinked_level_assets' as a from public.sync_log sl
              where sl.sync_source = 'railway_samsara_readings' and sl.status = 'success'
                and sl.details->'summary'->>'deep_pass' = 'true'
              order by sl.started_at desc limit 1) r
             cross join lateral jsonb_array_elements(case when jsonb_typeof(r.a) = 'array' then r.a else '[]' end) el
            where not exists (select 1 from public.entity_source_links e where e.entity_type = 'tank_sensor'
                                and e.source_id = coalesce(el->>'id', el #>> '{}'))),
    'T4', (select count(*) from public.sync_log sl
            where sl.sync_source = 'railway_samsara_readings' and sl.started_at > now() - interval '2 hours'
              and jsonb_typeof(sl.details->'summary'->'skipped_streams') = 'array'
              and jsonb_array_length(sl.details->'summary'->'skipped_streams') > 0),
    'T5', (select case when count(distinct (sl.started_at at time zone 'America/New_York')::date) >= 2 then 1 else 0 end
             from public.sync_log sl
            where sl.sync_source = 'railway_samsara_readings' and sl.status = 'success'
              and sl.started_at > now() - interval '14 days'
              and coalesce((sl.details->'summary'->>'deep_pass_recovered')::numeric, 0) > 0));

  f := jsonb_build_object(
    'F1', (select count(*) from public.v_visits_live vl
            where vl.visit_status = 'completed' and vl.visit_date >= date '2026-08-20' and vl.service_type = 'Pumping'
              and not public.fn_is_non_customer(vl.client_id, array['dump_site'])
              and exists (select 1 from public.entity_source_links e where e.entity_type = 'vehicle'
                            and e.source_system = 'samsara' and e.entity_id = vl.vehicle_id)
              and not exists (select 1 from public.visit_vehicle_stops l where l.visit_id = vl.id and l.deleted_at is null)),
    'F1b', (select count(*) from public.v_visits_live vl
             where vl.visit_status = 'completed' and vl.visit_date >= date '2026-08-20' and vl.vehicle_id is not null
               and public.fn_is_non_customer(vl.client_id, array['dump_site'])
               and not exists (select 1 from public.visit_vehicle_stops l where l.visit_id = vl.id and l.deleted_at is null
                                 and l.match_basis in ('dump_completion','dump_window'))),
    'F3', (select count(*) from public.vehicle_stops s
             join public.properties sp on sp.id = s.site_property_id
             join public.non_customer_clients n on n.client_id = sp.client_id and n.kind = 'dump_site'
            where s.superseded_at is null
              and not exists (select 1 from public.visit_vehicle_stops l where l.vehicle_stop_id = s.id and l.deleted_at is null
                                and l.match_basis in ('dump_completion','dump_window'))),
    'F5', (select count(*) from public.vehicle_stop_tank_levels l
             join public.vehicle_stops s on s.id = l.vehicle_stop_id
             join public.vehicle_tanks vt on vt.id = l.vehicle_tank_id and vt.contents = 'sludge'
             join public.vehicle_tank_configurations c on c.id = l.vehicle_tank_configuration_id
             left join public.properties sp on sp.id = s.site_property_id
            where l.superseded_at is null and s.superseded_at is null and c.capacity_gallons is not null
              and (l.arrival_fill_fraction - l.departure_fill_fraction) * c.capacity_gallons >= 300
              and not exists (select 1 from public.non_customer_clients n where n.client_id = sp.client_id and n.kind = 'dump_site')),
    'F7', (select count(*) from (
             select vl.id, vl.duration_minutes,
                    sum(extract(epoch from s.departed_at - s.arrived_at) / 60) as stop_minutes
               from public.v_visits_live vl
               join public.visit_vehicle_stops l on l.visit_id = vl.id and l.deleted_at is null
               join public.vehicle_stops s on s.id = l.vehicle_stop_id and s.superseded_at is null
              group by vl.id, vl.duration_minutes) x
            where x.duration_minutes is not null and abs(x.stop_minutes - x.duration_minutes) > 15),
    'F8', (select count(*) from public.vehicles ve
             join public.vehicle_tanks vt on vt.vehicle_id = ve.id and vt.contents = 'sludge' and vt.deleted_at is null
             join lateral (select c.capacity_gallons from public.vehicle_tank_configurations c
                            where c.vehicle_tank_id = vt.id and c.superseded_at is null and c.effective_from <= now()
                            order by c.effective_from desc limit 1) c on true
            where ve.grease_tank_capacity_gallons is distinct from c.capacity_gallons),
    'F2_F4_F6', 'counted by v_tank_data_quality_issues (M6)');

  return jsonb_build_object('integrity', z, 'feed', t, 'flags', f, 'checked_at', now());
end $$;

-- ============================================================ 7. REFRESH (plan 5.5)
create function public.fn_refresh_stop_facts(p_rebuild_vehicle_id bigint default null, p_rebuild_from timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_started timestamptz := clock_timestamp();
  v_wm      timestamptz;
  v_until   timestamptz;
  v_vehicle bigint;
  v_build   jsonb := '[]';  v_measure jsonb;  v_link jsonb;  v_checks jsonb;
  v_errors  jsonb := '[]';  v_state text;  v_msg text;
  v_ins     int := 0;  v_int_n int;  v_feed_n int;  v_z6 int;
begin
  if (p_rebuild_vehicle_id is null) <> (p_rebuild_from is null) then
    raise exception 'fn_refresh_stop_facts: give both rebuild arguments or neither' using errcode = '22023';
  end if;
  perform pg_advisory_xact_lock(hashtext('public.fn_refresh_stop_facts'));
  perform set_config('request.headers', '{"x-app-source":"stop-facts"}', true);

  -- watermark: never build past the readings feed (site events), nor closer than 30 minutes to now
  select max(sl.started_at) into v_wm from public.sync_log sl
   where sl.sync_source = 'railway_samsara_readings' and sl.status = 'success';
  v_until := least(now() - interval '30 minutes', v_wm - interval '15 minutes');   -- NULL when the feed never ran

  -- 1. build
  begin
    if v_until is null then
      v_errors := v_errors || jsonb_build_object('step', 'build', 'sqlstate', 'P0002', 'message', 'no successful readings run: build skipped');
    else
      for v_vehicle in
        select distinct e.entity_id from public.entity_source_links e join public.vehicles ve on ve.id = e.entity_id
         where e.entity_type = 'vehicle' and e.source_system = 'samsara' order by 1
      loop
        v_build := v_build || public.fn_build_vehicle_stops(v_vehicle, v_until, true,
                                case when v_vehicle = p_rebuild_vehicle_id then p_rebuild_from end);
      end loop;
    end if;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v_errors := v_errors || jsonb_build_object('step', 'build', 'sqlstate', v_state, 'message', left(v_msg, 300));
  end;

  -- 2. measure (35-day horizon, plus every Z2/Z3 pair whatever its age)
  begin
    v_measure := public.fn_measure_vehicle_stop_tank_levels(
                   least(now() - interval '35 days', coalesce(p_rebuild_from, 'infinity')), true);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v_errors := v_errors || jsonb_build_object('step', 'measure', 'sqlstate', v_state, 'message', left(v_msg, 300));
  end;

  -- 3. link (whole era)
  begin
    v_link := public.fn_link_visit_vehicle_stops(true);
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v_errors := v_errors || jsonb_build_object('step', 'link', 'sqlstate', v_state, 'message', left(v_msg, 300));
  end;

  -- 4. checks -> four sync_log sources (separate sources, so a long-open data finding cannot hide a process failure)
  begin
    v_checks := public.fn_stop_facts_checks();
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    v_errors := v_errors || jsonb_build_object('step', 'checks', 'sqlstate', v_state, 'message', left(v_msg, 300));
  end;

  v_ins := coalesce((select sum((b->>'inserted')::int) from jsonb_array_elements(v_build) b), 0)
         + coalesce((v_measure->>'inserted')::int, 0) + coalesce((v_link->>'inserted')::int, 0);

  insert into public.sync_log (sync_source, started_at, finished_at, rows_inserted, status, error_details, details, duration_seconds)
  values ('stop_facts_refresh', v_started, clock_timestamp(), v_ins,
          case when jsonb_array_length(v_errors) = 0 then 'success' else 'error' end,
          case when jsonb_array_length(v_errors) = 0 then null else v_errors end,
          jsonb_build_object('until', v_until, 'watermark', v_wm, 'rebuild_vehicle_id', p_rebuild_vehicle_id,
                             'rebuild_from', p_rebuild_from, 'build', v_build, 'measure', v_measure, 'link', v_link,
                             'flags', v_checks->'flags'),
          extract(epoch from clock_timestamp() - v_started));

  if v_checks is not null then
    select count(*) into v_feed_n from jsonb_each(v_checks->'feed') x where (x.value)::text::int > 0;
    select count(*) into v_int_n from jsonb_each(v_checks->'integrity') x
     where x.key in ('Z1','Z2','Z3','Z4','Z7','Z8','Z9') and (x.value)::text::int > 0;
    if (v_checks->'integrity'->>'Z8_control_found')::boolean is not true then v_int_n := v_int_n + 1; end if;
    v_z6 := (v_checks->'integrity'->>'Z6')::int;
    insert into public.sync_log (sync_source, started_at, finished_at, status, details, duration_seconds)
    values ('tank_feed_freshness', v_started, clock_timestamp(), case when v_feed_n = 0 then 'success' else 'error' end,
            v_checks->'feed', extract(epoch from clock_timestamp() - v_started)),
           ('stop_facts_integrity', v_started, clock_timestamp(), case when v_int_n = 0 then 'success' else 'error' end,
            (v_checks->'integrity') - 'Z6' - 'Z6_detail', extract(epoch from clock_timestamp() - v_started)),
           ('tank_geometry_drift', v_started, clock_timestamp(), case when v_z6 = 0 then 'success' else 'error' end,
            jsonb_build_object('Z6', v_z6, 'per_sensor', v_checks->'integrity'->'Z6_detail'),
            extract(epoch from clock_timestamp() - v_started));
  end if;

  return jsonb_build_object('until', v_until, 'build', v_build, 'measure', v_measure, 'link', v_link,
                            'checks', v_checks, 'errors', v_errors);
end $$;

-- ---------------------------------------------------------------- function privileges + comments
revoke all on function public.fn_build_vehicle_stops(bigint, timestamptz, boolean, timestamptz, integer, integer, integer)
  from public, anon, authenticated, service_role;
revoke all on function public.fn_measure_vehicle_stop_tank_levels(timestamptz, boolean, numeric, numeric, numeric, numeric, interval, interval)
  from public, anon, authenticated, service_role;
revoke all on function public.fn_link_visit_vehicle_stops(boolean, integer, integer, text[])
  from public, anon, authenticated, service_role;
revoke all on function public.fn_stop_facts_checks() from public, anon, authenticated, service_role;
revoke all on function public.fn_refresh_stop_facts(bigint, timestamptz) from public, anon, authenticated, service_role;

comment on function public.fn_build_vehicle_stops(bigint, timestamptz, boolean, timestamptz, integer, integer, integer) is
  'Tank sensors plan 5.2: builds one truck''s stops from its resume point (latest live departed_at, or 2026-08-20 ET) '
  'to p_until: site dwells from live address events (closed, 5 min or more, merged, dump site over yard; an open entry '
  'is a barrier for 12 h), then a GPS anchor walk (p_radius_m) that breaks at every dwell; a walk stop near a dump '
  'tip point or the yard (ops.v_depot) gets that site property. p_rebuild_from supersedes from that instant. '
  'Non-default thresholds with p_execute raise 22023. Called by fn_refresh_stop_facts.';
comment on function public.fn_measure_vehicle_stop_tank_levels(timestamptz, boolean, numeric, numeric, numeric, numeric, interval, interval) is
  'Tank sensors plan 5.3: recompute-and-diff of (live stop, tank) level rows for stops arrived since p_from plus every '
  'Z2 (missing) and Z3 (provenance changed) pair. Measurements are value changes; spike and look-ahead false-empty '
  'filters; arrival/departure edges; zig-zag risen/fallen with end flush. Identical results write nothing.';
comment on function public.fn_link_visit_vehicle_stops(boolean, integer, integer, text[]) is
  'Tank sensors plan 5.4: reconciles visit_vehicle_stops over every completed live visit since 2026-08-19: dump '
  'completion anchor, dump elimination, completion anchor, window fallback (volume visits), earlier same-site stops; '
  'soft-deletes links that no longer hold.';
comment on function public.fn_stop_facts_checks() is
  'Tank sensors plan section 8: integrity checks Z1-Z4, Z6-Z9 (Z8 carries its positive control), feed checks T1-T5, '
  'business flag counts F1, F1b, F3, F5, F7, F8 (F2, F4, F6 need the M6 views). Read-only.';
comment on function public.fn_refresh_stop_facts(bigint, timestamptz) is
  'Tank sensors plan 5.5: the one entry point. Build every Samsara-linked truck up to least(now - 30 min, readings '
  'watermark - 15 min), measure (35 days plus Z2/Z3), link (whole era), checks; writes sync_log sources '
  'stop_facts_refresh, tank_feed_freshness, stop_facts_integrity, tank_geometry_drift. Each step in its own '
  'exception block. Writes labelled x-app-source stop-facts. Rebuild: fn_refresh_stop_facts(vehicle, from).';

-- ============================================================ 8. VERIFY
do $v$
declare
  t text; s text; p text; n int; v_diff int; v_miss numeric; f text;
  v_tables text[] := array['vehicle_stops','vehicle_stop_tank_levels','visit_vehicle_stops'];
  v_expected aclitem[] := '{postgres=arwdDxtm/postgres,service_role=r/postgres,db_backup_reader=r/postgres}';
  v_writers text[] := array[
    'public.fn_build_vehicle_stops(bigint,timestamptz,boolean,timestamptz,integer,integer,integer)',
    'public.fn_measure_vehicle_stop_tank_levels(timestamptz,boolean,numeric,numeric,numeric,numeric,interval,interval)',
    'public.fn_link_visit_vehicle_stops(boolean,integer,integer,text[])',
    'public.fn_stop_facts_checks()',
    'public.fn_refresh_stop_facts(bigint,timestamptz)'];
begin
  foreach t in array v_tables loop
    select count(*) into v_diff from (
      (select grantor, grantee, privilege_type, is_grantable from pg_class c, aclexplode(c.relacl)
        where c.oid = ('public.' || t)::regclass
       except select grantor, grantee, privilege_type, is_grantable from aclexplode(v_expected))
      union all
      (select grantor, grantee, privilege_type, is_grantable from aclexplode(v_expected)
       except select grantor, grantee, privilege_type, is_grantable from pg_class c, aclexplode(c.relacl)
        where c.oid = ('public.' || t)::regclass)) d;
    if v_diff <> 0 then
      raise exception 'VERIFY M4-1: public.% relacl is %', t, (select relacl::text from pg_class where oid = ('public.' || t)::regclass);
    end if;
    foreach p in array array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER'] loop
      if has_table_privilege('anon', 'public.' || t, p) or has_table_privilege('authenticated', 'public.' || t, p) then
        raise exception 'VERIFY M4-2: anon or authenticated holds % on public.%', p, t;
      end if;
    end loop;
    if not has_table_privilege('service_role', 'public.' || t, 'SELECT') then raise exception 'VERIFY M4-2: service_role cannot read %', t; end if;
    foreach p in array array['INSERT','UPDATE','DELETE','TRUNCATE'] loop
      if has_table_privilege('service_role', 'public.' || t, p) then raise exception 'VERIFY M4-2: service_role holds % on %', p, t; end if;
    end loop;
    s := pg_get_serial_sequence('public.' || t, 'id');
    if has_sequence_privilege('authenticated', s, 'USAGE') or has_sequence_privilege('anon', s, 'SELECT')
       or has_sequence_privilege('service_role', s, 'USAGE') then
      raise exception 'VERIFY M4-3: sequence % is open', s;
    end if;
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then raise exception 'VERIFY M4-4: RLS off on %', t; end if;
    select count(*) into n from pg_trigger where tgrelid = ('public.' || t)::regclass and not tgisinternal
       and tgfoid = 'public.fn_append_only_guard()'::regprocedure;
    if n <> 2 then raise exception 'VERIFY M4-5: public.% has % guard triggers, expected 2', t, n; end if;
  end loop;

  -- audit: exactly visit_vehicle_stops among the three
  select count(*) into n from pg_trigger tg join pg_proc pr on pr.oid = tg.tgfoid join pg_namespace pn on pn.oid = pr.pronamespace
   where pn.nspname = 'audit' and pr.proname = 'log_change' and not tg.tgisinternal
     and tg.tgrelid = any (array['public.vehicle_stops','public.vehicle_stop_tank_levels','public.visit_vehicle_stops']::regclass[]);
  if n <> 1 or not exists (select 1 from pg_trigger where tgrelid = 'public.visit_vehicle_stops'::regclass
                                                        and tgname = 'audit_visit_vehicle_stops') then
    raise exception 'VERIFY M4-6: expected exactly visit_vehicle_stops audited, found %', n;
  end if;

  -- FKs: 8, all RESTRICT, each served by a non-partial index leading with its columns
  select count(*) into n from pg_constraint where contype = 'f' and conrelid = any (array[
    'public.vehicle_stops','public.vehicle_stop_tank_levels','public.visit_vehicle_stops']::regclass[]);
  if n <> 8 then raise exception 'VERIFY M4-7: expected 8 FKs, found %', n; end if;
  if exists (select 1 from pg_constraint where contype = 'f' and confdeltype <> 'r' and conrelid = any (array[
    'public.vehicle_stops','public.vehicle_stop_tank_levels','public.visit_vehicle_stops']::regclass[])) then
    raise exception 'VERIFY M4-7: an FK is not ON DELETE RESTRICT';
  end if;
  select string_agg(format('%s(%s)', c.conrelid::regclass, c.conkey::text), ', ') into p
    from pg_constraint c
   where c.contype = 'f' and c.conrelid = any (array['public.vehicle_stops','public.vehicle_stop_tank_levels',
                                                      'public.visit_vehicle_stops']::regclass[])
     and not exists (select 1 from pg_index i where i.indrelid = c.conrelid and i.indpred is null
                       and (i.indkey::int2[])[0:cardinality(c.conkey) - 1] = c.conkey);
  if p is not null then raise exception 'VERIFY M4-7b: FK without a non-partial leading index: %', p; end if;

  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = any (v_tables)
              and column_name ~ '^(samsara|jobber|airtable|fillout|odoo)_') then
    raise exception 'VERIFY M4-8: vendor-prefixed column';
  end if;

  -- writers: SECURITY DEFINER, search_path pinned to '', no EXECUTE for API roles or PUBLIC
  foreach f in array v_writers loop
    if not (select prosecdef and proconfig = array['search_path=""'] from pg_proc where oid = f::regprocedure) then
      raise exception 'VERIFY M4-9: % is not SECURITY DEFINER with search_path ''''', f;
    end if;
    if has_function_privilege('anon', f, 'EXECUTE') or has_function_privilege('authenticated', f, 'EXECUTE')
       or has_function_privilege('service_role', f, 'EXECUTE')
       or exists (select 1 from pg_proc pr, aclexplode(pr.proacl) a where pr.oid = f::regprocedure and a.grantee = 0) then
      raise exception 'VERIFY M4-9: % is executable by an API role or PUBLIC', f;
    end if;
  end loop;
  f := 'public.fn_tank_fill_fraction(numeric,numeric,numeric)';
  if (select prosecdef or provolatile <> 'i' from pg_proc where oid = f::regprocedure) then
    raise exception 'VERIFY M4-10: fn_tank_fill_fraction must be SECURITY INVOKER and IMMUTABLE';
  end if;
  if not has_function_privilege('service_role', f, 'EXECUTE') or has_function_privilege('anon', f, 'EXECUTE')
     or has_function_privilege('authenticated', f, 'EXECUTE') then
    raise exception 'VERIFY M4-10: fn_tank_fill_fraction EXECUTE is not service_role only';
  end if;

  -- fill-fraction controls (plan 5.1) and the negative control
  select count(*) into n from (values
      (1.34::numeric, 0.3048::numeric, 51.885::numeric), (0.75, 0.3048, 84.873), (1.83, 0.3048, 23.512),
      (1.14, 0.0000, 45.635), (0.50, 0.0000, 82.157)) x(d, o, pct)
   where abs(100 * public.fn_tank_fill_fraction(x.d, 2.1336, x.o) - x.pct) < 0.001;
  if n <> 5 then raise exception 'VERIFY M4-11: % of 5 fill-fraction controls passed', n; end if;
  v_miss := abs(100 * public.fn_tank_fill_fraction(1.34, 2.1336, 0) - 51.885);
  if v_miss <= 1 then raise exception 'VERIFY M4-11: zero-offset control missed by only % pp', v_miss; end if;
  if public.fn_tank_fill_fraction(0, 2.1336, 0) is not null then raise exception 'VERIFY M4-11: 0 m must be NULL (no echo)'; end if;
end $v$;

commit;
