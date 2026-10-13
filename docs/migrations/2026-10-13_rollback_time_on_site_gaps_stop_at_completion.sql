-- ROLLBACK of 2026-10-13_1935_time_on_site_gaps_stop_at_completion: puts back the 2026-10-13_0130 body of
-- fn_time_on_site_gaps (no stop_at_completion, Place ids as stored) and drops fn_gps_stays. Roll the edge function
-- time-on-site-reminder back FIRST (its new reasons read stop_at_completion; without it they simply never fire).
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE FUNCTION public.fn_time_on_site_gaps(p_date date DEFAULT (((now() AT TIME ZONE 'America/New_York'::text))::date - 1))
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with gap as (
    select v.id, v.visit_date, v.vehicle_id, v.service_type, v.completed_at, v.client_id, v.property_id,
           c.client_code, c.name as client_name,
           p.latitude::float8 as plat, p.longitude::float8 as plon
      from public.visits v
      join public.clients c on c.id = v.client_id
      left join public.properties p on p.id = v.property_id
     where v.visit_status = 'completed' and v.deleted_at is null
       and v.visit_date = p_date
       and v.duration_minutes is null
       and not coalesce(public.fn_is_non_customer(v.client_id), false)
  ), pings as (
    -- every GPS point of every truck in the window (not only the near ones): a point elsewhere is what ends a stay
    select g.id, r.vehicle_id, r.recorded_at,
           sqrt(power((r.latitude - g.plat) * 111320, 2) +
                power((r.longitude - g.plon) * 111320 * cos(radians(g.plat)), 2)) as d
      from gap g
      join public.vehicle_telemetry_readings r
        on g.plat is not null
       and r.recorded_at >= (g.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
       and r.recorded_at <  ((g.visit_date + 1) + time '10:00') at time zone 'America/New_York'
  ), closest as (
    select distinct on (id) id, vehicle_id, recorded_at, d from pings order by id, d
  ), marked as (
    -- A STAY is consecutive points within 150 m, however long the silence between them (a parked truck with its
    -- engine off can send no GPS), ended by a point outside 150 m or a silence over 4 hours. So two drive-bys are two
    -- passes, never one stay: visit 8765 (2026-10-09), David passed Casa Neos at 13:53 and 14:38 ET and was 500 m to
    -- 1.3 km away in between. Taking a truck's first and last near point as one stay (a report of 2026-10-12 did)
    -- reads that as "there 45 minutes". This list only describes; it fills nothing.
    select id, vehicle_id, recorded_at, d,
           case when lag(d) over w is null or lag(d) over w > 150 or d > 150
                  or recorded_at - lag(recorded_at) over w > interval '4 hours' then 1 else 0 end as n
      from pings
    window w as (partition by id, vehicle_id order by recorded_at)
  ), cl as (
    select id, vehicle_id, recorded_at, d, sum(n) over (partition by id, vehicle_id order by recorded_at) as c from marked
  ), stays as (
    select id, vehicle_id, min(recorded_at) as first_at, max(recorded_at) as last_at,
           round(extract(epoch from max(recorded_at) - min(recorded_at)) / 60)::int as minutes
      from cl where d <= 150 group by id, vehicle_id, c
  ), truck as (
    select vh.id, vh.name,
           (select e.source_id from public.entity_source_links e
             where e.entity_type = 'vehicle' and e.entity_id = vh.id and e.source_system = 'samsara' limit 1) as samsara_id
      from public.vehicles vh
  )
  select jsonb_build_object(
    'date', p_date,
    'older_count', (select count(*) from public.visits v
                     where v.visit_status = 'completed' and v.deleted_at is null and v.duration_minutes is null
                       and v.visit_date >= p_date - 30 and v.visit_date < p_date
                       and not coalesce(public.fn_is_non_customer(v.client_id), false)),
    'visits', coalesce((
      select jsonb_agg(jsonb_build_object(
               'visit_id', g.id, 'visit_date', g.visit_date, 'client_code', g.client_code, 'client_name', g.client_name,
               'service', g.service_type, 'completed_at', g.completed_at,
               'lat', g.plat, 'lng', g.plon,
               'truck', t.name, 'truck_samsara_id', t.samsara_id,
               'property_place_id', (select e.source_id from public.entity_source_links e
                                      where e.entity_type = 'property' and e.entity_id = g.property_id
                                        and e.source_system = 'samsara' limit 1),
               'client_place_ids', coalesce((select jsonb_agg(e.source_id) from public.entity_source_links e
                                              where e.entity_type = 'client' and e.entity_id = g.client_id
                                                and e.source_system = 'samsara'), '[]'::jsonb),
               'closest', (select jsonb_build_object('truck', ct.name, 'truck_samsara_id', ct.samsara_id,
                                                     'meters', round(c.d), 'at', c.recorded_at)
                             from closest c join truck ct on ct.id = c.vehicle_id where c.id = g.id),
               'stays', coalesce((select jsonb_agg(jsonb_build_object('truck', st.name, 'truck_samsara_id', st.samsara_id,
                                                                    'first', s.first_at, 'last', s.last_at, 'minutes', s.minutes)
                                                 order by s.minutes desc)
                                    from stays s join truck st on st.id = s.vehicle_id where s.id = g.id), '[]'::jsonb))
             order by g.client_code, g.id)
        from gap g left join truck t on t.id = g.vehicle_id), '[]'::jsonb));
$function$;

COMMENT ON FUNCTION public.fn_time_on_site_gaps(date) IS 'Client visits dated p_date (default yesterday ET) with no time on site, with the GPS facts behind each, for the daily Slack alert time-on-site-reminder. 2026-10-13_0130.';

DROP FUNCTION public.fn_gps_stays(bigint, timestamptz, timestamptz, integer, integer);

DO $a$ BEGIN
  IF md5(pg_get_functiondef('public.fn_time_on_site_gaps(date)'::regprocedure)) <> '7f19c163de572fb902bf2299a10485ff' THEN
    RAISE EXCEPTION 'rollback body differs from 2026-10-13_0130'; END IF;
END $a$;

COMMIT;
