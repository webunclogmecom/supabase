-- 2026-10-12_2330_fill_blank_time_on_site.sql
--
-- Fred, 2026-10-12: "So what i want is to fill some gaps we have in our visits, where yannick is saying that a 25% of
-- our visits do not hold a duration time."
--
-- Measured before this file: 2026-01-01 .. today, 1,419 completed live visits, 214 (15%) with duration_minutes NULL
-- (21 to 23% in Feb, May, Jun). 58 of the 214 are non-customers (dump sites, test clients). Of the 156 customer
-- visits, the nightly fn_compute_time_on_site leaves them blank because it only looks at the ASSIGNED truck
-- (visits.vehicle_id) and keeps the LONGEST stay near the property; for these visits the assigned truck is missing,
-- wrong, or its longest stay is a different visit's.
--
-- RULE (high confidence only): fill a BLANK customer visit when SOME truck's GPS shows a stay of 3 minutes or more
-- within 150 m of the visit's property, in the same window the nightly function uses (20:00 ET the evening before
-- to 10:00 ET the next morning), and that stay CONTAINS the driver's completion time (completed_at within the stay,
-- 15 min of slack each side). Among several such stays, the longest wins. Same clustering as the nightly function:
-- pings within 150 m, a gap over 15 min starts a new stay.
--   * Writes ONLY visits whose duration_minutes is NULL (never changes an existing value).
--   * Writes actual_arrival_at, actual_departure_at, duration_minutes; never vehicle_id, never is_gps_confirmed.
--   * Customers only (public.fn_is_non_customer false). Visit dates 2026-01-01 to today.
--   * Nothing goes to Jobber: neither the sync_pending nor the Jobber push trigger lists these columns.
-- Visits left blank are listed in the commit/report: dump visits (their stored point is far from where trucks tip;
-- they come from public.v_vehicle_dumps since 2026-08-20), visits no truck came near, and stays that do not hold the
-- completion time (not filled: the stay could be another visit's).
--
-- Rule 8: no table change; public.visits is audited, so every row written carries old_row/new_row (restore source).

begin;
set local lock_timeout = '3s';

create temp table _fill on commit drop as
with blank as (
  select v.id, v.visit_date, v.completed_at,
         p.latitude::float8 plat, p.longitude::float8 plon
    from public.visits v
    join public.properties p on p.id = v.property_id
   where v.visit_status = 'completed' and v.deleted_at is null
     and v.visit_date between '2026-01-01' and current_date
     and v.duration_minutes is null
     and v.completed_at is not null
     and p.latitude is not null and p.longitude is not null
     and not public.fn_is_non_customer(v.client_id)
), pings as (
  select b.id, r.vehicle_id, r.recorded_at
    from blank b
    join public.vehicle_telemetry_readings r
      on r.recorded_at >= (b.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
     and r.recorded_at <  ((b.visit_date + 1) + time '10:00') at time zone 'America/New_York'
     and sqrt(power((r.latitude - b.plat) * 111320, 2) +
              power((r.longitude - b.plon) * 111320 * cos(radians(b.plat)), 2)) <= 150
), mk as (
  select id, vehicle_id, recorded_at,
         case when lag(recorded_at) over w is null
                or recorded_at - lag(recorded_at) over w > interval '15 minutes' then 1 else 0 end n
    from pings window w as (partition by id, vehicle_id order by recorded_at)
), cl as (
  select id, vehicle_id, recorded_at, sum(n) over (partition by id, vehicle_id order by recorded_at) c from mk
), sp as (
  select id, vehicle_id, c, min(recorded_at) arrival, max(recorded_at) departure,
         extract(epoch from max(recorded_at) - min(recorded_at)) / 60 minutes
    from cl group by 1, 2, 3
)
select distinct on (sp.id) sp.id as visit_id, sp.vehicle_id, sp.arrival, sp.departure, round(sp.minutes)::integer as minutes
  from sp join blank b on b.id = sp.id
 where sp.minutes >= 3
   and b.completed_at between sp.arrival - interval '15 minutes' and sp.departure + interval '15 minutes'
 order by sp.id, sp.minutes desc;

do $$
declare n_fill int; n_written int;
begin
  select count(*) into n_fill from _fill;
  if n_fill = 0 then raise exception 'nothing to fill: the instrument is wrong'; end if;

  update public.visits v
     set actual_arrival_at = f.arrival, actual_departure_at = f.departure, duration_minutes = f.minutes
    from _fill f
   where v.id = f.visit_id and v.duration_minutes is null;
  get diagnostics n_written = row_count;
  if n_written <> n_fill then raise exception 'wrote % rows, expected %', n_written, n_fill; end if;

  -- VERIFY: every filled visit now has a positive duration whose stay holds its completion
  if exists (select 1 from _fill f join public.visits v on v.id = f.visit_id
              where v.duration_minutes is null or v.duration_minutes < 3
                 or v.completed_at not between v.actual_arrival_at - interval '15 minutes'
                                           and v.actual_departure_at + interval '15 minutes') then
    raise exception 'VERIFY: a filled visit does not hold its completion time';
  end if;
  -- VERIFY: no non-customer and nothing outside 2026 was written
  if exists (select 1 from _fill f join public.visits v on v.id = f.visit_id
              where public.fn_is_non_customer(v.client_id) or v.visit_date < '2026-01-01') then
    raise exception 'VERIFY: wrote outside scope';
  end if;
  raise notice 'filled % visits', n_written;
end $$;

select count(*) as filled,
       count(*) filter (where f.vehicle_id is distinct from v.vehicle_id) as other_truck_than_assigned,
       count(*) filter (where v.vehicle_id is null) as visit_had_no_truck
  from _fill f join public.visits v on v.id = f.visit_id;

commit;
