-- 2026-10-12_2120_watch_railway_samsara_readings.sql
--
-- The Railway service samsara-readings (UnclogMe Timed Jobs) collects the Moises tank sensors and the trucks'
-- RPM / PTO / geofence events every 5 minutes (plan docs/superpowers/specs/2026-10-12-samsara-tank-sensors-db-plan.md,
-- step J1). First Railway run 2026-10-12 ~17:10 ET; 14 of 14 successful by 18:15 ET. Same shape as
-- 2026-10-08_1048_watch_railway_samsara_gps.sql: adds ('railway_samsara_readings', 30 minutes) to the watched list
-- of log_jobber_sync_health, so a stopped or failing collector reaches the daily health email.
-- 30 minutes = 6 missed runs. Spliced from the live body, md5-pinned. Rule 8: no table change.

begin;

do $mig$
declare
  v_def text := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
  v_old text := E'      (''railway_samsara_gps'',           interval ''30 minutes'')\n  ),';
  v_new text := E'      (''railway_samsara_gps'',           interval ''30 minutes''),\n'
             || E'      -- Railway cron service samsara-readings (tank sensors + truck events), every 5 minutes.\n'
             || E'      (''railway_samsara_readings'',      interval ''30 minutes'')\n  ),';
begin
  if md5(v_def) <> '029593b6e86734d0c6dc82ed9cec718f' then
    raise exception 'log_jobber_sync_health changed since this migration was written (md5 %)', md5(v_def);
  end if;
  if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then
    raise exception 'anchor not found exactly once';
  end if;
  execute replace(v_def, v_old, v_new);
end
$mig$;

-- VERIFY
do $v$
declare v_def text := pg_get_functiondef('public.log_jobber_sync_health()'::regprocedure);
begin
  if position('''railway_samsara_readings''' in v_def) = 0 then raise exception 'railway_samsara_readings not watched'; end if;
  if position('''railway_samsara_gps''' in v_def) = 0 then raise exception 'samsara gps entry lost'; end if;
  perform public.log_jobber_sync_health();
end
$v$;

commit;
