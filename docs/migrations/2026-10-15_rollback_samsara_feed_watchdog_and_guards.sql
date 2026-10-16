-- ============================================================================
-- ROLLBACK of 2026-10-15_2230_samsara_feed_watchdog_and_guards.sql
-- ============================================================================
-- Puts back the six function bodies and the two health views exactly as they were before (dumped from Prod
-- 2026-10-15 ~22:20 ET), the reminder schedule (15:00 and 16:00 UTC), drops the watchdog cron and the four new
-- functions. Kept: the index idx_synclog_source_started (harmless, speeds every sync_log lookup by source), and the
-- samsara-feed-health / time_on_site_reminder_request rows in sync_log and health_alert_state (history; with the check
-- gone from the views they stop being read). Run: node scripts/probes/apply_sql_file.mjs <this file> rehearse, then for real.
-- ⚠ Deploy the previous derive_visit_vehicle_id.js FIRST (it calls fn_samsara_data_complete_through).

BEGIN;
SET LOCAL lock_timeout = '3s';
select cron.unschedule(jobid) from cron.job where jobname = 'samsara-feed-health';
select cron.alter_job((select jobid from cron.job where jobname = 'time-on-site-reminder'), schedule := '0 15,16 * * *');

CREATE OR REPLACE FUNCTION public.fn_refresh_stop_facts(p_rebuild_vehicle_id bigint DEFAULT NULL::bigint, p_rebuild_from timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
     where x.key in ('Z1','Z2','Z3','Z4','Z7','Z8','Z9','T1','T2','T3','T4','T5','T6') and (x.value)::text::int > 0;
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
end $function$;

CREATE OR REPLACE FUNCTION ops.fn_freeze_grease_estimates()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
DECLARE
  v_today   date := (now() AT TIME ZONE 'America/New_York')::date;
  v_started timestamptz := clock_timestamp();
  v_from    date;
  n         integer := 0;
  n_carried integer := 0;
  v_err     text;
BEGIN
  BEGIN
    -- only from the earliest past day that has a visit with no stored row (usually yesterday)
    SELECT min(cv.visit_date) INTO v_from
      FROM ops.v_calendar_visit cv
     WHERE cv.visit_date BETWEEN date '2026-01-01' AND v_today - 1
       AND NOT EXISTS (SELECT 1 FROM ops.visit_grease_frozen f
                        WHERE f.visit_id = cv.id AND f.visit_date = cv.visit_date AND f.superseded_at IS NULL);
    IF v_from IS NOT NULL THEN
      WITH src AS MATERIALIZED (
        SELECT * FROM ops.fn_grease_estimates_resolved(v_from, v_today - 1) r WHERE r.source <> 'frozen'
      ), ins AS (
        INSERT INTO ops.visit_grease_frozen (visit_id, visit_date, pump_kind, pump_kinds, vehicle_id, trap_size_gallons, gallons, basis, readings)
        SELECT s.visit_id, s.visit_date, s.pump_kind, s.pump_kinds, s.vehicle_id, s.trap_size_gallons, s.gallons, s.basis, s.readings
          FROM src s
        RETURNING 1
      )
      SELECT (SELECT count(*) FROM ins), (SELECT count(*) FROM src WHERE src.source = 'carried') INTO n, n_carried;
    END IF;
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, duration_seconds, rows_inserted, status, details)
    VALUES ('calendar_grease_freeze', v_started, clock_timestamp(),
            round(extract(epoch FROM clock_timestamp() - v_started)::numeric, 3), n, 'success',
            jsonb_build_object('frozen', n, 'carried', n_carried, 'from', v_from, 'through', v_today - 1));
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
    n := 0;
    INSERT INTO public.sync_log (sync_source, started_at, finished_at, duration_seconds, rows_errored, status, error_details, details)
    VALUES ('calendar_grease_freeze', v_started, clock_timestamp(),
            round(extract(epoch FROM clock_timestamp() - v_started)::numeric, 3), 1, 'error',
            jsonb_build_object('message', left(v_err, 300)), jsonb_build_object('through', v_today - 1));
  END;
  RETURN n;
END $function$;

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
    perform public.fn_fill_time_on_site_from_stops(true);   -- 2026-10-13 step 3: the completion stop first
    perform public.fn_compute_time_on_site(v_today - 3, v_today, true);
    perform public.fn_fill_blank_time_on_site(v_today - 3, v_today, true);
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

CREATE OR REPLACE FUNCTION public.fn_infer_visit_vehicle(p_from date, p_to date, p_execute boolean DEFAULT false, p_radius_m integer DEFAULT 150, p_gap_minutes integer DEFAULT 15, p_min_minutes integer DEFAULT 3, p_margin_ratio numeric DEFAULT 2.0, p_margin_minutes integer DEFAULT 10)
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
  -- 2026-10-13_2025 (time on site plan, step 2, Fred's default): a truck already on the visit is replaced only when
  -- the GPS truck has a stop (3 min or more, within 250 m) that holds the completion time and the truck on the visit
  -- has none, and never on a visit filed on a DERM manifest (its truck decal prints on the LWT report: Fred decides).
  -- 2026-10-14_1610 (Fred: "yes do both"): that stop is now the evidence on its own. The 150 m longest-stay test above
  -- no longer gates a replacement: a truck parked 150 to 250 m away (visit 6498: Moises 181 m, 34 min, inside its
  -- Samsara place, only 1.5 min within 150 m) never won it, so the wrong truck stayed and the time stayed blank. The
  -- evidence is the ONE truck whose stay (fn_gps_stays, 3 min or more) within 250 m holds the completion time (-5 / +15
  -- min, the stop rule); two such trucks decide nothing. Stays are read around the COMPLETION date, not the visit date
  -- (8017: visit Sep 4, marked complete Sep 7 while Moises was parked 17 m away). An empty truck takes that truck
  -- first, else the longest stay as before.
  drop table if exists _veh_evidence;
  create temp table _veh_evidence on commit drop as
  with c as (
    select vi.id as visit_id, vi.vehicle_id as stored_vehicle, vi.completed_at,
           (vi.completed_at at time zone 'America/New_York')::date as cdate,
           p.latitude as plat, p.longitude as plon,
           exists (select 1 from public.manifest_visits mv join public.derm_manifests dm on dm.id = mv.manifest_id
                    where mv.visit_id = vi.id and dm.deleted_at is null) as filed
      from public.visits vi
      join public.properties p on p.id = vi.property_id
     where vi.visit_status = 'completed' and vi.deleted_at is null
       and vi.visit_date >= p_from and vi.visit_date < p_to
       and p.latitude is not null and p.longitude is not null
  ), trucks as (
    select distinct s.vehicle_id from public.vehicle_stops s
  ), st as (
    select d.cdate, d.vehicle_id, s.arrived_at, s.departed_at, s.latitude, s.longitude
      from (select distinct c.cdate, t.vehicle_id from c cross join trucks t where c.cdate is not null) d
      cross join lateral public.fn_gps_stays(d.vehicle_id,
                   (d.cdate::timestamp at time zone 'America/New_York') - interval '4 hours',
                   ((d.cdate + 1) + time '10:00') at time zone 'America/New_York') s
  ), h as (
    select c.visit_id, array_agg(distinct st.vehicle_id) as holders
      from c join st on st.cdate = c.cdate
       and c.completed_at between st.arrived_at - interval '5 minutes' and st.departed_at + interval '15 minutes'
       and ops.fn_haversine_km(c.plat, c.plon, st.latitude, st.longitude) * 1000 <= 250
     group by c.visit_id
  )
  select c.visit_id, c.stored_vehicle, c.filed, coalesce(h.holders, '{}'::bigint[]) as holders,
         case when cardinality(h.holders) = 1 then h.holders[1] end as holder
    from c left join h using (visit_id);

  select count(*) into v_fix       from _veh_evidence
   where stored_vehicle is not null and holder is not null and holder <> stored_vehicle and not filed;
  select count(*) into v_ref_filed from _veh_evidence
   where stored_vehicle is not null and holder is not null and holder <> stored_vehicle and filed;
  select count(*) into v_fill      from _veh_evidence e left join _veh_infer r using (visit_id)
   where e.stored_vehicle is null and (e.holder is not null or r.decisive);
  select count(*) into v_ref_ev    from _veh_infer r join _veh_evidence e using (visit_id)
   where r.decisive and r.stored_vehicle is not null and r.stored_vehicle <> r.gps_vehicle
     and not (e.holder is not null and e.holder <> e.stored_vehicle);
  select count(*) into v_amb  from _veh_infer where not decisive
                                                and stored_vehicle is distinct from gps_vehicle;

  if p_execute then
    v_hdr := current_setting('request.headers', true);
    perform set_config('request.headers', (coalesce(nullif(v_hdr, '')::jsonb, '{}'::jsonb)
      || jsonb_build_object('x-app-source', 'truck-from-gps',
           'x-change-reason', 'Truck set from GPS: it was the only truck parked within 250 m when the job was marked complete (an empty truck with no such stop takes the truck that stayed there longest).'))::text, true);
    update public.visits v
       set vehicle_id = coalesce(e.holder, r.gps_vehicle)
      from _veh_evidence e
      left join _veh_infer r on r.visit_id = e.visit_id
     where v.id = e.visit_id
       and v.visit_status = 'completed'          -- re-asserted: never touch a plan
       and v.deleted_at is null
       and ((v.vehicle_id is null and (e.holder is not null or r.decisive))
            or (v.vehicle_id is not null and e.holder is not null and e.holder <> v.vehicle_id and not e.filed))
       and v.vehicle_id is distinct from coalesce(e.holder, r.gps_vehicle);
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

CREATE OR REPLACE FUNCTION public.log_jobber_sync_health()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'sync', 'pg_temp'
AS $function$
declare
  v_items    jsonb := '[]'::jsonb;
  v_conflict int := 0;
  v_stuck    int := 0;
  v_skipped  int := 0;
  v_total    int := 0;
  v_drift_visit_completion_lost      int := 0;
  v_drift_visit_crew                 int := 0;
  v_unresolvable_jobber_user_90d     int := 0;
  v_orphan_visit_shadow_match        int := 0;
  v_drift_client_archived_not_inactive int := 0;
  v_drift_client_inactive_not_archived_unpinned int := 0;
  v_drift_client_inactive_not_archived_pinned int := 0;
  v_drift_client_class_unpinned      int := 0;
  v_drift_client_class_pinned        int := 0;
  v_drift_client_name                int := 0;
  v_drift_property_grease_trap_jobber_only int := 0;
  v_drift_property_grease_trap_both_set int := 0;
  v_drift_property_grease_trap_ours_only int := 0;
  v_drift_property_lock_box          int := 0;
  v_shadow_seeded_never_adopted      int := 0;
  v_ss_failed  int := 0;
  v_ss_stalled int := 0;
  v_ss_stuck   int := 0;
  v_ss_crash   int := 0;
  v_bill_verdict   text;
  v_bill_observed  int := 0;
  v_bill_drift     int := 0;
  v_bill_unmapped  int := 0;
  v_bill_neverconf int := 0;
  v_bill_ids       bigint[] := '{}';
  v_link_orphans   int := 0;
  v_link_legacy    int := 0;
  v_link_shown     int := 0;
  v_tank_verdict   text;      -- M7
  v_tank_flags     jsonb;     -- M7
begin
  -- 1. A conflict the sync recorded and nobody has decided. This is the whole point of the
  --    mechanism: both sides moved, so it refused to guess. Refusing to guess is correct;
  --    refusing to guess in silence is the defect.
  with c as (
    select jsonb_build_object(
             'kind',   'shadow_conflict:' || s.entity_type || ':' || s.entity_id::text || ':' || coalesce(s.field_label, s.field_key),
             'issue',  'shadow_conflict',
             'reason', 'Both we and Jobber changed ' || coalesce(s.field_label, s.field_key) ||
                       ' on ' || s.entity_type || ' ' || s.entity_id::text ||
                       ' since the last sync, so neither value was copied. Ours reads ' ||
                       coalesce(s.conflict_our_value #>> '{}', 'null') || ', Jobber reads ' ||
                       coalesce(s.conflict_source_value #>> '{}', 'null') ||
                       '. Nothing is blocked and the app still works; the two systems will simply stay '
                       'different until someone makes them agree, which releases it automatically.',
             'entity_type',   s.entity_type,
             'entity_id',     s.entity_id,
             'field',         coalesce(s.field_label, s.field_key),
             'our_value',     s.conflict_our_value,
             'jobber_value',  s.conflict_source_value,
             'conflict_at',   s.conflict_at,
             'conflict_count', s.conflict_count) as item
      from sync.source_field_shadow s
     where s.conflict_at is not null
  )
  select coalesce(jsonb_agg(item), '[]'::jsonb), count(*) into v_items, v_conflict from c;

  -- 2. A push to Jobber that did not land. Deliberately NOT keyed on one status string: the only
  --    status this table has ever held is 'done', so hard-coding a failure name would be guessing
  --    at a value that has never occurred. Anything that is neither done nor a deliberate skip and
  --    is older than 30 minutes has missed 15 cycles of a */2 cron, and anything carrying an error
  --    or 3+ attempts is reported whatever its status says.
  with q as (
    select jsonb_build_object(
             'kind',   'outbound_stuck:' || o.id::text,
             'issue',  'outbound_stuck',
             'reason', 'A ' || coalesce(o.field_label, o.field_key) || ' change for ' || o.entity_type ||
                       ' ' || o.entity_id::text || ' has not reached Jobber. Status ' || o.status ||
                       ', ' || o.attempts::text || ' attempt(s), queued ' ||
                       round(extract(epoch from (now() - o.created_at)) / 60.0)::text || ' minutes ago' ||
                       case when o.last_error is not null then '. Last error: ' || left(o.last_error, 200) else '' end ||
                       '. Jobber still holds the old value.',
             'queue_id',    o.id,
             'entity_type', o.entity_type,
             'entity_id',   o.entity_id,
             'field',       coalesce(o.field_label, o.field_key),
             'status',      o.status,
             'attempts',    o.attempts,
             'last_error',  o.last_error,
             'queued_minutes', round(extract(epoch from (now() - o.created_at)) / 60.0)) as item
      from sync.outbound_queue o
     where o.status not in ('done', 'skipped')
       and ( o.created_at < now() - interval '30 minutes'
             or o.last_error is not null
             or coalesce(o.attempts, 0) >= 3 )
  )
  select v_items || coalesce(jsonb_agg(item), '[]'::jsonb), count(*) into v_items, v_stuck from q;

  -- 3. A deliberate skip that a person still needs to know about. Clearing a lock box here does
  --    NOT blank it in Jobber (blanking a field from an unattended process is the most destructive
  --    write this path can make), so the driver keeps seeing a code that no longer applies. The
  --    row is recorded as skipped rather than dropped precisely so it can be surfaced here.
  with s as (
    select jsonb_build_object(
             'kind',   'outbound_skipped_clear:' || o.id::text,
             'issue',  'outbound_skipped_clear',
             'reason', coalesce(o.field_label, o.field_key) || ' was CLEARED here for ' || o.entity_type ||
                       ' ' || o.entity_id::text || ', and a clear is deliberately never pushed, so '
                       'Jobber still shows the old value to a driver. Clear it in Jobber too, or put '
                       'the value back here.',
             'queue_id',    o.id,
             'entity_type', o.entity_type,
             'entity_id',   o.entity_id,
             'field',       coalesce(o.field_label, o.field_key),
             'skipped_at',  o.processed_at) as item
      from sync.outbound_queue o
     where o.status = 'skipped'
  )
  select v_items || coalesce(jsonb_agg(item), '[]'::jsonb), count(*) into v_items, v_skipped from s;

  -- STEP 2 DRIFT COUNTERS. One statement, 15 scalar subqueries, each executed read-only
  -- against Prod before shipping and each reproducing its stated expected value exactly.
  -- 🛑 COUNT-ONLY. None of these appends to v_items and none influences v_total, so none can
  --    make this check alert. Fred asked for a week of numbers before any threshold is set.
  select
    (SELECT count(*) FROM raw.jobber_pull_visits r JOIN public.entity_source_links l ON l.entity_type='visit' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.visits v ON v.id = l.entity_id WHERE v.deleted_at IS NULL AND v.visit_status = 'completed' AND v.completed_at IS NOT NULL AND (nullif(r.data->>'completedAt','') IS NULL OR r.data->>'visitStatus' <> 'COMPLETED') AND v.visit_date >= date '2026-05-05'),
    (WITH crew AS (SELECT v.id, count(*) FILTER (WHERE n.value IS NOT NULL) AS j_mentions, coalesce(array_agg(DISTINCT el.entity_id) FILTER (WHERE el.entity_id IS NOT NULL), '{}') AS j_ids, coalesce((SELECT array_agg(DISTINCT t.employee_id ORDER BY t.employee_id) FROM public.visit_team t WHERE t.visit_id = v.id), '{}') AS our_ids FROM raw.jobber_pull_visits r JOIN public.entity_source_links l ON l.entity_type='visit' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.visits v ON v.id = l.entity_id LEFT JOIN LATERAL jsonb_array_elements(coalesce(r.data->'assignedUsers'->'nodes','[]'::jsonb)) n ON true LEFT JOIN public.entity_source_links el ON el.entity_type='employee' AND el.source_system='jobber' AND el.source_id = n->>'id' WHERE v.deleted_at IS NULL AND (r.data->>'completedAt') IS NOT NULL AND v.visit_date >= date '2026-08-01' GROUP BY v.id) SELECT count(*) FROM crew WHERE j_mentions <> coalesce(array_length(our_ids,1),0) OR (SELECT array_agg(x ORDER BY x) FROM unnest(j_ids) x) IS DISTINCT FROM our_ids),
    (SELECT count(*) FROM raw.jobber_pull_visits r WHERE nullif(r.data->>'startAt','') IS NOT NULL AND (r.data->>'startAt')::timestamptz >= now() - interval '90 days' AND EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(r.data->'assignedUsers'->'nodes','[]'::jsonb)) n WHERE NOT EXISTS (SELECT 1 FROM public.entity_source_links el WHERE el.entity_type='employee' AND el.source_system='jobber' AND el.source_id = n->>'id'))),
    (SELECT count(*) FROM raw.jobber_pull_visits r JOIN public.entity_source_links cl ON cl.entity_type='client' AND cl.source_system='jobber' AND cl.source_id = r.data->'client'->>'id' JOIN public.visits v ON v.client_id = cl.entity_id AND v.deleted_at IS NULL AND nullif(r.data->>'startAt','') IS NOT NULL AND v.start_at IS NOT NULL AND abs(extract(epoch FROM (v.start_at - nullif(r.data->>'startAt','')::timestamptz))) < 3600 WHERE NOT EXISTS (SELECT 1 FROM public.entity_source_links l2 JOIN public.visits v2 ON v2.id = l2.entity_id AND v2.deleted_at IS NULL WHERE l2.entity_type='visit' AND l2.source_system='jobber' AND l2.source_id = r.data->>'id') AND NOT EXISTS (SELECT 1 FROM public.entity_source_links l3 WHERE l3.entity_type='visit' AND l3.source_system='jobber' AND l3.entity_id = v.id)),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE (r.data->>'isArchived')::boolean IS TRUE AND c.status <> 'INACTIVE'),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE c.status = 'INACTIVE' AND (r.data->>'isArchived')::boolean IS FALSE AND coalesce(c.status_source,'') <> 'manual'),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE c.status = 'INACTIVE' AND (r.data->>'isArchived')::boolean IS FALSE AND coalesce(c.status_source,'') = 'manual'),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE c.client_class IS DISTINCT FROM (CASE WHEN (r.data->>'isCompany')::boolean THEN 'commercial' ELSE 'residential' END) AND coalesce(c.client_class_source,'') <> 'manual'),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE c.client_class IS DISTINCT FROM (CASE WHEN (r.data->>'isCompany')::boolean THEN 'commercial' ELSE 'residential' END) AND coalesce(c.client_class_source,'') = 'manual'),
    (SELECT count(*) FROM public.clients c JOIN public.entity_source_links l ON l.entity_type='client' AND l.source_system='jobber' AND l.entity_id = c.id JOIN raw.jobber_pull_clients r ON r.data->>'id' = l.source_id WHERE c.name IS DISTINCT FROM (SELECT CASE WHEN v ~ '^(.*)\s+-\s+[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+\s*$' THEN btrim(regexp_replace(v,'^(.*?)\s+-\s+[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+\s*$','\1')) WHEN v ~ '^(.*)[([]\s*[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+\s*[)\]]\s*$' THEN btrim(regexp_replace(v,'^(.*?)\s*[([]\s*[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+\s*[)\]]\s*$','\1')) WHEN v ~ '^\s*[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+[\s,:-]+.+$' THEN btrim(regexp_replace(v,'^\s*[0-9]{2,3}\s*-\s*[A-Za-z0-9&]+[\s,:-]+(.+)$','\1')) WHEN v ~ '^\s*[0-9]{3}-\s+' THEN btrim(regexp_replace(v,'^\s*[0-9]{3}-\s+','')) ELSE btrim(v) END FROM (SELECT coalesce(nullif(btrim(CASE WHEN (r.data->>'isCompany')::boolean THEN coalesce(r.data->>'companyName','') ELSE btrim(coalesce(r.data->>'firstName','')||' '||coalesce(r.data->>'lastName','')) END),''), nullif(r.data->>'companyName','')) AS v) q)),
    (SELECT count(*) FROM raw.jobber_pull_properties r JOIN public.entity_source_links l ON l.entity_type='property' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.properties p ON p.id = l.entity_id WHERE p.deleted_at IS NULL AND l.source_id NOT LIKE '%\_billing' AND p.grease_trap_size_gallons IS NULL AND coalesce((SELECT nullif(cf->>'valueNumeric','')::numeric FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzA2MTExMQ=='),0) <> 0),
    (SELECT count(*) FROM raw.jobber_pull_properties r JOIN public.entity_source_links l ON l.entity_type='property' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.properties p ON p.id = l.entity_id WHERE p.deleted_at IS NULL AND l.source_id NOT LIKE '%\_billing' AND p.grease_trap_size_gallons IS NOT NULL AND coalesce((SELECT nullif(cf->>'valueNumeric','')::numeric FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzA2MTExMQ=='),0) <> 0 AND p.grease_trap_size_gallons::numeric <> (SELECT nullif(cf->>'valueNumeric','')::numeric FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzA2MTExMQ==')),
    (SELECT count(*) FROM raw.jobber_pull_properties r JOIN public.entity_source_links l ON l.entity_type='property' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.properties p ON p.id = l.entity_id WHERE p.deleted_at IS NULL AND l.source_id NOT LIKE '%\_billing' AND coalesce(p.grease_trap_size_gallons,0) <> 0 AND (SELECT nullif(cf->>'valueNumeric','')::numeric FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvbk51bWVyaWMvMzA2MTExMQ==') = 0),
    (SELECT count(*) FROM raw.jobber_pull_properties r JOIN public.entity_source_links l ON l.entity_type='property' AND l.source_system='jobber' AND l.source_id = r.data->>'id' JOIN public.properties p ON p.id = l.entity_id WHERE p.deleted_at IS NULL AND l.source_id NOT LIKE '%\_billing' AND (SELECT nullif(btrim(cf->>'valueText'),'') FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvblRleHQvMzA2MTExMg==') IS NOT NULL AND (SELECT nullif(btrim(cf->>'valueText'),'') FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvblRleHQvMzA2MTExMg==') <> 'N/A' AND coalesce(p.lock_box_key,'') <> (SELECT nullif(btrim(cf->>'valueText'),'') FROM jsonb_array_elements(coalesce(r.data->'customFields','[]'::jsonb)) cf WHERE cf->'customFieldConfiguration'->>'id' = 'Z2lkOi8vSm9iYmVyL0N1c3RvbUZpZWxkQ29uZmlndXJhdGlvblRleHQvMzA2MTExMg==')),
    (SELECT count(*) FROM sync.source_field_shadow s JOIN public.properties p ON p.id = s.entity_id AND p.deleted_at IS NULL WHERE s.adopted_at IS NULL AND s.conflict_at IS NULL AND jsonb_typeof(s.our_value) = 'null' AND jsonb_typeof(s.source_value) IS DISTINCT FROM 'null' AND s.source_value::text NOT IN ('0','""','"N/A"'))
  into
    v_drift_visit_completion_lost,
    v_drift_visit_crew,
    v_unresolvable_jobber_user_90d,
    v_orphan_visit_shadow_match,
    v_drift_client_archived_not_inactive,
    v_drift_client_inactive_not_archived_unpinned,
    v_drift_client_inactive_not_archived_pinned,
    v_drift_client_class_unpinned,
    v_drift_client_class_pinned,
    v_drift_client_name,
    v_drift_property_grease_trap_jobber_only,
    v_drift_property_grease_trap_both_set,
    v_drift_property_grease_trap_ours_only,
    v_drift_property_lock_box,
    v_shadow_seeded_never_adopted;

  -- ==========================================================================================
  -- SYNC SURFACE HEALTH (added 2026-09-07)
  --
  -- WHY: everything above this line compares FIELD VALUES. None of it asks whether the syncs that
  -- produce those values are still running. They were not: sync-jobber-job-drift died on 30 of its
  -- last 671 runs over 14 days and nothing could tell anyone, because ops.v_health_items watches
  -- five sources and no Jobber sync surface was one of them.
  --
  -- 🛑 'attention' IS NOT A FAILURE. It means the check ran and FOUND something. jobber_visit_drift
  --    reads 'attention' on 70% of runs because it is finding drift, which is it working. The real
  --    failure statuses are 'partial' and 'error'. Testing status <> 'success' conflates the two and
  --    would report the healthiest reconciler in the estate as the sickest.
  -- 🛑 AND 'ok' IS A CLEAN WORD TOO (2026-09-16_2350). calendar-task-poll writes 'ok' / 'attention',
  --    never 'success', so the stuck arm's status <> 'success' would have called a healthy poll stuck
  --    on its fourth clean day. Its real failures are 'attention' rows that carry error_details, which
  --    the failed arm below now counts alongside 'partial' and 'error'.
  --
  -- Thresholds are measured, not chosen. Over the 14 days to 2026-09-06, worst single day of
  -- partial/error: job_drift 8, upcoming_visits 13, poll 2, note_photo 1. A bare count >= 2 would
  -- fire on the poll's 2-of-288 (0.7%), which is noise, so the rate arm is what excludes it while
  -- still catching job_drift at 8-of-48 (17%).
  with watched(src, stale_after) as (values
      ('jobber_poll_pgcron',            interval '25 minutes'),
      ('jobber_upcoming_visits_pgcron', interval '50 minutes'),
      ('jobber_job_drift',              interval '95 minutes'),
      ('jobber_visit_drift',            interval '95 minutes'),
      -- added 2026-09-09 with the reconciler itself, so the surface and its watchdog ship together.
      -- Cadence is 25 */6 * * *, so 7h allows exactly one missed run before it reads stale.
      ('jobber-invoice-drift',          interval '7 hours'),
      ('calendar-task-poll',            interval '25 minutes'),
      -- weekly (Sunday 07:15 UTC), read-only; 8 days allows one missed run before it reads stale.
      ('jobber-client-state-sweep',     interval '8 days'),
      -- ⚠ This one runs irregularly by design (max observed gap 731 minutes), so a staleness
      --    window would be a guess. NULL means "watch it for failures, never for lateness".
      ('jobber_note_photo_sync',        null::interval),
      -- Railway cron service (UnclogMe Timed Jobs), every 5 minutes; 30 minutes = 6 missed runs.
      ('railway_samsara_gps',           interval '30 minutes'),
      -- Railway cron service samsara-readings (tank sensors + truck events), every 5 minutes.
      ('railway_samsara_readings',      interval '30 minutes'),
      ('time_on_site_samsara_recheck',  interval '26 hours'),   -- 2026-10-14_1630: nightly 03:50 ET
      -- M7 (2026-10-12): the hourly stop-facts refresh (cron vehicle-stop-facts, :35) writes four sources;
      -- 2 hours = one missed run. Process failure and data findings are separate sources on purpose.
      ('stop_facts_refresh',            interval '2 hours'),
      ('tank_feed_freshness',           interval '2 hours'),
      ('stop_facts_integrity',          interval '2 hours'),
      ('tank_geometry_drift',           interval '2 hours'),
      -- 2026-10-13_1235: intake-task-sync (cron intake-task-sync, every 5 minutes); 25 minutes = 4 missed runs.
      ('intake_task_sync',              interval '25 minutes'),
      -- 2026-10-15_1150: Calendar grease freezer (cron calendar-grease-freeze, hourly at :05); 3 hours = 2 missed runs.
      ('calendar_grease_freeze',        interval '3 hours')
  ),
  agg as (
    select w.src, w.stale_after,
           count(*) filter (where l.started_at > now() - interval '24 hours')            as runs_24h,
           count(*) filter (where l.started_at > now() - interval '24 hours'
                              and (l.status in ('partial','error')
                                   or l.error_details is not null))                      as fails_24h,
           count(*) filter (where l.started_at > now() - interval '24 hours'
                              and coalesce(l.details->'error_samples'->>0, '')
                                  ilike '%Cannot read properties of undefined%')         as crash_24h,
           max(l.started_at)                                                             as last_run
      from watched w
      left join public.sync_log l
        on l.sync_source = w.src and l.started_at > now() - interval '30 days'
     group by w.src, w.stale_after
  ),
  grp as (
    select l.sync_source, l.status, l.started_at,
           row_number() over (partition by l.sync_source order by l.started_at desc)
         - row_number() over (partition by l.sync_source, l.status order by l.started_at desc) as g
      from public.sync_log l join watched w on w.src = l.sync_source
     where l.started_at > now() - interval '30 days'
  ),
  cur as (
    select sync_source, status, count(*) as runs, min(started_at) as since, max(started_at) as until
      from grp group by sync_source, status, g
  ),
  stuck as (
    -- The CURRENT streak only, and only if it is still the newest run for that source. A source that
    -- was stuck last week and recovered is not a finding.
    select c.* from cur c
     where c.status not in ('success', 'ok')
       and c.until = (select max(l3.started_at) from public.sync_log l3 where l3.sync_source = c.sync_source)
       and now() - c.since >= interval '72 hours'
       -- a weekly source reports through its own items; one 'attention' run is not a streak (2026-09-18)
       and c.sync_source <> 'jobber-client-state-sweep'
  ),
  findings as (
    select jsonb_build_object(
             'kind',   'sync_failed:' || a.src, 'issue', 'sync_failed', 'source', a.src,
             'fails_24h', a.fails_24h, 'runs_24h', a.runs_24h,
             'reason', 'The ' || a.src || ' sync failed ' || a.fails_24h || ' of its ' || a.runs_24h ||
                       ' runs in the last 24 hours (status partial or error, or a run that logged errors). Those runs did not '
                       'reconcile anything, so whatever drifted during them is still drifted.') as item
      from agg a
     where a.runs_24h > 0 and a.fails_24h >= 2 and a.fails_24h::numeric >= 0.02 * a.runs_24h
    union all
    select jsonb_build_object(
             'kind',   'sync_stalled:' || a.src, 'issue', 'sync_stalled', 'source', a.src,
             'last_run', a.last_run,
             'reason', 'The ' || a.src || ' sync has not run since ' ||
                       coalesce(to_char(a.last_run at time zone 'America/New_York', 'YYYY-MM-DD HH24:MI') || ' ET',
                                'never in the last 30 days') ||
                       ', which is past its expected interval. It is not merely slow, it has stopped.')
      from agg a
     where a.stale_after is not null and (a.last_run is null or now() - a.last_run > a.stale_after)
    union all
    select jsonb_build_object(
             'kind',   'sync_crash_regression:' || a.src, 'issue', 'sync_crash_regression', 'source', a.src,
             'occurrences_24h', a.crash_24h,
             'reason', 'The ' || a.src || ' sync logged the undefined-dereference crash signature ' ||
                       a.crash_24h || ' time(s) in 24 hours. This is the exact defect fixed on '
                       '2026-09-06 (a missing Jobber answer read as data), so treat it as a regression '
                       'and re-check the content-type and data-key guards in that function''s gql().')
      from agg a where a.crash_24h > 0
    union all
    select jsonb_build_object(
             'kind',   'sync_stuck:' || s.sync_source, 'issue', 'sync_stuck', 'source', s.sync_source,
             'streak_runs', s.runs, 'since', s.since,
             'reason', 'The ' || s.sync_source || ' sync has reported ''' || s.status || ''' on every one of '
                       'its last ' || s.runs || ' runs, continuously since ' ||
                       to_char(s.since at time zone 'America/New_York', 'YYYY-MM-DD HH24:MI') || ' ET. '
                       'It is running fine and reporting the same unresolved item over and over, which '
                       'nobody sees, because sync_log has no dedup. Resolve the item or it repeats forever.')
      from stuck s
  )
  select v_items || coalesce(jsonb_agg(f.item), '[]'::jsonb),
         count(*) filter (where f.item->>'issue' = 'sync_failed'),
         count(*) filter (where f.item->>'issue' = 'sync_stalled'),
         count(*) filter (where f.item->>'issue' = 'sync_stuck'),
         count(*) filter (where f.item->>'issue' = 'sync_crash_regression')
    into v_items, v_ss_failed, v_ss_stalled, v_ss_stuck, v_ss_crash
    from findings f;

  -- ==========================================================================================
  -- BILLING OBSERVATION (added 2026-09-07). COUNT-ONLY, BY DESIGN.
  -- Nothing here is appended to v_items or added to v_total, so it cannot alert, cannot change
  -- this check's status and cannot mail anyone. Fred's precedent for the 15 drift counters was a
  -- week of numbers before any threshold, and every phase-A finding is unresolvable by
  -- construction anyway: the only writer of those columns is fn_record_client_job, and the
  -- operator's obvious move (re-save in the Client App) derives billing from the job TITLE and
  -- pushes OUR value over Jobber's.
  --
  -- 🛑 THE VERDICT IS READ FIRST AND UNCONDITIONALLY. If the observer has never succeeded this
  --    reports NO_EVIDENCE rather than a comforting zero. A drift count taken from an empty or
  --    frozen observation table is silence from an instrument that never ran, which is this
  --    estate's single most-repeated defect.
  select f.verdict, coalesce(f.observed_job_ids, '{}')
    into v_bill_verdict, v_bill_ids
    from sync.v_billing_observation_freshness f;

  if v_bill_verdict is distinct from 'NO_EVIDENCE' then
    select
      count(*),
      count(*) filter (where not o.norm_ok),
      count(*) filter (where o.norm_ok and j.billing_type is null),
      count(*) filter (where o.norm_ok and j.billing_type is not null and (
             o.norm_billing_type is distinct from j.billing_type
          -- Compare the periodic CLASS, not the label. 'monthly_last_day' and 'custom' are both
          -- PERIODIC to Jobber, so comparing labels manufactures drift on a rule we ourselves
          -- accept. The cost is a known blind spot: a pure label divergence is invisible.
          or o.norm_periodic_class is distinct from case j.invoice_frequency
               when 'per_visit' then 'PER_VISIT' when 'once_closed' then 'ON_COMPLETION'
               when 'as_needed' then 'NEVER' else 'PERIODIC' end
          -- BOTH sides canonicalised: our stored bytes are Jobber's own part order and are NOT
          -- canonical, so a raw compare reports false drift on 24 live rows.
          or sync.fn_canonical_rrule(o.norm_invoice_rrule)
             is distinct from sync.fn_canonical_rrule(j.invoice_rrule)))
      into v_bill_observed, v_bill_unmapped, v_bill_neverconf, v_bill_drift
      from sync.jobber_billing_observed o
      join public.jobs j on j.id = o.job_id
     -- Only rows the LAST SUCCESSFUL run actually saw. A stale row is not evidence, and this is
     -- what stops a half-drained sweep leaving old observations to be read as current.
     where o.job_id = any(v_bill_ids);
  end if;

  -- N. A ROW NO JOBBER SYNC CAN EVER REACH AGAIN. It has no entity_source_links row, so every
  --    handler resolves its Jobber GID to a DIFFERENT row and this one is frozen where it stands:
  --    it can never receive an update, a job, a visit or an invoice, and it never self-heals.
  --
  --    🛑 THIS EXISTS BECAUSE NOTHING COULD SEE IT. weekly_dedup_audit.js has three detectors and
  --    all three are structurally blind to this shape: #1 filters client_code IS NOT NULL (an
  --    orphan's is NULL), #2 joins properties (an orphan has none), and #3 selects FROM
  --    entity_source_links, so it can only ever see rows that HAVE a link -- the exact complement
  --    of the defect. Measured 2026-09-08: those three returned 4 / 65 / 465 rows overall and
  --    0 of the 8 orphans. The audit ran 2026-09-06 and reported nothing while Bibi's burgers sat
  --    in the Client App as four rows.
  --
  --    The cause was fixed the same day for CLIENTS (fn_jobber_resolve_client, migration
  --    2026-09-08_1100). It is NOT yet fixed for invoices or quotes, which is exactly why this
  --    detector is generic over the entity types rather than hard-wired to clients.
  --
  --    ⚠ THE FLOOR IS THE REGIME CHANGE, NOT AN ARBITRARY DATE. Real Jobber webhooks began
  --      working 2026-08-21 (the nested-payload fix), which is when a second concurrent driver
  --      joined the */5 poll. Rows older than that are a different, closed story and are counted
  --      separately as link_orphans_legacy so they cannot cause daily noise -- but they are still
  --      COUNTED, so they can never silently disappear either.
  declare
    r_ent   record;
    v_n     bigint;
    v_rows  jsonb;
  begin
    for r_ent in
      -- 🛑 THE 4th COLUMN IS NOT DECORATION. "Unlinked" only means ORPHAN for an entity we
      --    NEVER create ourselves. Measured 2026-09-08, link coverage by visits.source:
      --      jobber         795 rows, 99.7% linked  <- an unlinked one here IS suspicious
      --      supabase_cron 1000 rows, 47.9% linked  <- NORMAL: SA-generated, waiting on
      --                                                sa-visit-promote. Not orphans.
      --      visit-calendar 199 rows, 96.0% linked  <- the unlinked ones are cancelled before
      --                                                they were ever pushed
      --      manual           3 rows,  0.0% linked  <- never pushed, by design
      --    Without this filter the detector reported 202 orphans, of which 136 were our own
      --    unpushed visits. A check that cries wolf 136 times a day buries the 66 real ones, so
      --    the filter is what makes the number worth reading at all.
      --    Clients / invoices / quotes / jobs need no filter: Jobber masters them and the only
      --    writer is the matching handle* in webhook-jobber.
      --    Properties need none EITHER, but only since 2026-08-21: client.create_property used to
      --    mint DB-only rows with no link and now RAISES 22023, so every property created after
      --    the floor goes through save-client-property -> Jobber first -> handleProperty.
      select * from (values
        ('client','public.clients',false,''), ('invoice','public.invoices',false,''),
        ('quote','public.quotes',false,''),   ('job','public.jobs',false,''),
        ('property','public.properties',true,''),
        ('visit','public.visits',true,'and t.source = ''jobber'' and t.visit_status not in (''completed'',''skipped'')')
      ) as t(entity_type, tbl, has_deleted, extra_where)
    loop
      -- Cap the sample at 25 per entity and SAY SO in details. A silent cap reads as -that is all
      -- of them-, which is the same lie this detector exists to stop.
      execute format($q$
        select count(*), coalesce(jsonb_agg(x.item) filter (where x.rn <= 25), '[]'::jsonb)
          from (
            select row_number() over (order by t.created_at desc) rn,
                   jsonb_build_object(
                     'kind',   'jobber_link_orphan:%1$s:' || t.id::text,
                     'issue',  'jobber_link_orphan',
                     'entity_type', '%1$s',
                     'entity_id',   t.id,
                     'created_at',  t.created_at,
                     'reason', 'This %1$s row has no entity_source_links row for Jobber, so no sync '
                               'can ever find it again: every handler resolves the Jobber id to a '
                               'different row. It was almost certainly created by two handlers '
                               'racing on the same Jobber object. It is invisible debris, not a '
                               'customer record - look for a twin with the same name, and remove '
                               'this one.') as item
              from %2$s t
             where not exists (select 1 from public.entity_source_links e
                                where e.entity_type = '%1$s' and e.entity_id = t.id
                                  and e.source_system = 'jobber')
               and t.created_at >= timestamptz '2026-08-21 00:00:00+00'
               %3$s %4$s
          ) x $q$,
        r_ent.entity_type, r_ent.tbl,
        case when r_ent.has_deleted then 'and t.deleted_at is null' else '' end,
        r_ent.extra_where)
      into v_n, v_rows;

      v_link_orphans := v_link_orphans + v_n;
      v_link_shown   := v_link_shown + least(v_n, 25);
      v_items := v_items || v_rows;

      execute format($q$
        select count(*) from %2$s t
         where not exists (select 1 from public.entity_source_links e
                            where e.entity_type = '%1$s' and e.entity_id = t.id
                              and e.source_system = 'jobber')
           and t.created_at < timestamptz '2026-08-21 00:00:00+00'
           %3$s %4$s$q$,
        r_ent.entity_type, r_ent.tbl,
        case when r_ent.has_deleted then 'and t.deleted_at is null' else '' end,
        r_ent.extra_where)
      into v_n;
      v_link_legacy := v_link_legacy + v_n;
    end loop;
  end;
  -- M7 (2026-10-12): TANK SENSOR BUSINESS FLAGS, COUNT-ONLY like the billing observation above. Not in
  --    v_items, not in v_total: it cannot alert or mail anyone. The verdict is read FIRST, so a refresh
  --    that never ran reads NO_EVIDENCE and an old one STALE, never a comforting zero.
  select case when max(l.started_at) is null then 'NO_EVIDENCE'
              when max(l.started_at) < now() - interval '2 hours' then 'STALE' else 'CURRENT' end
    into v_tank_verdict
    from public.sync_log l where l.sync_source = 'stop_facts_refresh' and l.status = 'success';
  if v_tank_verdict is distinct from 'NO_EVIDENCE' then
    select jsonb_build_object('F1', l.details->'flags'->'F1', 'F1b', l.details->'flags'->'F1b',
                              'F3', l.details->'flags'->'F3')
      into v_tank_flags
      from public.sync_log l where l.sync_source = 'stop_facts_refresh' and l.status = 'success'
     order by l.started_at desc limit 1;
  end if;

  v_total := v_conflict + v_stuck + v_skipped + v_ss_failed + v_ss_stalled + v_ss_stuck + v_ss_crash + v_link_orphans;

  -- ðŸ›‘ clock_timestamp(), NOT now(). now() is the TRANSACTION timestamp, so two runs inside one
  --    transaction get identical started_at values and ops.v_health_items' DISTINCT ON ... ORDER BY
  --    started_at DESC ties between them, silently returning the wrong run. That is not theoretical:
  --    this migration's own positive control hit it and reported "the conflict did not reach
  --    ops.v_health_items", which reads exactly like a missed registration site. The siblings use
  --    now() only because cron calls them once per transaction. The ordering key has to be able to
  --    tell two runs apart.
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('jobber-sync-health', clock_timestamp(), clock_timestamp(), v_total,
          case when v_total > 0 then 'attention' else 'ok' end,
          jsonb_build_object(
            'shadow_conflicts',       v_conflict,
            'outbound_stuck',         v_stuck,
            'outbound_skipped_clear', v_skipped,
            'items',                  v_items,
            'drift_visit_completion_lost',  v_drift_visit_completion_lost,
            'drift_visit_crew',         v_drift_visit_crew,
            'unresolvable_jobber_user_90d',  v_unresolvable_jobber_user_90d,
            'orphan_visit_shadow_match',  v_orphan_visit_shadow_match,
            'drift_client_archived_not_inactive',  v_drift_client_archived_not_inactive,
            'drift_client_inactive_not_archived_unpinned',  v_drift_client_inactive_not_archived_unpinned,
            'drift_client_inactive_not_archived_pinned',  v_drift_client_inactive_not_archived_pinned,
            'drift_client_class_unpinned',  v_drift_client_class_unpinned,
            'drift_client_class_pinned',  v_drift_client_class_pinned,
            'drift_client_name',        v_drift_client_name,
            'drift_property_grease_trap_jobber_only',  v_drift_property_grease_trap_jobber_only,
            'drift_property_grease_trap_both_set',  v_drift_property_grease_trap_both_set,
            'drift_property_grease_trap_ours_only',  v_drift_property_grease_trap_ours_only,
            'drift_property_lock_box',  v_drift_property_lock_box,
            'shadow_seeded_never_adopted',  v_shadow_seeded_never_adopted,
            'link_orphans',            v_link_orphans,
            'link_orphans_listed',     v_link_shown,
            'link_orphans_legacy',     v_link_legacy,
            'sync_surface_failed',    v_ss_failed,
            'sync_surface_stalled',   v_ss_stalled,
            'sync_surface_stuck',     v_ss_stuck,
            'sync_surface_crash',     v_ss_crash,
            -- Count-only. Deliberately NOT in items and NOT in v_total: see the block above.
            'billing_observation',     v_bill_verdict,
            'billing_observed',        v_bill_observed,
            'billing_drift',           v_bill_drift,
            'billing_unmappable',      v_bill_unmapped,
            'billing_never_confirmed', v_bill_neverconf,
            -- M7: count-only, deliberately NOT in items and NOT in v_total.
            'tank_flags_observation', v_tank_verdict,
            'tank_flags',             v_tank_flags,
            -- Coverage is stated on every run so a clean verdict can never be read as
            -- "the whole Jobber sync is healthy". It is not: it is two fields.
            'covers', 'It also counts rows carrying NO entity_source_links row for Jobber across clients, invoices, quotes, jobs, properties and visits - rows no sync can ever reach again. That half is keyed on the LINK, not on any column, and is the one check weekly_dedup_audit.js cannot make: its stale-GID detector selects FROM entity_source_links and so can only see rows that already have one. At most 25 per entity are listed; link_orphans is the true count and link_orphans_listed is how many are shown. SEPARATELY it compares 13 columns of 93 across four Jobber-synced entities (visits 3 of 36, clients 4 '
                      'of 12, properties 2 of 28, jobs 0 of 17) against the payload the poll already staged, never '
                      'against live Jobber: 1,173 of 1,972 live visits are comparable at all and only 214 fall '
                      'inside the crew era floor, 462 of 473 clients, 477 of 939 properties, and 0 jobs; and '
                      'because the visits poll pages Jobber by completion time, the staged payload can only ever '
                      'contain COMPLETED visits, so a scheduled visit, any Jobber-side edit made after a visit '
                      'completed, and every job field are structurally invisible here - a zero on this report is a '
                      'zero on what it looks at, not an all-clear on the Jobber sync. '
                      'SEPARATELY it now also watches whether seven Jobber sync surfaces are still '
                      'RUNNING (failed / stalled / stuck / crash-signature). That half is about the '
                      'pipes, not the values, and it is deliberately blind to any sync surface not '
                      'named in its watched list. ',
            'what_it_means', case when v_total > 0
              then 'Something in the two-way sync needs a person. A shadow_conflict means both sides '
                   'changed and neither value was copied - nothing is blocked, the app works, the two '
                   'systems just stay different until someone makes them agree. An outbound_stuck '
                   'means a change made here never reached Jobber. An outbound_skipped_clear means a '
                   'field was emptied here and Jobber still shows the old value.'
              else 'No unresolved conflicts, no stuck pushes, no skipped clears on the two two-way fields.' end));

  return v_total;
end $function$;

create or replace view ops.v_health_items as
 WITH latest AS (
         SELECT DISTINCT ON (l.sync_source) l.sync_source,
            l.status,
            l.started_at,
            l.details
           FROM sync_log l
          WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'note-photo-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'db-backup-health'::text, 'notification-health'::text])
          ORDER BY l.sync_source, l.started_at DESC
        )
 SELECT la.sync_source AS check_name,
    la.status,
    la.started_at AS last_run_at,
    COALESCE(i.value ->> 'visit_id'::text, i.value ->> 'dump_folder'::text, i.value ->> 'kind'::text, i.value ->> 'client_code'::text, i.value::text) AS item_key,
    i.value AS item
   FROM latest la
     CROSS JOIN LATERAL jsonb_array_elements(
        CASE la.sync_source
            WHEN 'calendar-push-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'blackout-health'::text THEN COALESCE(la.details -> 'sheets'::text, '[]'::jsonb)
            WHEN 'rpa-derm-health'::text THEN COALESCE(la.details -> 'reasons'::text, '[]'::jsonb)
            WHEN 'sa-schedule-gap-check'::text THEN COALESCE(la.details -> 'sample'::text, '[]'::jsonb)
            WHEN 'jobber-sync-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'note-photo-sync-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'jobber-client-state-sweep'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'start-flags-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'db-backup-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            WHEN 'notification-health'::text THEN COALESCE(la.details -> 'items'::text, '[]'::jsonb)
            ELSE '[]'::jsonb
        END) i(value);

create or replace view ops.v_health_status as
 WITH runs AS (
         SELECT l.id,
            l.sync_source,
            l.status,
            l.started_at,
            l.rows_errored,
            l.details,
            row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC) AS rn,
                CASE l.sync_source
                    WHEN 'calendar-push-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'blackout-health'::text THEN COALESCE(l.details -> 'sheets'::text, '[]'::jsonb)
                    WHEN 'rpa-derm-health'::text THEN COALESCE(l.details -> 'reasons'::text, '[]'::jsonb)
                    WHEN 'sa-schedule-gap-check'::text THEN COALESCE(l.details -> 'sample'::text, '[]'::jsonb)
                    WHEN 'jobber-sync-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'jobber-client-state-sweep'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'start-flags-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'note-photo-sync-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'db-backup-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    WHEN 'notification-health'::text THEN COALESCE(l.details -> 'items'::text, '[]'::jsonb)
                    ELSE '[]'::jsonb
                END AS raw_items
           FROM sync_log l
          WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'note-photo-sync-health'::text, 'db-backup-health'::text, 'notification-health'::text])
        ), keyed AS (
         SELECT r.id,
            r.sync_source,
            r.status,
            r.started_at,
            r.rows_errored,
            r.details,
            r.rn,
            r.raw_items,
            COALESCE(( SELECT jsonb_agg(DISTINCT COALESCE(i.value ->> 'visit_id'::text, i.value ->> 'dump_folder'::text, i.value ->> 'kind'::text, i.value ->> 'client_code'::text, i.value::text)) AS jsonb_agg
                   FROM jsonb_array_elements(r.raw_items) i(value)), '[]'::jsonb) AS item_keys
           FROM runs r
          WHERE r.rn <= 2
        ), streak AS (
         SELECT g.sync_source,
            g.status,
            count(*) AS runs_in_streak,
            min(g.started_at) AS streak_started_at
           FROM ( SELECT l.sync_source,
                    l.status,
                    l.started_at,
                    row_number() OVER (PARTITION BY l.sync_source ORDER BY l.started_at DESC) - row_number() OVER (PARTITION BY l.sync_source, l.status ORDER BY l.started_at DESC) AS grp
                   FROM sync_log l
                  WHERE l.sync_source = ANY (ARRAY['calendar-push-health'::text, 'blackout-health'::text, 'rpa-derm-health'::text, 'sa-schedule-gap-check'::text, 'jobber-sync-health'::text, 'jobber-client-state-sweep'::text, 'start-flags-health'::text, 'note-photo-sync-health'::text, 'db-backup-health'::text, 'notification-health'::text])) g
          GROUP BY g.sync_source, g.status, g.grp
         HAVING max(g.started_at) = (( SELECT max(l2.started_at) AS max
                   FROM sync_log l2
                  WHERE l2.sync_source = g.sync_source))
        ), cur AS (
         SELECT keyed.id,
            keyed.sync_source,
            keyed.status,
            keyed.started_at,
            keyed.rows_errored,
            keyed.details,
            keyed.rn,
            keyed.raw_items,
            keyed.item_keys
           FROM keyed
          WHERE keyed.rn = 1
        ), prev AS (
         SELECT keyed.id,
            keyed.sync_source,
            keyed.status,
            keyed.started_at,
            keyed.rows_errored,
            keyed.details,
            keyed.rn,
            keyed.raw_items,
            keyed.item_keys
           FROM keyed
          WHERE keyed.rn = 2
        )
 SELECT c.sync_source AS check_name,
    c.status,
    c.started_at AS last_run_at,
    jsonb_array_length(c.item_keys) AS item_count,
    COALESCE(jsonb_array_length(p.item_keys), 0) AS item_count_previous_run,
    c.rows_errored AS rows_errored_raw,
    ( SELECT COALESCE(jsonb_agg(k.value), '[]'::jsonb) AS "coalesce"
           FROM jsonb_array_elements(c.item_keys) k(value)
          WHERE NOT COALESCE(p.item_keys, '[]'::jsonb) @> jsonb_build_array(k.value)) AS new_items,
    ( SELECT COALESCE(jsonb_agg(k.value), '[]'::jsonb) AS "coalesce"
           FROM jsonb_array_elements(COALESCE(p.item_keys, '[]'::jsonb)) k(value)
          WHERE NOT c.item_keys @> jsonb_build_array(k.value)) AS resolved_items,
    c.item_keys = COALESCE(p.item_keys, '[]'::jsonb) AS unchanged_since_last_run,
    s.runs_in_streak AS consecutive_runs_same_status,
    s.streak_started_at AS status_since,
    c.details
   FROM cur c
     LEFT JOIN prev p ON p.sync_source = c.sync_source
     LEFT JOIN streak s ON s.sync_source = c.sync_source AND s.status = c.status;

drop function public.fn_time_on_site_reminder_hold(timestamptz);
drop function public.log_samsara_feed_health(timestamptz, boolean);
drop function public.fn_samsara_data_complete_through(text, timestamptz);
drop function public.fn_samsara_gps_open_holes(timestamptz, integer);

do $verify$ begin
  if exists (select 1 from cron.job where jobname = 'samsara-feed-health') then raise exception 'cron still there'; end if;
  if exists (select 1 from ops.v_health_status where check_name = 'samsara-feed-health') then raise exception 'still registered'; end if;
  if to_regprocedure('public.fn_samsara_data_complete_through(text, timestamptz)') is not null then raise exception 'helper still there'; end if;
  if not exists (select 1 from cron.job where jobname = 'time-on-site-reminder' and schedule = '0 15,16 * * *') then raise exception 'reminder schedule not restored'; end if;
end $verify$;

COMMIT;
