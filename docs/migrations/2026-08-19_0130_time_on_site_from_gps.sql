-- ============================================================================
-- 2026-08-19_0130 - Time on site, measured from the truck's own GPS
-- ============================================================================
-- Fred, 2026-08-18: "I don't see `Time on site` showing anything ... is that even
-- be able to calculated? or should be save it in our db?" Answer: calculated, from
-- telemetry we already collect. Purpose agreed with him first: **internal ops insight
-- only** - nobody is paid or billed on this number, and a blank is acceptable.
--
-- WHY NOTHING SHOWED. The app is not at fault and needs NO change. It already reads
-- visits.duration_minutes and falls back to actual_departure_at - actual_arrival_at.
-- All three columns were 0% populated: 0 of 524 completed visits in the last 90 days.
-- Nothing has ever written them. Fill them and the dash becomes a number.
--
-- THE SOURCE. public.vehicle_telemetry_readings: 1.31M rows since 2026-01-01 carrying
-- latitude/longitude per vehicle, sampled roughly once a minute, indexed on
-- (vehicle_id, recorded_at). 897 of 899 properties are geocoded and 114 of 118 August
-- completed visits carry a vehicle, so the inputs exist.
--
-- THE RULE. For a completed visit with a vehicle and a geocoded property: take that
-- vehicle's pings across the visit's ET operating day, keep those within p_radius_m of
-- the property, split into clusters wherever there is a gap over p_gap_minutes, take
-- the LONGEST cluster, and require at least p_min_minutes. Arrival is its first ping,
-- departure its last.
--
-- 🛑 IT FAILS CLOSED, AND THAT IS THE POINT. No qualifying cluster leaves all three
-- columns NULL and the UI keeps showing "-". It must NEVER fall back to start_at/end_at:
-- those are 100% populated because they are the SCHEDULED window, and presenting a
-- schedule as a measurement is exactly the kind of plausible-but-wrong number that gets
-- believed. An honest blank beats a confident guess.
--
-- ⚠ THE WINDOW IS THE OPERATING DAY, NOT A WINDOW AROUND start_at. Measured while
-- designing this: a naive +/-6h around the scheduled start produced NO pings for 5 of 12
-- sample visits, and 3 of those 5 turned out to have the truck 36m, 5m and 16m away -
-- the visit simply ran outside the scheduled window. The narrow window was the defect,
-- not the data. -4h/+28h also covers the overnight routes (CLAUDE.md operating-date rule).
--
-- 🛑 SUPERSEDED THE SAME DAY: THE RADIUS IS NOW 150m. Fred, 2026-08-19: "go with 150m
-- instead". See 2026-08-19_0410_time_on_site_radius_150.sql. The paragraph below is kept
-- because it records the measurement that informed both choices, but the DEFAULT IN THIS
-- FILE (75) IS NO LONGER WHAT RUNS. Read the live signature, not this text.
--
-- ⚠ RADIUS: 75m, FRED'S EXPLICIT CHOICE AT THE TIME, and the trade-off was measured BEFORE he chose
-- and reported after. Over one week (58 visits): 150m resolves 51 (88%), 100m resolves 47
-- (81%), 75m resolves 46 (79%). Tightening does NOT reduce the long readings it was meant
-- to curb - average stays 54 min and the maximum stays ~177 min at every radius - it only
-- produces more blanks. It is a parameter with a default precisely so changing it back is
-- one word, not a body rewrite.
--
-- ⚠ WHAT THIS NUMBER IS NOT. It measures the TRUCK, not the crew. A visit whose
-- vehicle_id is wrong reads blank (2 of 12 samples were assigned a truck 6.7km and 51km
-- away). Two clients inside the same plaza can share one dwell. A truck parked over the
-- radius away reads as absent. All acceptable for ops insight; none acceptable if this
-- number ever starts driving pay or billing, which would need a different source.
--
-- AUDIT (rule 8): public.visits carries audit triggers, so every write here is captured
-- with old_row/new_row. The run labels itself via app_source so these are distinguishable
-- from human edits. No table or trigger is created or altered.
-- ============================================================================

create or replace function public.fn_compute_time_on_site(
  p_from        date,
  p_to          date,
  p_execute     boolean default false,
  p_radius_m    integer default 75,     -- Fred's choice; 150 resolves ~9pp more visits
  p_gap_minutes integer default 15,     -- a longer gap starts a new stay
  p_min_minutes integer default 3       -- below this it is a drive-by, not a visit
)
returns table (visits_considered integer, visits_resolved integer, visits_blank integer)
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_considered integer := 0;
  v_resolved   integer := 0;
begin
  -- 🛑 DROP FIRST. `on commit drop` fires at COMMIT, not at return, so two calls inside one
  -- transaction (which is exactly what the VERIFY block below does) hit 42P07 on the second.
  drop table if exists _tos_result;

  create temp table _tos_result on commit drop as
  with target as (
    select v.id, v.vehicle_id, v.visit_date,
           p.latitude::float8  as plat,
           p.longitude::float8 as plon
      from public.visits v
      join public.properties p on p.id = v.property_id
     where v.visit_status = 'completed'
       and v.deleted_at is null
       and v.visit_date >= p_from and v.visit_date < p_to
       and v.vehicle_id is not null
       and p.latitude is not null and p.longitude is not null
  ),
  pings as (
    select t.id, r.recorded_at
      from target t
      join public.vehicle_telemetry_readings r
        on r.vehicle_id = t.vehicle_id
       -- the whole ET operating day plus the overnight tail
       and r.recorded_at >= (t.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
       and r.recorded_at <  (t.visit_date::timestamp at time zone 'America/New_York') + interval '28 hours'
     where sqrt(power((r.latitude  - t.plat) * 111320, 2) +
                power((r.longitude - t.plon) * 111320 * cos(radians(t.plat)), 2)) <= p_radius_m
  ),
  marked as (
    select id, recorded_at,
           case when lag(recorded_at) over (partition by id order by recorded_at) is null
                  or recorded_at - lag(recorded_at) over (partition by id order by recorded_at)
                     > make_interval(mins => p_gap_minutes)
                then 1 else 0 end as new_cluster
      from pings
  ),
  clustered as (
    select id, recorded_at,
           sum(new_cluster) over (partition by id order by recorded_at) as cluster_no
      from marked
  ),
  spans as (
    select id, cluster_no, min(recorded_at) as arrival, max(recorded_at) as departure,
           extract(epoch from (max(recorded_at) - min(recorded_at)))/60 as minutes
      from clustered
     group by id, cluster_no
  )
  select distinct on (id) id as visit_id, arrival, departure, round(minutes)::integer as minutes
    from spans
   where minutes >= p_min_minutes
   order by id, minutes desc;

  select count(*) into v_considered
    from public.visits v
    join public.properties p on p.id = v.property_id
   where v.visit_status = 'completed' and v.deleted_at is null
     and v.visit_date >= p_from and v.visit_date < p_to
     and v.vehicle_id is not null and p.latitude is not null;

  select count(*) into v_resolved from _tos_result;

  if p_execute then
    update public.visits v
       set actual_arrival_at   = r.arrival,
           actual_departure_at = r.departure,
           duration_minutes    = r.minutes
      from _tos_result r
     where v.id = r.visit_id
       and (v.actual_arrival_at   is distinct from r.arrival
         or v.actual_departure_at is distinct from r.departure
         or v.duration_minutes    is distinct from r.minutes);
  end if;

  visits_considered := v_considered;
  visits_resolved   := v_resolved;
  visits_blank      := v_considered - v_resolved;
  return next;
end
$fn$;

comment on function public.fn_compute_time_on_site(date, date, boolean, integer, integer, integer) is
  'Derives visits.actual_arrival_at / actual_departure_at / duration_minutes from the assigned '
  'vehicle GPS dwell at the property. Internal ops insight only - it measures the TRUCK, not the '
  'crew, and leaves NULL rather than guessing. Never fall back to start_at/end_at (the schedule).';

revoke all on function public.fn_compute_time_on_site(date, date, boolean, integer, integer, integer) from public;
revoke all on function public.fn_compute_time_on_site(date, date, boolean, integer, integer, integer) from anon, authenticated;
grant execute on function public.fn_compute_time_on_site(date, date, boolean, integer, integer, integer) to service_role;

-- ============================================================================
-- VERIFY - exercise the function before trusting it. PL/pgSQL is not parsed at
-- CREATE, so "the migration applied" says nothing about whether the body runs.
-- ============================================================================
do $verify$
declare
  fail text := '';
  r record;
begin
  -- 1. a DRY RUN must not write anything
  select * into r from public.fn_compute_time_on_site('2026-08-11', '2026-08-19', false);
  if r.visits_considered = 0 then fail := fail || 'dry run considered 0 visits; '; end if;
  if r.visits_resolved = 0 then fail := fail || 'dry run resolved 0 visits - the join or radius is wrong; '; end if;
  if exists (select 1 from public.visits where duration_minutes is not null) then
    fail := fail || 'a dry run WROTE duration_minutes; ';
  end if;

  -- 2. POSITIVE CONTROL at a wider radius: 150m must resolve MORE than 75m, or the
  --    radius parameter is not actually reaching the distance test.
  declare r75 record; r150 record;
  begin
    select * into r75  from public.fn_compute_time_on_site('2026-08-11', '2026-08-19', false, 75);
    select * into r150 from public.fn_compute_time_on_site('2026-08-11', '2026-08-19', false, 150);
    if r150.visits_resolved <= r75.visits_resolved then
      fail := fail || format('radius is inert: 75m resolved %s, 150m resolved %s; ',
                             r75.visits_resolved, r150.visits_resolved);
    end if;
  end;

  -- 3. NEGATIVE CONTROL: an absurd minimum must resolve nothing.
  select * into r from public.fn_compute_time_on_site('2026-08-11', '2026-08-19', false, 75, 15, 100000);
  if r.visits_resolved <> 0 then
    fail := fail || 'a 100000-minute minimum still resolved visits; ';
  end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'fn_compute_time_on_site runs, the radius and minimum both bite, and a dry run writes nothing';
end
$verify$;
