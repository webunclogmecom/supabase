-- 2026-10-21 ET · Access decision D11: two lines in the daily health email
--
-- Fred, 2026-10-21: "go ahead with all recommended" (plan Building Apps/HR App/docs/specs/
-- 2026-10-21-access-switch-on-and-invite-plan.md, D11). New check 'access-health' (cron 13:21 UTC, before the 13:30
-- escalation), registered in ops.v_health_items and ops.v_health_status like the others:
--   * access:gate_setting_missing  the read gate (pgrst.db_pre_request on the authenticator role) is not set. It must
--     always be set: it refuses nobody while any app is in watch, and it is what closes the shared lists once all are on.
--   * access:app_not_on:<app>      a top-level app is still not 'on' after app_config 'access_all_on_by' (the date all
--     six switch-ons were planned to be done). A missing or empty key means no date yet: the item never fires.
-- Both say what to do in plain words. Silence is the normal outcome.
-- The two views are rebuilt from their live text with the new name added to their source lists (ops.v_health_status has
-- two) and one CASE arm each, md5 pinned; nothing else in them changes.

BEGIN;

insert into public.app_config (key, value)
values ('access_all_on_by', '2026-10-23 00:00:00-04')
on conflict (key) do nothing;

create or replace function public.log_access_health()
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
-- 2026-10-21 (D11): the read gate setting and apps left out of 'on' after the planned date
declare v_items jsonb := '[]'::jsonb; v_by timestamptz; n int;
begin
  if not exists (select 1 from pg_db_role_setting s join pg_roles r on r.oid = s.setrole
                  where r.rolname = 'authenticator' and array_to_string(s.setconfig, ' ') like '%pgrst.db_pre_request=public.fn_request_gate%') then
    v_items := v_items || jsonb_build_object('kind', 'access:gate_setting_missing', 'issue', 'gate_setting_missing',
      'reason', 'The read gate is switched off, so a sign-in with no access to any app can read the shared lists.',
      'what_to_do', 'If nobody turned it off on purpose, turn it back on: alter role authenticator set pgrst.db_pre_request to ''public.fn_request_gate''; notify pgrst, ''reload config''; (docs/runbooks/access-undo.md section 3).');
  end if;
  begin v_by := nullif(btrim((select value from public.app_config where key = 'access_all_on_by')), '')::timestamptz;
  exception when others then v_by := null; end;
  if v_by is not null and now() > v_by then
    select v_items || coalesce(jsonb_agg(jsonb_build_object('kind', 'access:app_not_on:' || a.app, 'issue', 'app_not_on', 'app', a.app,
             'reason', format('%s is still in %s, so its access is not enforced.', a.name, a.mode),
             'what_to_do', 'Finish its switch-on (plan HR App/docs/specs/2026-10-21-access-switch-on-and-invite-plan.md), or move app_config access_all_on_by if the date changed.')
             order by a.app), '[]'::jsonb)
      into v_items from hr.access_apps a where a.parent is null and a.mode <> 'on';
  end if;
  n := jsonb_array_length(v_items);
  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('access-health', clock_timestamp(), clock_timestamp(), n, case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items, 'all_on_by', v_by));
  return n;
end $function$;
revoke all on function public.log_access_health() from public, anon, authenticated;
grant execute on function public.log_access_health() to service_role;

do $views$
declare v_items text := pg_get_viewdef('ops.v_health_items'::regclass); v_status text := pg_get_viewdef('ops.v_health_status'::regclass);
  a_list text := $a$'trap-size-health'::text]$a$;
  a_case text := $a$WHEN 'trap-size-health'::text THEN COALESCE((la.details -> 'items'::text), '[]'::jsonb)$a$;
  b_case text := $a$WHEN 'trap-size-health'::text THEN COALESCE((l.details -> 'items'::text), '[]'::jsonb)$a$;
begin
  if md5(v_items) <> '0b870042b594ecbfab5ef4c8593f1aef' or md5(v_status) <> '18f4fbf2656632613ff5653012259c57' then
    raise exception 'a health view changed; re-splice from the live text';
  end if;
  if (length(v_items) - length(replace(v_items, a_list, ''))) / length(a_list) <> 1
     or (length(v_items) - length(replace(v_items, a_case, ''))) / length(a_case) <> 1
     or (length(v_status) - length(replace(v_status, a_list, ''))) / length(a_list) <> 2   -- the status view lists the checks twice (runs + streak groups)
     or (length(v_status) - length(replace(v_status, b_case, ''))) / length(b_case) <> 1 then
    raise exception 'an anchor is not found exactly once';
  end if;
  v_items := replace(replace(v_items, a_list, $r$'trap-size-health'::text, 'access-health'::text]$r$),
                     a_case, a_case || E'\n            WHEN ''access-health''::text THEN COALESCE((la.details -> ''items''::text), ''[]''::jsonb)');
  v_status := replace(replace(v_status, a_list, $r$'trap-size-health'::text, 'access-health'::text]$r$),
                      b_case, b_case || E'\n                    WHEN ''access-health''::text THEN COALESCE((l.details -> ''items''::text), ''[]''::jsonb)');
  execute 'create or replace view ops.v_health_items as ' || v_items;
  execute 'create or replace view ops.v_health_status as ' || v_status;
end $views$;

select cron.schedule('access-health', '21 13 * * *', 'select public.log_access_health()');

do $verify$
declare n int; k text;
begin
  -- 1. today: gate set, date in the future -> no items, ok
  n := public.log_access_health();
  if n <> 0 then raise exception 'VERIFY: % items today', n; end if;
  -- 2. a fixture run with the date in the past: one item per app not on, visible in BOTH views
  update public.app_config set value = '2026-01-01 00:00:00-05' where key = 'access_all_on_by';
  n := public.log_access_health();
  if n < 1 then raise exception 'VERIFY: no app_not_on item with a past date'; end if;
  select item_key into k from ops.v_health_items where check_name = 'access-health' limit 1;
  if k is null or k not like 'access:app_not_on:%' then raise exception 'VERIFY: item not in v_health_items (%)', k; end if;
  if not exists (select 1 from ops.v_health_status where check_name = 'access-health') then
    raise exception 'VERIFY: access-health not in v_health_status'; end if;
  -- clean the fixture: the date back, and the fixture sync_log rows removed (they are this transaction's own)
  update public.app_config set value = '2026-10-23 00:00:00-04' where key = 'access_all_on_by';
  delete from public.sync_log where sync_source = 'access-health' and started_at >= now() - interval '1 minute';
  raise notice 'VERIFY ok';
end $verify$;

COMMIT;
