-- 2026-10-22_rollback_samsara_watchdog_dead_token_item.sql
-- Puts public.log_samsara_feed_health back to its body before 2026-10-22_1855 (dead-token answers stay silent again).
begin;
set local lock_timeout = '3s';
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
-- 2026-10-16_0945: auto restart (Railway "Run now" for a service that has not run for 15 min, throttled) and
-- restart_token_invalid (the daily token check failed). See docs/reference/samsara-feeds-resilience.md.
declare
  v_started  timestamptz := clock_timestamp();
  v_items    jsonb;
  v_feeds    jsonb;
  v_prev     jsonb;
  v_call     boolean := false;
  v_gps_live boolean;
  -- 2026-10-16_0945 auto restart
  v_tok_set  boolean;
  v_notes    jsonb := '{}'::jsonb;
  v_note     text;
  v_res      jsonb;
  fr         record;
  v_press_at timestamptz;  v_presses int;
  v_resp_status int;  v_resp_content text;  v_resp_err text;  v_resp_found boolean;
  v_chk_at timestamptz;  v_chk_status int;  v_chk_content text;  v_chk_err text;  v_chk_ok boolean;
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
           'skipped_streams', f.skipped,
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

  -- AUTO RESTART (2026-10-16_0945, Fred: "yes set up the auto restart"). A Railway service that has not RUN at all for
  -- 15 minutes (a run that fails is not helped by another one) gets Railway's "Run now" pressed through
  -- public.fn_request_samsara_job_run, at most once every 30 minutes and 6 times in 24 hours per service. What Railway
  -- answered to the newest press (net._http_response) goes into the item's reason. Nothing is sent when p_write is false.
  select exists (select 1 from vault.decrypted_secrets where name = 'railway_timed_jobs_token') into v_tok_set;
  for fr in
    select i->>'service' as service, (i->>'last_run_at')::timestamptz as last_run, i->>'skipped_streams' as skipped
      from jsonb_array_elements(v_items) i where i->>'issue' = 'feed_stale'
  loop
    select max(l.started_at), count(*) into v_press_at, v_presses
      from public.sync_log l
     where l.sync_source = 'samsara-job-restart' and l.details->>'service' = fr.service
       and l.started_at > p_as_of - interval '24 hours' and l.started_at <= p_as_of;
    v_resp_found := false; v_resp_status := null; v_resp_content := null; v_resp_err := null;
    if v_press_at is not null then
      select resp.id is not null, resp.status_code, resp.content, coalesce(resp.error_msg, case when resp.timed_out then 'timed out' end)
        into v_resp_found, v_resp_status, v_resp_content, v_resp_err
        from public.sync_log l
        left join net._http_response resp on resp.id = (l.details->>'request_id')::bigint
       where l.sync_source = 'samsara-job-restart' and l.details->>'service' = fr.service and l.started_at = v_press_at
       limit 1;
    end if;
    v_note := case
      when fr.skipped is not null then
        'No automatic Run now: the job runs but skips a reading, which another run cannot fix.'
      when fr.last_run is not null and fr.last_run > p_as_of - interval '15 minutes' then
        'No automatic Run now: Railway is running the job (last run ' || to_char(fr.last_run at time zone et, 'FMHH12:MI AM')
        || ' ET) but it does not succeed, so another run would not help.'
      when not v_tok_set then
        'No automatic Run now: the Railway token is not set up (Supabase vault secret railway_timed_jobs_token).'
      when v_presses >= 6 then
        'Run now was pressed automatically 6 times in 24 hours; the watchdog stops pressing there.'
      when v_press_at > p_as_of - interval '30 minutes' then
        'Run now was pressed automatically at ' || to_char(v_press_at at time zone et, 'FMHH12:MI AM') || ' ET'
        || case when not v_resp_found then ' (no answer from Railway yet).'
                when v_resp_status = 200 and v_resp_content like '%"deploymentInstanceExecutionCreate":true%' then ' and Railway accepted it.'
                else ' but Railway refused it: ' || left(coalesce(v_resp_err, v_resp_content, 'HTTP ' || v_resp_status), 160) || '.' end
      end;
    if v_note is null then
      if p_write then
        v_res := public.fn_request_samsara_job_run(fr.service, 'watchdog: ' || fr.service || ' has not run for 15 minutes');
        v_note := case when (v_res->>'requested')::boolean
                       then 'Run now was pressed automatically just now (' || (v_presses + 1) || ' of at most 6 in 24 hours).'
                       else 'Automatic Run now not sent: ' || (v_res->>'why') || '.' end;
      else
        v_note := 'The watchdog would press Run now automatically.';
      end if;
    end if;
    v_notes := v_notes || jsonb_build_object(fr.service, v_note);
  end loop;
  if v_notes <> '{}'::jsonb then
    select coalesce(jsonb_agg(case when i->>'issue' = 'feed_stale' and v_notes ? (i->>'service')
                                   then i || jsonb_build_object('auto_restart', v_notes->>(i->>'service'),
                                                                'reason', (i->>'reason') || ' ' || (v_notes->>(i->>'service')))
                                   else i end), '[]'::jsonb)
      into v_items from jsonb_array_elements(v_items) i;
  end if;

  -- Is the token still accepted? A read-only check (public.fn_check_railway_token) once a day, hourly after a failure;
  -- the answer is read on a later run. A refused or wrong token raises restart_token_invalid.
  if v_tok_set then
    select l.started_at, resp.status_code, resp.content, coalesce(resp.error_msg, case when resp.timed_out then 'timed out' end)
      into v_chk_at, v_chk_status, v_chk_content, v_chk_err
      from public.sync_log l
      left join net._http_response resp on resp.id = (l.details->>'request_id')::bigint
     where l.sync_source = 'samsara-job-restart-check' and l.started_at <= p_as_of
     order by l.started_at desc limit 1;
    v_chk_ok := null;
    if v_chk_status is not null or v_chk_err is not null then
      begin
        v_chk_ok := v_chk_status = 200
                    and (v_chk_content::jsonb->'data'->'projectToken'->>'projectId') = '0488911d-3f3d-414b-8783-89234f808513';
      exception when others then v_chk_ok := false;
      end;
    end if;
    if v_chk_ok is false then
      v_items := v_items || jsonb_build_array(jsonb_build_object(
        'kind', 'restart_token_invalid', 'issue', 'restart_token_invalid', 'checked_at', v_chk_at,
        'reason', 'The Railway token the watchdog uses to press Run now was refused when it was checked at '
                  || to_char(v_chk_at at time zone et, 'Mon FMDD FMHH12:MI AM') || ' ET ('
                  || left(coalesce(v_chk_err, v_chk_content, 'HTTP ' || v_chk_status), 160) || '), so the automatic restart is off.',
        'what_to_do', 'Railway, project UnclogMe Timed Jobs, Settings, Tokens: create a token for the production environment, then '
                      || 'replace the value of the Supabase vault secret railway_timed_jobs_token with it.'));
    end if;
    if p_write and (v_chk_at is null
                    or v_chk_at < p_as_of - case when v_chk_ok then interval '24 hours' else interval '1 hour' end) then
      perform public.fn_check_railway_token();
    end if;
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
$function$
;
do $v$ begin
  if md5(pg_get_functiondef('public.log_samsara_feed_health'::regproc)) <> 'ed6efd5068d1dabff6b51efec84a5c32' then
    raise exception 'rollback: body md5 is not the pre-2026-10-22_1855 one';
  end if;
end $v$;
commit;
