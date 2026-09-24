-- =====================================================================================================
-- 2026-09-24_0715_start_freshness_phase1.sql
-- Start of day freshness, PHASE 1: detect and show. Nothing recomputes on its own; nothing is deleted.
-- =====================================================================================================
--
-- WHY. A Start marker is a snapshot of its truck's first visit. On 2026-09-23 visit 5994 was dragged
-- from Thu to Fri at 17:23 ET and marker 121 stayed wrong for 54 minutes: its Jobber Task told Michael
-- Escobar to start at 9:04 AM for a day whose first stop was 6:30 AM with Grecia, and nothing said so.
-- Fred: "we need a way that recompute happens so that stale Start point doesn't happen again", and
-- "the start card should only care about the first visit of that day related to the same truck".
-- Plan (revision 4, audited): Building Apps/Visit Calendar/docs/specs/2026-09-23-start-freshness-design.md
--
-- FRED'S DECISIONS THIS ENCODES (2026-09-23):
--   1. the whole day is one Start (no morning / night split);
--   2. "go by assigned trucks only": the Start follows visits.vehicle_id, NEVER a line-item default truck;
--   3. "can't have start with anytime": only timed visits count.
--
-- THE RULE (public.fn_start_verdict), per unfrozen truck Start (vehicle_id AND employee_id set):
--   first := the truck's first timed, scheduled, geo-coded visit that day (assigned truck only)
--   no first                                                     -> 'no timed visit'      (red)
--   DERIVED (eta_minutes set) and (first.id <> source_visit_id
--        or the start its OWN minute implies <> first's start)   -> 'first visit changed' (amber)
--   first.driver <> employee_id                                   -> 'driver changed'      (amber)
--   else fresh (both flag columns NULL).
--   "The start its own minute implies" = marker_date + (minutes + eta_minutes + fn_start_block_minutes())
--   at ET: 13p derives minutes = first visit's ET minute - eta - 30, so this IS the start the derivation
--   used, whenever and however it was written. It replaced a stored snapshot column after review: the app
--   computes the minute when the truck is picked and writes it later (the preview card, the Replace
--   dialog), so stamping the visit's start at write time would call a wrong minute fresh.
--   ⚠ fn_start_block_minutes() (30) must equal the app's START_BLOCK_MINUTES. Changing one without the
--   other flags every derived Start 'first visit changed', which is the correct outcome of a block change:
--   every Start then needs a Recompute.
--
-- WHAT THIS SHIPS
--   public.fn_start_first_visit(date, truck, exclude[])  the ONE SQL copy of 13p's selection, ASSIGNED
--                                                        truck; driver, coordinates and all-day copied
--                                                        verbatim from ops.v_calendar_visit.
--   ops.start_first_visit(date, truck)                   read-only wrapper for the app (same columns hu()
--                                                        already reads).
--   public.fn_start_block_minutes(), fn_start_frozen(date, minutes), fn_start_verdict(...),
--   fn_start_recheck_enabled()
--   ops.calendar_day_markers + stale_since, stale_reason (+ 2 CHECKs)
--   trg_aa_start_judge (BEFORE, markers)                 judges the row being written, in place. Callers
--                                                        can never set a flag: whatever they send is
--                                                        replaced by the verdict. Only fn_judge_starts,
--                                                        under app.start_judge_write = 'on', writes flags.
--   ops.start_recheck_queue (append-only) + trg_zz_queue_start_recheck on public.visits,
--   public.visit_assignments, public.inspections: the write path only NOTES which DAY to re-check. No
--   unique key, so no insert can ever wait on another transaction; a writer's own note is invisible to a
--   drain until that writer commits, so no change is ever lost to a concurrent drain.
--   ops.fn_judge_starts(dates[])                         locks each truck Start, then judges it; one bad
--                                                        marker is logged and skipped, never blocks the rest.
--   ops.refresh_start_flags()                            drains and judges; the app calls it after its own
--                                                        writes; cron start-flags-drain every 2 minutes.
--   cron start-flags-sweep 0 8 * * * UTC (04:00 EDT / 03:00 EST): re-judges every truck Start from today,
--                                                        covering what is not instrumented (re-geocodes,
--                                                        an employee going INACTIVE).
--   zzz_broadcast_inval on ops.calendar_day_markers     so a flag set by the cron reaches an open Calendar
--                                                        (topic inval:calendar_day_markers; the app
--                                                        subscribes in the same cycle).
--   app_config start_recheck_enabled = 'true'           KILL SWITCH. Anything but 'true' (a missing row
--                                                        counts as on) stops queueing and draining, and every
--                                                        marker write then CLEARS its flags: a judge that is
--                                                        off must not leave flags it can no longer maintain.
--                                                        Bulk jobs: set local app.suppress_start_recheck='on'.
--
-- WHAT IT DOES NOT DO: no automatic recompute (phase 3), no dialog, no removal (phase 2). A frozen Start
--   (its minute has passed, ET) carries no flag. End / Dump markers and the three legacy truck-only rows
--   (employee_id NULL) carry no flag. A hand-edited Start's MINUTE is never judged (13p: a typed minute is
--   the user's); it can only be 'no timed visit' or 'driver changed'.
--
-- JOBBER: no write here pushes anything. fn_push_marker_to_jobber returns early unless marker_date,
--   marker_type, minutes, vehicle_id, employee_id or dump_site changed (read live).
--
-- RULE 8 (audit): ops.calendar_day_markers has no audit trigger today (read live) and this does not add
--   one. stale_reason is fully recomputable from current data; stale_since is when the flag was first
--   set and is not. Neither can be written by a caller. ops.start_recheck_queue: derived work queue,
--   opt-out, dates only.
--
-- GRANTS: every new function has EXECUTE revoked BY NAME from public, anon, authenticated and
--   service_role, then only ops.start_first_visit and ops.refresh_start_flags are granted to
--   authenticated + service_role. The queue is revoked from every API role and yannick_readonly.
--   Asserted in VERIFY with has_function_privilege / has_table_privilege.
--
-- ROLLBACK, in this order:
--   0. Roll the Calendar app back first (it calls ops.start_first_visit and ops.refresh_start_flags). If
--      the DB must go first, keep both wrappers: replace refresh_start_flags' body with `select 0`.
--   1. update public.app_config set value = 'false' where key = 'start_recheck_enabled';
--   2. update ops.calendar_day_markers set stale_reason = stale_reason where stale_reason is not null;
--      (the trigger clears them while the switch is off)
--   3. select cron.unschedule('start-flags-drain'); select cron.unschedule('start-flags-sweep');
--   4. drop trigger trg_zz_queue_start_recheck on public.visits / public.visit_assignments /
--      public.inspections; drop trigger trg_aa_start_judge, zzz_broadcast_inval on ops.calendar_day_markers
--   5. drop the functions and ops.start_recheck_queue. The two columns are harmless if left.
-- =====================================================================================================

begin;
set local lock_timeout = '5s';   -- fail fast rather than hold the markers lock behind a visits writer

-- ---------------------------------------------------------------------------------------------------
-- PART 1. Columns
-- ---------------------------------------------------------------------------------------------------
alter table ops.calendar_day_markers
  add column stale_since  timestamptz,
  add column stale_reason text;

alter table ops.calendar_day_markers
  add constraint calendar_day_markers_stale_reason_chk
    check (stale_reason is null or stale_reason in ('no timed visit', 'first visit changed', 'driver changed')),
  add constraint calendar_day_markers_stale_pair_chk
    check ((stale_since is null) = (stale_reason is null));

comment on column ops.calendar_day_markers.stale_reason is
  '''no timed visit'' (red: a person removes the Start) | ''first visit changed'' (amber: Recompute) | ''driver changed'' (amber). NULL = fresh. Written only by ops.fn_judge_starts and the BEFORE trigger trg_aa_start_judge; a caller''s value is always replaced by the verdict.';
comment on column ops.calendar_day_markers.stale_since is
  'When the current flag was first set. NULL iff stale_reason is NULL. Not recomputable; not audited.';

-- ---------------------------------------------------------------------------------------------------
-- PART 2. Selection, block, frozen, switch, verdict
-- ---------------------------------------------------------------------------------------------------
create function public.fn_start_first_visit(p_date date, p_vehicle_id bigint, p_exclude_visit_ids bigint[] default null)
returns table (id bigint, start_at timestamptz, latitude numeric, longitude numeric,
               driver_id bigint, driver_name text, client_code text, client_name text)
language sql stable security definer
set search_path = public, pg_temp
as $$
  -- The truck's first timed, scheduled, geo-coded visit that day, on the ASSIGNED truck only (Fred,
  -- 2026-09-23: "go by assigned trucks only"). Driver, coordinates and the all-day rule are copied
  -- verbatim from ops.v_calendar_visit (lines 90-91, 110-112, 127 and the fa lateral), so the only
  -- intended difference from the view is visits.vehicle_id in place of the effective truck.
  select v.id, v.start_at,
         coalesce(prop.latitude, pp.latitude), coalesce(prop.longitude, pp.longitude),
         d.driver_id, e.full_name, c.client_code, c.name
    from public.visits v
    join public.clients c on c.id = v.client_id
    left join public.properties prop on prop.id = v.property_id
    left join public.properties pp on pp.client_id = v.client_id and pp.is_primary = true
    cross join lateral (
      select coalesce(
        (select min(e1.id) from public.visit_assignments va join public.employees e1 on e1.id = va.employee_id
          where va.visit_id = v.id and e1.status = 'ACTIVE'),
        (select min(va.employee_id) from public.visit_assignments va where va.visit_id = v.id),
        (select e2.id from public.inspections i join public.employees e2 on e2.id = i.employee_id
          where i.vehicle_id = v.vehicle_id
            and i.shift_date >= v.visit_date - 1 and i.shift_date <= v.visit_date + 1
          order by (i.shift_date = v.visit_date) desc, (e2.status = 'ACTIVE') desc,
                   abs(i.shift_date - v.visit_date), e2.id
          limit 1),
        v.assigned_driver_id) as driver_id
    ) d
    left join public.employees e on e.id = d.driver_id
   where v.deleted_at is null
     and v.visit_date = p_date
     and v.vehicle_id = p_vehicle_id
     and v.visit_status = 'scheduled'
     and v.start_at is not null
     and not ((v.start_at at time zone 'America/New_York')::time = '00:00:00'::time
              and v.end_at is not null and (v.end_at - v.start_at) >= '23:00:00'::interval)
     and coalesce(prop.latitude, pp.latitude) is not null
     and coalesce(prop.longitude, pp.longitude) is not null
     and (p_exclude_visit_ids is null or v.id <> all (p_exclude_visit_ids))
   order by v.start_at, v.id
   limit 1
$$;

create function ops.start_first_visit(p_date date, p_vehicle_id bigint)
returns table (id bigint, start_at timestamptz, latitude numeric, longitude numeric,
               driver_id bigint, driver_name text, client_code text, client_name text)
language sql stable security definer
set search_path = public, pg_temp
as $$ select * from public.fn_start_first_visit(p_date, p_vehicle_id) $$;

create function public.fn_start_block_minutes()
returns integer
language sql immutable
set search_path = pg_catalog, pg_temp
as $$ select 30 $$;   -- = the Calendar's START_BLOCK_MINUTES (2026-09-23 amendment of 13p). Change both.

create function public.fn_start_frozen(p_marker_date date, p_minutes integer)
returns boolean
language sql stable
set search_path = pg_catalog, pg_temp
as $$
  -- The database clock is UTC: never current_date. marker_date + minutes is an ET wall-clock time.
  select now() >= ((p_marker_date + make_interval(mins => p_minutes)) at time zone 'America/New_York')
$$;

create function public.fn_start_recheck_enabled()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  -- A missing row counts as ON; any present value other than 'true' is OFF.
  select coalesce(current_setting('app.suppress_start_recheck', true), 'off') <> 'on'
     and coalesce((select lower(btrim(value)) = 'true' from public.app_config
                    where key = 'start_recheck_enabled'), true)
$$;

create function public.fn_start_verdict(p_marker_date date, p_vehicle_id bigint, p_employee_id bigint,
                                        p_source_visit_id bigint, p_minutes integer, p_eta_minutes integer)
returns text
language sql stable security definer
set search_path = public, pg_temp
as $$
  select case
           when f.id is null then 'no timed visit'
           when p_eta_minutes is not null     -- DERIVED only: a hand-typed minute belongs to the user
                and (f.id is distinct from p_source_visit_id
                     or date_trunc('minute', f.start_at) is distinct from
                        ((p_marker_date + make_interval(mins => p_minutes + p_eta_minutes
                                                                + public.fn_start_block_minutes()))
                          at time zone 'America/New_York'))
             then 'first visit changed'
           when f.driver_id is distinct from p_employee_id then 'driver changed'
         end
    from (select 1) one
    left join lateral public.fn_start_first_visit(p_marker_date, p_vehicle_id) f on true
$$;

insert into public.app_config (key, value)
select 'start_recheck_enabled', 'true'
 where not exists (select 1 from public.app_config where key = 'start_recheck_enabled');

-- ---------------------------------------------------------------------------------------------------
-- PART 3. Judge in place on every marker write
-- ---------------------------------------------------------------------------------------------------
create function ops.fn_start_judge()
returns trigger
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare
  v_reason text;
  v_since  timestamptz;
begin
  -- The judge's own write: it computed the flags itself and marked the write with this GUC.
  if coalesce(current_setting('app.start_judge_write', true), 'off') = 'on' then
    return NEW;
  end if;

  -- Anyone else: whatever they sent in the flag columns is replaced by the verdict.
  if NEW.marker_type = 'start' and NEW.vehicle_id is not null and NEW.employee_id is not null
     and public.fn_start_recheck_enabled()
     and public.fn_start_frozen(NEW.marker_date, NEW.minutes) is not true then
    v_reason := public.fn_start_verdict(NEW.marker_date, NEW.vehicle_id, NEW.employee_id,
                                        NEW.source_visit_id, NEW.minutes, NEW.eta_minutes);
  end if;

  if v_reason is null then
    NEW.stale_reason := null;
    NEW.stale_since  := null;
  else
    if tg_op = 'UPDATE' then           -- never read OLD on an INSERT
      if OLD.stale_reason is not null then v_since := OLD.stale_since; end if;
    end if;
    NEW.stale_reason := v_reason;
    NEW.stale_since  := coalesce(v_since, now());
  end if;
  return NEW;
end
$$;

create trigger trg_aa_start_judge
  before insert or update on ops.calendar_day_markers
  for each row execute function ops.fn_start_judge();

-- ---------------------------------------------------------------------------------------------------
-- PART 4. The queue: the write path only notes the DAY (append-only, nothing to wait on)
-- ---------------------------------------------------------------------------------------------------
create table ops.start_recheck_queue (
  id          bigint generated always as identity primary key,
  marker_date date not null,
  queued_at   timestamptz not null default now()
);
comment on table ops.start_recheck_queue is
  'Days whose truck Start must be re-judged. Append-only on purpose (no unique key): an insert can never wait on another transaction, and a note from an uncommitted writer is invisible to ops.refresh_start_flags until that writer commits. Drained and de-duplicated by refresh_start_flags. Derived; rule 8 opt-out.';
revoke all on ops.start_recheck_queue from public, anon, authenticated, service_role, yannick_readonly;

create function public.fn_queue_start_recheck()
returns trigger
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare
  v_today date := (now() at time zone 'America/New_York')::date;
  v_raw   date[] := '{}';
  v_ids   bigint[] := '{}';
  v_dates date[];
begin
  if not public.fn_start_recheck_enabled() then return null; end if;

  if tg_table_name = 'visits' then
    if tg_op in ('UPDATE', 'DELETE') then v_raw := v_raw || OLD.visit_date; end if;
    if tg_op in ('UPDATE', 'INSERT') then v_raw := v_raw || NEW.visit_date; end if;
  elsif tg_table_name = 'visit_assignments' then
    if tg_op in ('UPDATE', 'DELETE') then v_ids := v_ids || OLD.visit_id; end if;
    if tg_op in ('UPDATE', 'INSERT') then v_ids := v_ids || NEW.visit_id; end if;
    v_raw := array(select vv.visit_date from public.visits vv where vv.id = any (v_ids));
  elsif tg_table_name = 'inspections' then
    if tg_op in ('UPDATE', 'DELETE') then
      v_raw := v_raw || array[OLD.shift_date - 1, OLD.shift_date, OLD.shift_date + 1];
    end if;
    if tg_op in ('UPDATE', 'INSERT') then
      v_raw := v_raw || array[NEW.shift_date - 1, NEW.shift_date, NEW.shift_date + 1];
    end if;
  end if;

  -- Only days that are today or later AND hold a truck Start (served by the existing unique index
  -- calendar_day_markers_start_truck_uniq). Almost every write stops here.
  v_dates := array(
    select distinct d from unnest(v_raw) d
     where d is not null and d >= v_today
       and exists (select 1 from ops.calendar_day_markers m
                    where m.marker_type = 'start' and m.vehicle_id is not null and m.marker_date = d));
  if cardinality(v_dates) = 0 then return null; end if;

  -- A plain insert into a table with no unique key cannot wait on anyone. The block is a last guard so
  -- this can never abort the visit write; it only opens a subtransaction on this rare path.
  begin
    insert into ops.start_recheck_queue (marker_date) select d from unnest(v_dates) d;
  exception when others then
    begin
      insert into public.sync_log (sync_source, started_at, finished_at, status, rows_errored, error_details, details)
      values ('start-recheck-queue', now(), now(), 'error', 1,
              jsonb_build_object('sqlstate', sqlstate, 'message', sqlerrm),
              jsonb_build_object('table', tg_table_name, 'op', tg_op, 'dates', to_jsonb(v_dates)));
    exception when others then
      raise warning 'start-recheck-queue: could not queue % and could not log it: %', v_dates, sqlerrm;
    end;
  end;
  return null;
end
$$;

create trigger trg_zz_queue_start_recheck
  after insert or delete or update of visit_date, start_at, end_at, vehicle_id, visit_status, deleted_at,
                                      property_id, client_id, assigned_driver_id
  on public.visits
  for each row execute function public.fn_queue_start_recheck();

create trigger trg_zz_queue_start_recheck
  after insert or delete or update on public.visit_assignments
  for each row execute function public.fn_queue_start_recheck();

create trigger trg_zz_queue_start_recheck
  after insert or delete or update of shift_date, vehicle_id, employee_id on public.inspections
  for each row execute function public.fn_queue_start_recheck();

-- ---------------------------------------------------------------------------------------------------
-- PART 5. The judge, the drain, the cron, the broadcast
-- ---------------------------------------------------------------------------------------------------
create function ops.fn_judge_starts(p_dates date[])
returns integer
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare
  r        record;
  v_reason text;
  v_n      integer := 0;
begin
  if not public.fn_start_recheck_enabled() or p_dates is null then return 0; end if;
  -- LOCK FIRST, THEN JUDGE: the verdict is read by a later statement, so under read committed it sees
  -- whatever a concurrent writer committed while we waited for the lock.
  for r in
    select m.id, m.marker_date, m.minutes, m.vehicle_id, m.employee_id, m.source_visit_id,
           m.eta_minutes, m.stale_reason
      from ops.calendar_day_markers m
     where m.marker_type = 'start' and m.vehicle_id is not null and m.employee_id is not null
       and m.marker_date = any (p_dates)
     order by m.id
       for update
  loop
    begin
      v_reason := case when public.fn_start_frozen(r.marker_date, r.minutes) is true then null
                       else public.fn_start_verdict(r.marker_date, r.vehicle_id, r.employee_id,
                                                    r.source_visit_id, r.minutes, r.eta_minutes) end;
      if v_reason is distinct from r.stale_reason then
        perform set_config('app.start_judge_write', 'on', true);
        update ops.calendar_day_markers
           set stale_reason = v_reason,
               stale_since  = case when v_reason is null then null else coalesce(stale_since, now()) end
         where id = r.id;
        perform set_config('app.start_judge_write', 'off', true);
        v_n := v_n + 1;
      end if;
    exception when others then        -- one bad marker is logged and skipped, never blocks the rest
      perform set_config('app.start_judge_write', 'off', true);
      insert into public.sync_log (sync_source, started_at, finished_at, status, rows_errored, error_details, details)
      values ('start-flags-judge', now(), now(), 'error', 1,
              jsonb_build_object('sqlstate', sqlstate, 'message', sqlerrm),
              jsonb_build_object('marker_id', r.id, 'marker_date', r.marker_date));
    end;
  end loop;
  return v_n;
end
$$;

create function ops.refresh_start_flags()
returns integer
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare v_dates date[];
begin
  if not public.fn_start_recheck_enabled() then return 0; end if;   -- keep the notes for when it is back on
  perform set_config('lock_timeout', '3s', true);
  with d as (
    delete from ops.start_recheck_queue q
     where q.id in (select id from ops.start_recheck_queue for update skip locked)
    returning q.marker_date)
  select array_agg(distinct marker_date) into v_dates from d;
  if v_dates is null then return 0; end if;
  return ops.fn_judge_starts(v_dates);
end
$$;

select cron.schedule('start-flags-drain', '*/2 * * * *', $cron$select ops.refresh_start_flags()$cron$);
select cron.schedule('start-flags-sweep', '0 8 * * *', $cron$
  select ops.fn_judge_starts(array(
    select distinct marker_date from ops.calendar_day_markers
     where marker_type = 'start' and vehicle_id is not null
       and marker_date >= (now() at time zone 'America/New_York')::date))
$cron$);

create trigger zzz_broadcast_inval
  after insert or delete or update on ops.calendar_day_markers
  for each statement execute function public.tg_broadcast_inval();

-- ---------------------------------------------------------------------------------------------------
-- PART 6. Grants (Supabase default privileges grant by NAME; revoke by name, then assert)
-- ---------------------------------------------------------------------------------------------------
revoke all on function public.fn_start_first_visit(date, bigint, bigint[]) from public, anon, authenticated, service_role;
revoke all on function public.fn_start_block_minutes()                     from public, anon, authenticated, service_role;
revoke all on function public.fn_start_frozen(date, integer)               from public, anon, authenticated, service_role;
revoke all on function public.fn_start_recheck_enabled()                   from public, anon, authenticated, service_role;
revoke all on function public.fn_start_verdict(date, bigint, bigint, bigint, integer, integer)
                                                                            from public, anon, authenticated, service_role;
revoke all on function public.fn_queue_start_recheck()                      from public, anon, authenticated, service_role;
revoke all on function ops.fn_start_judge()                                 from public, anon, authenticated, service_role;
revoke all on function ops.fn_judge_starts(date[])                          from public, anon, authenticated, service_role;
revoke all on function ops.start_first_visit(date, bigint)                  from public, anon;
revoke all on function ops.refresh_start_flags()                            from public, anon;
grant execute on function ops.start_first_visit(date, bigint) to authenticated, service_role;
grant execute on function ops.refresh_start_flags()           to authenticated, service_role;

-- Judge every truck Start from today once, now.
select ops.fn_judge_starts(array(
  select distinct marker_date from ops.calendar_day_markers
   where marker_type = 'start' and vehicle_id is not null
     and marker_date >= (now() at time zone 'America/New_York')::date));

-- ---------------------------------------------------------------------------------------------------
-- VERIFY (inside the transaction: any failure rolls the whole migration back)
-- ---------------------------------------------------------------------------------------------------
do $verify$
declare
  v_pairs int; v_mism int; v_mism_eff int;
  v_121_flag text; v_5994_start timestamptz; v_121_minutes smallint;
  v_q_pos int; v_q_notes int; v_q_nomarker int; v_q_va int; v_q_insp int;
  v_flag_move text; v_flag_back text; v_flag_good_recompute text; v_flag_bad_recompute text;
  v_flag_forged text; v_flag_cleared_by_caller text; v_flag_driver text;
  v_off_refresh int; v_off_queue int; v_off_flag text;
  v_other_visit bigint;
begin
  -- V1. Equivalence with the view on the ASSIGNED truck, every (date, truck) pair -120 .. +60 days,
  --     on (visit id, driver id); a pair found on only one side counts as a mismatch.
  with days as (
    select d::date as d from generate_series((now() at time zone 'America/New_York')::date - 120,
                                             (now() at time zone 'America/New_York')::date + 60, '1 day') d),
  fn as (
    select dd.d, t.id as truck, f.id as vid, f.driver_id
      from days dd cross join public.vehicles t
      cross join lateral public.fn_start_first_visit(dd.d, t.id) f),
  vw as (
    select distinct on (visit_date, assigned_vehicle_id) visit_date as d, assigned_vehicle_id as truck,
           id as vid, driver_id
      from ops.v_calendar_visit
     where visit_date between (now() at time zone 'America/New_York')::date - 120
                          and (now() at time zone 'America/New_York')::date + 60
       and assigned_vehicle_id is not null and visit_status = 'scheduled' and is_all_day = false
       and start_at is not null and latitude is not null and longitude is not null
     order by visit_date, assigned_vehicle_id, start_at, id)
  select count(*),
         count(*) filter (where fn.vid is distinct from vw.vid or fn.driver_id is distinct from vw.driver_id)
    into v_pairs, v_mism
    from fn full join vw on vw.d = fn.d and vw.truck = fn.truck;
  if v_pairs < 1 then raise exception 'V1 compared nothing (no pairs): the check is untested'; end if;
  if v_mism <> 0 then raise exception 'V1 fn_start_first_visit disagrees with the view on % of % pairs', v_mism, v_pairs; end if;

  -- V1b. Mutation control: against the EFFECTIVE truck the comparison must find a difference, or V1
  --      cannot see the thing it guards.
  with days as (
    select d::date as d from generate_series((now() at time zone 'America/New_York')::date - 120,
                                             (now() at time zone 'America/New_York')::date + 60, '1 day') d),
  fn as (
    select dd.d, t.id as truck, f.id as vid
      from days dd cross join public.vehicles t
      cross join lateral public.fn_start_first_visit(dd.d, t.id) f),
  vw as (
    select distinct on (visit_date, vehicle_id) visit_date as d, vehicle_id as truck, id as vid
      from ops.v_calendar_visit
     where visit_date between (now() at time zone 'America/New_York')::date - 120
                          and (now() at time zone 'America/New_York')::date + 60
       and vehicle_id is not null and visit_status = 'scheduled' and is_all_day = false
       and start_at is not null and latitude is not null and longitude is not null
     order by visit_date, vehicle_id, start_at, id)
  select count(*) filter (where fn.vid is distinct from vw.vid) into v_mism_eff
    from fn full join vw on vw.d = fn.d and vw.truck = fn.truck;
  if v_mism_eff < 1 then raise exception 'V1b the effective-truck control found no difference, so V1 proves nothing'; end if;

  -- V2. Marker 121 fresh on install (326 + 34 + 30 = 390 = 6:30 AM = visit 5994).
  select stale_reason, minutes into v_121_flag, v_121_minutes from ops.calendar_day_markers where id = 121;
  if v_121_flag is not null then raise exception 'V2 marker 121 judged stale (%) on install', v_121_flag; end if;

  -- V3. Grants.
  if has_function_privilege('anon', 'ops.start_first_visit(date, bigint)', 'EXECUTE')
     or has_function_privilege('anon', 'ops.refresh_start_flags()', 'EXECUTE')
     or has_function_privilege('anon', 'public.fn_start_first_visit(date, bigint, bigint[])', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_start_first_visit(date, bigint, bigint[])', 'EXECUTE')
     or has_function_privilege('authenticated', 'ops.fn_judge_starts(date[])', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_start_verdict(date, bigint, bigint, bigint, integer, integer)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_queue_start_recheck()', 'EXECUTE')
     or has_function_privilege('authenticated', 'ops.fn_start_judge()', 'EXECUTE')
     or has_table_privilege('authenticated', 'ops.start_recheck_queue', 'SELECT')
     or has_table_privilege('anon', 'ops.start_recheck_queue', 'SELECT')
     or has_table_privilege('yannick_readonly', 'ops.start_recheck_queue', 'SELECT') then
    raise exception 'V3 a grant is wider than intended';
  end if;
  if not has_function_privilege('authenticated', 'ops.start_first_visit(date, bigint)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'ops.refresh_start_flags()', 'EXECUTE') then
    raise exception 'V3 the app cannot call its two functions';
  end if;

  -- V4. The whole path on live rows, inside a block that is rolled back. Jobber pushes suppressed.
  select start_at into v_5994_start from public.visits where id = 5994;
  select vv.id into v_other_visit
    from public.visits vv
   where vv.deleted_at is null and vv.visit_status = 'scheduled'
     and vv.visit_date >= (now() at time zone 'America/New_York')::date
     and not exists (select 1 from ops.calendar_day_markers m
                      where m.marker_type = 'start' and m.vehicle_id is not null and m.marker_date = vv.visit_date)
   order by vv.visit_date, vv.id limit 1;
  if v_other_visit is null then raise exception 'V4 no control visit on a day without a Start'; end if;

  begin
    perform set_config('app.suppress_jobber_push', 'on', true);
    perform set_config('app.suppress_marker_push', 'on', true);
    delete from ops.start_recheck_queue;

    -- a) a column outside the trigger list queues nothing
    update public.visits set notes = coalesce(notes, '') || ' ' where id = 5994;
    select count(*) into v_q_notes from ops.start_recheck_queue;
    -- b) a day with no truck Start queues nothing (the early exit)
    update public.visits set start_at = start_at + interval '1 minute' where id = v_other_visit;
    select count(*) into v_q_nomarker from ops.start_recheck_queue;
    -- c) THE first visit moves 30 minutes -> Fri queued -> 'first visit changed'
    update public.visits set start_at = start_at + interval '30 minutes' where id = 5994;
    select count(*) into v_q_pos from ops.start_recheck_queue where marker_date = '2026-09-25';
    perform ops.refresh_start_flags();
    select stale_reason into v_flag_move from ops.calendar_day_markers where id = 121;
    -- d) a caller cannot clear a real flag (flags-only write is re-judged)
    update ops.calendar_day_markers set stale_reason = null, stale_since = null where id = 121;
    select stale_reason into v_flag_cleared_by_caller from ops.calendar_day_markers where id = 121;
    -- e) a Recompute that writes the OLD minute (derived before the move) stays flagged
    update ops.calendar_day_markers set eta_computed_at = now() where id = 121;
    select stale_reason into v_flag_bad_recompute from ops.calendar_day_markers where id = 121;
    -- f) a correct Recompute (minute + 30, as 13p derives it) clears the flag
    update ops.calendar_day_markers set minutes = minutes + 30, eta_computed_at = now() where id = 121;
    select stale_reason into v_flag_good_recompute from ops.calendar_day_markers where id = 121;
    -- g) the visit moves back: now the marker's minute is the one that is wrong
    update public.visits set start_at = start_at - interval '30 minutes' where id = 5994;
    perform ops.refresh_start_flags();
    update ops.calendar_day_markers set minutes = minutes - 30, eta_computed_at = now() where id = 121;
    select stale_reason into v_flag_back from ops.calendar_day_markers where id = 121;
    -- h) a caller cannot forge a flag on a fresh Start
    update ops.calendar_day_markers set stale_reason = 'no timed visit', stale_since = now() where id = 121;
    select stale_reason into v_flag_forged from ops.calendar_day_markers where id = 121;
    -- i) driver: the marker names someone who is not on the visit
    update ops.calendar_day_markers set employee_id = 40 where id = 121;
    select stale_reason into v_flag_driver from ops.calendar_day_markers where id = 121;
    -- j) the crew table queues the day
    delete from ops.start_recheck_queue;
    delete from public.visit_assignments where visit_id = 5994;
    select count(*) into v_q_va from ops.start_recheck_queue where marker_date = '2026-09-25';
    -- k) an inspection queues shift_date +/- 1
    delete from ops.start_recheck_queue;
    insert into public.inspections (shift_date, inspection_type, vehicle_id, employee_id)
    values ('2026-09-26', 'POST', 1, 42);
    select count(*) into v_q_insp from ops.start_recheck_queue where marker_date = '2026-09-25';
    -- l) the kill switch: no draining, no queueing, and a marker write clears the flag
    update public.app_config set value = 'false' where key = 'start_recheck_enabled';
    select ops.refresh_start_flags() into v_off_refresh;
    delete from ops.start_recheck_queue;
    update public.visits set start_at = start_at + interval '1 minute' where id = 5994;
    select count(*) into v_off_queue from ops.start_recheck_queue;
    update ops.calendar_day_markers set eta_computed_at = now() where id = 121;
    select stale_reason into v_off_flag from ops.calendar_day_markers where id = 121;

    raise exception 'ROLLBACK_PROBE';
  exception when raise_exception then
    if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;

  if v_q_notes <> 0 then raise exception 'V4a a notes edit queued a recheck'; end if;
  if v_q_nomarker <> 0 then raise exception 'V4b a day with no Start was queued'; end if;
  if v_q_pos < 1 then raise exception 'V4c moving the first visit did not queue Fri 09-25'; end if;
  if v_flag_move is distinct from 'first visit changed' then
    raise exception 'V4c expected first visit changed, got %', coalesce(v_flag_move, 'NULL'); end if;
  if v_flag_cleared_by_caller is distinct from 'first visit changed' then
    raise exception 'V4d a caller cleared a real flag (%)', coalesce(v_flag_cleared_by_caller, 'NULL'); end if;
  if v_flag_bad_recompute is distinct from 'first visit changed' then
    raise exception 'V4e a Recompute with the old minute was judged %', coalesce(v_flag_bad_recompute, 'NULL'); end if;
  if v_flag_good_recompute is not null then
    raise exception 'V4f a correct Recompute left the flag at %', v_flag_good_recompute; end if;
  if v_flag_back is not null then raise exception 'V4g the flag did not clear after the move back (%)', v_flag_back; end if;
  if v_flag_forged is not null then raise exception 'V4h a caller forged a flag (%)', v_flag_forged; end if;
  if v_flag_driver is distinct from 'driver changed' then
    raise exception 'V4i expected driver changed, got %', coalesce(v_flag_driver, 'NULL'); end if;
  if v_q_va < 1 then raise exception 'V4j a crew change did not queue the day'; end if;
  if v_q_insp < 1 then raise exception 'V4k an inspection did not queue the day'; end if;
  if v_off_refresh <> 0 or v_off_queue <> 0 then
    raise exception 'V4l the kill switch did not stop draining (%) or queueing (%)', v_off_refresh, v_off_queue; end if;
  if v_off_flag is not null then raise exception 'V4l with the switch off a marker write kept its flag'; end if;

  -- V5. The probe left nothing behind.
  if (select stale_reason from ops.calendar_day_markers where id = 121) is not null then
    raise exception 'V5 marker 121 is flagged after the rollback'; end if;
  if (select minutes from ops.calendar_day_markers where id = 121) <> v_121_minutes then
    raise exception 'V5 marker 121 minutes changed'; end if;
  if exists (select 1 from ops.start_recheck_queue) then raise exception 'V5 the queue is not empty'; end if;
  if (select start_at from public.visits where id = 5994) <> v_5994_start then raise exception 'V5 visit 5994 moved'; end if;
  if not exists (select 1 from public.visit_assignments where visit_id = 5994) then
    raise exception 'V5 visit 5994 lost its crew'; end if;
  if (select value from public.app_config where key = 'start_recheck_enabled') <> 'true' then
    raise exception 'V5 the kill switch was left off'; end if;
end
$verify$;

commit;
