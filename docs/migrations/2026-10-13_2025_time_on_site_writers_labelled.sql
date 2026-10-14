-- ============================================================================
-- 2026-10-13_2025 Time on site, step 2b: every writer labels its writes, the measurement stops overwriting values it
-- did not write, the truck guesser needs completion evidence, and the 11 AM run stops measuring today
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-13: "go ahead with step 2" (plan samsara-checks/time_on_site_fix_plan_2026-10-13.md, outside the
--   repos; defaults approved). Needs 2026-10-13_2020 (the time_on_site_source column) first.
--
-- WHAT CHANGES (bodies spliced from the live definitions, md5-pinned)
--   1. fn_compute_time_on_site, fn_fill_blank_time_on_site, fn_fill_time_on_site_from_stops: each write carries
--      x-app-source (time-on-site-measure / time-on-site-any-truck / time-on-site-from-stops) and a plain
--      x-change-reason, set around its own UPDATE and put back after (so Viktor's attribution, which calls two of
--      them, is untouched), and records time_on_site_source. Until now the cron writes logged as app_source 'sql' with
--      no path and no reason.
--   2. fn_compute_time_on_site only replaces values whose source is NULL (from before the column) or its own
--      gps_150m_cluster. It no longer rewrites a stop-based, any-truck or reviewed value (25 nightly rewrites of more
--      than 10 min since Aug 20, e.g. 8744 68 -> 216). It still never clears a value.
--   3. fn_infer_visit_vehicle (cron 27, 03:05 ET): an EMPTY truck is still filled by the longest 150 m stay, as
--      before. A truck already on the visit is REPLACED only when the GPS truck has a stop (fn_gps_stays: 3 min or
--      more, within 250 m) holding the completion time and the truck on the visit has none, and never on a visit filed
--      on a DERM manifest (its truck decal prints on the Miami-Dade LWT report: Fred decides those). Measured on the
--      guesser's own history: the 7 wrong replacements tested (8744, 8170, 7987, 7988, 7989, 7840, 6737) all have the
--      human truck at completion and not the guessed one; the 3 right ones not filed (7814, 7825, 7997) all the
--      reverse. Return gains refused_no_evidence and refused_filed (so DROP + CREATE; its only caller is cron 27).
--      NOT done here: porting scripts/sync/derive_visit_vehicle_id.js (GitHub, fills empty trucks only): it needs the
--      30-day parity run and question 9 of TIMED_JOBS_PLAN 2.10, and it never replaces a truck.
--   4. fn_request_time_on_site_reminder (11 AM ET): measures yesterday back 3 days, no longer today. At 11 AM it
--      measured trucks still working and froze cut-short values (8773: 05:13 to 05:21 for a job completed 06:44).
--      The 03:20 nightly run (cron 26) keeps its window.
--   Nothing reaches Jobber: the time columns, the source column and a completed visit's vehicle_id are outside both
--   Jobber push triggers (vehicle_id is LOCAL_ONLY; checked 2026-10-13).
--
-- HOW TO RUN: one call (one transaction, COMMIT last). Rehearse with apply_sql_file.mjs <file> rehearse. The checks
--   run the writers for real inside subtransactions that are rolled back (SQLSTATE P0901).
-- ROLLBACK: 2026-10-13_rollback_time_on_site_writers_labelled.sql (the 2026-10-13 bodies).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('fn_compute_time_on_site', 'c5b552f43f802c401257e100e65ef833'),
      ('fn_fill_blank_time_on_site', 'faafc85760e5132868e4dd2b2f32f809'),
      ('fn_fill_time_on_site_from_stops', '71f741452316eaf61da7a503a1fccabb'),
      ('fn_infer_visit_vehicle', 'a7b9826d345ffb3d4a626846362a53b1'),
      ('fn_request_time_on_site_reminder', '2c3ccb4eb8c88f10e42bfd6e9e3eef83')) t(f, m) LOOP
    IF (SELECT md5(pg_get_functiondef(p.oid)) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = r.f) IS DISTINCT FROM r.m THEN
      RAISE EXCEPTION '% changed since this file was written: splice from the live body again', r.f; END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'visits'
                  AND column_name = 'time_on_site_source') THEN
    RAISE EXCEPTION 'apply 2026-10-13_2020 first (time_on_site_source)'; END IF;
END $g$;

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
  v_hdr text;
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
    -- 2026-10-13_2025: labelled, and the source recorded
    v_hdr := current_setting('request.headers', true);
    perform set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'time-on-site-any-truck',
           'x-change-reason', 'Time on site measured from the GPS of a truck that stayed within 150 m of the property when the job was marked complete.'))::text, true);
    update public.visits v
       set actual_arrival_at = f.arrival, actual_departure_at = f.departure, duration_minutes = f.minutes,
           time_on_site_source = 'gps_150m_any_truck'
      from _fill_tos f
     where v.id = f.visit_id and v.duration_minutes is null
       and v.visit_status = 'completed' and v.deleted_at is null;
    get diagnostics v_filled = row_count;
    perform set_config('request.headers', coalesce(v_hdr, ''), true);
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
$function$;

DROP FUNCTION public.fn_infer_visit_vehicle(date, date, boolean, integer, integer, integer, numeric, integer);

CREATE FUNCTION public.fn_infer_visit_vehicle(p_from date, p_to date, p_execute boolean DEFAULT false, p_radius_m integer DEFAULT 150, p_gap_minutes integer DEFAULT 15, p_min_minutes integer DEFAULT 3, p_margin_ratio numeric DEFAULT 2.0, p_margin_minutes integer DEFAULT 10)
 RETURNS TABLE(considered integer, evidence integer, already_correct integer, filled_null integer, corrected integer, ambiguous integer, refused_no_evidence integer, refused_filed integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_considered integer; v_evidence integer; v_ok integer;
  v_fill integer; v_fix integer; v_amb integer;
  v_ref_ev integer; v_ref_filed integer; v_hdr text;
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
  -- 2026-10-13_2025 (time on site plan, step 2, Fred's default): a truck already on the visit is replaced only when
  -- the GPS truck has a stop (3 min or more, within 250 m) that holds the completion time and the truck on the visit
  -- has none, and never on a visit filed on a DERM manifest (its truck decal prints on the LWT report: Fred decides).
  -- Since 2026-08-20 the longest-stay rule alone replaced 26 trucks, 12 of them wrongly (8744: Cloggy was there 64 min
  -- at completion, the rule put Moises's night stay on it). An empty truck is still filled by the longest stay.
  drop table if exists _veh_evidence;
  create temp table _veh_evidence on commit drop as
  with c as (
    select r.visit_id, r.stored_vehicle, r.gps_vehicle, vi.visit_date, vi.completed_at,
           p.latitude as plat, p.longitude as plon,
           exists (select 1 from public.manifest_visits mv join public.derm_manifests dm on dm.id = mv.manifest_id
                    where mv.visit_id = r.visit_id and dm.deleted_at is null) as filed
      from _veh_infer r
      join public.visits vi on vi.id = r.visit_id
      join public.properties p on p.id = vi.property_id
     where r.decisive and r.stored_vehicle is not null and r.stored_vehicle <> r.gps_vehicle
  ), st as (
    select d.visit_date, d.vehicle_id, s.arrived_at, s.departed_at, s.latitude, s.longitude
      from (select distinct c.visit_date, x.vehicle_id from c cross join lateral (values (c.stored_vehicle), (c.gps_vehicle)) x(vehicle_id)) d
      cross join lateral public.fn_gps_stays(d.vehicle_id,
                   (d.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours',
                   ((d.visit_date + 1) + time '10:00') at time zone 'America/New_York') s
  )
  select c.visit_id, c.filed,
         exists (select 1 from st where st.visit_date = c.visit_date and st.vehicle_id = c.gps_vehicle
                    and c.completed_at between st.arrived_at - interval '5 minutes' and st.departed_at + interval '15 minutes'
                    and ops.fn_haversine_km(c.plat, c.plon, st.latitude, st.longitude) * 1000 <= 250) as gps_holds,
         exists (select 1 from st where st.visit_date = c.visit_date and st.vehicle_id = c.stored_vehicle
                    and c.completed_at between st.arrived_at - interval '5 minutes' and st.departed_at + interval '15 minutes'
                    and ops.fn_haversine_km(c.plat, c.plon, st.latitude, st.longitude) * 1000 <= 250) as stored_holds
    from c;

  select count(*) into v_fix       from _veh_evidence where gps_holds and not stored_holds and not filed;
  select count(*) into v_ref_filed from _veh_evidence where filed;
  select count(*) into v_ref_ev    from _veh_evidence where not filed and not (gps_holds and not stored_holds);
  select count(*) into v_amb  from _veh_infer where not decisive
                                                and stored_vehicle is distinct from gps_vehicle;

  if p_execute then
    v_hdr := current_setting('request.headers', true);
    perform set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'truck-from-gps',
           'x-change-reason', 'Truck set from GPS: it stayed at the property longest, and when another truck was on the visit, only this one was parked there when the job was marked complete.'))::text, true);
    update public.visits v
       set vehicle_id = r.gps_vehicle
      from _veh_infer r
     where v.id = r.visit_id
       and r.decisive
       and v.visit_status = 'completed'          -- re-asserted: never touch a plan
       and v.deleted_at is null
       and v.vehicle_id is distinct from r.gps_vehicle
       and (v.vehicle_id is null
            or exists (select 1 from _veh_evidence e
                        where e.visit_id = v.id and e.gps_holds and not e.stored_holds and not e.filed));
    perform set_config('request.headers', coalesce(v_hdr, ''), true);
  end if;

  considered      := v_considered;
  evidence        := v_evidence;
  already_correct := v_ok;
  filled_null     := v_fill;
  corrected       := v_fix;
  ambiguous       := v_amb;
  refused_no_evidence := v_ref_ev;
  refused_filed   := v_ref_filed;
  return next;
end
$function$;

REVOKE ALL ON FUNCTION public.fn_infer_visit_vehicle(date, date, boolean, integer, integer, integer, numeric, integer) FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_infer_visit_vehicle(date, date, boolean, integer, integer, integer, numeric, integer) TO service_role;
COMMENT ON FUNCTION public.fn_infer_visit_vehicle(date, date, boolean, integer, integer, integer, numeric, integer) IS 'Truck of a completed visit from GPS (cron 27 vehicle-gps-reconcile-nightly). Fills an empty truck from the decisive longest 150 m stay; replaces a truck already on the visit only with completion evidence (the GPS truck has a stop within 250 m holding completed_at, the stored one has none) and never on a visit filed on a DERM manifest. Writes labelled truck-from-gps. 2026-10-13_2025.';

DO $v$
DECLARE x record; r record; n int; v_ok boolean := false;
BEGIN
  -- V1 the measurement protects a value it did not write, and labels the ones it does
  PERFORM public.fn_compute_time_on_site(current_date - 30, current_date, false);
  SELECT t.visit_id, t.minutes, v.visit_date INTO x FROM _tos_result t JOIN public.visits v ON v.id = t.visit_id
   WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL ORDER BY t.visit_id DESC LIMIT 1;
  IF x.visit_id IS NULL THEN RAISE EXCEPTION 'V1: no visit to test the measurement on (control empty)'; END IF;
  BEGIN
    UPDATE public.visits SET duration_minutes = x.minutes + 7, time_on_site_source = 'stop_at_completion' WHERE id = x.visit_id;
    PERFORM public.fn_compute_time_on_site(x.visit_date, x.visit_date + 1, true);
    IF (SELECT duration_minutes FROM public.visits WHERE id = x.visit_id) IS DISTINCT FROM x.minutes + 7 THEN
      RAISE EXCEPTION 'V1: the measurement overwrote a stop-based value (visit %)', x.visit_id; END IF;
    UPDATE public.visits SET time_on_site_source = 'gps_150m_cluster' WHERE id = x.visit_id;
    PERFORM public.fn_compute_time_on_site(x.visit_date, x.visit_date + 1, true);
    SELECT duration_minutes, time_on_site_source INTO r FROM public.visits WHERE id = x.visit_id;
    IF r.duration_minutes IS DISTINCT FROM x.minutes OR r.time_on_site_source IS DISTINCT FROM 'gps_150m_cluster' THEN
      RAISE EXCEPTION 'V1: the measurement did not replace its own value (visit %: %)', x.visit_id, r; END IF;
    IF NOT EXISTS (SELECT 1 FROM audit.logs a WHERE a.table_name = 'visits' AND a.record_pk->>'id' = x.visit_id::text
                     AND a.txid = txid_current() AND a.app_source = 'time-on-site-measure'
                     AND coalesce(a.request_context->>'change_reason', '') <> '') THEN
      RAISE EXCEPTION 'V1: the measurement''s write is not labelled'; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0901', MESSAGE = 'probe rolled back';
  EXCEPTION WHEN SQLSTATE 'P0901' THEN NULL;
  END;

  -- V2 the any-truck fill records its source and label (a visit completed today, waiting for the nightly run)
  PERFORM public.fn_fill_blank_time_on_site(current_date - 30, current_date + 1, false);
  SELECT f.visit_id, v.visit_date INTO x FROM _fill_tos f JOIN public.visits v ON v.id = f.visit_id ORDER BY f.visit_id LIMIT 1;
  IF x.visit_id IS NOT NULL THEN
    BEGIN
      PERFORM public.fn_fill_blank_time_on_site(x.visit_date, x.visit_date + 1, true);
      IF (SELECT time_on_site_source FROM public.visits WHERE id = x.visit_id) IS DISTINCT FROM 'gps_150m_any_truck'
         OR NOT EXISTS (SELECT 1 FROM audit.logs a WHERE a.table_name = 'visits' AND a.record_pk->>'id' = x.visit_id::text
                          AND a.txid = txid_current() AND a.app_source = 'time-on-site-any-truck') THEN
        RAISE EXCEPTION 'V2: the any-truck fill of visit % is not labelled', x.visit_id; END IF;
      v_ok := true;
      RAISE EXCEPTION USING ERRCODE = 'P0901', MESSAGE = 'probe rolled back';
    EXCEPTION WHEN SQLSTATE 'P0901' THEN NULL;
    END;
  END IF;
  IF NOT v_ok THEN RAISE NOTICE 'V2: no any-truck candidate today, label not exercised'; END IF;

  -- V3 the stop fill records stop_at_completion and its label (a filled visit with one completion link, emptied first)
  SELECT v.id INTO x FROM public.visits v
    JOIN public.visit_vehicle_stops l ON l.visit_id = v.id AND l.deleted_at IS NULL
    JOIN public.vehicle_stops s ON s.id = l.vehicle_stop_id AND s.superseded_at IS NULL
   WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND v.duration_minutes IS NOT NULL
   GROUP BY v.id HAVING count(*) = 1 AND min(l.match_basis) = 'completion' AND max(s.departed_at) > min(s.arrived_at)
   ORDER BY v.id DESC LIMIT 1;
  IF x.id IS NULL THEN RAISE EXCEPTION 'V3: no visit with one completion link (control empty)'; END IF;
  BEGIN
    UPDATE public.visits SET duration_minutes = null, actual_arrival_at = null, actual_departure_at = null WHERE id = x.id;
    PERFORM public.fn_fill_time_on_site_from_stops(true);
    IF (SELECT time_on_site_source FROM public.visits WHERE id = x.id) IS DISTINCT FROM 'stop_at_completion'
       OR NOT EXISTS (SELECT 1 FROM audit.logs a WHERE a.table_name = 'visits' AND a.record_pk->>'id' = x.id::text
                        AND a.txid = txid_current() AND a.app_source = 'time-on-site-from-stops') THEN
      RAISE EXCEPTION 'V3: the stop fill of visit % is not labelled', x.id; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0901', MESSAGE = 'probe rolled back';
  EXCEPTION WHEN SQLSTATE 'P0901' THEN NULL;
  END;

  -- V4 the truck guesser: refuses the wrong replacement of 8744 (Cloggy there at completion), still makes the right one
  -- on 7814 (Cloggy there, Moises on the visit), and refuses a filed visit (6469)
  BEGIN
    UPDATE public.visits SET vehicle_id = 2 WHERE id = 8744;
    SELECT * INTO r FROM public.fn_infer_visit_vehicle('2026-10-06', '2026-10-07', true);
    IF (SELECT vehicle_id FROM public.visits WHERE id = 8744) IS DISTINCT FROM 2 THEN
      RAISE EXCEPTION 'V4: the guesser replaced the truck of 8744 without completion evidence'; END IF;
    IF r.refused_no_evidence < 1 THEN RAISE EXCEPTION 'V4: refused_no_evidence did not count 8744 (%)', r; END IF;
    UPDATE public.visits SET vehicle_id = 1 WHERE id = 7814;
    PERFORM public.fn_infer_visit_vehicle('2026-08-27', '2026-08-28', true);
    IF (SELECT vehicle_id FROM public.visits WHERE id = 7814) IS DISTINCT FROM 2 THEN
      RAISE EXCEPTION 'V4: the guesser no longer makes the right replacement on 7814'; END IF;
    IF NOT EXISTS (SELECT 1 FROM audit.logs a WHERE a.table_name = 'visits' AND a.record_pk->>'id' = '7814'
                     AND a.txid = txid_current() AND a.app_source = 'truck-from-gps'
                     AND a.new_row->>'vehicle_id' = '2') THEN
      RAISE EXCEPTION 'V4: the truck change on 7814 is not labelled'; END IF;
    UPDATE public.visits SET vehicle_id = 1 WHERE id = 6469;
    SELECT * INTO r FROM public.fn_infer_visit_vehicle('2026-08-21', '2026-08-22', true);
    IF (SELECT vehicle_id FROM public.visits WHERE id = 6469) IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION 'V4: the guesser replaced the truck of filed visit 6469'; END IF;
    IF r.refused_filed < 1 THEN RAISE EXCEPTION 'V4: refused_filed did not count 6469 (%)', r; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0901', MESSAGE = 'probe rolled back';
  EXCEPTION WHEN SQLSTATE 'P0901' THEN NULL;
  END;
  IF (SELECT vehicle_id FROM public.visits WHERE id = 8744) IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'V4: probe leaked'; END IF;

  -- V5 the 11 AM run no longer measures today; grants
  IF pg_get_functiondef('public.fn_request_time_on_site_reminder()'::regprocedure) LIKE '%v_today + 1%' THEN
    RAISE EXCEPTION 'V5: the reminder still measures today'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_infer_visit_vehicle(date,date,boolean,integer,integer,integer,numeric,integer)'::regprocedure)
     IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN RAISE EXCEPTION 'V5: guesser ACL'; END IF;
END $v$;

COMMIT;
