-- ============================================================================
-- ROLLBACK of 2026-10-13_2210_time_on_site_stop_matcher_v2: the 2026-10-13_2025 bodies, cron 26 back to its old order,
-- and the links rebuilt with algorithm 1 (which retires every completion_chain link on its own).
-- Kept on purpose: the widened match_basis CHECK (the retired completion_chain rows still carry that value) and the
-- time on site values step 3 filled (labelled stop_at_completion; they are the truck's stop at the completion time).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF strpos(pg_get_functiondef('public.fn_link_visit_vehicle_stops'::regproc), 'algorithm version 2') = 0 THEN
    RAISE EXCEPTION 'step 3 is not applied: nothing to roll back'; END IF;
END $g$;

CREATE OR REPLACE FUNCTION public.fn_link_visit_vehicle_stops(p_execute boolean, p_radius_m integer DEFAULT 150, p_earlier_hours integer DEFAULT 12, p_volume_service_types text[] DEFAULT '{Pumping}'::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_fill_time_on_site_from_stops(p_execute boolean DEFAULT false)
 RETURNS TABLE(candidates integer, filled integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cand integer := 0;
  v_filled integer := 0;
  v_hdr text;
begin
  drop table if exists _fill_stops;
  create temp table _fill_stops on commit drop as
  select v.id as visit_id, min(s.arrived_at) as arrival, max(s.departed_at) as departure,
         min(l.match_basis) as basis
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
    -- 2026-10-13_2025: labelled, and the source recorded (a completion link, or a dump site visit)
    v_hdr := current_setting('request.headers', true);
    perform set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'time-on-site-from-stops',
           'x-change-reason', 'Time on site copied from the truck stop matched to the visit (the stop that holds the completion time, or the dump site visit).'))::text, true);
    update public.visits v
       set actual_arrival_at = f.arrival, actual_departure_at = f.departure,
           duration_minutes  = round(extract(epoch from f.departure - f.arrival) / 60)::integer,
           time_on_site_source = case when f.basis = 'completion' then 'stop_at_completion' else 'dump_site_dwell' end
      from _fill_stops f
     where v.id = f.visit_id and v.duration_minutes is null
       and v.visit_status = 'completed' and v.deleted_at is null;
    get diagnostics v_filled = row_count;
    perform set_config('request.headers', coalesce(v_hdr, ''), true);
  end if;

  return query select v_cand, v_filled;
end
$function$
;

CREATE OR REPLACE FUNCTION public.fn_compute_time_on_site(p_from date, p_to date, p_execute boolean DEFAULT false, p_radius_m integer DEFAULT 150, p_gap_minutes integer DEFAULT 15, p_min_minutes integer DEFAULT 3)
 RETURNS TABLE(visits_considered integer, visits_resolved integer, visits_blank integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_considered integer := 0;
  v_resolved   integer := 0;
  v_hdr        text;
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
    -- 2026-10-13_2025 (time on site plan, step 2): the write is labelled, and it only replaces its OWN values (or
    -- values from before time_on_site_source existed), never a stop-based, any-truck or reviewed one. Until then it
    -- rewrote any differing value of the last 10 days (8744: 68 -> 216 after the truck guesser changed the truck).
    v_hdr := current_setting('request.headers', true);
    perform set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'time-on-site-measure',
           'x-change-reason', 'Time on site measured from the visit''s truck GPS within 150 m of the property.'))::text, true);
    update public.visits v
       set actual_arrival_at   = r.arrival,
           actual_departure_at = r.departure,
           duration_minutes    = r.minutes,
           time_on_site_source = 'gps_150m_cluster'
      from _tos_result r
     where v.id = r.visit_id
       and v.visit_status = 'completed' and v.deleted_at is null
       and (v.time_on_site_source is null or v.time_on_site_source = 'gps_150m_cluster')
       and (v.actual_arrival_at   is distinct from r.arrival
         or v.actual_departure_at is distinct from r.departure
         or v.duration_minutes    is distinct from r.minutes);
    perform set_config('request.headers', coalesce(v_hdr, ''), true);
  end if;

  visits_considered := v_considered;
  visits_resolved   := v_resolved;
  visits_blank      := v_considered - v_resolved;
  return next;
end
$function$
;

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
  -- measure first, so a route that ended this morning is not listed as missing; a failure here never skips the alert.
  -- The window ends at YESTERDAY (2026-10-13_2025): measuring today at 11 AM caught trucks still working and froze
  -- cut-short values (the fills write once). Today's visits are measured by the 03:20 nightly run tomorrow.
  begin
    perform public.fn_compute_time_on_site(v_today - 3, v_today, true);
    perform public.fn_fill_blank_time_on_site(v_today - 3, v_today, true);
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
$function$
;

CREATE OR REPLACE FUNCTION public.viktor_set_visit_truck(p_visit_id bigint, p_truck text, p_requested_by text, p_reason text, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v record; t record; v_hdr text; v_who text := pg_catalog.btrim(coalesce(p_requested_by, ''));
  v_why text := pg_catalog.btrim(coalesce(p_reason, '')); v_label text; v_trucks text; v_after record;
begin
  select string_agg(name, ', ' order by name) into v_trucks from public.vehicles where status = 'ACTIVE';
  if length(v_who) < 2 then
    return jsonb_build_object('ok', false, 'message', 'I need the name of the person who asked for this change.');
  end if;
  if length(v_why) < 3 then
    return jsonb_build_object('ok', false, 'message', 'I need the reason for this change (the request as it was written).');
  end if;

  select vi.id, vi.visit_status, vi.visit_date, vi.vehicle_id, vi.deleted_at, c.client_code, c.name as client_name,
         (select name from public.vehicles where id = vi.vehicle_id) as old_truck
    into v from public.visits vi join public.clients c on c.id = vi.client_id where vi.id = p_visit_id;
  if v.id is null or v.deleted_at is not null then
    return jsonb_build_object('ok', false, 'message', format('I can''t find visit %s.', p_visit_id));
  end if;
  v_label := format('visit %s (%s %s, %s)', v.id, coalesce(v.client_code, ''), coalesce(v.client_name, ''),
                    to_char(v.visit_date, 'Dy, Mon FMDD'));
  -- Fred, 2026-10-12: "if the visit isn't complete then don't"
  if v.visit_status <> 'completed' then
    return jsonb_build_object('ok', false, 'visit_id', v.id, 'message',
      format('I didn''t change %s: it is %s, not completed, and I only change completed visits.', v_label, v.visit_status));
  end if;

  select id, name into t from public.vehicles
   where status = 'ACTIVE' and pg_catalog.lower(name) = pg_catalog.lower(pg_catalog.btrim(coalesce(p_truck, '')));
  if t.id is null then
    return jsonb_build_object('ok', false, 'visit_id', v.id, 'message',
      format('There is no truck called "%s". The trucks are %s.', pg_catalog.btrim(coalesce(p_truck, '')), v_trucks));
  end if;
  if v.vehicle_id = t.id then
    return jsonb_build_object('ok', true, 'changed', false, 'visit_id', v.id,
      'message', format('%s already has %s as its truck. Nothing changed.', pg_catalog.initcap(v_label), t.name));
  end if;
  if p_dry_run then
    return jsonb_build_object('ok', true, 'changed', false, 'dry_run', true, 'visit_id', v.id,
      'message', format('I would set %s as the truck on %s (now: %s).', t.name, v_label, coalesce(v.old_truck, 'no truck')));
  end if;

  -- attribution for the audit row, set here so no caller can leave it out; put back right after the write
  v_hdr := pg_catalog.current_setting('request.headers', true);
  perform pg_catalog.set_config('request.headers',
    (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
       || jsonb_build_object('x-app-source', 'viktor', 'x-actor-name', pg_catalog.left(v_who, 120),
                             'x-change-reason', pg_catalog.left(v_why, 500)))::text, true);
  update public.visits set vehicle_id = t.id where id = v.id and visit_status = 'completed' and deleted_at is null;
  perform pg_catalog.set_config('request.headers', coalesce(v_hdr, ''), true);

  -- measure it now, the same way the nightly job does (never clears a value)
  perform public.fn_compute_time_on_site(v.visit_date, v.visit_date + 1, true);
  perform public.fn_fill_blank_time_on_site(v.visit_date, v.visit_date + 1, true);
  select actual_arrival_at, actual_departure_at, duration_minutes into v_after from public.visits where id = v.id;

  return jsonb_build_object('ok', true, 'changed', true, 'visit_id', v.id, 'truck', t.name,
    'previous_truck', v.old_truck, 'duration_minutes', v_after.duration_minutes,
    'message', format('%s is now the truck on %s%s. ', t.name, v_label,
                      case when v.old_truck is null then '' else ' (it was ' || v.old_truck || ')' end)
      || case when v_after.duration_minutes is not null
              then format('Time on site: %s min (%s to %s).', v_after.duration_minutes,
                          to_char(v_after.actual_arrival_at at time zone 'America/New_York', 'FMHH12:MI AM'),
                          to_char(v_after.actual_departure_at at time zone 'America/New_York', 'FMHH12:MI AM'))
              else format('Time on site is still empty: %s''s GPS did not stop within 150 m of the property that day.', t.name) end);
end
$function$
;

CREATE OR REPLACE FUNCTION public.fn_stop_facts_checks()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$
;

SELECT cron.alter_job((SELECT jobid FROM cron.job WHERE jobname = 'time-on-site-nightly'),
  command := 'select public.fn_compute_time_on_site(current_date - 10, current_date + 1, true); select public.fn_fill_blank_time_on_site(current_date - 10, current_date + 1, true); select public.fn_fill_time_on_site_from_stops(true)');
SELECT set_config('request.headers', '{"x-app-source":"stop-facts"}', true);
SELECT public.fn_link_visit_vehicle_stops(true);
SELECT set_config('request.headers', '', true);
DO $v$ BEGIN
  IF EXISTS (SELECT 1 FROM public.visit_vehicle_stops WHERE deleted_at IS NULL AND match_basis = 'completion_chain') THEN
    RAISE EXCEPTION 'completion_chain links still live'; END IF;
  IF (public.fn_stop_facts_checks()->'integrity'->>'Z4')::int <> 0 THEN RAISE EXCEPTION 'Z4 after rollback'; END IF;
END $v$;
COMMIT;
