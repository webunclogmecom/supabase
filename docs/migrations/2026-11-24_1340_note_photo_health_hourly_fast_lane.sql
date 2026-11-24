-- 2026-11-24_1340_note_photo_health_hourly_fast_lane.sql  (Trello #247 ZkN6Rzho)
--
-- WHY. The card asks for an alert when photos have not arrived within 6 hours. 2026-11-24_1310 made "no run" an item
-- after 2 hours, but the check ran every 6 hours and its items reached Fred only in the daily 9:30 AM ET health email,
-- so a stop at night would have been seen the next morning. Same fix the Samsara watchdog uses (2026-10-15_2230):
-- 1. pg_cron note-photo-sync-health (jobid 39) runs hourly at :35 (was every 6 hours).
-- 2. log_jobber_note_photo_health's fast lane: when all_runs_stale is present and not yet emailed (or acknowledged),
--    it calls public.fn_request_health_escalation() at once (which emails only NEW items). Only all_runs_stale takes
--    the fast lane: the oversized and hot-window items stay in the daily email, as before.
-- Worst case from a stopped sync to Fred's inbox: about 3 hours (2 h rule + up to 1 h to the next check).
-- Spliced from the live body (md5-pinned, anchors asserted once). Rule 8: no table change.
-- ROLLBACK: 2026-11-24_1340_note_photo_health_hourly_fast_lane_rollback.sql.

begin;
set local lock_timeout = '3s';

do $mig$
declare f text; a1 text; a2 text;
begin
  f := pg_get_functiondef('public.log_jobber_note_photo_health()'::regprocedure);
  if md5(f) <> '34553faf68dae10d6a7e18905516225a' then raise exception 'log_jobber_note_photo_health changed (md5 %)', md5(f); end if;
  a1 := E'  st     text;\nbegin\n';
  a2 := E'  return n_bad;\nend\n';
  if (length(f) - length(replace(f, a1, ''))) / length(a1) <> 1 then raise exception 'anchor 1 not once'; end if;
  if (length(f) - length(replace(f, a2, ''))) / length(a2) <> 1 then raise exception 'anchor 2 not once'; end if;
  f := replace(f, a1, E'  st     text;\n  v_call boolean := false;\nbegin\n');
  f := replace(f, a2,
       E'  -- 2026-11-24_1340 (Trello #247): a stopped sync emails at once, not in the next morning''s health email.\n'
    || E'  if h.all_runs_stale and not exists (\n'
    || E'       select 1 from public.health_alert_state s\n'
    || E'        where s.check_name = ''note-photo-sync-health'' and s.item_key = ''all_runs_stale''\n'
    || E'          and s.resolved_at is null and (s.alert_count > 0 or s.acknowledged_until >= now())) then\n'
    || E'    v_call := true;\n'
    || E'    perform public.fn_request_health_escalation();\n'
    || E'  end if;\n\n'
    || E'  return n_bad;\nend\n');
  execute f;
end
$mig$;

select cron.alter_job(39, schedule := '35 * * * *');

-- VERIFY
do $v$
begin
  if (select schedule from cron.job where jobid = 39) <> '35 * * * *' then raise exception 'VERIFY: schedule not hourly'; end if;
  if position('fn_request_health_escalation' in pg_get_functiondef('public.log_jobber_note_photo_health()'::regprocedure)) = 0 then
    raise exception 'VERIFY: fast lane missing';
  end if;
  if (select all_runs_stale from public.v_jobber_note_photo_health) then raise exception 'VERIFY: stale right after Railway runs'; end if;
  perform public.log_jobber_note_photo_health();   -- runs clean, takes no fast lane (nothing stale)
end
$v$;

commit;
