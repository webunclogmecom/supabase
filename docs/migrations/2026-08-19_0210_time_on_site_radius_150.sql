-- ============================================================================
-- 2026-08-19_0210 - time on site: radius default 75m -> 150m
-- ============================================================================
-- Fred, 2026-08-19: "go with 150m instead".
--
-- This reverses the 75m default chosen a few hours earlier, on the measurement reported
-- with it: across one week 150m resolved 51 of 58 visits (88%) and 75m resolved 46 (79%),
-- while the average (54 min) and the maximum (~177 min) were IDENTICAL at both. The
-- tighter radius bought no accuracy and only produced blanks, which is why it went back.
--
-- The body below is the live pg_get_functiondef output with exactly one token changed,
-- asserted to match once (CLAUDE.md: CREATE OR REPLACE takes the WHOLE definition, so
-- anything not reproduced is silently deleted). Nothing else moved.
--
-- The nightly cron 'time-on-site-nightly' calls the function WITHOUT a radius argument,
-- so it picks this default up on its next run with no cron change.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_compute_time_on_site(p_from date, p_to date, p_execute boolean DEFAULT false, p_radius_m integer DEFAULT 150, p_gap_minutes integer DEFAULT 15, p_min_minutes integer DEFAULT 3)
 RETURNS TABLE(visits_considered integer, visits_resolved integer, visits_blank integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$
;


do $verify$
declare r150 record; r75 record;
begin
  -- the default must now BE 150: calling with no radius must match calling with 150
  select * into r150 from public.fn_compute_time_on_site('2026-08-01','2026-09-01', false);
  select * into r75  from public.fn_compute_time_on_site('2026-08-01','2026-09-01', false, 75);
  if r150.visits_resolved <= r75.visits_resolved then
    raise exception 'VERIFY FAILED: default resolved % but 75m resolved % - the default did not change',
      r150.visits_resolved, r75.visits_resolved;
  end if;
  raise notice 'default radius now resolves % of % (75m resolved %)',
    r150.visits_resolved, r150.visits_considered, r75.visits_resolved;
end
$verify$;
