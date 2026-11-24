-- Rollback of 2026-11-24_1340_note_photo_health_hourly_fast_lane.sql (Trello #247): every 6 hours again, no fast lane.
begin;
do $rb$
declare f text := pg_get_functiondef('public.log_jobber_note_photo_health()'::regprocedure);
begin
  f := replace(f, E'  v_call boolean := false;\n', '');
  f := regexp_replace(f, E'  -- 2026-11-24_1340 \(Trello #247\).*?  end if;\n\n', '', 's');
  execute f;
end
$rb$;
select cron.alter_job(39, schedule := '35 */6 * * *');
commit;
