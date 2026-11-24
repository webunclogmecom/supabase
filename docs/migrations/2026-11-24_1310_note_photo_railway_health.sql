-- 2026-11-24_1310_note_photo_railway_health.sql  (Trello #247 ZkN6Rzho)
--
-- WHY. The Jobber note-photo sync runs hourly on Railway since 2026-11-24 ~12:08 ET (service note-photo, source
-- railway_note_photo; plan docs/specs/2026-11-24-note-photo-sync-railway-plan.md, steps 5-6). Its watchdogs were tuned to
-- GitHub's throttling: "no run" alerted only after 12 hours, so on 11-24 a 10-hour gap with three routes of photos
-- missing said nothing. Fred: "they should've been in our system 4~6 hours after they were posted".
--
-- WHAT (all spliced from the live bodies, md5-pinned, each anchor asserted exactly once):
-- 1. public.v_jobber_note_photo_health: all_runs_stale 12 h -> 2 h; full_sweep_stale 24 h -> 26 h (one sweep a day at
--    05 UTC now). hot_window_collapsed ("< 2 hourly runs in 24 h") is left as it is on purpose: the 2-hour rule now
--    catches a stopped sync, and a higher floor would warn for the first ~18 hours after the switch.
-- 2. public.log_jobber_note_photo_health: the three sentences say the new limits.
-- 3. public.log_jobber_sync_health watched list: jobber_note_photo_sync gets 2 hours (it was NULL, "irregular by
--    design" on GitHub), and railway_note_photo is added at 2 hours, so a failing Railway run reaches the health email.
-- Rule 8: no table change. ROLLBACK: 2026-11-24_1310_note_photo_railway_health_rollback.sql (the reverse splices).

begin;
set local lock_timeout = '3s';

do $mig$
declare v text; f text;
begin
  -- 1. the view
  v := pg_get_viewdef('public.v_jobber_note_photo_health'::regclass);
  if md5(v) <> 'c43c8e40b468bc860b10cfd21d489fff' then raise exception 'view changed (md5 %)', md5(v); end if;
  foreach f in array array[
      '(now() - a.last_run_at) > ''12:00:00''::interval',
      '(now() - a.last_full_sweep_at) > ''24:00:00''::interval'] loop
    if (length(v) - length(replace(v, f, ''))) / length(f) <> 1 then raise exception 'view anchor not once: %', f; end if;
  end loop;
  v := replace(v, '(now() - a.last_run_at) > ''12:00:00''::interval', '(now() - a.last_run_at) > ''02:00:00''::interval');
  v := replace(v, '(now() - a.last_full_sweep_at) > ''24:00:00''::interval', '(now() - a.last_full_sweep_at) > ''26:00:00''::interval');
  execute 'create or replace view public.v_jobber_note_photo_health as ' || v;

  -- 2. the note-photo health sentences
  f := pg_get_functiondef('public.log_jobber_note_photo_health()'::regprocedure);
  if md5(f) <> '8684aa9cb97b9f904ecccb4b29c89d64' then raise exception 'log_jobber_note_photo_health changed (md5 %)', md5(f); end if;
  if position('(alert at 24h)' in f) = 0 or position('(alert at 12h)' in f) = 0 then
    raise exception 'sentence anchors missing';
  end if;
  f := replace(f, '(alert at 24h)', '(alert at 26h)');
  f := replace(f, '(alert at 12h)', '(alert at 2h; it runs hourly on Railway, service note-photo)');
  execute f;

  -- 3. the watched list
  f := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
  if md5(f) <> 'd96377d76ed20aa1da1055a60fc0b92a' then raise exception 'log_jobber_sync_health changed (md5 %)', md5(f); end if;
  v := E'      -- ⚠ This one runs irregularly by design (max observed gap 731 minutes), so a staleness\n'
    || E'      --    window would be a guess. NULL means "watch it for failures, never for lateness".\n'
    || E'      (''jobber_note_photo_sync'',        null::interval),\n';
  if (length(f) - length(replace(f, v, ''))) / length(v) <> 1 then raise exception 'watched-list anchor not once'; end if;
  f := replace(f, v,
       E'      -- 2026-11-24 (Trello #247): hourly on Railway (service note-photo); 2 hours = one missed run. The script''s\n'
    || E'      -- own row and the Railway runner''s row (exit code, stderr tail) are both watched.\n'
    || E'      (''jobber_note_photo_sync'',        interval ''2 hours''),\n'
    || E'      (''railway_note_photo'',            interval ''2 hours''),\n');
  execute f;
end
$mig$;

-- VERIFY
do $v$
declare h record; n int;
begin
  select * into h from public.v_jobber_note_photo_health;
  if h.all_runs_stale then raise exception 'VERIFY: all_runs_stale true right after a Railway run (last run % h ago)', h.hours_since_any_run; end if;
  if position('''02:00:00''::interval' in pg_get_viewdef('public.v_jobber_note_photo_health'::regclass)) = 0 then raise exception 'VERIFY: view not 2h'; end if;
  if position('''railway_note_photo''' in pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure)) = 0 then raise exception 'VERIFY: railway_note_photo not watched'; end if;
  if has_table_privilege('authenticated', 'public.v_jobber_note_photo_health', 'SELECT') then raise exception 'VERIFY: view ACL widened'; end if;
  n := public.log_jobber_note_photo_health();   -- writes its sync_log row; must run
  perform public.log_jobber_sync_health();
end
$v$;

commit;
