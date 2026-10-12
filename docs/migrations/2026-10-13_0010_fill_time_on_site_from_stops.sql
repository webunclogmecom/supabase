-- 2026-10-13_0010_fill_time_on_site_from_stops.sql
--
-- Fred, 2026-10-12: "can you do a check with Samsara? specially since 10 days ago? so we can do a backfill?"
-- Checked: for 2026-10-09/10 our public.vehicle_telemetry_readings hold the same GPS as Samsara's
-- /fleet/vehicles/locations/history (6,537 / 1,453 / 2,039 points vs Samsara's 6,538 / 1,453 / 2,040), so a re-pull
-- from Samsara recovers nothing. What DOES recover blanks is the stop data built 2026-10-12 (M4): a completed visit
-- with no time on site that public.fn_link_visit_vehicle_stops linked to exactly ONE live stop by completion time
-- (match_basis 'completion') or, for a dump, by 'dump_completion' / 'dump_window', takes that stop's arrival and
-- departure. Measured: 19 visits (3 customers, 16 Dump Offload at the dump sites), 24 to 94 minutes.
--
-- public.fn_fill_time_on_site_from_stops(p_execute): writes actual_arrival_at, actual_departure_at, duration_minutes
-- ONLY where duration_minutes is NULL; never vehicle_id, never is_gps_confirmed; nothing reaches Jobber. Visits with
-- several links, or linked only by 'window' / 'same_site_earlier', are left alone (the stop may be shared).
-- pg_cron 'time-on-site-nightly' gains it as a third step. Stops exist from 2026-08-20, so it cannot reach earlier.
-- SECURITY DEFINER, search_path '', EXECUTE revoked by name from public/anon/authenticated.
-- Rule 8: no table change; public.visits is audited.

begin;
set local lock_timeout = '3s';

create or replace function public.fn_fill_time_on_site_from_stops(p_execute boolean default false)
returns table(candidates integer, filled integer)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_cand integer := 0;
  v_filled integer := 0;
begin
  drop table if exists _fill_stops;
  create temp table _fill_stops on commit drop as
  select v.id as visit_id, min(s.arrived_at) as arrival, max(s.departed_at) as departure
    from public.visits v
    join public.visit_vehicle_stops l on l.visit_id = v.id and l.deleted_at is null
    join public.vehicle_stops s on s.id = l.vehicle_stop_id and s.superseded_at is null
   where v.visit_status = 'completed' and v.deleted_at is null and v.duration_minutes is null
   group by v.id
  having count(*) = 1
     and bool_and(l.match_basis in ('completion', 'dump_completion', 'dump_window'))
     and max(s.departed_at) > min(s.arrived_at);

  select count(*) into v_cand from _fill_stops;

  if p_execute then
    update public.visits v
       set actual_arrival_at = f.arrival, actual_departure_at = f.departure,
           duration_minutes  = round(extract(epoch from f.departure - f.arrival) / 60)::integer
      from _fill_stops f
     where v.id = f.visit_id and v.duration_minutes is null;
    get diagnostics v_filled = row_count;
  end if;

  return query select v_cand, v_filled;
end
$function$;

revoke all on function public.fn_fill_time_on_site_from_stops(boolean) from public, anon, authenticated;
grant execute on function public.fn_fill_time_on_site_from_stops(boolean) to service_role;
comment on function public.fn_fill_time_on_site_from_stops(boolean) is
  'Fills BLANK time on site from the single stop a visit is linked to (completion / dump_completion / dump_window). '
  'Third step of pg_cron time-on-site-nightly. Never changes an existing value. 2026-10-13_0010.';

do $$
declare r record;
begin
  select * into r from public.fn_fill_time_on_site_from_stops(true);
  if r.candidates = 0 then raise exception 'VERIFY: no candidates, instrument broken'; end if;
  if r.filled <> r.candidates then raise exception 'VERIFY: filled % of % candidates', r.filled, r.candidates; end if;
  raise notice 'filled % visits from their linked stop', r.filled;
  select * into r from public.fn_fill_time_on_site_from_stops(false);
  if r.candidates <> 0 then raise exception 'VERIFY: % candidates remain after the fill', r.candidates; end if;
  if has_function_privilege('authenticated', 'public.fn_fill_time_on_site_from_stops(boolean)', 'EXECUTE')
     or has_function_privilege('anon', 'public.fn_fill_time_on_site_from_stops(boolean)', 'EXECUTE') then
    raise exception 'VERIFY: anon/authenticated can execute the fill';
  end if;
end $$;

select cron.alter_job(
  (select jobid from cron.job where jobname = 'time-on-site-nightly'),
  command := 'select public.fn_compute_time_on_site(current_date - 10, current_date + 1, true); '
          || 'select public.fn_fill_blank_time_on_site(current_date - 10, current_date + 1, true); '
          || 'select public.fn_fill_time_on_site_from_stops(true)');

do $$
begin
  if (select command from cron.job where jobname = 'time-on-site-nightly') not like '%fn_fill_time_on_site_from_stops%' then
    raise exception 'VERIFY: cron job not updated';
  end if;
end $$;

commit;
