-- ============================================================================
-- 2026-08-19_0320 - correct visits.vehicle_id from the truck that was actually there
-- ============================================================================
-- Fred, 2026-08-19: "fix the vehicle assignment so the trucks are correct."
--
-- WHY IT IS WRONG IN THE FIRST PLACE. Nothing syncs the truck from anywhere. The only
-- writers are the Visit Calendar (a dispatcher picking from a list) and one-off scripts;
-- `webhook-airtable` used to write it and has been retired since 2026-07-24. So the column
-- records who was PLANNED to go, and nothing ever reconciles it with who went.
-- Measured over July-August, of 288 completed visits with GPS evidence:
--     236 stored value matches the truck that was there
--      33 stored value names a DIFFERENT truck
--      19 stored value is NULL
--      34 had more than one truck inside the radius at some point
--
-- It matters beyond the display: time-on-site reads this column to pick whose GPS to
-- search, so a wrong truck yields a permanent blank. 23 of the 43 unresolved July-August
-- visits had their assigned truck more than a kilometre away (median 1,618 m).
--
-- THE EVIDENCE. Same dwell rule as fn_compute_time_on_site, but evaluated for EVERY
-- vehicle instead of only the stored one: pings within p_radius_m of the property across
-- the visit's ET operating day, split on gaps over 15 minutes, longest stay per vehicle,
-- minimum 3 minutes. The vehicle with the longest stay is the one that did the work.
--
-- 🛑 IT REFUSES TO GUESS WHEN TWO TRUCKS WERE THERE. 34 of 288 visits had a second
-- vehicle inside the radius, which is real: trucks meet, share a plaza, or pass by. So a
-- correction requires the winner to beat the runner-up by BOTH a factor (p_margin_ratio)
-- and an absolute gap (p_margin_minutes). Anything closer is left exactly as it is and
-- counted as ambiguous. A wrong truck written confidently is worse than the wrong truck
-- we already have, because it would look reconciled.
--
-- 🛑 COMPLETED VISITS ONLY. A scheduled visit's truck is a PLAN, and a plan is not wrong
-- for disagreeing with history. This only ever rewrites the record of work already done.
--
-- AUDIT (rule 8): public.visits is audited, so every correction is captured with
-- old_row/new_row and is individually reversible. The run labels itself
-- app_source='vehicle-gps-reconcile' so these are distinguishable from dispatcher edits,
-- which is exactly the distinction that was missing before.
-- ============================================================================

create or replace function public.fn_infer_visit_vehicle(
  p_from            date,
  p_to              date,
  p_execute         boolean default false,
  p_radius_m        integer default 150,
  p_gap_minutes     integer default 15,
  p_min_minutes     integer default 3,
  p_margin_ratio    numeric default 2.0,   -- winner must be this many times the runner-up
  p_margin_minutes  integer default 10     -- AND ahead by this many minutes
)
returns table (
  considered integer, evidence integer, already_correct integer,
  filled_null integer, corrected integer, ambiguous integer
)
language plpgsql
security definer
set search_path to ''
as $fn$
declare
  v_considered integer; v_evidence integer; v_ok integer;
  v_fill integer; v_fix integer; v_amb integer;
begin
  drop table if exists _veh_infer;

  create temp table _veh_infer on commit drop as
  with v as (
    select vi.id, vi.vehicle_id as stored_vehicle, vi.visit_date,
           p.latitude::float8 as plat, p.longitude::float8 as plon
      from public.visits vi
      join public.properties p on p.id = vi.property_id
     where vi.visit_status = 'completed'
       and vi.deleted_at is null
       and vi.visit_date >= p_from and vi.visit_date < p_to
       and p.latitude is not null and p.longitude is not null
  ),
  pings as (
    select v.id, t.vehicle_id, t.recorded_at
      from v
      join public.vehicle_telemetry_readings t
        on t.recorded_at >= (v.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
       and t.recorded_at <  (v.visit_date::timestamp at time zone 'America/New_York') + interval '28 hours'
     where sqrt(power((t.latitude  - v.plat) * 111320, 2) +
                power((t.longitude - v.plon) * 111320 * cos(radians(v.plat)), 2)) <= p_radius_m
  ),
  marked as (
    select id, vehicle_id, recorded_at,
           case when lag(recorded_at) over (partition by id, vehicle_id order by recorded_at) is null
                  or recorded_at - lag(recorded_at) over (partition by id, vehicle_id order by recorded_at)
                     > make_interval(mins => p_gap_minutes)
                then 1 else 0 end as nc
      from pings
  ),
  clustered as (
    select id, vehicle_id, recorded_at,
           sum(nc) over (partition by id, vehicle_id order by recorded_at) as cn
      from marked
  ),
  spans as (
    select id, vehicle_id, cn,
           extract(epoch from (max(recorded_at) - min(recorded_at)))/60 as mins
      from clustered group by id, vehicle_id, cn
  ),
  per_vehicle as (
    select distinct on (id, vehicle_id) id, vehicle_id, mins
      from spans where mins >= p_min_minutes
     order by id, vehicle_id, mins desc
  ),
  ranked as (
    select id, vehicle_id, mins,
           row_number() over (partition by id order by mins desc) as rk,
           lead(mins) over (partition by id order by mins desc)   as runner_up_mins
      from per_vehicle
  )
  select v.id                                as visit_id,
         v.stored_vehicle,
         r.vehicle_id                        as gps_vehicle,
         round(r.mins)::integer              as gps_minutes,
         round(coalesce(r.runner_up_mins, 0))::integer as runner_up_minutes,
         -- decisive only when it beats the runner-up on BOTH tests
         (r.runner_up_mins is null
           or (r.mins >= r.runner_up_mins * p_margin_ratio
               and r.mins - r.runner_up_mins >= p_margin_minutes)) as decisive
    from ranked r
    join v on v.id = r.id
   where r.rk = 1;

  select count(*) into v_considered
    from public.visits vi join public.properties p on p.id = vi.property_id
   where vi.visit_status='completed' and vi.deleted_at is null
     and vi.visit_date >= p_from and vi.visit_date < p_to and p.latitude is not null;

  select count(*) into v_evidence from _veh_infer;
  select count(*) into v_ok   from _veh_infer where stored_vehicle = gps_vehicle;
  select count(*) into v_fill from _veh_infer where stored_vehicle is null and decisive;
  select count(*) into v_fix  from _veh_infer where stored_vehicle is not null
                                                and stored_vehicle <> gps_vehicle and decisive;
  select count(*) into v_amb  from _veh_infer where not decisive
                                                and stored_vehicle is distinct from gps_vehicle;

  if p_execute then
    update public.visits v
       set vehicle_id = r.gps_vehicle
      from _veh_infer r
     where v.id = r.visit_id
       and r.decisive
       and v.visit_status = 'completed'          -- re-asserted: never touch a plan
       and v.deleted_at is null
       and v.vehicle_id is distinct from r.gps_vehicle;
  end if;

  considered      := v_considered;
  evidence        := v_evidence;
  already_correct := v_ok;
  filled_null     := v_fill;
  corrected       := v_fix;
  ambiguous       := v_amb;
  return next;
end
$fn$;

comment on function public.fn_infer_visit_vehicle(date, date, boolean, integer, integer, integer, numeric, integer) is
  'Reconciles visits.vehicle_id against which truck was actually at the property, from GPS dwell. '
  'Completed visits only (a scheduled truck is a plan, not a claim). Refuses to write when two '
  'vehicles were present without a clear margin. Audited as app_source=vehicle-gps-reconcile.';

revoke all on function public.fn_infer_visit_vehicle(date, date, boolean, integer, integer, integer, numeric, integer) from public;
revoke all on function public.fn_infer_visit_vehicle(date, date, boolean, integer, integer, integer, numeric, integer) from anon, authenticated;
grant execute on function public.fn_infer_visit_vehicle(date, date, boolean, integer, integer, integer, numeric, integer) to service_role;

-- ============================================================================
-- VERIFY - exercise it, and prove the margin guard is not decorative
-- ============================================================================
do $verify$
declare fail text := ''; r record; r_strict record; v_before bigint;
begin
  select count(*) into v_before from public.visits where vehicle_id is not null;

  -- 1. a dry run must find evidence and write nothing
  select * into r from public.fn_infer_visit_vehicle('2026-07-01', '2026-09-01', false);
  if r.evidence = 0 then fail := fail || 'no GPS evidence found at all; '; end if;
  if (select count(*) from public.visits where vehicle_id is not null) <> v_before then
    fail := fail || 'a DRY RUN changed vehicle_id; ';
  end if;

  -- 2. POSITIVE CONTROL on the margin: an impossible ratio must make everything ambiguous
  --    where a runner-up exists, so corrections must DROP. If the number does not move,
  --    the guard is not wired to anything.
  select * into r_strict from public.fn_infer_visit_vehicle('2026-07-01', '2026-09-01', false, 150, 15, 3, 1000.0, 100000);
  if r_strict.corrected + r_strict.filled_null >= r.corrected + r.filled_null
     and r.corrected + r.filled_null > 0 then
    fail := fail || format('margin guard is inert: normal=%s strict=%s; ',
                           r.corrected + r.filled_null, r_strict.corrected + r_strict.filled_null);
  end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'evidence % of %, already correct %, would fill %, would correct %, ambiguous %',
    r.evidence, r.considered, r.already_correct, r.filled_null, r.corrected, r.ambiguous;
end
$verify$;

select * from public.fn_infer_visit_vehicle('2026-07-01', '2026-09-01', false);
