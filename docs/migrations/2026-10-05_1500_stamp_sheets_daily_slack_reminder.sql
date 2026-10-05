-- Daily Slack reminder: Stamp Studio sheets not completed, 10 AM Eastern, #apps-notifications
--
-- Fred, 2026-10-05: "we need to create a functionality of sending notifications once per day at
-- 10 AM EST through slack about any Manifest not completed at the Stamp Studio App". Channel:
-- #apps-notifications (C0BJYHQKZM1, the renamed #dump-visits, where the shared bot already posts).
-- On a day when every sheet is completed: post nothing (Fred picked it).
--
-- 1. derm.fn_stamp_open_sheets() -> jsonb: the Studio's own list (derm.v_stamp_sheets, so the
--    Broward-since-Sep-2 filter and everything else the app hides is hidden here too), not
--    completed, oldest first: manifest, service/dump date, placed / total, pages, status
--    ("Not started" / "In progress", the app's own rule: placed > 0), days waiting since the dump
--    (ET). service_role only.
-- 2. public.fn_request_stamp_sheets_reminder(): the cron wrapper. Lets through only the run that is
--    10 AM in New York (the job fires at 14:00 and 15:00 UTC: 14:00 is 10 AM EDT, 15:00 is 10 AM
--    EST), makes NO call when nothing is open, else posts to edge fn stamp-sheets-reminder with the
--    vault service key (edge_invoke_service_key), like the other fn_request_* wrappers.
-- 3. pg_cron `stamp-sheets-reminder` '0 14,15 * * *'.
-- The edge fn (verify_jwt pinned, service_role gate) builds the message and posts it with the shared
-- Slack bot (SLACK_BOT_TOKEN). Body {dry_run:true} returns the text without posting.
-- Rule 8: no table; nothing to audit. Both functions revoked by name from public, anon, authenticated.

begin;

create function derm.fn_stamp_open_sheets()
returns jsonb
language sql
stable
security definer
set search_path to 'derm', 'public'
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'manifest', s.white_manifest_number,
           'service_date', s.service_date,
           'dump_date', s.dump_date,
           'placed', s.placed_rows,
           'total', s.total_rows,
           'pages', s.page_count,
           'status', case when s.placed_rows > 0 then 'In progress' else 'Not started' end,
           'days_waiting', (now() at time zone 'America/New_York')::date - coalesce(s.dump_date, s.service_date))
         order by coalesce(s.dump_date, s.service_date) nulls last, s.white_manifest_number), '[]'::jsonb)
    from derm.v_stamp_sheets s
   where not s.completed;
$function$;
revoke all on function derm.fn_stamp_open_sheets() from public, anon, authenticated;
grant execute on function derm.fn_stamp_open_sheets() to service_role;

create function public.fn_request_stamp_sheets_reminder()
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare v_key text;
begin
  -- 10 AM Eastern whatever the season: the job runs at 14:00 and 15:00 UTC, and only one is 10 AM in New York
  if extract(hour from now() at time zone 'America/New_York') <> 10 then
    return;
  end if;
  -- every sheet completed: post nothing (Fred, 2026-10-05), and make no call
  if jsonb_array_length(derm.fn_stamp_open_sheets()) = 0 then
    return;
  end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping the Stamp Studio reminder';
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/stamp-sheets-reminder',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
end
$function$;
revoke all on function public.fn_request_stamp_sheets_reminder() from public, anon, authenticated;

select cron.schedule('stamp-sheets-reminder', '0 14,15 * * *',
                     'select public.fn_request_stamp_sheets_reminder()');

do $verify$
declare v jsonb; n int;
begin
  v := derm.fn_stamp_open_sheets();
  if jsonb_typeof(v) <> 'array' then raise exception 'VERIFY: fn_stamp_open_sheets is not an array'; end if;
  select count(*) into n from derm.v_stamp_sheets where not completed;
  if jsonb_array_length(v) <> n then raise exception 'VERIFY: % open in the list, % in the view', jsonb_array_length(v), n; end if;
  if has_function_privilege('authenticated', 'derm.fn_stamp_open_sheets()', 'EXECUTE')
     or has_function_privilege('anon', 'derm.fn_stamp_open_sheets()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_request_stamp_sheets_reminder()', 'EXECUTE')
     or has_function_privilege('anon', 'public.fn_request_stamp_sheets_reminder()', 'EXECUTE') then
    raise exception 'VERIFY: a reminder function is executable by anon or authenticated'; end if;
  if not exists (select 1 from cron.job where jobname = 'stamp-sheets-reminder' and schedule = '0 14,15 * * *') then
    raise exception 'VERIFY: cron job missing'; end if;
end $verify$;

commit;
