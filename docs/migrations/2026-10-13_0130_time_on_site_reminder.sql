-- 2026-10-13_0130_time_on_site_reminder.sql
--
-- A daily Slack alert listing yesterday's client visits that have no time on site.
-- Yannick, huddle 2026-10-12: daily alerts identifying visits without recorded duration "so adjustments can be made in
-- Samsara". Fred, 2026-10-12: "build the daily alert for visits without duration ... make it look and good simple",
-- picked Option A of the mockups (one line per visit with the reason) and "tag Diego".
-- Format and rules: docs/reference/slack-notifications.md (header, plain words, 11 AM ET, run record, no post when empty).
--
-- 1. public.fn_time_on_site_gaps(p_date): the list. Completed, live, CUSTOMER visits (public.fn_is_non_customer
--    false) dated p_date whose duration_minutes is NULL: the canonical "no time on site" (rule 3b of the guide: read
--    the column the apps show, never re-derive it). For each: client, property point, service, assigned truck, the
--    Samsara ids it is linked to (truck, property place, client places), the closest any truck came, and each truck's
--    stays within 150 m (same window and clustering as fn_compute_time_on_site / fn_fill_blank_time_on_site:
--    20:00 ET the evening before to 10:00 ET the next morning, a gap over 15 min starts a new stay). Plus older_count:
--    the same kind of visit dated in the 30 days before p_date. The edge function time-on-site-reminder words the
--    reason; Samsara Place geometry is read from Samsara there (it is not stored in our database).
-- 2. public.fn_request_time_on_site_reminder(): the 11 AM ET wrapper (same gate, vault key and run-record rule as the
--    Stamp and Admin Review wrappers, 2026-10-12_1310). Before calling the edge function it re-runs the three
--    time-on-site fills for the last 3 days, so an overnight route that ended this morning is measured before the
--    list is read (the nightly run at 03:20 ET cannot see GPS after 03:20). A fill failure is a warning, never a
--    reason to skip the alert.
-- 3. pg_cron 'time-on-site-reminder' '0 15,16 * * *' (only the run that is 11 AM in New York goes through).
-- 4. public.fn_notification_health_items: the reminder joins the reminder_not_run / reminder_failed watch
--    (source 'time_on_site_reminder'). Spliced from the live body, md5-pinned.
-- Rule 8: no table change. Functions are SECURITY DEFINER with a pinned search_path and revoked by name.

begin;
set local lock_timeout = '3s';

-- 1. the list ------------------------------------------------------------------------------------------------------
create or replace function public.fn_time_on_site_gaps(
  p_date date default ((now() at time zone 'America/New_York')::date - 1))
returns jsonb
language sql
stable
security definer
set search_path to ''
as $function$
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

revoke all on function public.fn_time_on_site_gaps(date) from public, anon, authenticated;
grant execute on function public.fn_time_on_site_gaps(date) to service_role;
comment on function public.fn_time_on_site_gaps(date) is
  'Client visits dated p_date (default yesterday ET) with no time on site, with the GPS facts behind each, for the '
  'daily Slack alert time-on-site-reminder. 2026-10-13_0130.';

-- 2. the 11 AM wrapper -------------------------------------------------------------------------------------------
create or replace function public.fn_request_time_on_site_reminder()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
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

revoke all on function public.fn_request_time_on_site_reminder() from public, anon, authenticated;

-- 3. the schedule ------------------------------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from cron.job where jobname = 'time-on-site-reminder') then
    perform cron.unschedule('time-on-site-reminder');
  end if;
end $$;
select cron.schedule('time-on-site-reminder', '0 15,16 * * *', 'select public.fn_request_time_on_site_reminder()');

-- 4. the health watch ---------------------------------------------------------------------------------------------
do $mig$
declare
  v_def text := pg_get_functiondef('public.fn_notification_health_items(jsonb, timestamptz)'::regprocedure);
  v_old text := $o$('stamp_sheets_reminder', 'Stamp Studio', 'stamp-sheets-reminder')) s(src, label, job)$o$;
  v_new text := $n$('stamp_sheets_reminder', 'Stamp Studio', 'stamp-sheets-reminder'),
                 ('time_on_site_reminder', 'time on site', 'time-on-site-reminder')) s(src, label, job)$n$;
begin
  if md5(v_def) <> '8a9961d5db8d288b830ccbd0f3a52085' then
    raise exception 'fn_notification_health_items changed since this migration was written (md5 %)', md5(v_def);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'anchor not found exactly once in fn_notification_health_items';
  end if;
  execute replace(v_def, v_old, v_new);
end
$mig$;

-- VERIFY --------------------------------------------------------------------------------------------------------
do $v$
declare j jsonb; ids int[];
begin
  -- positive control: 2026-10-09 has exactly two such visits (8752 Granada Condo, 8765 Casa Neos), measured 2026-10-12
  j := public.fn_time_on_site_gaps('2026-10-09');
  select array_agg((x->>'visit_id')::int order by (x->>'visit_id')::int) into ids from jsonb_array_elements(j->'visits') x;
  if ids is distinct from array[8752, 8765] then
    raise exception 'VERIFY 1: 2026-10-09 should list visits 8752 and 8765, got %', ids;
  end if;
  -- 8765: David drove past twice (13:53 and 14:38 ET), so two passes under 3 minutes, never one 45-minute stay
  -- (the control that the "a far point ends a stay" rule works); 8752: nobody within 150 m, closest about 290 m
  if not exists (select 1 from jsonb_array_elements(j->'visits') x
                  where (x->>'visit_id')::int = 8765 and jsonb_array_length(x->'stays') = 2
                    and (select max((s->>'minutes')::int) from jsonb_array_elements(x->'stays') s) < 3) then
    raise exception 'VERIFY 2: visit 8765 should show two short passes by David';
  end if;
  if not exists (select 1 from jsonb_array_elements(j->'visits') x
                  where (x->>'visit_id')::int = 8752 and jsonb_array_length(x->'stays') = 0
                    and (x->'closest'->>'meters')::int between 250 and 350) then
    raise exception 'VERIFY 3: visit 8752 should have no stay and a closest approach near 290 m';
  end if;
  -- a test client never appears: 112-YA visits are filtered by fn_is_non_customer (control: the filter exists)
  if position('fn_is_non_customer' in pg_get_functiondef('public.fn_time_on_site_gaps(date)'::regprocedure)) = 0 then
    raise exception 'VERIFY 4: the list lost its test-client filter';
  end if;
  if has_function_privilege('authenticated', 'public.fn_time_on_site_gaps(date)', 'EXECUTE')
     or has_function_privilege('anon', 'public.fn_time_on_site_gaps(date)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_request_time_on_site_reminder()', 'EXECUTE')
     or has_function_privilege('anon', 'public.fn_request_time_on_site_reminder()', 'EXECUTE') then
    raise exception 'VERIFY 5: anon or authenticated can execute the reminder functions';
  end if;
  if (select count(*) from cron.job where jobname = 'time-on-site-reminder' and schedule = '0 15,16 * * *' and active) <> 1 then
    raise exception 'VERIFY 6: cron job missing';
  end if;
  if position('time_on_site_reminder' in pg_get_functiondef('public.fn_notification_health_items(jsonb, timestamptz)'::regprocedure)) = 0 then
    raise exception 'VERIFY 7: the health watch does not list the reminder';
  end if;
  -- the health items still compute (the splice did not break the function)
  perform public.fn_notification_health_items('[]'::jsonb);
end
$v$;

commit;
