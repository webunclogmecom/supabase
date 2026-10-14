-- ============================================================================
-- 2026-10-14_1110 Time on site, step 8: checks so it cannot go wrong silently again
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-14: "go ahead with step 8" (plan samsara-checks/time_on_site_fix_plan_2026-10-13.md, outside the repos).
--
-- WHAT CHANGES
--   1. public.fn_time_on_site_checks(): T1..T6, each must be 0, with the visit ids in T_detail.
--      T1 a recent visit (3 to 10 days, after the nightly fill) whose stop holds the completion has no time or one far
--         too short; T2 the 6509 positive control (its 34 min stop and its saved 31 to 35 min); T3 a time written
--         without a source or reason (24 h); T4 a stop-based or reviewed time overwritten by a GPS fallback; T5 the 11 AM
--         alert's own instrument misses a stop the stop table has (yesterday); T6 a visit that is not completed still
--         carries a time.
--   2. fn_stop_facts_checks merges them into its integrity set; fn_refresh_stop_facts (hourly, cron 141) counts them,
--      so stop_facts_integrity turns error and log_jobber_sync_health raises it to the health email.
--   Measured at apply: all six read 0. T3 counts from 2026-10-14 02:00 UTC, when step 2 labelled the writers (the
--   five unlabelled writes of the 2026-10-13 11 AM run predate it).
--   The monthly check against Samsara is scripts/checks/time_on_site_audit.mjs over the previous month (no scheduler:
--   GitHub timed jobs are unreliable until TIMED_JOBS_PLAN.md moves them).
-- ROLLBACK: restore fn_stop_facts_checks and fn_refresh_stop_facts from 2026-10-13_2210 and drop fn_time_on_site_checks.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF (SELECT md5(pg_get_functiondef('public.fn_stop_facts_checks'::regproc))) IS DISTINCT FROM 'a428b744c4cbe94643e6220dfa0b47f7'
     OR (SELECT md5(pg_get_functiondef('public.fn_refresh_stop_facts'::regproc))) IS DISTINCT FROM 'd796072a91bd0addba97c593c89d63ba' THEN
    RAISE EXCEPTION 'fn_stop_facts_checks or fn_refresh_stop_facts changed since this file was written: splice again'; END IF;
END $g$;

CREATE FUNCTION public.fn_time_on_site_checks()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO ''
AS $f$
-- 2026-10-14_1110 (time on site plan step 8): the checks that keep the time on site honest. Each must read 0; they ride
-- in fn_stop_facts_checks' integrity set, so fn_refresh_stop_facts (hourly) writes stop_facts_integrity as error when one
-- is not, and log_jobber_sync_health raises it to the health email. T_detail names the visits (never counted).
DECLARE
  v_today date := (now() at time zone 'America/New_York')::date;
  v_since timestamptz := greatest(now() - interval '24 hours', timestamptz '2026-10-14 02:00+00');   -- writers labelled from step 2
  t1 bigint[]; t3 bigint[]; t4 bigint[]; t5 bigint[]; t6 bigint[]; t2 int; g jsonb;
BEGIN
  -- T1 a client visit from 3 to 10 days ago (the nightly fill has run) whose truck stop holds the completion, but its
  --    time is blank or under 70% of the stop and at least 5 min shorter
  SELECT array_agg(v.id ORDER BY v.id) INTO t1
    FROM public.visits v JOIN public.v_visit_stop_reference r ON r.visit_id = v.id AND r.basis = 'completion' AND r.split_ok
   WHERE v.visit_status = 'completed' AND v.deleted_at IS NULL AND NOT public.fn_is_non_customer(v.client_id)
     AND v.visit_date BETWEEN v_today - 10 AND v_today - 3
     AND coalesce(v.time_on_site_source, '') NOT IN ('review', 'reviewed_blank')
     AND (v.duration_minutes IS NULL
          OR (v.duration_minutes < 0.7 * extract(epoch FROM r.departure - r.arrival) / 60
              AND extract(epoch FROM r.departure - r.arrival) / 60 - v.duration_minutes >= 5));
  -- T2 positive control: visit 6509 (the truck parked 164 m from the map point) keeps its 34 min stop. Fires if the
  --    matching rule is narrowed again.
  t2 := CASE WHEN EXISTS (SELECT 1 FROM public.v_visit_stop_reference r JOIN public.visits v ON v.id = r.visit_id
                           WHERE r.visit_id = 6509 AND r.basis = 'completion'
                             AND r.arrival = timestamptz '2026-09-25 14:29:11+00' AND r.departure = timestamptz '2026-09-25 15:02:59+00'
                             AND v.duration_minutes BETWEEN 31 AND 35) THEN 0 ELSE 1 END;
  -- T3 a time on site written without a source or a reason (in the last 24 hours)
  SELECT array_agg(DISTINCT (a.record_pk->>'id')::bigint) INTO t3 FROM audit.logs a
   WHERE a.table_name = 'visits' AND a.changed_at > v_since
     AND a.new_row->>'duration_minutes' IS NOT NULL AND a.new_row->>'duration_minutes' IS DISTINCT FROM a.old_row->>'duration_minutes'
     AND (a.new_row->>'time_on_site_source' IS NULL OR coalesce(a.request_context->>'change_reason', '') = '');
  -- T4 a stop-based or reviewed time overwritten by a GPS fallback (ever, since the source column exists)
  SELECT array_agg(DISTINCT (a.record_pk->>'id')::bigint) INTO t4 FROM audit.logs a
   WHERE a.table_name = 'visits' AND a.changed_at > timestamptz '2026-10-14 01:00+00'
     AND a.old_row->>'time_on_site_source' IN ('stop_at_completion', 'dump_site_dwell', 'review', 'reviewed_blank')
     AND a.new_row->>'time_on_site_source' IN ('gps_150m_cluster', 'gps_150m_any_truck');
  -- T5 the 11 AM alert's instrument misses a stop the stop table has (yesterday's blanks): the alert would say
  --    "passed by" or "no truck" about a truck that was parked there
  g := public.fn_time_on_site_gaps(v_today - 1);
  SELECT array_agg((x->>'visit_id')::bigint) INTO t5 FROM jsonb_array_elements(coalesce(g->'visits', '[]')) x
   WHERE (x->'stop_at_completion' IS NULL OR jsonb_typeof(x->'stop_at_completion') = 'null')
     AND EXISTS (SELECT 1 FROM public.v_visit_stop_reference r WHERE r.visit_id = (x->>'visit_id')::bigint AND r.basis = 'completion');
  -- T6 a visit that is not completed still carries a time on site
  SELECT array_agg(v.id ORDER BY v.id) INTO t6 FROM public.visits v
   WHERE v.deleted_at IS NULL AND v.visit_status <> 'completed'
     AND (v.duration_minutes IS NOT NULL OR v.actual_arrival_at IS NOT NULL OR v.actual_departure_at IS NOT NULL);
  RETURN jsonb_build_object('T1', coalesce(cardinality(t1), 0), 'T2', t2, 'T3', coalesce(cardinality(t3), 0),
    'T4', coalesce(cardinality(t4), 0), 'T5', coalesce(cardinality(t5), 0), 'T6', coalesce(cardinality(t6), 0),
    'T_detail', jsonb_build_object('T1', t1, 'T3', t3, 'T4', t4, 'T5', t5, 'T6', t6));
END $f$;
REVOKE ALL ON FUNCTION public.fn_time_on_site_checks() FROM public, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_time_on_site_checks() TO service_role;
COMMENT ON FUNCTION public.fn_time_on_site_checks() IS 'Time on site checks T1..T6, each must be 0 (2026-10-14_1110, plan step 8). Read by fn_stop_facts_checks; fn_refresh_stop_facts counts them in stop_facts_integrity.';

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
                            or ops.fn_haversine_km(vp.latitude, vp.longitude, s.latitude, s.longitude) * 1000
                               > case when l.match_basis in ('completion', 'completion_chain') then 250 else 150 end))
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

  -- 2026-10-14_1110: the time on site checks T1..T6 (fn_time_on_site_checks) ride in the integrity set
  return jsonb_build_object('integrity', z || public.fn_time_on_site_checks(), 'feed', t, 'flags', f, 'checked_at', now());
end $function$
;

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
end $function$
;

DO $v$
DECLARE j jsonb; k text; vid bigint;
BEGIN
  -- V1 everything reads 0 today, through the hourly entry point
  j := public.fn_stop_facts_checks()->'integrity';
  FOREACH k IN ARRAY array['T1','T2','T3','T4','T5','T6'] LOOP
    IF (j->>k)::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'V1: % reads %: %', k, j->>k, j->'T_detail'; END IF;
  END LOOP;
  -- V2 each check fires on purpose (rolled back)
  BEGIN   -- T1: blank a recent visit that has a stop
    SELECT r.visit_id INTO vid FROM public.v_visit_stop_reference r JOIN public.visits v ON v.id = r.visit_id
     WHERE r.basis = 'completion' AND r.split_ok AND v.visit_status = 'completed' AND v.duration_minutes IS NOT NULL
       AND NOT public.fn_is_non_customer(v.client_id)
       AND v.visit_date BETWEEN (now() at time zone 'America/New_York')::date - 10 AND (now() at time zone 'America/New_York')::date - 3
     ORDER BY r.visit_id LIMIT 1;
    IF vid IS NULL THEN RAISE EXCEPTION 'V2: no visit to test T1 on'; END IF;
    UPDATE public.visits SET duration_minutes = NULL, actual_arrival_at = NULL, actual_departure_at = NULL WHERE id = vid;
    IF (public.fn_time_on_site_checks()->>'T1')::int < 1 THEN RAISE EXCEPTION 'V2: T1 did not fire'; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0901', MESSAGE = 'rolled back';
  EXCEPTION WHEN SQLSTATE 'P0901' THEN NULL; END;
  BEGIN   -- T2 and T3: 6509 written to 10 min with no label
    UPDATE public.visits SET duration_minutes = 10 WHERE id = 6509;
    j := public.fn_time_on_site_checks();
    IF (j->>'T2')::int <> 1 OR (j->>'T3')::int < 1 THEN RAISE EXCEPTION 'V2: T2/T3 did not fire %', j; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0901', MESSAGE = 'rolled back';
  EXCEPTION WHEN SQLSTATE 'P0901' THEN NULL; END;
  BEGIN   -- T4: a stop-based value overwritten by the 150 m measurement
    UPDATE public.visits SET time_on_site_source = 'gps_150m_cluster' WHERE id = 6509;
    IF (public.fn_time_on_site_checks()->>'T4')::int < 1 THEN RAISE EXCEPTION 'V2: T4 did not fire'; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0901', MESSAGE = 'rolled back';
  EXCEPTION WHEN SQLSTATE 'P0901' THEN NULL; END;
  BEGIN   -- T6: a scheduled visit with a time
    UPDATE public.visits SET duration_minutes = 30 WHERE id = (SELECT id FROM public.visits WHERE visit_status = 'scheduled' AND deleted_at IS NULL ORDER BY id LIMIT 1);
    IF (public.fn_time_on_site_checks()->>'T6')::int < 1 THEN RAISE EXCEPTION 'V2: T6 did not fire'; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0901', MESSAGE = 'rolled back';
  EXCEPTION WHEN SQLSTATE 'P0901' THEN NULL; END;
  -- V3 the hourly refresh counts the T keys
  IF strpos(pg_get_functiondef('public.fn_refresh_stop_facts'::regproc), '''T1'',''T2'',''T3'',''T4'',''T5'',''T6''') = 0 THEN
    RAISE EXCEPTION 'V3: refresh does not count T'; END IF;
  IF has_function_privilege('authenticated', 'public.fn_time_on_site_checks()', 'EXECUTE') THEN RAISE EXCEPTION 'V4: grants'; END IF;
END $v$;

COMMIT;
