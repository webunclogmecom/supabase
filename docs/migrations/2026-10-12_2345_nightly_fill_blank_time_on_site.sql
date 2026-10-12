-- 2026-10-12_2345_nightly_fill_blank_time_on_site.sql
--
-- Fred, 2026-10-12: "fill some gaps we have in our visits, where yannick is saying that a 25% of our visits do not
-- hold a duration time." 2026-10-12_2330 filled 60 blank customer visits once (blank 214 -> 154). This makes the same
-- rule run every night after public.fn_compute_time_on_site, so new visits do not open the same gap.
--
-- public.fn_fill_blank_time_on_site(p_from, p_to, p_execute): for a completed, live, CUSTOMER visit whose
-- duration_minutes is still NULL, take any truck's stay of 3 min or more within 150 m of the property (same window
-- and clustering as fn_compute_time_on_site) that CONTAINS completed_at (15 min slack); the longest such stay wins.
-- Writes only NULL rows; never vehicle_id, never is_gps_confirmed; nothing reaches Jobber. It is a separate function
-- on purpose: fn_compute_time_on_site is md5-pinned by 2026-10-12_1530 and stays unchanged.
-- pg_cron job 'time-on-site-nightly' now runs both, the existing function first.
-- SECURITY DEFINER, search_path '', EXECUTE revoked by name from public/anon/authenticated (service_role keeps it).
-- Rule 8: no table change; public.visits is audited.

begin;
set local lock_timeout = '3s';

create or replace function public.fn_fill_blank_time_on_site(p_from date, p_to date, p_execute boolean default false)
returns table(blank_considered integer, filled integer)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_blank integer := 0;
  v_filled integer := 0;
begin
  drop table if exists _fill_tos;
  create temp table _fill_tos on commit drop as
  with blank as (
    select v.id, v.visit_date, v.completed_at,
           p.latitude::float8 plat, p.longitude::float8 plon
      from public.visits v
      join public.properties p on p.id = v.property_id
     where v.visit_status = 'completed' and v.deleted_at is null
       and v.visit_date >= p_from and v.visit_date < p_to
       and v.duration_minutes is null
       and v.completed_at is not null
       and p.latitude is not null and p.longitude is not null
       and not public.fn_is_non_customer(v.client_id)
  ), pings as (
    select b.id, r.vehicle_id, r.recorded_at
      from blank b
      join public.vehicle_telemetry_readings r
        on r.recorded_at >= (b.visit_date::timestamp at time zone 'America/New_York') - interval '4 hours'
       and r.recorded_at <  ((b.visit_date + 1) + time '10:00') at time zone 'America/New_York'
       and sqrt(power((r.latitude - b.plat) * 111320, 2) +
                power((r.longitude - b.plon) * 111320 * cos(radians(b.plat)), 2)) <= 150
  ), mk as (
    select id, vehicle_id, recorded_at,
           case when lag(recorded_at) over w is null
                  or recorded_at - lag(recorded_at) over w > interval '15 minutes' then 1 else 0 end n
      from pings window w as (partition by id, vehicle_id order by recorded_at)
  ), cl as (
    select id, vehicle_id, recorded_at, sum(n) over (partition by id, vehicle_id order by recorded_at) c from mk
  ), sp as (
    select id, vehicle_id, c, min(recorded_at) arrival, max(recorded_at) departure,
           extract(epoch from max(recorded_at) - min(recorded_at)) / 60 minutes
      from cl group by 1, 2, 3
  )
  select distinct on (sp.id) sp.id as visit_id, sp.arrival, sp.departure, round(sp.minutes)::integer as minutes
    from sp join blank b on b.id = sp.id
   where sp.minutes >= 3
     and b.completed_at between sp.arrival - interval '15 minutes' and sp.departure + interval '15 minutes'
   order by sp.id, sp.minutes desc;

  select count(*) into v_blank
    from public.visits v
   where v.visit_status = 'completed' and v.deleted_at is null
     and v.visit_date >= p_from and v.visit_date < p_to
     and v.duration_minutes is null and not public.fn_is_non_customer(v.client_id);

  if p_execute then
    update public.visits v
       set actual_arrival_at = f.arrival, actual_departure_at = f.departure, duration_minutes = f.minutes
      from _fill_tos f
     where v.id = f.visit_id and v.duration_minutes is null;
    get diagnostics v_filled = row_count;
  else
    select count(*) into v_filled from _fill_tos;
  end if;

  return query select v_blank, v_filled;
end
$function$;

revoke all on function public.fn_fill_blank_time_on_site(date, date, boolean) from public, anon, authenticated;
grant execute on function public.fn_fill_blank_time_on_site(date, date, boolean) to service_role;
comment on function public.fn_fill_blank_time_on_site(date, date, boolean) is
  'Fills BLANK time on site for customer visits from any truck''s GPS stay (3+ min, 150 m) that contains completed_at. '
  'Runs nightly after fn_compute_time_on_site (pg_cron time-on-site-nightly). Never changes an existing value. 2026-10-12_2345.';

select cron.alter_job(
  (select jobid from cron.job where jobname = 'time-on-site-nightly'),
  command := 'select public.fn_compute_time_on_site(current_date - 10, current_date + 1, true); '
          || 'select public.fn_fill_blank_time_on_site(current_date - 10, current_date + 1, true)');

-- VERIFY
do $$
declare r record;
begin
  if has_function_privilege('anon', 'public.fn_fill_blank_time_on_site(date,date,boolean)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_fill_blank_time_on_site(date,date,boolean)', 'EXECUTE') then
    raise exception 'VERIFY: anon/authenticated can execute the fill';
  end if;
  if (select command from cron.job where jobname = 'time-on-site-nightly') not like '%fn_fill_blank_time_on_site%' then
    raise exception 'VERIFY: cron job not updated';
  end if;
  -- the one-off fill already ran, so a dry run over 2026 must find nothing left that this rule can fill
  select * into r from public.fn_fill_blank_time_on_site('2026-01-01', current_date + 1, false);
  if r.filled <> 0 then raise exception 'VERIFY: % visits still fillable after 2026-10-12_2330', r.filled; end if;
  if r.blank_considered = 0 then raise exception 'VERIFY: no blank customer visits seen, instrument broken'; end if;
end $$;

commit;
