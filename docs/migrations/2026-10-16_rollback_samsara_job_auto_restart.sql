-- ============================================================================
-- ROLLBACK of 2026-10-16_0945_samsara_job_auto_restart.sql
-- ============================================================================
-- Puts back public.log_samsara_feed_health as 2026-10-15_2230 left it (dumped from Prod 2026-10-16 09:44 ET) and drops the two
-- restart functions. The vault secret railway_timed_jobs_token and the samsara-job-restart* sync_log rows stay; delete the
-- secret by hand (and the token in Railway) if the restart is retired for good.

BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE OR REPLACE FUNCTION public.log_samsara_feed_health(p_as_of timestamp with time zone DEFAULT now(), p_write boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-15_2230. Every 10 minutes (pg_cron samsara-feed-health). Items (key = kind), each with reason + what_to_do:
--   feed_stale:<railway source>  no good run of that Railway service in 20 minutes
--   gps_dropped_span:<from>      GPS never fetched for a span (an outage longer than the job's 7-day look-back)
--   gps_silent:vehicle-<id>      while GPS is otherwise live: engine running in the last 6 h, more than 30 min after
--                                the truck's last stored GPS point
-- Writes one sync_log row (source samsara-feed-health, status success | attention). Fast lane: a never-emailed item,
-- or an open one gone for 2 runs in a row, calls fn_request_health_escalation() now (it emails only NEW items).
-- p_write false = compute only (tests, or a look by hand).
declare
  v_started  timestamptz := clock_timestamp();
  v_items    jsonb;
  v_feeds    jsonb;
  v_prev     jsonb;
  v_call     boolean := false;
  v_gps_live boolean;
  et constant text := 'America/New_York';
begin
  -- the GPS FEED is live (a good run in the last 20 minutes), whatever old hole is still open
  select exists (select 1 from public.sync_log sl
                  where sl.sync_source in ('railway_samsara_gps', 'github_samsara_gps') and sl.status = 'success'
                    and coalesce(sl.details->'summary'->>'resume_point', 'true') = 'true'
                    and sl.started_at > p_as_of - interval '20 minutes' and sl.started_at <= p_as_of)
    into v_gps_live;
  with feeds(source, fallback, service, workflow, label) as (
         values ('railway_samsara_gps',      'github_samsara_gps',      'samsara-gps',      'Samsara GPS (fallback)',           'GPS points'),
                ('railway_samsara_readings', 'github_samsara_readings', 'samsara-readings', 'Samsara tank readings (fallback)', 'tank and engine readings')),
       f as (
         select fd.*,
                (select max(sl.started_at) from public.sync_log sl
                  where sl.sync_source = fd.source and sl.status = 'success'
                    and coalesce(sl.details->'summary'->>'resume_point', 'true') = 'true'
                    and sl.started_at <= p_as_of) as last_good,
                (select max(sl.started_at) from public.sync_log sl
                  where sl.sync_source = fd.source and sl.started_at <= p_as_of) as last_run,
                (select max(sl.started_at) from public.sync_log sl
                  where sl.sync_source = fd.fallback and sl.status = 'success'
                    and coalesce(sl.details->'summary'->>'resume_point', 'true') = 'true'
                    and sl.started_at <= p_as_of) as fallback_good,
                (select string_agg(x->>'stream', ', ')
                   from jsonb_array_elements(
                          (select case when jsonb_typeof(sl.details->'summary'->'skipped_streams') = 'array'
                                       then sl.details->'summary'->'skipped_streams' else '[]'::jsonb end
                             from public.sync_log sl
                            where sl.sync_source = fd.source and sl.started_at <= p_as_of
                            order by sl.started_at desc limit 1)) x) as skipped
           from feeds fd)
  select jsonb_agg(jsonb_build_object('source', f.source, 'last_good_at', f.last_good, 'last_run_at', f.last_run,
                                      'fallback_good_at', f.fallback_good) order by f.source),
         coalesce(jsonb_agg(jsonb_build_object(
           'kind', 'feed_stale:' || f.source, 'issue', 'feed_stale', 'source', f.source, 'service', f.service,
           'last_good_at', f.last_good, 'last_run_at', f.last_run, 'fallback_good_at', f.fallback_good,
           'minutes_since_good', round(extract(epoch from p_as_of - f.last_good) / 60),
           'reason', 'The Railway service ' || f.service || ' (Samsara ' || f.label || ') has not completed a good run since '
                     || coalesce(to_char(f.last_good at time zone et, 'Mon FMDD FMHH12:MI AM') || ' ET', 'it was created') || '.'
                     || case when f.fallback_good > coalesce(f.last_good, '-infinity')
                             then ' The GitHub fallback last stored them at ' || to_char(f.fallback_good at time zone et, 'Mon FMDD FMHH12:MI AM') || ' ET.'
                             else '' end
                     || case when f.skipped is not null then ' Its latest run skipped: ' || f.skipped || '.' else '' end,
           'what_to_do', case when f.skipped is not null
                              then 'Samsara changed the units of ' || f.skipped || ', so every run skips it and Run now will not help: '
                                   || 'compare Samsara''s /readings/definitions with PINNED in scripts/sync/cron_samsara_tank_readings.js and update it.'
                              else 'Railway, project UnclogMe Timed Jobs, service ' || f.service || ', Cron Runs: read the latest run, then Run now. '
                                   || 'If Railway itself is down, run the GitHub Actions workflow "' || f.workflow || '". '
                                   || 'Either way the job catches up from the last good run.' end) order by f.source)
           filter (where f.last_good is null or f.last_good < p_as_of - interval '20 minutes'), '[]'::jsonb)
    into v_feeds, v_items
    from f;

  v_items := v_items || coalesce((
    select jsonb_agg(jsonb_build_object(
             'kind', 'gps_dropped_span:' || to_char(h.gap_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI"Z"'),
             'issue', 'gps_dropped_span', 'gap_from', h.gap_from, 'gap_to', h.gap_to, 'run_id', h.run_id,
             'blocking', h.run_at > p_as_of - interval '14 days',
             'reason', 'GPS from ' || to_char(h.gap_from at time zone et, 'Mon FMDD FMHH12:MI AM') || ' to '
                       || to_char(h.gap_to at time zone et, 'Mon FMDD FMHH12:MI AM') || ' ET was never fetched (the outage was longer than '
                       || 'the 7 days the GPS job catches up on its own). '
                       || case when h.run_at > p_as_of - interval '14 days'
                               then 'Until it is re-pulled, the stop builder and the time on site fills wait at its start.'
                               else 'After 14 days the jobs no longer wait for it, so stops built since may run across it.' end,
             'what_to_do', 'Run the GitHub Actions workflow "Samsara GPS (fallback)" with start_time '
                           || to_char(h.gap_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
                           || ' and end_time left blank. The span closes by itself when that run succeeds.'
                           || case when h.run_at > p_as_of - interval '14 days' then ''
                                   else ' Then rebuild each truck''s stops from that time: select public.fn_refresh_stop_facts(<vehicle id>, '''
                                        || to_char(h.gap_from at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"') || ''');' end)
           order by h.gap_from)
      from public.fn_samsara_gps_open_holes(p_as_of, 60) h), '[]'::jsonb);

  if v_gps_live then
    v_items := v_items || coalesce((
      select jsonb_agg(jsonb_build_object(
               'kind', 'gps_silent:vehicle-' || x.vehicle_id, 'issue', 'gps_silent', 'vehicle_id', x.vehicle_id,
               'truck', x.truck, 'last_gps_at', x.last_gps, 'last_engine_at', x.last_rpm,
               'reason', x.truck || '''s engine was running at '
                         || to_char(x.last_rpm at time zone et, 'Mon FMDD FMHH12:MI AM') || ' ET, but its last stored GPS point is from '
                         || coalesce(to_char(x.last_gps at time zone et, 'Mon FMDD FMHH12:MI AM') || ' ET', 'more than a week ago') || '.',
               'what_to_do', 'Open the truck in Samsara. If Samsara has its GPS, the GPS job is missing it: read the latest '
                             || 'samsara-gps run in Railway. If Samsara has no location either, the truck''s gateway is not reporting.')
             order by x.vehicle_id)
        from (select ve.id as vehicle_id, ve.name as truck, g.last_gps, r.last_rpm
                from (select distinct e.entity_id from public.entity_source_links e
                       where e.entity_type = 'vehicle' and e.source_system = 'samsara') l
                join public.vehicles ve on ve.id = l.entity_id
                cross join lateral (
                  select max(t.recorded_at) as last_gps from public.vehicle_telemetry_readings t
                   where t.vehicle_id = ve.id and t.latitude is not null
                     and t.odometer_meters is null and t.fuel_percent is null and t.engine_state is null
                     and t.recorded_at > p_as_of - interval '7 days' and t.recorded_at <= p_as_of) g
                cross join lateral (
                  select max(rr.recorded_at) as last_rpm from public.vehicle_engine_rpm_readings rr
                   where rr.vehicle_id = ve.id and rr.engine_rpm > 0
                     and rr.recorded_at > p_as_of - interval '6 hours' and rr.recorded_at <= p_as_of) r
               where r.last_rpm is not null
                 and (g.last_gps is null or r.last_rpm > g.last_gps + interval '30 minutes')) x), '[]'::jsonb);
  end if;

  -- one item per kind: a duplicate (check, item_key) breaks the health scan's upsert for EVERY check
  select coalesce(jsonb_agg(x.i order by x.k), '[]'::jsonb) into v_items
    from (select distinct on (i->>'kind') i->>'kind' as k, i from jsonb_array_elements(v_items) i order by i->>'kind') x;

  if p_write then
    select l.details->'items' into v_prev
      from public.sync_log l where l.sync_source = 'samsara-feed-health' order by l.started_at desc limit 1;
    insert into public.sync_log (sync_source, started_at, finished_at, duration_seconds, status, details)
    values ('samsara-feed-health', v_started, clock_timestamp(), extract(epoch from clock_timestamp() - v_started),
            case when jsonb_array_length(v_items) = 0 then 'success' else 'attention' end,
            jsonb_build_object('as_of', p_as_of, 'items', v_items, 'feeds', v_feeds));
    select exists (
             select 1 from jsonb_array_elements(v_items) i
              where not exists (select 1 from public.health_alert_state s
                                 where s.check_name = 'samsara-feed-health' and s.item_key = i->>'kind'
                                   and s.resolved_at is null
                                   and (s.alert_count > 0 or s.acknowledged_until >= now())))
        or exists (   -- an open item gone for two runs in a row (one quiet run alone does not re-arm a flapping feed)
             select 1 from public.health_alert_state s
              where s.check_name = 'samsara-feed-health' and s.resolved_at is null
                and not exists (select 1 from jsonb_array_elements(v_items) i where i->>'kind' = s.item_key)
                and not exists (select 1 from jsonb_array_elements(coalesce(v_prev, '[]'::jsonb)) i where i->>'kind' = s.item_key))
      into v_call;
    if v_call then
      perform public.fn_request_health_escalation();
    end if;
  end if;

  return jsonb_build_object('status', case when jsonb_array_length(v_items) = 0 then 'success' else 'attention' end,
                            'items', v_items, 'feeds', v_feeds, 'escalation_requested', v_call);
end
$function$;

drop function public.fn_request_samsara_job_run(text, text);
drop function public.fn_check_railway_token();

do $verify$ begin
  if to_regprocedure('public.fn_request_samsara_job_run(text, text)') is not null then raise exception 'still there'; end if;
  if position('fn_request_samsara_job_run' in pg_get_functiondef('public.log_samsara_feed_health(timestamptz,boolean)'::regprocedure)) > 0 then raise exception 'watchdog still presses'; end if;
end $verify$;

COMMIT;
