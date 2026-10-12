-- 2026-10-12_2250_schedule_vehicle_stop_facts.sql  (plan step M5)
--
-- Runs public.fn_refresh_stop_facts() hourly at :35 (after the 5-minute collector and samsara-gps have landed
-- the hour's readings). It builds new stops, measures tank levels, links visits, and writes its own sync_log
-- rows (sources listed in M7). Idempotent: a refresh with nothing new writes nothing (proven in M4's probe).
-- Fred, 2026-10-12: "go ahead with phase 2". Rule 8: no table change.

begin;
do $$
begin
  if exists (select 1 from cron.job where jobname = 'vehicle-stop-facts') then
    perform cron.unschedule('vehicle-stop-facts');
  end if;
end $$;
select cron.schedule('vehicle-stop-facts', '35 * * * *', 'select public.fn_refresh_stop_facts()');

do $$
begin
  if (select count(*) from cron.job where jobname = 'vehicle-stop-facts' and schedule = '35 * * * *' and active) <> 1 then
    raise exception 'VERIFY: vehicle-stop-facts not scheduled';
  end if;
end $$;
commit;
