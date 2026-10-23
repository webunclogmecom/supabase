-- 2026-10-22_rollback_hr_hours_day_span.sql
-- Puts hr.fn_hours_worked back to its body from before 2026-10-22_2230 (no day_start / day_end), owner only.
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION hr.fn_hours_worked(bigint, date, date);
CREATE FUNCTION hr.fn_hours_worked(p_employee_id bigint, p_from date, p_to date)
 RETURNS TABLE(work_day date, minutes integer, source text, approval text, running boolean, flags text[], hourly_rate numeric, pay numeric, entries jsonb)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- 2026-10-22 (Trello KqGyoiKQ; Fred's picks: "Fall back to his shift forms", count all and show approval, flag
  -- mismatches). One row per ET work day (the day an entry STARTS, as Jobber shows it) in [p_from, p_to]:
  --   1. 'jobber': the person clocked a finished shift that day (GENERAL with no timer target: visit timers are GENERAL too) -> the sum of that day's finished entries.
  --   2. 'shift_forms': no clock-in that day and a complete PRE + POST pair (public.v_inspection_shifts) -> POST - PRE.
  --      A pair overlapping a clocked shift never counts (Jobber wins), and an entry inside a counted pair is absorbed.
  --   3. 'jobber_no_clock_in': otherwise the day's finished entries as they are.
  -- A running entry counts nothing. Flags never change the count. Pay = hours x hr.fn_rate_on(person, 'hourly', day).
  -- ponytail: "no work behind it" checks the person's visits and shift forms, not truck movement; add the truck when a
  -- driver has a clocked shift with no visit and no form that was real.
  with lo as (
    select ((p_from - 1)::timestamp at time zone 'America/New_York') as t0,
           ((p_to + 2)::timestamp at time zone 'America/New_York') as t1),
  e as (
    select t.id, t.started_at, t.ended_at, t.category, t.timer_target, t.is_approved, t.visit_id, t.job_id,
           (t.started_at at time zone 'America/New_York')::date as d,
           extract(epoch from (t.ended_at - t.started_at)) as secs
      from hr.time_entries t, lo
     where t.employee_id = p_employee_id and t.removed_at is null
       and t.started_at >= lo.t0 and t.started_at < lo.t1),
  clock as (select distinct e.d from e where e.category = 'GENERAL' and e.timer_target is null and e.ended_at is not null),
  f as (
    select s.shift_date as d, s.pre_submitted_at as a, s.post_submitted_at as b
      from public.v_inspection_shifts s
     where s.employee_id = p_employee_id and s.shift_date between p_from - 1 and p_to + 1),
  fc as (
    select f.* from f
     where f.a is not null and f.b is not null and f.b > f.a
       and f.d not in (select clock.d from clock)
       and not exists (select 1 from e where e.category = 'GENERAL' and e.timer_target is null and e.ended_at is not null
                                         and e.started_at < f.b and e.ended_at > f.a)),
  c as (
    select e.*,
           case when e.ended_at is null then null
                when e.d in (select clock.d from clock) then 'jobber'
                when exists (select 1 from fc where fc.d = e.d) then null
                when exists (select 1 from fc where e.started_at >= fc.a and e.started_at < fc.b) then null
                else 'jobber_no_clock_in' end as counted_as
      from e),
  dd as (
    select x.d from (select e.d from e union select f.d from f) x where x.d between p_from and p_to),
  day as (
    select dd.d,
           case when dd.d in (select clock.d from clock) then 'jobber'
                when exists (select 1 from fc where fc.d = dd.d) then 'shift_forms'
                when exists (select 1 from c where c.d = dd.d and c.counted_as = 'jobber_no_clock_in') then 'jobber_no_clock_in'
           end as src
      from dd),
  agg as (
    select day.d, day.src,
           case when day.src = 'shift_forms'
                then (select sum(extract(epoch from (fc.b - fc.a))) from fc where fc.d = day.d)
                else (select sum(c.secs) from c where c.d = day.d and c.counted_as = day.src) end as secs,
           (select min(c.started_at) from c where c.d = day.d and c.counted_as is not null) as w0,
           (select max(c.ended_at) from c where c.d = day.d and c.counted_as is not null) as w1,
           (select bool_and(c.is_approved) from c where c.d = day.d and c.counted_as = day.src) as all_ok,
           (select bool_or(c.is_approved) from c where c.d = day.d and c.counted_as = day.src) as any_ok,
           exists (select 1 from e where e.d = day.d and e.ended_at is null) as is_running
      from day)
  select a.d,
         coalesce(round(a.secs / 60.0), 0)::integer,
         a.src,
         case when a.src = 'shift_forms' then 'not_in_jobber'
              when a.src is null then null
              when a.all_ok then 'approved' when a.any_ok then 'partly' else 'not_approved' end,
         a.is_running,
         array_remove(array[
           case when a.src = 'jobber'
                 and not exists (select 1 from public.visits v
                                  where v.deleted_at is null and v.visit_date between a.d - 1 and a.d + 1
                                    and (v.assigned_driver_id = p_employee_id
                                         or exists (select 1 from public.visit_team vt where vt.visit_id = v.id and vt.employee_id = p_employee_id))
                                    and coalesce(v.actual_arrival_at, v.completed_at, v.actual_departure_at) between a.w0 and a.w1)
                 and not exists (select 1 from public.inspections i
                                  where i.employee_id = p_employee_id
                                    and i.submitted_at between a.w0 - interval '2 hours' and a.w1 + interval '2 hours')
                then 'no_work_behind' end,
           case when exists (select 1 from e where e.d = a.d and e.secs > 14 * 3600) or coalesce(a.secs, 0) > 16 * 3600
                then 'high_hours' end,
           case when exists (select 1 from e where e.d = a.d and e.ended_at is null and e.started_at < now() - interval '14 hours')
                then 'still_clocked_in' end,
           case when a.src is distinct from 'jobber' and exists (select 1 from f where f.d = a.d and (f.a is null or f.b is null))
                then 'half_shift' end,
           case when a.src = 'jobber_no_clock_in' then 'no_shift_clocked_in' end
         ], null),
         r.amount,
         case when r.amount is not null and a.secs is not null then round(a.secs / 3600.0 * r.amount, 2) end,
         coalesce((select jsonb_agg(jsonb_build_object(
                     'id', c.id,
                     'start', c.started_at,
                     'end', c.ended_at,
                     'minutes', round(c.secs / 60.0)::integer,
                     'category', c.category,
                     'timer_target', c.timer_target,
                     'approved', c.is_approved,
                     'visit_id', c.visit_id,
                     'client_code', (select cl.client_code from public.visits v join public.clients cl on cl.id = v.client_id where v.id = c.visit_id),
                     'counted', c.counted_as is not null) order by c.started_at)
                     from c where c.d = a.d), '[]'::jsonb)
    from agg a
    left join lateral (select x.amount from hr.fn_rate_on(p_employee_id, 'hourly', a.d) x) r on true
   order by a.d
$function$;
REVOKE ALL ON FUNCTION hr.fn_hours_worked(bigint, date, date) FROM PUBLIC, anon, authenticated, service_role;
DO $v$ BEGIN
  IF md5(regexp_replace(pg_get_functiondef('hr.fn_hours_worked(bigint,date,date)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '9868f4d6d01d317ab1ba1284143c72fa' THEN
    RAISE EXCEPTION 'VERIFY: not back to the earlier body'; END IF;
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
