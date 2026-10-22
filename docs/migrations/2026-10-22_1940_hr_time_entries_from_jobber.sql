-- 2026-10-22_1940_hr_time_entries_from_jobber.sql
--
-- Trello KqGyoiKQ (Yan, 2026-10-06: "how much they are making per hour, per job, and per shift"). Fred, 2026-10-22: "for the
-- hours worked from each of them we can use the Jobber timesheet", then his picks: Mark (no clock-in) "Fall back to his shift
-- forms", count every entry and show whether Jobber approved it, flag mismatches. Plan:
-- Building Apps/HR App/docs/specs/2026-10-22-hours-worked-from-jobber-timesheet.md (steps 1-3).
--
-- 1. public.entity_source_links CHECK gains 'time_entry' (the Jobber TimeSheetEntry id). Grepped first: 0 function and 0 view
--    bodies mention time_entr, so no dormant reader wakes up.
-- 2. NEW hr.time_entries: Jobber's time sheet, one row per entry, written ONLY by hr.sync_time_entries (edge fn
--    sync-jobber-timesheets, next migration). No duration column: for every finished entry Jobber's finalDuration equals
--    endAt - startAt (measured on 955 of 955); a running entry has ended_at NULL (Jobber sends endAt = now and finalDuration 0
--    while ticking). 🛑 Jobber files VISIT timers under GENERAL too, so a clocked shift = GENERAL with timer_target NULL
--    (found by this migration's own probe: Mark's visit timers read as a clocked shift until timer_target was added).
-- 3. NEW hr.sync_time_entries(entries, window_from, window_to): idempotent on the Jobber id; with a window it marks entries
--    Jobber no longer returns as removed_at (never deletes) and refuses an empty answer over a window holding entries, or a
--    removal of more than 20 and a quarter of the window. service_role only.
-- 4. NEW hr.fn_hours_worked(employee, from, to): the rule, one row per ET work day (the day an entry starts, as Jobber shows
--    it): a clocked shift -> Jobber's total; else a complete PRE + POST pair -> POST - PRE (an entry inside it is absorbed);
--    else the entries as they are. A running entry counts nothing; flags (no_work_behind, high_hours, still_clocked_in,
--    half_shift, no_shift_clocked_in) never change the count; pay = hours x hr.fn_rate_on(person, 'hourly', day). Callable
--    only by the hr readers (no app grant).
-- 5. hr.get_employee_record gains 'hours' (last 26 weeks, each day with week_start / week_end of the person's payroll week)
--    and hr.get_pay_summary gains hours_this_week / hourly_pay_this_week, both only for people with "Pay rates and bonus
--    settings" (v_pay), like the hourly rate. Spliced from the live bodies (md5 guards), nothing else moved.
--
-- Rule 8: hr.time_entries is a sync-only copy of Jobber -> NOT audited (opt-out): every write is the sync, Jobber holds the
-- history, and removed_at keeps a deleted entry. RLS on, no policy, no app grant (postgres + db_backup_reader, like the other
-- hr tables).
-- Rehearsed in a rolled-back transaction with all 955 entries of 2026 read from Jobber's API the same night (29 checks: the
-- stored week totals equal Jobber's Timesheets Week view for Michael, Grecia and Mark, Oct 5-25, to the minute; Michael Oct 13
-- 9h 7m; Mark Oct 12 4h 15m from his forms; Michael Oct 12 flagged; a copy of the rule without the form fallback FAILS the
-- Mark check; window removal and its refusals; both readers as Fred through the app role). Rollback rehearsed after the
-- forward: 2026-10-22_rollback_hr_time_entries_from_jobber.sql.

BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(regexp_replace(pg_get_functiondef('hr.get_employee_record(bigint)'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> 'be558f103040f2fc4657fc9358556a88' THEN RAISE EXCEPTION 'guard: hr.get_employee_record(bigint) changed'; END IF;
  IF md5(regexp_replace(pg_get_functiondef('hr.get_pay_summary()'::regprocedure), '^[[:space:]]+|[[:space:]]+$', '', 'g')) <> '4d802a5c581fa4625a5265eb97a1990e' THEN RAISE EXCEPTION 'guard: hr.get_pay_summary() changed'; END IF;
  IF to_regclass('hr.time_entries') IS NOT NULL THEN RAISE EXCEPTION 'guard: hr.time_entries exists'; END IF;
END $g$;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS SELECT p.oid::regprocedure::text k, p.proacl::text a FROM pg_proc p
 WHERE p.oid IN ('hr.get_employee_record(bigint)'::regprocedure, 'hr.get_pay_summary()'::regprocedure);
CREATE TEMP TABLE pending_before ON COMMIT DROP AS
  SELECT e.id, hr.fn_pending_bonus(e.id, (now() at time zone 'America/New_York')::date) amt FROM public.employees e;
CREATE TEMP TABLE esl_before ON COMMIT DROP AS SELECT count(*) n FROM public.entity_source_links;

-- ---------- the link kind: a Jobber time sheet entry ----------
ALTER TABLE public.entity_source_links DROP CONSTRAINT entity_source_links_entity_type_chk;
ALTER TABLE public.entity_source_links ADD CONSTRAINT entity_source_links_entity_type_chk CHECK ((entity_type = ANY (ARRAY[
  'client'::text, 'derm_manifest'::text, 'employee'::text, 'inspection'::text, 'invoice'::text, 'job'::text, 'line_item'::text,
  'note'::text, 'photo'::text, 'property'::text, 'quote'::text, 'vehicle'::text, 'visit'::text, 'calendar_day_marker'::text,
  'calendar_task'::text, 'tank_sensor'::text, 'time_entry'::text])));

-- ---------- the copy of Jobber's time sheet ----------
CREATE TABLE hr.time_entries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id bigint NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  started_at timestamptz NOT NULL,
  ended_at timestamptz,
  is_approved boolean NOT NULL,
  approved_by_employee_id bigint REFERENCES public.employees(id) ON DELETE RESTRICT,
  category text,
  timer_target text CONSTRAINT time_entries_timer_target CHECK (timer_target IN ('visit', 'job', 'assessment')),
  note text,
  visit_id bigint REFERENCES public.visits(id) ON DELETE RESTRICT,
  job_id bigint REFERENCES public.jobs(id) ON DELETE RESTRICT,
  source_updated_at timestamptz NOT NULL,
  removed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT time_entries_end_after_start CHECK (ended_at IS NULL OR ended_at >= started_at),
  CONSTRAINT time_entries_one_target CHECK (visit_id IS NULL OR job_id IS NULL)
);
COMMENT ON TABLE hr.time_entries IS
  'Jobber''s time sheet, one row per entry (2026-10-22, Trello KqGyoiKQ; Fred: "for the hours worked from each of them we can '
  'use the Jobber timesheet"). Jobber is the master: written ONLY by hr.sync_time_entries (edge fn sync-jobber-timesheets), '
  'never edited here. The Jobber id is in public.entity_source_links (entity_type time_entry). ended_at NULL = still clocked '
  'in. The duration is ended_at - started_at (equal to Jobber''s finalDuration for every finished entry, measured on 955). '
  'removed_at = Jobber no longer returns it (deleted there); never deleted here. Hours per day: hr.fn_hours_worked.';
COMMENT ON COLUMN hr.time_entries.category IS 'Jobber timeSheetCategory: GENERAL, DRIVING, SUPPLIES, BREAK, OFFICE, CUSTOM, or NULL. Jobber files VISIT timers under GENERAL too: a clocked shift is GENERAL with timer_target NULL.';
COMMENT ON COLUMN hr.time_entries.timer_target IS 'What the entry''s timer ran on in Jobber (targetItem): visit, job, assessment, or NULL for a clock-in. Kept even when the visit or job is not in our DB.';
COMMENT ON COLUMN hr.time_entries.visit_id IS 'The visit the entry''s timer ran on (Jobber targetItem Visit), when that visit is in our DB.';
COMMENT ON COLUMN hr.time_entries.job_id IS 'The job the entry''s timer ran on when its target is a Job (not a visit).';
CREATE INDEX time_entries_employee_start ON hr.time_entries (employee_id, started_at);
CREATE TRIGGER time_entries_updated_at BEFORE UPDATE ON hr.time_entries FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
ALTER TABLE hr.time_entries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON hr.time_entries FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON hr.time_entries TO db_backup_reader;

-- ---------- the only writer ----------
CREATE FUNCTION hr.sync_time_entries(p_entries jsonb, p_window_from timestamptz DEFAULT NULL, p_window_to timestamptz DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-10-22 (Trello KqGyoiKQ): copies Jobber time sheet entries (the raw timeSheetEntries nodes, as the edge fn
-- sync-jobber-timesheets reads them) into hr.time_entries. Idempotent on the Jobber id. With a window (both ends), the
-- caller read EVERY entry Jobber has starting in [from, to): an entry of ours in that window that Jobber no longer
-- returns is marked removed_at. 🛑 A missing answer is not an empty one: an empty list over a window that holds entries,
-- or a removal of more than 20 entries and a quarter of the window, is refused (the whole call rolls back).
declare
  v_n int; v_ins int := 0; v_upd int := 0; v_rem int := 0; v_win int := 0; v_id bigint; r record;
  v_unlinked jsonb; v_no_target int; v_bad int;
begin
  if jsonb_typeof(p_entries) is distinct from 'array' then
    raise exception 'p_entries must be a JSON array' using errcode = '22023';
  end if;
  if (p_window_from is null) <> (p_window_to is null) or p_window_from >= p_window_to then
    raise exception 'a window needs both ends, from before to' using errcode = '22023';
  end if;

  drop table if exists pg_temp.te_in;
  create temp table te_in on commit drop as
  select x->>'id' as gid,
         (x->>'startAt')::timestamptz as started_at,
         case when coalesce((x->>'ticking')::boolean, false) then null else (x->>'endAt')::timestamptz end as ended_at,
         coalesce((x->>'approved')::boolean, false) as is_approved,
         x #>> '{approvedBy,id}' as approver_gid,
         x->>'timeSheetCategory' as category,
         lower(x #>> '{targetItem,__typename}') as timer_target,
         nullif(btrim(x->>'note'), '') as note,
         (x->>'updatedAt')::timestamptz as source_updated_at,
         x #>> '{user,id}' as user_gid,
         x #>> '{user,name,full}' as user_name,
         x #>> '{targetItem,__typename}' as target_type,
         x #>> '{targetItem,id}' as target_gid
    from jsonb_array_elements(p_entries) x;
  select count(*) into v_n from pg_temp.te_in;

  select count(*) into v_bad from pg_temp.te_in
   where gid is null or started_at is null or source_updated_at is null or user_gid is null
      or (ended_at is not null and ended_at < started_at);
  if v_bad > 0 then
    raise exception '% time sheet entries are missing their id, start, update time or person, or end before they start', v_bad using errcode = '22023';
  end if;
  if (select count(distinct gid) from pg_temp.te_in) <> v_n then
    raise exception 'the same time sheet entry appears twice in one call' using errcode = '22023';
  end if;

  drop table if exists pg_temp.te_r;
  create temp table te_r on commit drop as
  select i.*, le.entity_id as employee_id, la.entity_id as approver_id,
         case when i.target_type = 'Visit' then lv.entity_id end as visit_id,
         case when i.target_type = 'Job' then lj.entity_id end as job_id,
         lt.entity_id as existing_id
    from pg_temp.te_in i
    left join public.entity_source_links le on le.entity_type = 'employee' and le.source_system = 'jobber' and le.source_id = i.user_gid
    left join public.entity_source_links la on la.entity_type = 'employee' and la.source_system = 'jobber' and la.source_id = i.approver_gid
    left join public.entity_source_links lv on lv.entity_type = 'visit' and lv.source_system = 'jobber' and lv.source_id = i.target_gid
    left join public.entity_source_links lj on lj.entity_type = 'job' and lj.source_system = 'jobber' and lj.source_id = i.target_gid
    left join public.entity_source_links lt on lt.entity_type = 'time_entry' and lt.source_system = 'jobber' and lt.source_id = i.gid;

  select coalesce(jsonb_agg(jsonb_build_object('user', u.user_gid, 'name', u.user_name, 'entries', u.n)), '[]'::jsonb) into v_unlinked
    from (select user_gid, max(user_name) user_name, count(*) n from pg_temp.te_r where employee_id is null group by 1) u;
  select count(*) into v_no_target from pg_temp.te_r
   where employee_id is not null and target_type in ('Visit', 'Job') and coalesce(visit_id, job_id) is null;

  for r in select * from pg_temp.te_r where existing_id is null and employee_id is not null loop
    insert into hr.time_entries (employee_id, started_at, ended_at, is_approved, approved_by_employee_id, category, timer_target, note,
                                 visit_id, job_id, source_updated_at)
    values (r.employee_id, r.started_at, r.ended_at, r.is_approved, r.approver_id, r.category, r.timer_target, r.note,
            r.visit_id, r.job_id, r.source_updated_at)
    returning id into v_id;
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id, match_method, synced_at)
    values ('time_entry', v_id, 'jobber', r.gid, 'sync-jobber-timesheets', now());
    v_ins := v_ins + 1;
  end loop;

  update hr.time_entries t
     set employee_id = x.employee_id, started_at = x.started_at, ended_at = x.ended_at, is_approved = x.is_approved,
         approved_by_employee_id = x.approver_id, category = x.category, timer_target = x.timer_target, note = x.note, visit_id = x.visit_id,
         job_id = x.job_id, source_updated_at = x.source_updated_at, removed_at = null
    from pg_temp.te_r x
   where t.id = x.existing_id and x.employee_id is not null
     and (t.employee_id, t.started_at, t.ended_at, t.is_approved, t.approved_by_employee_id, t.category, t.timer_target, t.note, t.visit_id,
          t.job_id, t.source_updated_at, t.removed_at)
         is distinct from
         (x.employee_id, x.started_at, x.ended_at, x.is_approved, x.approver_id, x.category, x.timer_target, x.note, x.visit_id,
          x.job_id, x.source_updated_at, null::timestamptz);
  get diagnostics v_upd = row_count;

  if p_window_from is not null then
    select count(*) into v_win from hr.time_entries t
     where t.removed_at is null and t.started_at >= p_window_from and t.started_at < p_window_to;
    if v_n = 0 and v_win > 0 then
      raise exception 'Jobber returned no time sheet entries for a window that holds % here; refusing to mark them removed', v_win
        using errcode = 'P0001';
    end if;
    update hr.time_entries t set removed_at = now()
     where t.removed_at is null and t.started_at >= p_window_from and t.started_at < p_window_to
       and not exists (select 1 from public.entity_source_links l join pg_temp.te_in i on i.gid = l.source_id
                        where l.entity_type = 'time_entry' and l.source_system = 'jobber' and l.entity_id = t.id);
    get diagnostics v_rem = row_count;
    if v_rem > 20 and v_rem * 4 > v_win then
      raise exception 'refusing to mark % of % time sheet entries removed in one call', v_rem, v_win using errcode = 'P0001';
    end if;
  end if;

  return jsonb_build_object('received', v_n, 'inserted', v_ins, 'updated', v_upd, 'removed', v_rem,
                            'unlinked_users', v_unlinked, 'target_not_in_db', v_no_target);
end $function$;
REVOKE ALL ON FUNCTION hr.sync_time_entries(jsonb, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION hr.sync_time_entries(jsonb, timestamptz, timestamptz) TO service_role;

-- ---------- the rule: hours per person per work day ----------
CREATE FUNCTION hr.fn_hours_worked(p_employee_id bigint, p_from date, p_to date)
 RETURNS TABLE(work_day date, minutes integer, source text, approval text, running boolean, flags text[],
               hourly_rate numeric, pay numeric, entries jsonb)
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

-- ---------- the readers: hours in the record and this week's hours in the summary (spliced from the live bodies) ----------
CREATE OR REPLACE FUNCTION hr.get_employee_record(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller bigint; v_level text; v_e public.employees; v_pay boolean; v_seebonus boolean; v_can_edit boolean;
  v_today date := (now() at time zone 'America/New_York')::date;
  v_rates jsonb; v_history jsonb; v_weeks jsonb; v_activity jsonb; v_company jsonb; v_bonus jsonb; v_hours jsonb;
begin
  select c.employee_id, c.access_level into v_caller, v_level from hr.fn_require_level(array['admin', 'office']) c;
  select * into v_e from public.employees where id = p_id;
  if not found then
    raise exception 'That person was not found. Reload the page.' using errcode = 'P0002', detail = 'blocker=not_found employee_id=' || p_id;
  end if;
  -- 2026-10-19_2200: the HR App checks the person's access settings (hr.access_*); pay rates follow "Pay rates and bonus
  -- settings", bonuses "See bonus amounts", editing the HR App level. While a row is not checked, the old group rule stands.
  perform hr.fn_require_app('hr', 'view');
  v_pay := case when hr.fn_app_mode('hr_pay') = 'on' then hr.fn_app_level('hr_pay') = 'yes' else v_level = 'admin' end;
  v_seebonus := case when hr.fn_app_mode('hr_bonus') = 'on' then hr.fn_app_level('hr_bonus') = 'yes' else true end;
  v_can_edit := case when hr.fn_app_mode('hr') = 'on' then hr.fn_app_level('hr') = 'edit' else true end;

  v_company := jsonb_build_object(
    'per_visit_bonus', (select r.amount from hr.fn_rate_on(p_id, 'per_visit_bonus', v_today) r),
    'per_shift_bonus', (select r.amount from hr.fn_rate_on(p_id, 'per_shift_bonus', v_today) r));

  -- 2026-10-19_1200: this person's own bonus amounts (admin and office), with the next scheduled change
  select jsonb_object_agg(k.kind, jsonb_build_object(
           'amount', r.amount,
           'since', p.effective_from,
           'next', (select jsonb_build_object('amount', n.amount, 'effective_from', n.effective_from)
                      from hr.pay_rates n where n.employee_id = p_id and n.kind = k.kind and n.effective_from > v_today
                       and not hr.fn_rate_superseded(n.id, n.employee_id, n.kind, n.effective_from)
                     order by n.effective_from, n.id desc limit 1)))
    into v_bonus
    from unnest(array['per_visit_bonus', 'per_shift_bonus']) k(kind)
    cross join lateral hr.fn_rate_on(p_id, k.kind, v_today) r
    left join hr.pay_rates p on p.id = r.rate_id;

  if v_pay then
    select coalesce(jsonb_agg(x order by x->>'kind'), '[]'::jsonb) into v_rates from (
      select jsonb_build_object('kind', k.kind, 'amount', r.amount, 'effective_from', p.effective_from,
                                'reason', p.reason, 'set_by', hr.fn_person_label(p.created_by_email)) x
        from unnest(array['hourly', 'salary_weekly', 'salary_yearly']) k(kind)
        cross join lateral hr.fn_rate_on(p_id, k.kind, v_today) r
        left join hr.pay_rates p on p.id = r.rate_id
       where r.amount is not null) s;
  end if;

  -- One history list, newest first: rate changes (admin only) and bonuses (admin and office)
  select coalesce(jsonb_agg(h order by (h->>'date') desc, (h->>'sort_at') desc, (h->>'id')::bigint desc), '[]'::jsonb) into v_history from (
    -- 2026-10-19_1815 (Fred): pay rate changes are shown in Activity, never in this history table
    select jsonb_build_object(
      'id', g.id, 'type', case when g.rule = 'reversal' then 'reversal' else g.kind end,
      'date', g.work_date, 'sort_at', g.created_at,
      'title', case when g.rule = 'reversal' then 'Bonus taken back'
                    when g.kind = 'visit_bonus' then 'Visit bonus' else 'Shift bonus' end,
      'amount', g.amount, 'unit', null,
      'detail', concat_ws(' · ',
                  case when g.kind = 'visit_bonus' then concat_ws(' ', c.client_code, c.name) else 'Shift forms of ' || to_char(g.work_date, 'Mon FMDD') end,
                  case when g.crew_size > 1 then 'shared visit, ' || g.crew_size || ' on the crew' end,
                  g.note),
      'by', coalesce(hr.fn_person_label(g.decided_by_email), case when g.rule = 'reversal' then 'System' end),
      'decided_at', g.decided_at,
      'source', 'Admin Review',
      'link', case when g.kind = 'visit_bonus' then '/review/' || g.visit_id
                   else '/review-shift/shift-' || g.employee_id || '-' || to_char(g.work_date, 'YYYY-MM-DD') end,
      'reversed', exists (select 1 from hr.bonus_events r where r.reverses_id = g.id),
      -- 2026-10-19_0215: structured fields (additive; the keys above are unchanged)
      'bonus_kind', g.kind, 'rule', g.rule, 'visit_id', g.visit_id,
      'client_code', c.client_code, 'client_name', c.name,
      'crew_size', g.crew_size,
      'shared_with', (select jsonb_agg(e2.full_name order by e2.full_name)
                        from hr.bonus_events b2 join public.employees e2 on e2.id = b2.employee_id
                       where g.visit_id is not null and b2.visit_id = g.visit_id and b2.employee_id <> g.employee_id
                         and b2.kind = 'visit_bonus' and b2.reverses_id is null
                         and not exists (select 1 from hr.bonus_events r2 where r2.reverses_id = b2.id)),
      'note', g.note,
      'decided_on', (g.decided_at at time zone 'America/New_York')::date, 'decided_time', to_char(g.decided_at at time zone 'America/New_York', 'HH24:MI'),
      'recorded_on', (g.created_at at time zone 'America/New_York')::date,
      'week_start', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6,
      'reverses_id', g.reverses_id,
      'reversed_on', (select (r.created_at at time zone 'America/New_York')::date from hr.bonus_events r where r.reverses_id = g.id order by r.id limit 1),
      'after_week_ended', case when g.rule = 'reversal'
                               then (g.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6
                               else (select (r.created_at at time zone 'America/New_York')::date > hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6
                                       from hr.bonus_events r where r.reverses_id = g.id order by r.id limit 1) end,
      'counts_in_total', true,
      'admin_review_url', hr.fn_admin_review_url(g.kind, g.visit_id, g.employee_id, g.work_date),
      -- 2026-10-19_1900 (Fred): every row says its status
      'status', case when g.rule = 'reversal' then 'taken_back' else 'approved' end) h
      from hr.bonus_events g
      left join public.visits v on v.id = g.visit_id
      left join public.clients c on c.id = v.client_id
     where g.employee_id = p_id
    -- 2026-10-19_1900 (Fred): the bonuses not recorded in HR, so the table shows every bonus with its status.
    -- Pending: what Admin Review still has to decide (the same scope as hr.fn_pending_bonus), priced at the person's
    -- rate on the work date. Rejected: a decision of "not eligible", $0, with Admin Review's reason. Neither counts in
    -- a total. Ids are negative (visits: -visit_id; shifts: -(1000000 + days since 2020-01-01)) so a row key never
    -- equals a recorded bonus id.
    union all
    select jsonb_build_object(
      'id', -v.id, 'type', 'visit_bonus', 'date', v.visit_date, 'sort_at', v.completed_at,
      'title', 'Visit bonus', 'amount', case when coalesce(v.bonus_status, 'pending') = 'pending' then coalesce(r.amount, 0) else 0 end,
      'detail', concat_ws(' ', c.client_code, c.name),
      'by', case when v.bonus_status = 'denied' then coalesce(hr.fn_person_label(rj.email), 'Admin Review') end,
      'decided_at', case when v.bonus_status = 'denied' then vr.bonus_decided_at end,
      'link', '/review/' || v.id,
      'bonus_kind', 'visit_bonus', 'rule', case when v.bonus_status = 'denied' then 'denied' else 'pending' end,
      'visit_id', v.id, 'client_code', c.client_code, 'client_name', c.name,
      'crew_size', (select count(*) from public.visit_team t2 where t2.visit_id = v.id),
      'shared_with', (select jsonb_agg(e2.full_name order by e2.full_name) from public.visit_team t2
                        join public.employees e2 on e2.id = t2.employee_id where t2.visit_id = v.id and t2.employee_id <> p_id),
      'note', case when v.bonus_status = 'denied' then vr.bonus_denial_note else r.custom_note end,
      'decided_on', case when v.bonus_status = 'denied' then (vr.bonus_decided_at at time zone 'America/New_York')::date end,
      'decided_time', case when v.bonus_status = 'denied' then to_char(vr.bonus_decided_at at time zone 'America/New_York', 'HH24:MI') end,
      'week_start', hr.fn_payroll_week_start(v.visit_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(v.visit_date, v_e.payroll_week_start_day) + 6,
      'admin_review_url', hr.fn_admin_review_url('visit_bonus', v.id, p_id, v.visit_date),
      'status', case when v.bonus_status = 'denied' then 'rejected' else 'pending' end)
      || jsonb_build_object(
      'unit', null, 'source', 'Admin Review', 'reversed', false, 'reverses_id', null, 'reversed_on', null,
      'after_week_ended', false, 'counts_in_total', false, 'recorded_on', null) h
      from public.visits_with_review v
      join public.visit_team t on t.visit_id = v.id and t.employee_id = p_id
      left join public.visit_reviews vr on vr.visit_id = v.id
      left join public.clients c on c.id = v.client_id
      left join lateral hr.fn_visit_rate_on(p_id, v.id, v.visit_date) r on true
      left join lateral (select lower(btrim(nullif(a.jwt_claims->>'email', ''))) as email from audit.logs a
                          where a.table_name = 'visit_reviews' and a.record_pk = jsonb_build_object('visit_id', v.id)
                            and a.new_row->>'bonus_status' = 'denied'
                            and (a.old_row is null or a.old_row->>'bonus_status' is distinct from 'denied')
                          order by a.id desc limit 1) rj on v.bonus_status = 'denied'
     where v.visit_status = 'completed' and not public.fn_is_non_customer(v.client_id)
       and ((coalesce(v.bonus_status, 'pending') = 'pending' and v.in_review_scope and v.visit_date <= v_today)
            or v.bonus_status = 'denied')
    union all
    select jsonb_build_object(
      'id', -(1000000 + (x.shift_date - date '2020-01-01')), 'type', 'shift_bonus', 'date', x.shift_date, 'sort_at', x.shift_date::timestamptz,
      'title', 'Shift bonus', 'amount', case when x.status = 'pending' then coalesce(r.amount, 0) else 0 end,
      'detail', 'Shift forms of ' || to_char(x.shift_date, 'Mon FMDD'),
      'by', case when x.status = 'rejected' then coalesce(hr.fn_person_label(rj.email), 'Admin Review') end,
      'decided_at', x.decided_at, 'link', '/review-shift/shift-' || p_id || '-' || to_char(x.shift_date, 'YYYY-MM-DD'),
      'bonus_kind', 'shift_bonus', 'rule', case when x.status = 'rejected' then 'denied' else 'pending' end,
      'visit_id', null, 'client_code', null, 'client_name', null, 'crew_size', null, 'shared_with', null,
      'note', coalesce(x.note, case when x.status = 'pending' then r.custom_note end),
      'decided_on', (x.decided_at at time zone 'America/New_York')::date,
      'decided_time', to_char(x.decided_at at time zone 'America/New_York', 'HH24:MI'),
      'week_start', hr.fn_payroll_week_start(x.shift_date, v_e.payroll_week_start_day), 'week_end', hr.fn_payroll_week_start(x.shift_date, v_e.payroll_week_start_day) + 6,
      'admin_review_url', hr.fn_admin_review_url('shift_bonus', null, p_id, x.shift_date),
      'status', x.status)
      || jsonb_build_object(
      'unit', null, 'source', 'Admin Review', 'reversed', false, 'reverses_id', null, 'reversed_on', null,
      'after_week_ended', false, 'counts_in_total', false, 'recorded_on', null) h
      from (
        -- pending: the shifts of the last 28 days with both forms and no issue, not decided (as hr.fn_pending_bonus)
        select s.shift_date, 'pending'::text as status, null::timestamptz as decided_at, null::text as note
          from (select v.shift_date from public.v_inspection_shifts v   -- 2026-10-21 ZEYkT63t: paired shifts
                 where v.employee_id = p_id and v.shift_date >= v_today - 28 and v.shift_date <= v_today and v.kind = 'pair'
                 group by v.shift_date) s
         where not exists (select 1 from public.shift_reviews sr where sr.employee_id = p_id and sr.shift_date = s.shift_date
                             and coalesce(sr.bonus_status, 'pending') <> 'pending')
        union all
        select sr.shift_date, 'rejected', sr.bonus_decided_at, sr.bonus_denial_note
          from public.shift_reviews sr where sr.employee_id = p_id and sr.bonus_status = 'denied'
      ) x
      left join lateral hr.fn_shift_rate_on(p_id, x.shift_date) r on true
      left join lateral (select lower(btrim(nullif(a.jwt_claims->>'email', ''))) as email from audit.logs a
                          where a.table_name = 'shift_reviews'
                            and a.record_pk = jsonb_build_object('employee_id', p_id, 'shift_date', to_char(x.shift_date, 'YYYY-MM-DD'))
                            and a.new_row->>'bonus_status' = 'denied'
                            and (a.old_row is null or a.old_row->>'bonus_status' is distinct from 'denied')
                          order by a.id desc limit 1) rj on x.status = 'rejected'
  ) s;

  select coalesce(jsonb_agg(w order by w->>'week_start' desc), '[]'::jsonb) into v_weeks from (
    select jsonb_build_object('week_start', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day),
                              'week_end', hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day) + 6,
                              'total', sum(g.amount),
                              'visit_bonuses', count(*) filter (where g.kind = 'visit_bonus' and g.rule <> 'reversal'),
                              'shift_bonuses', count(*) filter (where g.kind = 'shift_bonus' and g.rule <> 'reversal')) w
      from hr.bonus_events g where g.employee_id = p_id
     group by hr.fn_payroll_week_start(g.work_date, v_e.payroll_week_start_day)) s;

  select coalesce(jsonb_agg(a order by (a->>'at') desc, (a->>'id')::bigint desc), '[]'::jsonb) into v_activity from (
    select a from (
    select jsonb_build_object(
      'id', l.id, 'at', l.changed_at, 'operation', l.operation,
      'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'),
                     case when l.app_source is null then 'Not recorded'
                          when l.app_source = 'sql' then 'Changed outside the apps'
                          when l.app_source = 'employee-dedup-merge' then 'Duplicate clean-up'
                          when l.app_source = 'hr-app' then 'HR App'
                          when l.app_source = 'admin-review' then 'Admin Review'
                          when l.app_source = 'visit-calendar' then 'Visit Calendar'
                          when l.app_source = 'client-app' then 'Client App'
                          when l.app_source = 'derm-tracker' then 'DERM Tracker'
                          when l.app_source = 'jobber' then 'Jobber sync'
                          else 'Another app' end),
      'app', case l.app_source when 'hr-app' then 'HR App' else null end,
      'changes', (select coalesce(jsonb_agg(jsonb_build_object('field', f.label,
                      -- 2026-10-19_2130: the payroll week is stored as a day number; Activity shows "Thu to Wed"
                      'old', case when f.col = 'payroll_week_start_day' then hr.fn_week_label((l.old_row->>f.col)::smallint) else l.old_row->>f.col end,
                      'new', case when f.col = 'payroll_week_start_day' then hr.fn_week_label((l.new_row->>f.col)::smallint) else l.new_row->>f.col end)
                                             order by f.ord), '[]'::jsonb)
                    from (values (1, 'full_name', 'Name'), (2, 'status', 'Status'), (3, 'shift', 'Shift'), (4, 'email', 'Email'),
                                 (5, 'phone', 'Phone'), (6, 'hire_date', 'Start date'), (7, 'access_level', 'Access'),
                                 (8, 'color_hex', 'Color'), (9, 'payroll_week_start_day', 'Payroll week')) f(ord, col, label)
                   where l.operation = 'INSERT' and l.new_row->>f.col is not null
                      or l.operation = 'UPDATE' and (l.old_row->>f.col) is distinct from (l.new_row->>f.col))) a
      from audit.logs l
     where l.table_name = 'employees' and l.record_pk->>'id' = p_id::text
     order by l.id desc limit 100) s
   where jsonb_array_length(a->'changes') > 0 or a->>'operation' <> 'UPDATE'
  -- 2026-10-19_1815 (Fred): pay rate changes are part of the person's Activity. Bonus amounts for admin and office,
  -- hourly and salary for admin only. The id is negative so it can never equal an audit row id.
  union all
  select jsonb_build_object(
      'id', -p.id, 'at', p.created_at, 'operation', 'RATE',
      'by', coalesce(hr.fn_person_label(p.created_by_email), 'Changed outside the apps'),
      'app', 'HR App',
      'changes', jsonb_build_array(
        jsonb_build_object('field', case p.kind when 'hourly' then 'Hourly rate' when 'salary_weekly' then 'Weekly salary'
                                                when 'salary_yearly' then 'Yearly salary' when 'per_visit_bonus' then 'Visit bonus'
                                                else 'Shift bonus' end,
                           'old', case when p.prev_amount is null then null else to_char(p.prev_amount, 'FM$999,999,990.00') end,
                           'new', coalesce(to_char(p.amount, 'FM$999,999,990.00'), 'Stopped')
                                  || ' from ' || to_char(p.effective_from, 'Mon FMDD, YYYY')),
        jsonb_build_object('field', 'Reason', 'old', null, 'new', p.reason))
      -- 2026-10-21 (Fred): an amount change that also moved approved bonuses says how many
      || coalesce((select jsonb_build_array(jsonb_build_object('field', 'Approved bonuses updated', 'old', null,
                     'new', count(*) || case when p.kind = 'per_shift_bonus' then ' shift' else ' visit' end
                            || case when count(*) = 1 then '' else 's' end || ' changed to the new amount'))
                     from hr.bonus_events b where b.reprice_rate_id = p.id and b.reverses_id is null having count(*) > 0),
                  '[]'::jsonb)
      -- 2026-10-21 (Fred: "make since replace later amounts too"): the later dated amounts this change replaced
      || coalesce((select jsonb_build_array(jsonb_build_object('field', 'Replaces later amounts', 'old', null,
                     'new', string_agg(to_char(o.amount, 'FM$999,999,990.00') || ' from ' || to_char(o.effective_from, 'Mon FMDD, YYYY'), ', '
                                       order by o.effective_from)))
                     from (select distinct on (o0.effective_from) o0.* from hr.pay_rates o0
                            where p.replaces_later and o0.employee_id = p.employee_id and o0.kind = p.kind
                              and o0.effective_from > p.effective_from and o0.id < p.id
                              and not exists (select 1 from hr.pay_rates y where y.employee_id = o0.employee_id and y.kind = o0.kind
                                                and y.replaces_later and y.id > o0.id and y.id < p.id and y.effective_from <= o0.effective_from)
                            order by o0.effective_from, o0.id desc) o
                   having count(*) > 0), '[]'::jsonb)) a
    from (select p0.*, lag(p0.amount) over (partition by p0.kind order by p0.effective_from, p0.id) as prev_amount
            from hr.pay_rates p0 where p0.employee_id = p_id) p
   where (p.kind in ('per_visit_bonus', 'per_shift_bonus') and v_seebonus) or v_pay
  -- 2026-10-20 (Trello bZvoo91Z, Fred: "that should be saved who change that number btw in the history activity"): a
  -- custom visit bonus amount set or removed in Admin Review for this person on one visit.
  union all
  select jsonb_build_object(
      'id', -(2000000000 + o.id), 'at', o.created_at, 'operation', 'RATE',
      'by', coalesce(hr.fn_person_label(o.created_by_email), 'Changed outside the apps'),
      'app', 'Admin Review',
      'changes', jsonb_build_array(
        jsonb_build_object('field', 'Visit bonus, ' || concat_ws(' ', c.client_code, to_char(v.visit_date, 'Mon FMDD, YYYY')),
                           'old', case when o.prev_amount is not null then to_char(o.prev_amount, 'FM$999,999,990.00') || ' for this visit'
                                       else 'Normal amount' end,
                           'new', case when o.amount is not null then to_char(o.amount, 'FM$999,999,990.00') || ' for this visit'
                                       else 'Normal amount' end))
      || case when o.reason is not null then jsonb_build_array(jsonb_build_object('field', 'Reason', 'old', null, 'new', o.reason))
              else '[]'::jsonb end) a
    from (select o0.*, lag(o0.amount) over (partition by o0.visit_id order by o0.id) as prev_amount
            from hr.visit_bonus_overrides o0 where o0.employee_id = p_id) o
    join public.visits v on v.id = o.visit_id
    left join public.clients c on c.id = v.client_id
   where v_seebonus
     and not public.fn_is_non_customer(v.client_id)   -- 2026-10-20 (Fred): a smoke test on the test client never reaches HR
  -- 2026-10-21 (Fred): a custom SHIFT bonus amount set or removed in Admin Review for this person on one shift.
  union all
  select jsonb_build_object(
      'id', -(3000000000 + o.id), 'at', o.created_at, 'operation', 'RATE',
      'by', coalesce(hr.fn_person_label(o.created_by_email), 'Changed outside the apps'),
      'app', 'Admin Review',
      'changes', jsonb_build_array(
        jsonb_build_object('field', 'Shift bonus, ' || to_char(o.shift_date, 'Mon FMDD, YYYY'),
                           'old', case when o.prev_amount is not null then to_char(o.prev_amount, 'FM$999,999,990.00') || ' for this shift'
                                       else 'Normal amount' end,
                           'new', case when o.amount is not null then to_char(o.amount, 'FM$999,999,990.00') || ' for this shift'
                                       else 'Normal amount' end))
      || case when o.reason is not null then jsonb_build_array(jsonb_build_object('field', 'Reason', 'old', null, 'new', o.reason))
              else '[]'::jsonb end) a
    from (select o0.*, lag(o0.amount) over (partition by o0.shift_date order by o0.id) as prev_amount
            from hr.shift_bonus_overrides o0 where o0.employee_id = p_id) o
   where v_seebonus
  -- 2026-10-19_2145: a change to this person's own access settings ("Visit Calendar: Group default -> View")
  union all
  select jsonb_build_object(
      'id', l.id, 'at', l.changed_at, 'operation', 'ACCESS',
      'by', coalesce(hr.fn_person_label(l.jwt_claims->>'email'), 'Changed outside the apps'),
      'app', 'HR App',
      'changes', jsonb_build_array(jsonb_build_object(
        'field', coalesce(ap.name, coalesce(l.new_row, l.old_row)->>'app'),
        'old', case when l.operation = 'INSERT' then 'Group default' else hr.fn_access_label(l.old_row->>'level') end,
        'new', case when l.operation = 'DELETE' then 'Group default' else hr.fn_access_label(l.new_row->>'level') end))) a
    from audit.logs l
    left join hr.access_apps ap on ap.app = coalesce(l.new_row, l.old_row)->>'app'
   where l.table_schema = 'hr' and l.table_name = 'access_overrides' and v_level = 'admin'   -- 2026-10-19_2230: admins only
     and coalesce(l.new_row, l.old_row)->>'employee_id' = p_id::text
     and (l.operation <> 'UPDATE' or (l.old_row->>'level') is distinct from (l.new_row->>'level'))
  -- 2026-10-19_2300: sign-in changes made from the HR App ("Password reset email sent")
  union all
  select jsonb_build_object(
      'id', -(1000000000 + c.id), 'at', coalesce(c.finished_at, c.created_at), 'operation', 'SIGN_IN',
      'by', coalesce(hr.fn_person_label(c.requested_by_email), 'HR App'), 'app', 'HR App',
      'changes', jsonb_build_array(jsonb_build_object('field', 'Sign-in', 'old', null,
        'new', case c.action when 'reset_email' then 'Password reset email sent' when 'turn_off' then 'Sign-in turned off'
                             when 'sign_out' then 'Signed out on ' || coalesce(c.reason, 'every device')
                             else 'Sign-in turned back on' end
               || case when c.status = 'failed' then ' (failed: ' || coalesce(c.reason, 'no reason') || ')' else '' end))) a
    from hr.sign_in_changes c
   where c.employee_id = p_id and c.status in ('done', 'failed') and v_level = 'admin'
  ) s2;

  if not v_seebonus then
    v_history := '[]'::jsonb; v_weeks := '[]'::jsonb; v_bonus := null; v_company := null;
  end if;

  -- 2026-10-22 (Trello KqGyoiKQ): hours worked from the Jobber time sheet (hr.fn_hours_worked), the last 26 weeks, each day
  -- with its payroll week. Hours and hourly pay follow "Pay rates and bonus settings", like the hourly rate.
  if v_pay then
    select coalesce(jsonb_agg(to_jsonb(h) || jsonb_build_object(
             'week_start', hr.fn_payroll_week_start(h.work_day, v_e.payroll_week_start_day),
             'week_end', hr.fn_payroll_week_start(h.work_day, v_e.payroll_week_start_day) + 6) order by h.work_day desc), '[]'::jsonb)
      into v_hours from hr.fn_hours_worked(p_id, v_today - 182, v_today) h;
  end if;

  return jsonb_build_object(
    'employee', hr.fn_employee_json(v_e),
    'viewer', jsonb_build_object('level', v_level, 'can_edit', v_can_edit, 'can_see_pay', v_pay, 'can_see_bonus', v_seebonus, 'is_self', v_e.id = v_caller,
                                 -- 2026-10-19_2145 (decision 10): access follows the email, so only an admin changes email or status
                                 'can_change_email_status', v_e.id <> v_caller and v_level = 'admin',
                                 -- 2026-10-19_2130: only an admin changes a person's payroll week (hr.set_payroll_week)
                                 'can_set_payroll_week', v_pay,
                                 -- 2026-10-19_2300: send a reset email, turn a sign-in off or on (admins, never their own)
                                 'can_manage_sign_in', v_level = 'admin' and v_e.id <> v_caller),
    'sign_in', hr.fn_sign_in_summary(p_id),
    'impact_if_inactive', hr.fn_employee_impact(p_id),
    'company_bonus', v_company,
    'bonus_amounts', v_bonus,
    'rates', v_rates,
    'history', v_history,
    'bonus_weeks', v_weeks,
    'activity', v_activity,
    'hours', v_hours);
end $function$;

CREATE OR REPLACE FUNCTION hr.get_pay_summary()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_level text; v_today date := (now() at time zone 'America/New_York')::date; v_rows jsonb; v_pay boolean; v_seebonus boolean;
begin
  select c.access_level into v_level from hr.fn_require_level(array['admin', 'office']) c;
  -- 2026-10-19_2200: the person's access settings decide
  perform hr.fn_require_app('hr', 'view');
  v_pay := case when hr.fn_app_mode('hr_pay') = 'on' then hr.fn_app_level('hr_pay') = 'yes' else v_level = 'admin' end;
  v_seebonus := case when hr.fn_app_mode('hr_bonus') = 'on' then hr.fn_app_level('hr_bonus') = 'yes' else true end;
  if not v_pay then
    -- 2026-10-19_1200: office sees bonus amounts (not pay rates)
    select coalesce(jsonb_agg(jsonb_build_object(
             'employee_id', e.id,
             'per_visit_bonus', case when v_seebonus then (select r.amount from hr.fn_rate_on(e.id, 'per_visit_bonus', v_today) r) end,
             'per_shift_bonus', case when v_seebonus then (select r.amount from hr.fn_rate_on(e.id, 'per_shift_bonus', v_today) r) end,
             'pending_bonus', case when v_seebonus then hr.fn_pending_bonus(e.id, v_today) end
           ) order by e.id), '[]'::jsonb) into v_rows
      from public.employees e;
    return jsonb_build_object('can_see_pay', false, 'can_see_bonus', v_seebonus, 'rows', v_rows);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'employee_id', e.id,
           'hourly', (select r.amount from hr.fn_rate_on(e.id, 'hourly', v_today) r),
           'salary_weekly', (select r.amount from hr.fn_rate_on(e.id, 'salary_weekly', v_today) r),
           'salary_yearly', (select r.amount from hr.fn_rate_on(e.id, 'salary_yearly', v_today) r),
           'per_visit_bonus', (select r.amount from hr.fn_rate_on(e.id, 'per_visit_bonus', v_today) r),
           'per_shift_bonus', (select r.amount from hr.fn_rate_on(e.id, 'per_shift_bonus', v_today) r),
           'bonus_this_week', (select sum(g.amount) from hr.bonus_events g
                                where g.employee_id = e.id and hr.fn_payroll_week_start(g.work_date, e.payroll_week_start_day) = hr.fn_payroll_week_start(v_today, e.payroll_week_start_day)),
           'pending_bonus', hr.fn_pending_bonus(e.id, v_today),
           -- 2026-10-22 (Trello KqGyoiKQ): this payroll week's hours from the Jobber time sheet and their hourly pay
           'hours_this_week', (select round(sum(h.minutes) / 60.0, 2) from hr.fn_hours_worked(e.id, hr.fn_payroll_week_start(v_today, e.payroll_week_start_day), v_today) h),
           'hourly_pay_this_week', (select sum(h.pay) from hr.fn_hours_worked(e.id, hr.fn_payroll_week_start(v_today, e.payroll_week_start_day), v_today) h)
         ) order by e.id), '[]'::jsonb) into v_rows
    from public.employees e;
  return jsonb_build_object('can_see_pay', true, 'can_see_bonus', true, 'rows', v_rows);
end $function$;

DO $v$ BEGIN
  IF EXISTS (SELECT 1 FROM acl_before b JOIN pg_proc p ON p.oid = b.k::regprocedure WHERE p.proacl::text IS DISTINCT FROM b.a) THEN
    RAISE EXCEPTION 'VERIFY 1: privileges of a replaced function moved'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'hr.sync_time_entries(jsonb,timestamptz,timestamptz)'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}'
  OR (SELECT proacl::text FROM pg_proc WHERE oid = 'hr.fn_hours_worked(bigint,date,date)'::regprocedure) IS DISTINCT FROM '{postgres=X/postgres}' THEN
    RAISE EXCEPTION 'VERIFY 2: privileges of the new functions are wrong'; END IF;
  IF (SELECT relacl::text FROM pg_class WHERE oid = 'hr.time_entries'::regclass) IS DISTINCT FROM '{postgres=arwdDxtm/postgres,db_backup_reader=r/postgres}' THEN
    RAISE EXCEPTION 'VERIFY 3: hr.time_entries privileges are not postgres + db_backup_reader'; END IF;
  IF has_table_privilege('authenticated', 'hr.time_entries', 'SELECT') OR has_table_privilege('anon', 'hr.time_entries', 'SELECT') THEN
    RAISE EXCEPTION 'VERIFY 4: hr.time_entries readable by an app role'; END IF;
  IF EXISTS (SELECT 1 FROM pending_before b WHERE b.amt IS DISTINCT FROM hr.fn_pending_bonus(b.id, (now() at time zone 'America/New_York')::date)) THEN
    RAISE EXCEPTION 'VERIFY 5: a pending total moved'; END IF;
  IF (SELECT count(*) FROM public.entity_source_links) <> (SELECT n FROM esl_before) THEN RAISE EXCEPTION 'VERIFY 6: entity_source_links changed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'entity_source_links_entity_type_chk' AND pg_get_constraintdef(oid) LIKE '%time_entry%'
                 AND pg_get_constraintdef(oid) LIKE '%tank_sensor%' AND pg_get_constraintdef(oid) LIKE '%calendar_day_marker%') THEN
    RAISE EXCEPTION 'VERIFY 7: the link CHECK is wrong'; END IF;
  RAISE NOTICE 'VERIFY passed';
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
