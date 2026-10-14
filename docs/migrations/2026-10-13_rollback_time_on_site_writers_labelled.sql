-- ROLLBACK of 2026-10-13_2025_time_on_site_writers_labelled: the bodies as they were before it (copied from the live
-- definitions of 2026-10-13). Values already labelled keep their time_on_site_source (harmless; the column stays until
-- 2026-10-13_2020 is rolled back too).
BEGIN;
SET LOCAL lock_timeout = '3s';

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
           p.longitude::float8 as plon,
           -- 2026-10-12 guard: the same truck completed a visit at the same property the next day,
           -- so the next morning is that visit's and this one keeps the old +28 h tail
           exists (select 1 from public.visits n
                     where n.vehicle_id = v.vehicle_id and n.property_id = v.property_id
                       and n.visit_date = v.visit_date + 1
                       and n.visit_status = 'completed' and n.deleted_at is null) as next_day_same_site
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
       -- the whole ET operating day plus the overnight tail, to 10:00 ET next morning (2026-10-12,
       -- Fred: "Extend it, Good."; routes that finished after 04:00 ET came out blank), except when
       -- the guard above says the next morning belongs to the same truck's next-day visit here
       and r.recorded_at >= (t.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
       and r.recorded_at <  case when t.next_day_same_site
                                 then (t.visit_date::timestamp at time zone 'America/New_York') + interval '28 hours'
                                 else ((t.visit_date + 1) + time '10:00') at time zone 'America/New_York' end
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
$function$;

CREATE OR REPLACE FUNCTION public.fn_fill_blank_time_on_site(p_from date, p_to date, p_execute boolean DEFAULT false)
 RETURNS TABLE(blank_considered integer, filled integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_blank integer := 0;
  v_filled integer := 0;
begin
  drop table if exists _fill_tos;
  create temp table _fill_tos on commit drop as
  with blank as (
    select v.id, v.visit_date, v.completed_at,
           p.latitude::float8 plat, p.longitude::float8 plon
      from public.visits v
      join public.properties p on p.id = v.property_id
     where v.visit_status = 'completed' and v.deleted_at is null
       and v.visit_date >= p_from and v.visit_date < p_to
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
  select distinct on (sp.id) sp.id as visit_id, sp.arrival, sp.departure, round(sp.minutes)::integer as minutes
    from sp join blank b on b.id = sp.id
   where sp.minutes >= 3
     and b.completed_at between sp.arrival - interval '15 minutes' and sp.departure + interval '15 minutes'
   order by sp.id, sp.minutes desc;

  select count(*) into v_blank
    from public.visits v
   where v.visit_status = 'completed' and v.deleted_at is null
     and v.visit_date >= p_from and v.visit_date < p_to
     and v.duration_minutes is null and not public.fn_is_non_customer(v.client_id);

  if p_execute then
    update public.visits v
       set actual_arrival_at = f.arrival, actual_departure_at = f.departure, duration_minutes = f.minutes
      from _fill_tos f
     where v.id = f.visit_id and v.duration_minutes is null;
    get diagnostics v_filled = row_count;
  else
    select count(*) into v_filled from _fill_tos;
  end if;

  return query select v_blank, v_filled;
end
$function$;

CREATE OR REPLACE FUNCTION public.fn_fill_time_on_site_from_stops(p_execute boolean DEFAULT false)
 RETURNS TABLE(candidates integer, filled integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cand integer := 0;
  v_filled integer := 0;
begin
  drop table if exists _fill_stops;
  create temp table _fill_stops on commit drop as
  select v.id as visit_id, min(s.arrived_at) as arrival, max(s.departed_at) as departure
    from public.visits v
    join public.visit_vehicle_stops l on l.visit_id = v.id and l.deleted_at is null
    join public.vehicle_stops s on s.id = l.vehicle_stop_id and s.superseded_at is null
   where v.visit_status = 'completed' and v.deleted_at is null and v.duration_minutes is null
   group by v.id
  having count(*) = 1
     and bool_and(l.match_basis in ('completion', 'dump_completion', 'dump_window'))
     and max(s.departed_at) > min(s.arrived_at);

  select count(*) into v_cand from _fill_stops;

  if p_execute then
    update public.visits v
       set actual_arrival_at = f.arrival, actual_departure_at = f.departure,
           duration_minutes  = round(extract(epoch from f.departure - f.arrival) / 60)::integer
      from _fill_stops f
     where v.id = f.visit_id and v.duration_minutes is null;
    get diagnostics v_filled = row_count;
  end if;

  return query select v_cand, v_filled;
end
$function$;

CREATE OR REPLACE FUNCTION public.fn_request_time_on_site_reminder()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text; v_today date := (now() at time zone 'America/New_York')::date;
begin
  -- 11 AM Eastern whatever the season (Fred, 2026-10-07: every scheduled notification at 11): the job runs at 15:00
  -- and 16:00 UTC, and only one is 11 AM in New York
  if extract(hour from now() at time zone 'America/New_York') <> 11 then
    return;
  end if;
  -- measure first, so a route that ended this morning is not listed as missing; a failure here never skips the alert
  begin
    perform public.fn_compute_time_on_site(v_today - 3, v_today + 1, true);
    perform public.fn_fill_blank_time_on_site(v_today - 3, v_today + 1, true);
    perform public.fn_fill_time_on_site_from_stops(true);
  exception when others then
    raise warning 'time on site refresh before the reminder failed: %', sqlerrm;
  end;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping the time on site reminder';
    insert into public.sync_log (sync_source, started_at, finished_at, duration_seconds, status, rows_errored,
                                 error_details, details)
    values ('time_on_site_reminder', now(), clock_timestamp(), 0, 'error', 1,
            jsonb_build_object('message', 'The time on site Slack reminder did not run today: the database is missing the key '
                               || 'it uses to call the reminder. Put the key back, then the reminder runs again tomorrow.'),
            jsonb_build_object('posted', false, 'reason', 'no vault key', 'missing_secret', 'edge_invoke_service_key',
                               'test', false));
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/time-on-site-reminder',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
end
$function$;

DROP FUNCTION public.fn_infer_visit_vehicle(date, date, boolean, integer, integer, integer, numeric, integer);

CREATE FUNCTION public.fn_infer_visit_vehicle(p_from date, p_to date, p_execute boolean DEFAULT false, p_radius_m integer DEFAULT 150, p_gap_minutes integer DEFAULT 15, p_min_minutes integer DEFAULT 3, p_margin_ratio numeric DEFAULT 2.0, p_margin_minutes integer DEFAULT 10)
 RETURNS TABLE(considered integer, evidence integer, already_correct integer, filled_null integer, corrected integer, ambiguous integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;
REVOKE ALL ON FUNCTION public.fn_infer_visit_vehicle(date, date, boolean, integer, integer, integer, numeric, integer) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_infer_visit_vehicle(date, date, boolean, integer, integer, integer, numeric, integer) TO service_role;

COMMIT;
