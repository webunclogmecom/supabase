-- =====================================================================================================
-- 2026-09-24_0845_start_freshness_phase2.sql
-- Start of day freshness, PHASE 2: the Start heals itself, the dialog gets its pre-check, failed Jobber
-- pushes are retried, and a daily health check reports anything that did not heal.
-- =====================================================================================================
--
-- FRED, 2026-09-24 (verbatim, the spec for this file): "if it's changed by Jobber and our App adopts
-- ... then we don't need any warning or whatsoever just remove the Start Point if there are no more
-- visits (or they're anytime) or recalculate if there are any other visit with scheduled time, but
-- because is a change done by the system we don't need any warnings, and we need to actually check if
-- there are errors because of it."
-- Plan: Building Apps/Visit Calendar/docs/specs/2026-09-23-start-freshness-design.md (sections 4.3, 4.4).
--
-- THE RULE, applied the same way whoever changed the visits (a Jobber adoption, SQL, a cron, the app):
--   'no timed visit'      -> the Start is REMOVED (its Jobber Task is deleted by the existing push).
--   'driver changed'      -> employee_id becomes the first visit's driver (the Task is reassigned).
--   'first visit changed' -> a DERIVED Start is RECOMPUTED by the edge function heal-day-starts (it
--                            needs a drive time): minute = first visit - ETA - 30, driver = its driver.
--   A hand-typed minute is never recomputed (it can only be removed or get a new driver).
--   A frozen Start (its minute has passed, ET) is never touched.
-- The only question a PERSON is asked is the Calendar dialog before THEY move a truck's last timed
-- visit; ops.preview_start_impact is its read-only pre-check. After the write the same healer removes
-- the Start, so there is no separate remover.
--
-- 🛑 start_heal_enabled SHIPS 'false'. Healing removes Starts and moves Jobber Tasks. It is switched on
-- in the same hour the Calendar dialog is published, so a dispatcher is never surprised by a removal
-- the app did not warn about. A missing row counts as OFF (fail closed), unlike the phase-1 judge.
--
-- WHAT THIS SHIPS
--   public.fn_start_heal_enabled()          switch: app_config start_heal_enabled = 'true' AND the judge
--                                           on AND no app.suppress_start_heal = 'on' in the transaction.
--   ops.calendar_day_markers.push_changed_at + trg_ab_marker_push_stamp: when a Jobber-visible column
--                                           last changed (the same six columns fn_push_marker_to_jobber
--                                           tests). A caller cannot set it. It is what the push retry
--                                           compares with the link's synced_at; updated_at cannot be used
--                                           because every flag write bumps it.
--   ops.fn_judge_starts (spliced)           heals 'no timed visit' and 'driver changed' in place; logs a
--                                           Start that BEGAN while still out of date as an error.
--   ops.refresh_start_flags (spliced)       also re-judges every day that still carries a flag (retries a
--                                           skipped heal, catches a freeze within 2 minutes) and kicks
--                                           the edge healer when a recompute is due.
--   ops.start_heal_candidates() / ops.apply_start_heal(...)   service_role only, for heal-day-starts.
--                                           apply re-derives under a row lock and refuses unless the
--                                           first visit is exactly the one the ETA was computed for.
--   ops.start_heal_attempts                 one row per marker: the last refused try and the first visit
--                                           it was for, so a refusal is retried after 10 minutes or at
--                                           once when the first visit changes, never every 2 minutes.
--   public.fn_request_start_heal()          pg_net kick of heal-day-starts, only when a candidate exists,
--                                           at most once a minute (ops.start_heal_kick).
--   ops.retry_marker_pushes() + cron start-push-retry (every 5 min): re-sends a Task delete whose link
--                                           outlived its marker, and a Task edit whose marker changed
--                                           after the last successful push. 3 tries 5 minutes apart,
--                                           then one every 6 hours (a Task fixed by hand then converges).
--                                           NEVER re-sends a create: a create is not idempotent.
--   public.fn_request_marker_push           spliced: timeout_milliseconds 30000 (pg_net's 5000 default
--                                           is shorter than a throttled push).
--   ops.preview_start_impact(jsonb)         the dialog's pre-check, read-only, authenticated.
--   public.log_start_flags_health() + cron start-flags-health 13:20 UTC, registered in ops.v_health_items
--                                           and ops.v_health_status: emails Fred (health-escalate, 13:30)
--                                           a Start out of date for 30+ minutes, a marker with no Task, a
--                                           Task not deleted or not updated after the retries, any error
--                                           in 26 hours, the judge switched off, a leaked marker Task.
--
-- SYNC_LOG SOURCES: 'start-flags-heal' (every heal action, every edge run, every error of the healer),
--   'start-flags-push-retry' (a row only when something was re-sent), 'start-flags-health' (the check;
--   the ONLY one registered in the health views, because they read the latest row per source).
--
-- REVIEWED before apply: 4 adversarial lenses + a skeptic per lens, 24 findings, 20 confirmed, every
-- confirmed one fixed here except the three kept on purpose below. The fixes: a hand-typed Start's driver
-- is healed only when its first visit is still the one it was made for (it was handed to another visit's
-- driver and marked fresh); apply_start_heal refuses a Start that has already begun; fn_start_verdict
-- compares ET wall-clock minutes (the repeated 01:xx hour of the November clock change made a correct
-- Start read as changed for ever); a recompute that cannot clear the flag backs off instead of raising;
-- refusals back off by cause; the retry never moves a marker whose minute has passed; a write made under
-- app.suppress_marker_push is not re-sent later; per-incident health items for a Start that began out of
-- date; the orphan-Task item waits for a retry to fail; a liveness item for the retry and the recompute.
-- KEPT ON PURPOSE (each is recorded in the reference doc):
--   * the edit retry and health item 4 compare push_changed_at (DB clock, start of the writing
--     transaction) with synced_at (edge clock, end of the push). Two pushes of ONE marker in flight at
--     once that land out of order can leave Jobber one version behind unseen. It needs two writes to the
--     same marker within about two seconds; the exact fix (jobber-push-task recording the version it
--     pushed) is a separate change to that function.
--   * the health check runs once a day (13:20 UTC, before health-escalation at 13:30). A heal that fails
--     in the evening is reported the next morning, after that Start has begun. An evening escalation would
--     change the email cadence of EVERY health check: Fred's decision, not made here.
--   * the whole day is one Start (decision 1), so a timed stop after midnight IS the truck's first visit
--     that day, and the recompute follows it.
-- SUPPRESSION: set local app.suppress_marker_push = 'on' still keeps a marker EDIT away from Jobber for
--   good (its push_changed_at is not stamped, so the retry never re-sends it). A suppressed DELETE of a
--   marker that has a Jobber link leaves the link behind, and the retry deletes that Task 2 to 7 minutes
--   later: a link to a marker that no longer exists is never left dangling.
--
-- JOBBER: nothing here calls Jobber directly. A removal, a driver update or a recompute is an ordinary
--   marker write, so trg_push_marker_to_jobber sends it exactly as a person's edit would.
--   The healer never sets app.suppress_marker_push.
--
-- RULE 8 (audit): ops.calendar_day_markers stays unaudited (as before; not changed here). The heal
--   actions are journalled in public.sync_log with the before and after values. The three new ops
--   tables are bookkeeping (retry and backoff state), opt-out.
--
-- GRANTS: every new function is revoked BY NAME from public, anon, authenticated, service_role; then
--   ops.preview_start_impact -> authenticated, service_role; ops.start_heal_candidates and
--   ops.apply_start_heal -> service_role. New tables: revoked from every API role and yannick_readonly.
--   Asserted in VERIFY.
--
-- ROLLBACK, in this order:
--   0. update public.app_config set value = 'false' where key = 'start_heal_enabled';  (stops all healing)
--   1. select cron.unschedule('start-push-retry'); select cron.unschedule('start-flags-health');
--   2. re-apply the phase-1 bodies of ops.fn_judge_starts and ops.refresh_start_flags
--      (docs/migrations/2026-09-24_0715_start_freshness_phase1.sql PART 5), and fn_request_marker_push
--      without timeout_milliseconds.
--   3. remove 'start-flags-health' from ops.v_health_items and ops.v_health_status (the reverse splice).
--   4. drop trigger trg_ab_marker_push_stamp; drop the new functions and tables. push_changed_at is
--      harmless if left.
-- =====================================================================================================

begin;
set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------
-- PART 1. The heal switch (fail closed)
-- ---------------------------------------------------------------------------------------------------
insert into public.app_config (key, value)
select 'start_heal_enabled', 'false'
 where not exists (select 1 from public.app_config where key = 'start_heal_enabled');

create function public.fn_start_heal_enabled()
returns boolean
language sql stable security definer
set search_path = public, pg_temp
as $$
  -- Fail CLOSED: healing deletes Starts and moves Jobber Tasks, so a missing row counts as OFF and only
  -- 'true' is on. It also needs the judge itself on, and a bulk job can switch it off for one
  -- transaction with set local app.suppress_start_heal = 'on'.
  select public.fn_start_recheck_enabled()
     and coalesce(current_setting('app.suppress_start_heal', true), 'off') <> 'on'
     and coalesce((select lower(btrim(value)) = 'true' from public.app_config
                    where key = 'start_heal_enabled'), false)
$$;

-- fn_start_verdict: the phase-1 body with ONE change. It compared the first visit's instant with
-- (marker_date + minutes) converted back to an instant; on the repeated 01:xx hour of the November clock
-- change that conversion picks EST while the visit is EDT, so a Start derived exactly per 13p read
-- 'first visit changed' for ever. It now compares ET wall-clock minutes, which is what 13p derives from.
create or replace function public.fn_start_verdict(p_marker_date date, p_vehicle_id bigint, p_employee_id bigint,
                                        p_source_visit_id bigint, p_minutes integer, p_eta_minutes integer)
returns text
language sql stable security definer
set search_path = public, pg_temp
as $$
  select case
           when f.id is null then 'no timed visit'
           when p_eta_minutes is not null     -- DERIVED only: a hand-typed minute belongs to the user
                and (f.id is distinct from p_source_visit_id
                     or date_trunc('minute', f.start_at at time zone 'America/New_York') is distinct from
                        (p_marker_date + make_interval(mins => p_minutes + p_eta_minutes
                                                               + public.fn_start_block_minutes())))
             then 'first visit changed'
           when f.driver_id is distinct from p_employee_id then 'driver changed'
         end
    from (select 1) one
    left join lateral public.fn_start_first_visit(p_marker_date, p_vehicle_id) f on true
$$;

-- ---------------------------------------------------------------------------------------------------
-- PART 2. When a Jobber-visible column last changed
-- ---------------------------------------------------------------------------------------------------
alter table ops.calendar_day_markers add column push_changed_at timestamptz;
comment on column ops.calendar_day_markers.push_changed_at is
  'When a column Jobber can see (marker_date, marker_type, minutes, vehicle_id, employee_id, dump_site) last changed; set on INSERT. Maintained only by trg_ab_marker_push_stamp (a caller''s value is replaced). NULL = unchanged since before 2026-09-24. ops.retry_marker_pushes re-sends the Task edit when it is later than the link''s synced_at.';

create function ops.fn_marker_push_stamp()
returns trigger
language plpgsql
set search_path = pg_catalog, pg_temp
as $$
begin
  -- A write made under app.suppress_marker_push never reached Jobber on purpose: leave the stamp as it
  -- was (NULL on an insert) so ops.retry_marker_pushes does not send it later.
  if coalesce(current_setting('app.suppress_marker_push', true), 'off') = 'on' then
    NEW.push_changed_at := case when tg_op = 'INSERT' then null else OLD.push_changed_at end;
  elsif tg_op = 'INSERT' then
    NEW.push_changed_at := now();
  elsif NEW.marker_date is distinct from OLD.marker_date
     or NEW.marker_type is distinct from OLD.marker_type
     or NEW.minutes     is distinct from OLD.minutes
     or NEW.vehicle_id  is distinct from OLD.vehicle_id
     or NEW.employee_id is distinct from OLD.employee_id
     or NEW.dump_site   is distinct from OLD.dump_site then
    NEW.push_changed_at := now();
  else
    NEW.push_changed_at := OLD.push_changed_at;
  end if;
  return NEW;
end
$$;

create trigger trg_ab_marker_push_stamp
  before insert or update on ops.calendar_day_markers
  for each row execute function ops.fn_marker_push_stamp();

-- ---------------------------------------------------------------------------------------------------
-- PART 3. Bookkeeping tables
-- ---------------------------------------------------------------------------------------------------
create table ops.start_heal_attempts (
  marker_id      bigint primary key,
  first_visit_id bigint,
  first_start_at timestamptz,
  outcome        text not null,
  attempted_at   timestamptz not null default now()
);
comment on table ops.start_heal_attempts is
  'The last recompute try per Start (ops.apply_start_heal) and the first visit it was for. ops.start_heal_candidates skips a refused Start for 10 minutes unless its first visit changes. No FK: a removed marker''s row is kept for traceability and deleted after 7 days by ops.retry_marker_pushes. Bookkeeping; rule 8 opt-out.';

create table ops.marker_push_retries (
  kind            text not null check (kind in ('delete', 'edit')),
  ref_id          bigint not null,        -- the link id (delete) or the marker id (edit)
  armed_at        timestamptz not null,   -- the link's synced_at (delete) or the marker's push_changed_at (edit)
  marker_id       bigint not null,
  attempts        integer not null default 0,
  last_attempt_at timestamptz,
  primary key (kind, ref_id, armed_at)
);
comment on table ops.marker_push_retries is
  'Re-sends of a marker''s Jobber Task push by ops.retry_marker_pushes. A new change arms a new row, so the count restarts. Rows older than 30 days are deleted. Bookkeeping; rule 8 opt-out.';

create table ops.start_heal_kick (
  id           integer primary key check (id = 1),
  requested_at timestamptz not null
);
insert into ops.start_heal_kick values (1, '-infinity');
comment on table ops.start_heal_kick is
  'One row: when public.fn_request_start_heal last posted to heal-day-starts. The UPDATE is the gate, so two callers cannot both post within a minute.';

revoke all on ops.start_heal_attempts  from public, anon, authenticated, service_role, yannick_readonly;
revoke all on ops.marker_push_retries  from public, anon, authenticated, service_role, yannick_readonly;
revoke all on ops.start_heal_kick      from public, anon, authenticated, service_role, yannick_readonly;

-- ---------------------------------------------------------------------------------------------------
-- PART 4. The judge heals (spliced from the live phase-1 body; the new lines are marked PHASE 2)
-- ---------------------------------------------------------------------------------------------------
create or replace function ops.fn_judge_starts(p_dates date[])
returns integer
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare
  r        record;
  f        record;                   -- PHASE 2
  v_reason text;
  v_n      integer := 0;
  v_heal   boolean;                  -- PHASE 2
  v_frozen boolean;                  -- PHASE 2
  v_link   timestamptz;              -- PHASE 2
  v_after  text;                     -- PHASE 2
begin
  if not public.fn_start_recheck_enabled() or p_dates is null then return 0; end if;
  v_heal := public.fn_start_heal_enabled();                                     -- PHASE 2
  -- LOCK FIRST, THEN JUDGE: the verdict is read by a later statement, so under read committed it sees
  -- whatever a concurrent writer committed while we waited for the lock.
  for r in
    select m.id, m.marker_date, m.minutes, m.vehicle_id, m.employee_id, m.source_visit_id,
           m.eta_minutes, m.stale_reason, m.created_at
      from ops.calendar_day_markers m
     where m.marker_type = 'start' and m.vehicle_id is not null and m.employee_id is not null
       and m.marker_date = any (p_dates)
     order by m.id
       for update
  loop
    begin
      v_frozen := public.fn_start_frozen(r.marker_date, r.minutes) is true;     -- PHASE 2
      v_reason := case when v_frozen then null
                       else public.fn_start_verdict(r.marker_date, r.vehicle_id, r.employee_id,
                                                    r.source_visit_id, r.minutes, r.eta_minutes) end;

      -- PHASE 2: a Start whose minute passed while it was still flagged: the crew started from a
      -- Jobber Task that was out of date. Logged as an error (the health check reads it for 26 hours);
      -- the flag itself is cleared below, as in phase 1 (frozen means frozen).
      if v_frozen and r.stale_reason is not null then
        insert into public.sync_log (sync_source, started_at, finished_at, status, rows_errored, error_details, details)
        select 'start-flags-judge', clock_timestamp(), clock_timestamp(), 'error', 1,
               jsonb_build_object('message', format(
                 'The Start of day of truck %s on %s (%s, %s) began while it was still out of date (%s), so the crew had a wrong Jobber Task.',
                 coalesce(v.name, r.vehicle_id::text), to_char(r.marker_date, 'Dy Mon FMDD'),
                 to_char(date '2000-01-01' + make_interval(mins => r.minutes), 'FMHH12:MI AM'),
                 coalesce(e.full_name, r.employee_id::text), r.stale_reason)),
               jsonb_build_object('action', 'froze_while_stale', 'marker_id', r.id, 'marker_date', r.marker_date,
                                  'vehicle_id', r.vehicle_id, 'employee_id', r.employee_id,
                                  'minutes', r.minutes, 'stale_reason', r.stale_reason)
          from (select 1) one
          left join public.vehicles v on v.id = r.vehicle_id
          left join public.employees e on e.id = r.employee_id;
      end if;

      -- PHASE 2: heal what needs no drive time. Only a Start whose Jobber link exists and is older than
      -- 10 seconds (a create push takes 0.5-1.3 s; a write inside that window would race it), or, for a
      -- removal only, a Start with no link that is older than 10 minutes (its create never linked).
      if v_heal and v_reason in ('no timed visit', 'driver changed') then
        v_link := null;
        select l.synced_at into v_link
          from public.entity_source_links l
         where l.entity_type = 'calendar_day_marker' and l.source_system = 'jobber' and l.entity_id = r.id;

        if v_reason = 'no timed visit'
           and ((v_link is not null and v_link < now() - interval '10 seconds')
                or (v_link is null and r.created_at < now() - interval '10 minutes')) then
          delete from ops.calendar_day_markers where id = r.id;
          insert into public.sync_log (sync_source, started_at, finished_at, status, rows_updated, details)
          values ('start-flags-heal', clock_timestamp(), clock_timestamp(), 'ok', 1,
                  jsonb_build_object('action', 'removed', 'marker_id', r.id, 'marker_date', r.marker_date,
                                     'vehicle_id', r.vehicle_id, 'employee_id', r.employee_id,
                                     'minutes', r.minutes, 'had_jobber_link', v_link is not null));
          v_n := v_n + 1;
          continue;
        end if;

        if v_reason = 'driver changed' and v_link is not null and v_link < now() - interval '10 seconds' then
          select * into f from public.fn_start_first_visit(r.marker_date, r.vehicle_id);
          -- Only when the first visit is still the one the Start was made for. A hand-typed Start's minute
          -- is never judged, so 'driver changed' on it can hide a DIFFERENT first visit; giving it that
          -- visit's driver would keep the typed minute and call the Start fresh. A person decides then.
          if f.driver_id is not null and f.id = r.source_visit_id then
            -- trg_aa_start_judge judges the row as written; anything but NULL means the verdict moved
            -- under us, and the raise rolls this marker back to be retried on the next pass.
            update ops.calendar_day_markers set employee_id = f.driver_id where id = r.id
            returning stale_reason into v_after;
            if v_after is not null then
              raise exception 'the driver update left the Start flagged (%)', v_after;
            end if;
            insert into public.sync_log (sync_source, started_at, finished_at, status, rows_updated, details)
            values ('start-flags-heal', clock_timestamp(), clock_timestamp(), 'ok', 1,
                    jsonb_build_object('action', 'driver_updated', 'marker_id', r.id, 'marker_date', r.marker_date,
                                       'vehicle_id', r.vehicle_id, 'from_employee_id', r.employee_id,
                                       'to_employee_id', f.driver_id, 'first_visit_id', f.id));
            v_n := v_n + 1;
            continue;
          end if;
        end if;
      end if;

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

-- ---------------------------------------------------------------------------------------------------
-- PART 5. The recompute: candidates and the guarded write, for heal-day-starts (service_role only)
-- ---------------------------------------------------------------------------------------------------
create function ops.start_heal_candidates()
returns table (marker_id bigint, marker_date date, vehicle_id bigint, employee_id bigint, minutes smallint,
               eta_minutes integer, first_visit_id bigint, first_start_at timestamptz,
               latitude numeric, longitude numeric, driver_id bigint, driver_name text, client_code text)
language sql stable security definer
set search_path = public, ops, pg_temp
as $$
  -- Derived Starts flagged 'first visit changed', not frozen, whose Jobber link is older than 10 s.
  -- A refused Start waits while its first visit (same id and start) is unchanged: 10 minutes for a
  -- missing driver, 1 hour for a drive time that could not be computed (each try can spend a routing
  -- token from the Calendar's 300 a day), and until the first visit changes for a refusal that cannot
  -- improve (before midnight, already passed, a verdict the recompute cannot clear). A new first visit is
  -- tried at once. At most 10 per run (one drive-time leg each, 6 s timeout each).
  select m.id, m.marker_date, m.vehicle_id, m.employee_id, m.minutes, m.eta_minutes,
         f.id, f.start_at, f.latitude, f.longitude, f.driver_id, f.driver_name, f.client_code
    from ops.calendar_day_markers m
    join public.entity_source_links l
      on l.entity_type = 'calendar_day_marker' and l.source_system = 'jobber' and l.entity_id = m.id
   cross join lateral public.fn_start_first_visit(m.marker_date, m.vehicle_id) f
   where public.fn_start_heal_enabled()
     and m.marker_type = 'start' and m.vehicle_id is not null and m.employee_id is not null
     and m.stale_reason = 'first visit changed' and m.eta_minutes is not null
     and public.fn_start_frozen(m.marker_date, m.minutes) is not true
     and l.synced_at < now() - interval '10 seconds'
     and not exists (select 1 from ops.start_heal_attempts a
                      where a.marker_id = m.id and a.outcome <> 'healed'
                        and a.attempted_at > now() - case a.outcome
                                                       when 'no_driver' then interval '10 minutes'
                                                       when 'eta_unknown' then interval '1 hour'
                                                       when 'eta_implausible' then interval '1 hour'
                                                       else interval '100 years' end
                        and a.first_visit_id is not distinct from f.id
                        and a.first_start_at is not distinct from f.start_at)
   order by m.marker_date, m.id
   limit 10
$$;

create function ops.apply_start_heal(p_marker_id bigint, p_first_visit_id bigint, p_first_start_at timestamptz,
                                     p_driver_id bigint, p_eta_minutes integer)
returns jsonb
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare
  m         record;
  f         record;
  v_minutes integer;
  v_after   text;
  v_outcome text;
begin
  perform set_config('lock_timeout', '3s', true);
  select * into m from ops.calendar_day_markers where id = p_marker_id for update;
  if not found then return jsonb_build_object('outcome', 'gone', 'marker_id', p_marker_id); end if;
  select * into f from public.fn_start_first_visit(m.marker_date, m.vehicle_id);

  if not public.fn_start_heal_enabled() then
    v_outcome := 'off';
  elsif m.marker_type <> 'start' or m.vehicle_id is null or m.employee_id is null or m.eta_minutes is null then
    v_outcome := 'not_derived';
  elsif m.stale_reason is distinct from 'first visit changed' then
    v_outcome := 'not_flagged';
  elsif public.fn_start_frozen(m.marker_date, m.minutes) is true then
    v_outcome := 'frozen';           -- it has begun: frozen means frozen (the judge logs it as began out of date)
  elsif f.id is null or f.id is distinct from p_first_visit_id or f.start_at is distinct from p_first_start_at
        or f.driver_id is distinct from p_driver_id then
    v_outcome := 'changed';          -- the ETA was computed for another first visit; the next run retries
  elsif f.driver_id is null then
    v_outcome := 'no_driver';
  elsif p_eta_minutes is null then
    v_outcome := 'eta_unknown';
  elsif p_eta_minutes < 1 or p_eta_minutes > 600 then
    v_outcome := 'eta_implausible';
  else
    -- 13p, exactly as the Calendar derives it: the first visit's ET minute of day - ETA - the block.
    v_minutes := extract(hour from f.start_at at time zone 'America/New_York')::integer * 60
               + extract(minute from f.start_at at time zone 'America/New_York')::integer
               - p_eta_minutes - public.fn_start_block_minutes();
    if v_minutes < 0 then
      v_outcome := 'before_midnight';
    elsif public.fn_start_frozen(m.marker_date, v_minutes) is true then
      v_outcome := 'too_late';
    else
      -- The BEFORE trigger judges the row as written. If the verdict still is not NULL, undo the write
      -- (the inner block is a savepoint) and record the refusal, so the Start backs off instead of being
      -- offered again on every kick.
      begin
        update ops.calendar_day_markers
           set minutes = v_minutes, employee_id = f.driver_id, source_visit_id = f.id,
               eta_minutes = p_eta_minutes, eta_computed_at = now()
         where id = p_marker_id
        returning stale_reason into v_after;
        if v_after is not null then
          raise exception using message = 'START_HEAL_UNRESOLVABLE';
        end if;
        v_outcome := 'healed';
      exception when raise_exception then
        if sqlerrm <> 'START_HEAL_UNRESOLVABLE' then raise; end if;
        v_outcome := 'unresolvable';
      end;
    end if;
  end if;

  if v_outcome not in ('gone', 'changed', 'off', 'not_derived', 'not_flagged', 'frozen') then
    insert into ops.start_heal_attempts (marker_id, first_visit_id, first_start_at, outcome, attempted_at)
    values (p_marker_id, f.id, f.start_at, v_outcome, now())
    on conflict (marker_id) do update
       set first_visit_id = excluded.first_visit_id, first_start_at = excluded.first_start_at,
           outcome = excluded.outcome, attempted_at = excluded.attempted_at;
  end if;

  return jsonb_build_object('outcome', v_outcome, 'marker_id', p_marker_id, 'marker_date', m.marker_date,
                            'vehicle_id', m.vehicle_id, 'first_visit_id', f.id,
                            'from_minutes', m.minutes, 'to_minutes', v_minutes,
                            'from_employee_id', m.employee_id, 'to_employee_id', f.driver_id,
                            'eta_minutes', p_eta_minutes);
end
$$;

-- ---------------------------------------------------------------------------------------------------
-- PART 6. The kick (only when a recompute is due, at most once a minute)
-- ---------------------------------------------------------------------------------------------------
create function public.fn_request_start_heal()
returns boolean
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare
  v_key text;
  v_hit integer;
begin
  if not exists (select 1 from ops.start_heal_candidates()) then return false; end if;
  -- the gate IS the write: a second caller waits on the row, re-reads it, and updates nothing
  update ops.start_heal_kick set requested_at = now()
   where id = 1 and requested_at < now() - interval '60 seconds';
  get diagnostics v_hit = row_count;
  if v_hit = 0 then return false; end if;

  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    insert into public.sync_log (sync_source, started_at, finished_at, status, rows_errored, error_details, details)
    values ('start-flags-heal', clock_timestamp(), clock_timestamp(), 'error', 1,
            jsonb_build_object('message', 'The vault secret edge_invoke_service_key is missing, so no Start of day can be recomputed automatically.'),
            jsonb_build_object('action', 'kick', 'key_missing', true));
    return false;
  end if;
  perform net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/heal-day-starts',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := jsonb_build_object('trigger', 'kick'),
    timeout_milliseconds := 120000);
  return true;
end
$$;

-- ---------------------------------------------------------------------------------------------------
-- PART 7. The drain also retries flagged days and kicks the recompute (spliced from phase 1)
-- ---------------------------------------------------------------------------------------------------
create or replace function ops.refresh_start_flags()
returns integer
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare
  v_dates date[];
  v_n     integer;                                                              -- PHASE 2
begin
  if not public.fn_start_recheck_enabled() then return 0; end if;   -- keep the notes for when it is back on
  perform set_config('lock_timeout', '3s', true);
  with d as (
    delete from ops.start_recheck_queue q
     where q.id in (select id from ops.start_recheck_queue for update skip locked)
    returning q.marker_date)
  select array_agg(distinct marker_date) into v_dates from d;
  -- PHASE 2: also every day that still carries a flag, so a heal that was skipped (a young link, a
  -- missing driver) is retried, and a Start that freezes while flagged is caught within two minutes.
  v_dates := array(
    select distinct x from unnest(coalesce(v_dates, '{}'::date[]) || array(
      select m.marker_date from ops.calendar_day_markers m
       where m.marker_type = 'start' and m.vehicle_id is not null and m.stale_reason is not null)) x);
  if cardinality(v_dates) = 0 then return 0; end if;
  v_n := ops.fn_judge_starts(v_dates);
  -- PHASE 2: a 'first visit changed' needs a drive time: hand it to heal-day-starts. Never let the kick
  -- undo the judging above.
  begin
    perform public.fn_request_start_heal();
  exception when others then
    insert into public.sync_log (sync_source, started_at, finished_at, status, rows_errored, error_details, details)
    values ('start-flags-heal', clock_timestamp(), clock_timestamp(), 'error', 1,
            jsonb_build_object('sqlstate', sqlstate, 'message', sqlerrm), jsonb_build_object('action', 'kick'));
  end;
  return v_n;
end
$$;

-- ---------------------------------------------------------------------------------------------------
-- PART 8. Re-send a Task push that did not land (never a create)
-- ---------------------------------------------------------------------------------------------------
create function ops.retry_marker_pushes()
returns integer
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare
  r      record;
  v_hit  integer;
  v_n    integer := 0;
  v_done jsonb := '[]'::jsonb;
begin
  delete from ops.marker_push_retries where coalesce(last_attempt_at, armed_at) < now() - interval '30 days';
  delete from ops.start_heal_attempts where attempted_at < now() - interval '7 days';

  for r in
    -- a) the marker is gone but its link is still there: the Task delete failed or never ran.
    --    jobber-push-task's delete reads only the link, so it works with the marker gone.
    select 'delete'::text as kind, l.id as ref_id, l.synced_at as armed_at, l.entity_id as marker_id,
           'delete'::text as op
      from public.entity_source_links l
     where l.entity_type = 'calendar_day_marker' and l.source_system = 'jobber'
       and l.synced_at < now() - interval '2 minutes'
       and not exists (select 1 from ops.calendar_day_markers m where m.id = l.entity_id)
    union all
    -- b) a Jobber-visible column changed after the last successful push (synced_at is written only on
    --    a verified push), today or later, settled for 2 minutes. An edit, idempotent.
    select 'edit', m.id, m.push_changed_at, m.id, 'upsert'
      from ops.calendar_day_markers m
      join public.entity_source_links l
        on l.entity_type = 'calendar_day_marker' and l.source_system = 'jobber' and l.entity_id = m.id
     where m.marker_date >= (now() at time zone 'America/New_York')::date
       and m.push_changed_at > l.synced_at
       and m.push_changed_at < now() - interval '2 minutes'
       and public.fn_start_frozen(m.marker_date, m.minutes) is not true   -- its time has passed: leave the Task
  loop
    insert into ops.marker_push_retries (kind, ref_id, armed_at, marker_id, attempts, last_attempt_at)
    values (r.kind, r.ref_id, r.armed_at, r.marker_id, 1, now())
    on conflict (kind, ref_id, armed_at) do update
       set attempts = ops.marker_push_retries.attempts + 1, last_attempt_at = now()
     where (ops.marker_push_retries.attempts < 3
            and ops.marker_push_retries.last_attempt_at < now() - interval '4 minutes')
        or ops.marker_push_retries.last_attempt_at < now() - interval '6 hours';
    get diagnostics v_hit = row_count;
    if v_hit > 0 then
      perform public.fn_request_marker_push(r.marker_id, r.op);
      v_n := v_n + 1;
      v_done := v_done || jsonb_build_object('kind', r.kind, 'ref_id', r.ref_id, 'marker_id', r.marker_id);
    end if;
  end loop;

  if v_n > 0 then
    insert into public.sync_log (sync_source, started_at, finished_at, status, rows_updated, details)
    values ('start-flags-push-retry', clock_timestamp(), clock_timestamp(), 'ok', v_n,
            jsonb_build_object('count', v_n, 'items', v_done));
  end if;
  return v_n;
end
$$;

-- fn_request_marker_push: the live body with ONE change, timeout_milliseconds 30000 (spliced; the
-- anchor must occur exactly once and no timeout may be there already).
do $$
declare
  v_def    text := pg_get_functiondef('public.fn_request_marker_push(bigint,text)'::regprocedure);
  v_anchor text := 'body    := jsonb_build_object(''op'', p_op, ''marker_id'', p_marker_id));';
  v_n      int;
begin
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then raise exception 'fn_request_marker_push: expected 1 anchor, found %', v_n; end if;
  if v_def ~ 'timeout_milliseconds' then raise exception 'fn_request_marker_push already has a timeout'; end if;
  v_def := replace(v_def, v_anchor,
    'body    := jsonb_build_object(''op'', p_op, ''marker_id'', p_marker_id),' || chr(10) ||
    '    timeout_milliseconds := 30000);   -- 2026-09-24: pg_net''s 5000 default is shorter than a throttled push');
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- PART 9. The dialog's pre-check (read-only)
-- ---------------------------------------------------------------------------------------------------
create function ops.preview_start_impact(p_changes jsonb)
returns table (marker_id bigint, marker_date date, vehicle_id bigint, truck_name text, minutes smallint,
               employee_id bigint, driver_name text, leaving jsonb, anytime_codes text[])
language plpgsql stable security definer
set search_path = public, ops, pg_temp
as $$
begin
  -- p_changes: one object per visit the gesture writes, with the keys the write changes:
  --   {"visit_id": 5994, "visit_date": "2026-09-26"}                 a date move (a ripple link too);
  --   {"visit_id": 5994, "start_at": "...", "end_at": "..."}         a time change; start_at null = Anytime;
  --   {"visit_id": 5994, "vehicle_id": 2 | null}                     a truck change (null = No truck);
  --   {"visit_id": 5994, "visit_status": "completed" | "skipped"}   a status change;
  --   {"visit_id": 5994, "deleted": true}                            a delete or an unschedule.
  -- As in the real write: a date move without start_at keeps the ET wall-clock time
  -- (ripple_reschedule_visit), and a start_at without visit_date moves the date with it
  -- (trg_aa_reconcile_operating_date). Returns one row per unfrozen truck Start whose truck-day HAS a
  -- timed visit now and would have NONE after the gesture.
  if p_changes is null or jsonb_typeof(p_changes) <> 'array' then
    raise exception 'The Start of day check needs the list of visit changes.'
      using errcode = '22023', detail = 'blocker=bad_changes in ops.preview_start_impact';
  end if;

  return query
  with ch as (
    select v.id, v.visit_date as old_date, v.vehicle_id as old_vehicle,
           v.visit_status as old_status, v.start_at as old_start, v.end_at as old_end,
           d.nd as new_date,
           case when c ? 'start_at' then (c->>'start_at')::timestamptz
                else ((v.start_at at time zone 'America/New_York') + make_interval(days => d.nd - v.visit_date))
                       at time zone 'America/New_York' end as new_start,
           case when c ? 'end_at' then (c->>'end_at')::timestamptz
                else ((v.end_at at time zone 'America/New_York') + make_interval(days => d.nd - v.visit_date))
                       at time zone 'America/New_York' end as new_end,
           case when c ? 'vehicle_id' then (c->>'vehicle_id')::bigint else v.vehicle_id end as new_vehicle,
           coalesce(c->>'visit_status', v.visit_status) as new_status,
           coalesce((c->>'deleted')::boolean, false) as new_deleted,
           coalesce(prop.latitude, pp.latitude) is not null
             and coalesce(prop.longitude, pp.longitude) is not null as has_coords,
           cl.client_code, cl.name as client_name
      from jsonb_array_elements(p_changes) as x(c)
      join public.visits v on v.id = (c->>'visit_id')::bigint and v.deleted_at is null
      join public.clients cl on cl.id = v.client_id
      left join public.properties prop on prop.id = v.property_id
      left join public.properties pp on pp.client_id = v.client_id and pp.is_primary = true
     cross join lateral (select coalesce((c->>'visit_date')::date,
                                         case when c ? 'start_at' and c->>'start_at' is not null
                                              then ((c->>'start_at')::timestamptz at time zone 'America/New_York')::date end,
                                         v.visit_date) as nd) d
  ),
  -- the same timed-visit test as public.fn_start_first_visit, applied to the proposed state
  q as (
    select ch.*,
           (ch.new_status = 'scheduled' and not ch.new_deleted and ch.new_start is not null and ch.has_coords
            and not ((ch.new_start at time zone 'America/New_York')::time = '00:00:00'::time
                     and ch.new_end is not null and (ch.new_end - ch.new_start) >= '23:00:00'::interval)) as new_timed,
           (ch.old_status = 'scheduled' and ch.old_start is not null and ch.has_coords
            and not ((ch.old_start at time zone 'America/New_York')::time = '00:00:00'::time
                     and ch.old_end is not null and (ch.old_end - ch.old_start) >= '23:00:00'::interval)) as old_timed
      from ch
  ),
  starts as (
    select distinct m.id, m.marker_date, m.vehicle_id, m.minutes, m.employee_id
      from ops.calendar_day_markers m
      join q on q.old_date = m.marker_date and q.old_vehicle = m.vehicle_id and q.old_timed
     where m.marker_type = 'start' and m.vehicle_id is not null and m.employee_id is not null
       and public.fn_start_frozen(m.marker_date, m.minutes) is not true
  )
  select s.id, s.marker_date, s.vehicle_id, t.name, s.minutes, s.employee_id, e.full_name,
         (select jsonb_agg(jsonb_build_object('visit_id', q.id, 'client_code', q.client_code,
                                              'client_name', q.client_name, 'new_date', q.new_date,
                                              'new_vehicle_id', q.new_vehicle, 'new_status', q.new_status,
                                              'deleted', q.new_deleted, 'anytime', q.new_start is null)
                           order by q.old_start, q.id)
            from q where q.old_date = s.marker_date and q.old_vehicle = s.vehicle_id and q.old_timed),
         array(select distinct c2.client_code
                 from public.visits v2 join public.clients c2 on c2.id = v2.client_id
                where v2.deleted_at is null and v2.visit_status = 'scheduled'
                  and v2.visit_date = s.marker_date and v2.vehicle_id = s.vehicle_id
                  and v2.id not in (select q.id from q)
                  and (v2.start_at is null
                       or ((v2.start_at at time zone 'America/New_York')::time = '00:00:00'::time
                           and v2.end_at is not null and (v2.end_at - v2.start_at) >= '23:00:00'::interval))
                order by c2.client_code)
    from starts s
    left join public.vehicles t on t.id = s.vehicle_id
    left join public.employees e on e.id = s.employee_id
   where exists (select 1 from public.fn_start_first_visit(s.marker_date, s.vehicle_id))
     and not exists (select 1 from public.fn_start_first_visit(s.marker_date, s.vehicle_id,
                                                               array(select q.id from q)))
     and not exists (select 1 from q where q.new_date = s.marker_date and q.new_vehicle = s.vehicle_id
                                         and q.new_timed)
   order by s.marker_date, s.vehicle_id;
end
$$;

-- ---------------------------------------------------------------------------------------------------
-- PART 10. The health check, and its registration in both health views
-- ---------------------------------------------------------------------------------------------------
create function public.log_start_flags_health()
returns integer
language plpgsql
set search_path = public, ops, pg_temp
as $$
declare
  n       integer;
  v_items jsonb;
  v_today date := (now() at time zone 'America/New_York')::date;
  v_heal  boolean := public.fn_start_heal_enabled();
begin
  with l as (
    select * from public.entity_source_links where entity_type = 'calendar_day_marker' and source_system = 'jobber'
  ),
  mk as (
    select m.*, coalesce(v.name, 'no truck') as truck, e.full_name as driver,
           to_char(m.marker_date, 'Dy Mon FMDD') as day,
           to_char(date '2000-01-01' + make_interval(mins => m.minutes), 'FMHH12:MI AM') as at_time,
           case m.marker_type when 'start' then 'Start of day' when 'end' then 'End of day'
                              when 'dump' then 'Dump' else m.marker_type end as what
      from ops.calendar_day_markers m
      left join public.vehicles v on v.id = m.vehicle_id
      left join public.employees e on e.id = m.employee_id
  ),
  f as (
    -- 1. a truck Start still out of date 30 minutes after it was flagged (keyed by day + truck)
    select jsonb_build_object(
             'kind', 'start_unhealed:' || mk.marker_date || ':' || mk.vehicle_id,
             'issue', 'start_out_of_date',
             'reason', format('Truck %s, %s: the Start of day (%s, %s) has been out of date since %s ET because %s%s.',
                              mk.truck, mk.day, mk.at_time, coalesce(mk.driver, 'no driver'),
                              to_char(mk.stale_since at time zone 'America/New_York', 'FMHH12:MI AM'),
                              case when mk.stale_reason = 'no timed visit' then 'the truck has no visit with a set time left'
                                   when mk.stale_reason = 'first visit changed' then 'its first visit changed'
                                   when fv.driver_id is null then 'its first visit has no driver'
                                   when fv.id is distinct from mk.source_visit_id then 'its first visit is now another visit, with another driver'
                                   else 'the first visit has another driver' end,
                              case when not v_heal then ', and automatic fixing is switched off'
                                   when mk.stale_reason = 'driver changed' and fv.driver_id is null then ''
                                   when mk.stale_reason = 'driver changed' and fv.id is distinct from mk.source_visit_id
                                     then ', so a person has to choose (the Start''s time was typed by hand)'
                                   when a.outcome = 'no_driver' then ', and the new first visit has no driver'
                                   when a.outcome = 'eta_unknown' then ', and the drive time from the yard could not be computed'
                                   when a.outcome = 'eta_implausible' then ', and the drive time from the yard came back implausible'
                                   when a.outcome = 'before_midnight' then ', and the drive plus the 30-minute block would start before midnight'
                                   when a.outcome = 'too_late' then ', and the new start time has already passed'
                                   when a.outcome = 'unresolvable' then ', and the recompute could not make it match its first visit'
                                   when mk.stale_reason = 'first visit changed'
                                        and not exists (select 1 from public.sync_log s
                                                         where s.sync_source = 'start-flags-heal'
                                                           and s.details->>'action' = 'recompute_run'
                                                           and s.started_at > mk.stale_since)
                                     then ', and the automatic recompute has not run since (check that heal-day-starts is deployed and the edge_invoke_service_key vault secret exists)'
                                   else ', and it was not fixed automatically' end),
             'what_to_do', case when mk.stale_reason = 'driver changed' and fv.driver_id is null
                                  then 'Put a driver on that visit, or Remove the Start in the Calendar.'
                                else 'Open that day in the Calendar and use Recompute, Update driver or Remove on the Start.' end,
             'marker_id', mk.id, 'marker_date', mk.marker_date, 'vehicle_id', mk.vehicle_id) as item
      from mk
      left join ops.start_heal_attempts a on a.marker_id = mk.id
      left join lateral public.fn_start_first_visit(mk.marker_date, mk.vehicle_id) fv on true
     where mk.marker_type = 'start' and mk.vehicle_id is not null and mk.stale_reason is not null
       and mk.marker_date >= v_today and mk.stale_since < now() - interval '30 minutes'
    union all
    -- 2. a marker that never reached Jobber
    select jsonb_build_object(
             'kind', 'marker_task_missing:' || mk.id,
             'issue', 'marker_not_in_jobber',
             'reason', format('The %s on %s at %s (%s, %s) has no Jobber Task: the push that creates it did not complete.',
                              mk.what, mk.day, mk.at_time, mk.truck, coalesce(mk.driver, 'no driver')),
             'what_to_do', 'Delete the marker in the Calendar and place it again. If it happens again, tell Fred.',
             'marker_id', mk.id, 'marker_date', mk.marker_date)
      from mk
     where mk.marker_date >= v_today and mk.created_at < now() - interval '10 minutes'
       and not exists (select 1 from l where l.entity_id = mk.id)
    union all
    -- 3. a Task whose marker is gone, after a retry has already tried and failed to delete it
    select jsonb_build_object(
             'kind', 'marker_task_orphan:' || l.id,
             'issue', 'marker_task_not_deleted',
             'reason', format('The Jobber Task "%s" belongs to a marker that was removed, and deleting it failed (%s tries). It may still be on the crew''s Jobber schedule.',
                              coalesce(l.source_name, 'with no title'), coalesce(r.attempts, 0)),
             'what_to_do', 'Delete that Task in Jobber by hand. The retry that runs every 6 hours then removes the link.',
             'link_id', l.id, 'marker_id', l.entity_id)
      from l
      join ops.marker_push_retries r on r.kind = 'delete' and r.ref_id = l.id and r.armed_at = l.synced_at
     where not exists (select 1 from ops.calendar_day_markers m where m.id = l.entity_id)
       and r.attempts >= 1 and r.last_attempt_at < now() - interval '4 minutes'
    union all
    -- 4. a marker that changed after its last successful push and was still not updated after the retries
    select jsonb_build_object(
             'kind', 'marker_task_out_of_date:' || mk.id,
             'issue', 'marker_task_not_updated',
             'reason', format('The %s on %s (%s, %s) changed at %s ET but its Jobber Task was not updated, so the crew sees the old version.',
                              mk.what, mk.day, mk.truck, coalesce(mk.driver, 'no driver'),
                              to_char(mk.push_changed_at at time zone 'America/New_York', 'FMHH12:MI AM')),
             'what_to_do', 'Check the Task in Jobber. If it is missing, delete the marker in the Calendar and place it again.',
             'marker_id', mk.id, 'marker_date', mk.marker_date)
      from mk join l on l.entity_id = mk.id
     where mk.marker_date >= v_today and mk.push_changed_at > l.synced_at
       and mk.push_changed_at < now() - interval '20 minutes'
    union all
    -- 5. errors in the last 26 hours (a Start that began while out of date is one of them)
    select jsonb_build_object(
             'kind', 'start_errors:' || s.sync_source,
             'issue', 'start_errors',
             'reason', format('%s problem(s) in the last 26 hours in %s. The latest: %s',
                              s.n, case s.sync_source when 'start-flags-heal' then 'the automatic Start of day fixing'
                                                      when 'start-flags-judge' then 'the Start of day checker'
                                                      when 'start-recheck-queue' then 'the Start of day queue'
                                                      else 'the Jobber Task retry' end,
                              s.last_msg),
             'what_to_do', 'Read public.sync_log for sync_source ' || s.sync_source || ' (status error).',
             'count', s.n)
      from (select sl.sync_source, count(*) as n,
                   (array_agg(coalesce(sl.error_details->>'message', sl.details->>'error', sl.status)
                              order by sl.started_at desc))[1] as last_msg
              from public.sync_log sl
             where sl.sync_source in ('start-flags-heal', 'start-flags-judge', 'start-recheck-queue', 'start-flags-push-retry')
               and sl.status in ('error', 'partial')
               and coalesce(sl.details->>'action', '') <> 'froze_while_stale'
               and sl.started_at > now() - interval '26 hours'
             group by sl.sync_source) s
    union all
    -- 5b. each Start that began while it was still out of date, one item per incident (a per-source key
    --     would email the first one and then swallow every later one for a week)
    select jsonb_build_object(
             'kind', 'start_began_out_of_date:' || x.marker_id || ':' || x.marker_date,
             'issue', 'start_began_out_of_date',
             'reason', x.msg,
             'what_to_do', 'Check that crew''s Day Start Task in Jobber and tell them the right time if it is still wrong.',
             'marker_id', x.marker_id, 'marker_date', x.marker_date)
      from (select distinct on (sl.details->>'marker_id', sl.details->>'marker_date')
                   sl.details->>'marker_id' as marker_id, sl.details->>'marker_date' as marker_date,
                   sl.error_details->>'message' as msg
              from public.sync_log sl
             where sl.sync_source = 'start-flags-judge' and sl.details->>'action' = 'froze_while_stale'
               and sl.started_at > now() - interval '26 hours'
             order by sl.details->>'marker_id', sl.details->>'marker_date', sl.started_at desc) x
    union all
    -- 5c. the retry sweep itself has stopped (then items 3 and 4 could never appear)
    select jsonb_build_object(
             'kind', 'start_push_retry_not_running',
             'issue', 'start_push_retry_not_running',
             'reason', 'The Jobber Task retry (cron start-push-retry) has not completed a run in the last 30 minutes, so a failed Task push would not be re-sent.',
             'what_to_do', 'Check cron.job_run_details for start-push-retry.')
     where not exists (select 1 from cron.job_run_details d join cron.job j on j.jobid = d.jobid
                        where j.jobname = 'start-push-retry' and d.status = 'succeeded'
                          and d.end_time > now() - interval '30 minutes')
       and exists (select 1 from cron.job j where j.jobname = 'start-push-retry'
                     and j.jobid in (select jobid from cron.job_run_details))
    union all
    -- 6. the judge is switched off, so nothing is checked or fixed (and items 1-4 read as clear)
    select jsonb_build_object(
             'kind', 'start_recheck_disabled',
             'issue', 'start_recheck_disabled',
             'reason', 'Start of day checking is switched off (app_config start_recheck_enabled), so no Start is checked or fixed.',
             'what_to_do', 'Set public.app_config start_recheck_enabled back to true.')
     where not public.fn_start_recheck_enabled()
    union all
    -- 7. a marker's Jobber Task lost its link and was imported as a Calendar Task (a duplicate)
    select jsonb_build_object(
             'kind', 'marker_task_leaked:' || t.id,
             'issue', 'marker_task_duplicate',
             'reason', format('A Jobber Task made for a route marker ("%s" on %s) was imported as a Calendar Task, so the crew may see it twice.',
                              t.title, to_char(t.task_date, 'Dy Mon FMDD')),
             'what_to_do', 'Delete the extra Task in Jobber; the Calendar Task then disappears on the next poll.',
             'calendar_task_id', t.id)
      from ops.calendar_tasks t
     where t.instructions like 'Route marker from the UnclogMe Visit Calendar%'
       and t.task_date >= v_today - 30
  )
  select count(*), coalesce(jsonb_agg(item order by item->>'kind'), '[]'::jsonb) into n, v_items from f;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('start-flags-health', clock_timestamp(), clock_timestamp(), n,
          case when n > 0 then 'attention' else 'ok' end,
          jsonb_build_object('count', n, 'items', v_items));
  return n;
end
$$;

do $$
declare
  v_def text;
  v_n   int;
  v_arr text := '''jobber-client-state-sweep''::text]';
  v_new text := '''jobber-client-state-sweep''::text, ''start-flags-health''::text]';
begin
  -- ops.v_health_items: the source list once, the CASE once (alias la)
  v_def := pg_get_viewdef('ops.v_health_items'::regclass, true);
  v_n := (length(v_def) - length(replace(v_def, v_arr, ''))) / length(v_arr);
  if v_n <> 1 then raise exception 'v_health_items: expected 1 array anchor, found %', v_n; end if;
  v_def := replace(v_def, v_arr, v_new);
  v_n := (length(v_def) - length(replace(v_def, 'WHEN ''jobber-client-state-sweep''::text THEN COALESCE(la.details -> ''items''::text, ''[]''::jsonb)', ''))) / length('WHEN ''jobber-client-state-sweep''::text THEN COALESCE(la.details -> ''items''::text, ''[]''::jsonb)');
  if v_n <> 1 then raise exception 'v_health_items: expected 1 CASE anchor, found %', v_n; end if;
  v_def := replace(v_def,
    'WHEN ''jobber-client-state-sweep''::text THEN COALESCE(la.details -> ''items''::text, ''[]''::jsonb)',
    'WHEN ''jobber-client-state-sweep''::text THEN COALESCE(la.details -> ''items''::text, ''[]''::jsonb) WHEN ''start-flags-health''::text THEN COALESCE(la.details -> ''items''::text, ''[]''::jsonb)');
  execute 'create or replace view ops.v_health_items as ' || v_def;

  -- ops.v_health_status: the source list twice (runs CTE, streak subquery), the CASE once (alias l)
  v_def := pg_get_viewdef('ops.v_health_status'::regclass, true);
  v_n := (length(v_def) - length(replace(v_def, v_arr, ''))) / length(v_arr);
  if v_n <> 2 then raise exception 'v_health_status: expected 2 array anchors, found %', v_n; end if;
  v_def := replace(v_def, v_arr, v_new);
  v_n := (length(v_def) - length(replace(v_def, 'WHEN ''jobber-client-state-sweep''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb)', ''))) / length('WHEN ''jobber-client-state-sweep''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb)');
  if v_n <> 1 then raise exception 'v_health_status: expected 1 CASE anchor, found %', v_n; end if;
  v_def := replace(v_def,
    'WHEN ''jobber-client-state-sweep''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb)',
    'WHEN ''jobber-client-state-sweep''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb) WHEN ''start-flags-health''::text THEN COALESCE(l.details -> ''items''::text, ''[]''::jsonb)');
  execute 'create or replace view ops.v_health_status as ' || v_def;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- PART 11. Crons and grants
-- ---------------------------------------------------------------------------------------------------
select cron.schedule('start-push-retry', '1-59/5 * * * *', $cron$select ops.retry_marker_pushes()$cron$);
-- 13:20 UTC: after jobber-sync-health (13:13), before health-escalation (13:30), which reads the latest row
select cron.schedule('start-flags-health', '20 13 * * *', $cron$select public.log_start_flags_health()$cron$);

revoke all on function public.fn_start_heal_enabled()                         from public, anon, authenticated, service_role;
revoke all on function ops.fn_marker_push_stamp()                              from public, anon, authenticated, service_role;
revoke all on function ops.start_heal_candidates()                             from public, anon, authenticated, service_role;
revoke all on function ops.apply_start_heal(bigint, bigint, timestamptz, bigint, integer)
                                                                               from public, anon, authenticated, service_role;
revoke all on function public.fn_request_start_heal()                          from public, anon, authenticated, service_role;
revoke all on function ops.retry_marker_pushes()                               from public, anon, authenticated, service_role;
revoke all on function public.log_start_flags_health()                         from public, anon, authenticated, service_role;
revoke all on function ops.preview_start_impact(jsonb)                         from public, anon;
grant execute on function ops.preview_start_impact(jsonb)                      to authenticated, service_role;
grant execute on function ops.start_heal_candidates()                          to service_role;
grant execute on function ops.apply_start_heal(bigint, bigint, timestamptz, bigint, integer) to service_role;

-- A first real row for the health check, so health-escalate has a baseline.
select public.log_start_flags_health();

-- ---------------------------------------------------------------------------------------------------
-- VERIFY (inside the transaction: any failure rolls the whole migration back)
-- ---------------------------------------------------------------------------------------------------
do $verify$
declare
  v_121 record; v_5994_start timestamptz; v_fri date := '2026-09-25';
  v_today date := (now() at time zone 'America/New_York')::date;
  p_stamp_null timestamptz; p_stamp_set boolean; p_stamp_forged boolean;
  p_pre_move int; p_pre_same_day int; p_pre_anytime int; p_pre_truck int; p_pre_notruck int;
  p_pre_delete int; p_pre_complete int; p_pre_noop int; p_pre_start_move int; p_pre_leaving text;
  p_pre_bad text;
  p_off_removed boolean; p_off_flag text;
  p_drv_emp bigint; p_drv_flag text; p_drv_log int;
  p_cand_n int; p_cand_fv bigint; p_eta_unknown text; p_cand_after_refusal int; p_changed text;
  p_healed text; p_healed_min smallint; p_healed_flag text; p_healed_emp bigint;
  p_rm_gone boolean; p_rm_log int;
  p_froze_log int; p_froze_flag text;
  p_retry_first int; p_retry_again int; p_retry_edit int; p_retry_ledger int;
  p_h_n int; p_h_items int; p_h_dup int; p_h_kinds text;
  v_orphan_link bigint;
  v_g_id bigint; p_stamp_suppressed timestamptz; p_frozen_apply text;
  p_hand_emp bigint; p_hand_flag text; p_dst_flag text; p_retry_passed int;
begin
  select * into v_121 from ops.calendar_day_markers where id = 121;
  select start_at into v_5994_start from public.visits where id = 5994;
  if v_121.id is null or v_121.stale_reason is not null then
    raise exception 'V0 marker 121 missing or already flagged, the probes need it fresh'; end if;
  if public.fn_start_frozen(v_fri, v_121.minutes) then
    raise exception 'V0 marker 121 has begun: this VERIFY is pinned to it, re-pin the probe to a later Start'; end if;
  if (select id from public.fn_start_first_visit(v_fri, 1)) is distinct from 5994 then
    raise exception 'V0 visit 5994 is no longer the first timed visit of truck 1 on Fri 09-25'; end if;

  -- V1. Grants.
  if has_function_privilege('anon', 'ops.preview_start_impact(jsonb)', 'EXECUTE')
     or has_function_privilege('authenticated', 'ops.start_heal_candidates()', 'EXECUTE')
     or has_function_privilege('authenticated', 'ops.apply_start_heal(bigint, bigint, timestamptz, bigint, integer)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_request_start_heal()', 'EXECUTE')
     or has_function_privilege('authenticated', 'ops.retry_marker_pushes()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.log_start_flags_health()', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_start_heal_enabled()', 'EXECUTE')
     or has_function_privilege('authenticated', 'ops.fn_judge_starts(date[])', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.fn_request_marker_push(bigint, text)', 'EXECUTE')
     or has_function_privilege('service_role', 'ops.retry_marker_pushes()', 'EXECUTE')
     or has_function_privilege('service_role', 'public.fn_request_start_heal()', 'EXECUTE')
     or has_table_privilege('authenticated', 'ops.start_heal_attempts', 'SELECT')
     or has_table_privilege('service_role', 'ops.start_heal_attempts', 'SELECT')
     or has_table_privilege('authenticated', 'ops.marker_push_retries', 'SELECT')
     or has_table_privilege('yannick_readonly', 'ops.marker_push_retries', 'SELECT')
     or has_table_privilege('anon', 'ops.start_heal_kick', 'SELECT') then
    raise exception 'V1 a grant is wider than intended';
  end if;
  if not has_function_privilege('authenticated', 'ops.preview_start_impact(jsonb)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'ops.refresh_start_flags()', 'EXECUTE')
     or not has_function_privilege('service_role', 'ops.start_heal_candidates()', 'EXECUTE')
     or not has_function_privilege('service_role', 'ops.apply_start_heal(bigint, bigint, timestamptz, bigint, integer)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.fn_request_marker_push(bigint, text)', 'EXECUTE') then
    raise exception 'V1 a caller cannot reach its function';
  end if;
  if pg_get_functiondef('public.fn_request_marker_push(bigint,text)'::regprocedure) !~ 'timeout_milliseconds := 30000' then
    raise exception 'V1 fn_request_marker_push has no 30 s timeout'; end if;

  -- V2. Switch ships OFF; the health check is registered in both views.
  if public.fn_start_heal_enabled() then raise exception 'V2 healing is on at install'; end if;
  if not exists (select 1 from ops.v_health_status where check_name = 'start-flags-health') then
    raise exception 'V2 start-flags-health is not in ops.v_health_status'; end if;
  if not exists (select 1 from ops.v_health_status where check_name = 'jobber-sync-health') then
    raise exception 'V2 jobber-sync-health disappeared from ops.v_health_status'; end if;

  -- V3. The whole path on live rows, rolled back. Jobber pushes suppressed; healing switched on inside.
  begin
    perform set_config('app.suppress_jobber_push', 'on', true);
    perform set_config('app.suppress_marker_push', 'on', true);
    delete from ops.start_recheck_queue;
    update ops.start_heal_kick set requested_at = now();   -- the probe must never post to heal-day-starts

    -- a) the push stamp. Under app.suppress_marker_push a minute change is NOT stamped (the retry must not
    --    send it later). Without it (the push trigger disabled so nothing is even queued): a bookkeeping
    --    write keeps the stamp, a minute change sets it, a caller cannot forge it.
    update ops.calendar_day_markers set minutes = minutes + 1 where id = 121;
    select push_changed_at into p_stamp_suppressed from ops.calendar_day_markers where id = 121;
    update ops.calendar_day_markers set minutes = minutes - 1 where id = 121;
    alter table ops.calendar_day_markers disable trigger trg_push_marker_to_jobber;
    perform set_config('app.suppress_marker_push', 'off', true);
    update ops.calendar_day_markers set eta_computed_at = eta_computed_at where id = 121;
    select push_changed_at into p_stamp_null from ops.calendar_day_markers where id = 121;
    update ops.calendar_day_markers set minutes = minutes + 1 where id = 121;
    select push_changed_at is not null into p_stamp_set from ops.calendar_day_markers where id = 121;
    update ops.calendar_day_markers set push_changed_at = '2000-01-01' where id = 121;
    select push_changed_at > '2001-01-01' into p_stamp_forged from ops.calendar_day_markers where id = 121;
    update ops.calendar_day_markers set minutes = minutes - 1 where id = 121;
    perform set_config('app.suppress_marker_push', 'on', true);
    alter table ops.calendar_day_markers enable trigger trg_push_marker_to_jobber;

    -- b) the pre-check, one gesture at a time, against the committed state
    select count(*) into p_pre_move from ops.preview_start_impact('[{"visit_id":5994,"visit_date":"2026-09-26"}]');
    select count(*) into p_pre_same_day from ops.preview_start_impact(
      jsonb_build_array(jsonb_build_object('visit_id', 5994, 'start_at', v_5994_start + interval '1 hour',
                                           'end_at', v_5994_start + interval '90 minutes')));
    select count(*) into p_pre_anytime from ops.preview_start_impact('[{"visit_id":5994,"start_at":null,"end_at":null}]');
    select count(*) into p_pre_truck from ops.preview_start_impact('[{"visit_id":5994,"vehicle_id":2}]');
    select count(*) into p_pre_notruck from ops.preview_start_impact('[{"visit_id":5994,"vehicle_id":null}]');
    select count(*) into p_pre_delete from ops.preview_start_impact('[{"visit_id":5994,"deleted":true}]');
    select count(*) into p_pre_complete from ops.preview_start_impact('[{"visit_id":5994,"visit_status":"completed"}]');
    select count(*) into p_pre_noop from ops.preview_start_impact('[{"visit_id":5994}]');
    select count(*) into p_pre_start_move from ops.preview_start_impact(
      jsonb_build_array(jsonb_build_object('visit_id', 5994, 'start_at', v_5994_start + interval '1 day')));
    select leaving::text into p_pre_leaving from ops.preview_start_impact('[{"visit_id":5994,"deleted":true}]');
    begin
      perform ops.preview_start_impact('{"visit_id":5994}');
      p_pre_bad := 'accepted';
    exception when sqlstate '22023' then p_pre_bad := 'refused';
    end;

    -- c) healing OFF: the last timed visit leaves, the Start turns red and STAYS (phase-1 behaviour)
    update public.visits set deleted_at = now() where id = 5994;
    perform ops.refresh_start_flags();
    select not exists (select 1 from ops.calendar_day_markers where id = 121),
           (select stale_reason from ops.calendar_day_markers where id = 121)
      into p_off_removed, p_off_flag;
    update public.visits set deleted_at = null where id = 5994;
    perform ops.refresh_start_flags();

    update public.app_config set value = 'true' where key = 'start_heal_enabled';

    -- d) driver changed -> the judge gives the Start the first visit's driver
    perform set_config('app.start_judge_write', 'on', true);          -- plant the old driver without a verdict
    update ops.calendar_day_markers set employee_id = 40 where id = 121;
    perform set_config('app.start_judge_write', 'off', true);
    perform ops.fn_judge_starts(array[v_fri]);
    select employee_id, stale_reason into p_drv_emp, p_drv_flag from ops.calendar_day_markers where id = 121;
    select count(*) into p_drv_log from public.sync_log
     where sync_source = 'start-flags-heal' and details->>'action' = 'driver_updated'
       and (details->>'marker_id')::bigint = 121 and started_at >= now();

    -- d2) a hand-typed Start (no ETA) made for no particular visit: 'driver changed' is left for a person
    perform set_config('app.start_judge_write', 'on', true);
    update ops.calendar_day_markers set eta_minutes = null, source_visit_id = null, employee_id = 40 where id = 121;
    perform set_config('app.start_judge_write', 'off', true);
    perform ops.fn_judge_starts(array[v_fri]);
    select employee_id, stale_reason into p_hand_emp, p_hand_flag from ops.calendar_day_markers where id = 121;
    update ops.calendar_day_markers set eta_minutes = 34, source_visit_id = 5994, employee_id = 1 where id = 121;

    -- e) the first visit moves 30 minutes -> candidate; a refusal backs off; a stale snapshot is refused;
    --    the right ETA heals it to (6:30 + 0:30) - 34 - 30 = 356
    update public.visits set start_at = start_at + interval '30 minutes', end_at = end_at + interval '30 minutes'
     where id = 5994;
    perform ops.refresh_start_flags();
    select count(*), max(c.first_visit_id) into p_cand_n, p_cand_fv from ops.start_heal_candidates() c where c.marker_id = 121;
    select ops.apply_start_heal(121, 5994, v_5994_start + interval '30 minutes', 1, null)->>'outcome' into p_eta_unknown;
    select count(*) into p_cand_after_refusal from ops.start_heal_candidates() c where c.marker_id = 121;
    select ops.apply_start_heal(121, 5994, v_5994_start, 1, 34)->>'outcome' into p_changed;
    select ops.apply_start_heal(121, 5994, v_5994_start + interval '30 minutes', 1, 34)->>'outcome' into p_healed;
    select minutes, stale_reason, employee_id into p_healed_min, p_healed_flag, p_healed_emp
      from ops.calendar_day_markers where id = 121;

    -- f) the only timed visit becomes Anytime (Anytime is not enough) -> the Start is removed
    update public.visits set start_at = null, end_at = null where id = 5994;
    perform ops.refresh_start_flags();
    select not exists (select 1 from ops.calendar_day_markers where id = 121) into p_rm_gone;
    select count(*) into p_rm_log from public.sync_log
     where sync_source = 'start-flags-heal' and details->>'action' = 'removed'
       and (details->>'marker_id')::bigint = 121 and started_at >= now();

    -- g) a Start that is flagged when its minute passes is logged as an error and loses the flag
    insert into ops.calendar_day_markers (marker_date, marker_type, minutes, vehicle_id, employee_id)
    values (v_today, 'start', 1, 2, 1)
    returning id into v_g_id;
    perform set_config('app.start_judge_write', 'on', true);
    update ops.calendar_day_markers
       set stale_reason = 'first visit changed', stale_since = now(), eta_minutes = 34, source_visit_id = 5994
     where id = v_g_id;
    perform set_config('app.start_judge_write', 'off', true);
    select ops.apply_start_heal(v_g_id, 5994, v_5994_start, 1, 34)->>'outcome' into p_frozen_apply;
    perform ops.refresh_start_flags();
    select count(*) into p_froze_log from public.sync_log
     where sync_source = 'start-flags-judge' and details->>'action' = 'froze_while_stale'
       and (details->>'marker_id')::bigint = v_g_id and started_at >= now();
    select stale_reason into p_froze_flag from ops.calendar_day_markers where id = v_g_id;

    -- h) the retry sweep: an orphan link is re-deleted once, not twice in a row; an edit is re-sent
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id, source_name,
                                           match_method, synced_at)
    values ('calendar_day_marker', 999999999, 'jobber',
            'probe-task-gid', 'Day Start (probe)', 'calendar_push', now() - interval '20 minutes')
    returning id into v_orphan_link;
    select ops.retry_marker_pushes() into p_retry_first;
    select ops.retry_marker_pushes() into p_retry_again;
    insert into ops.calendar_day_markers (marker_date, marker_type, minutes, vehicle_id, employee_id)
    values ('2026-12-31', 'end', 900, 2, 1);
    alter table ops.calendar_day_markers disable trigger trg_ab_marker_push_stamp;
    update ops.calendar_day_markers set push_changed_at = now() - interval '5 minutes'
     where marker_date = '2026-12-31' and marker_type = 'end' and vehicle_id = 2;
    alter table ops.calendar_day_markers enable trigger trg_ab_marker_push_stamp;
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id, source_name,
                                           match_method, synced_at)
    select 'calendar_day_marker', m.id, 'jobber',
           'probe-task-gid-2', 'Day End (probe)', 'calendar_push', now() - interval '10 minutes'
      from ops.calendar_day_markers m where m.marker_date = '2026-12-31' and m.marker_type = 'end' and m.vehicle_id = 2;
    select ops.retry_marker_pushes() into p_retry_edit;
    select count(*) into p_retry_ledger from ops.marker_push_retries;
    alter table ops.calendar_day_markers disable trigger trg_ab_marker_push_stamp;
    update ops.calendar_day_markers set push_changed_at = now() - interval '5 minutes' where id = v_g_id;
    alter table ops.calendar_day_markers enable trigger trg_ab_marker_push_stamp;
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id, source_name,
                                           match_method, synced_at)
    values ('calendar_day_marker', v_g_id, 'jobber', 'probe-task-gid-3', 'Day Start (probe)', 'calendar_push',
            now() - interval '10 minutes');
    select ops.retry_marker_pushes() into p_retry_passed;       -- orphan and edit are spaced; today's has begun
    update ops.marker_push_retries set last_attempt_at = now() - interval '5 minutes' where kind = 'delete';

    -- i) the health check sees the orphan link and the froze-while-stale error, keys stay unique,
    --    and its items reach ops.v_health_items
    select public.log_start_flags_health() into p_h_n;
    select count(*), string_agg(item_key, ',' order by item_key) into p_h_items, p_h_kinds
      from ops.v_health_items where check_name = 'start-flags-health';
    select count(*) into p_h_dup from (select check_name, item_key from ops.v_health_items
                                        group by 1, 2 having count(*) > 1) d;

    -- l) 01:30 EDT on Sun 2026-11-01 (the hour that repeats): 90 - 34 - 30 = 26 is fresh on insert
    update public.visits set start_at = '2026-11-01 05:30:00+00', end_at = '2026-11-01 06:00:00+00' where id = 5994;
    insert into ops.calendar_day_markers (marker_date, marker_type, minutes, vehicle_id, employee_id,
                                          source_visit_id, eta_minutes)
    values ('2026-11-01', 'start', 26, 1, 1, 5994, 34);
    select stale_reason into p_dst_flag from ops.calendar_day_markers
     where marker_date = '2026-11-01' and vehicle_id = 1 and marker_type = 'start';

    raise exception 'ROLLBACK_PROBE';
  exception when raise_exception then
    if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;

  if p_stamp_suppressed is not null then raise exception 'V3a a suppressed minute change was stamped'; end if;
  if p_stamp_null is not null then raise exception 'V3a a bookkeeping write set push_changed_at'; end if;
  if not p_stamp_set then raise exception 'V3a a minute change did not set push_changed_at'; end if;
  if not p_stamp_forged then raise exception 'V3a a caller forged push_changed_at'; end if;

  if p_pre_move <> 1 or p_pre_anytime <> 1 or p_pre_truck <> 1 or p_pre_notruck <> 1
     or p_pre_delete <> 1 or p_pre_complete <> 1 or p_pre_start_move <> 1 then
    raise exception 'V3b a leaving gesture was not reported (move % anytime % truck % notruck % delete % complete % start_move %)',
      p_pre_move, p_pre_anytime, p_pre_truck, p_pre_notruck, p_pre_delete, p_pre_complete, p_pre_start_move;
  end if;
  if p_pre_same_day <> 0 or p_pre_noop <> 0 then
    raise exception 'V3b a gesture that keeps a timed visit was reported (same_day % noop %)', p_pre_same_day, p_pre_noop;
  end if;
  if p_pre_leaving !~ '031-KRU' then raise exception 'V3b the leaving visit is not named: %', p_pre_leaving; end if;
  if p_pre_bad <> 'refused' then raise exception 'V3b a malformed list was accepted'; end if;

  if p_off_removed or p_off_flag is distinct from 'no timed visit' then
    raise exception 'V3c with healing off the Start was removed (%) or not flagged red (%)', p_off_removed, p_off_flag; end if;

  if p_drv_emp is distinct from 1 or p_drv_flag is not null or p_drv_log <> 1 then
    raise exception 'V3d driver heal: employee % flag % log %', p_drv_emp, p_drv_flag, p_drv_log; end if;

  if p_hand_emp is distinct from 40 or p_hand_flag is distinct from 'driver changed' then
    raise exception 'V3d2 a hand-typed Start was given another driver (% %)', p_hand_emp, p_hand_flag; end if;

  if p_cand_n <> 1 or p_cand_fv is distinct from 5994 then raise exception 'V3e marker 121 is not a candidate (%)', p_cand_n; end if;
  if p_eta_unknown <> 'eta_unknown' then raise exception 'V3e expected eta_unknown, got %', p_eta_unknown; end if;
  if p_cand_after_refusal <> 0 then raise exception 'V3e a refused Start was offered again at once'; end if;
  if p_changed <> 'changed' then raise exception 'V3e a stale snapshot was not refused: %', p_changed; end if;
  if p_healed <> 'healed' or p_healed_min <> 356 or p_healed_flag is not null or p_healed_emp <> 1 then
    raise exception 'V3e recompute: % minutes % flag % employee %', p_healed, p_healed_min, p_healed_flag, p_healed_emp; end if;

  if not p_rm_gone or p_rm_log <> 1 then raise exception 'V3f removal: gone % log %', p_rm_gone, p_rm_log; end if;

  if p_frozen_apply is distinct from 'frozen' then
    raise exception 'V3g a Start that has begun was recomputed (%)', p_frozen_apply; end if;
  if p_froze_log <> 1 or p_froze_flag is not null then
    raise exception 'V3g froze while stale: log % flag %', p_froze_log, p_froze_flag; end if;

  if p_retry_first < 1 or p_retry_again <> 0 then
    raise exception 'V3h orphan link retry: first % again %', p_retry_first, p_retry_again; end if;
  if p_retry_edit < 1 then raise exception 'V3h the stale edit was not re-sent'; end if;
  if p_retry_ledger < 2 then raise exception 'V3h the retry ledger has % rows', p_retry_ledger; end if;
  if p_retry_passed <> 0 then raise exception 'V3h the retry re-sent % push(es), a begun marker among them', p_retry_passed; end if;
  if p_dst_flag is not null then raise exception 'V3l the November clock change flags a correct Start (%)', p_dst_flag; end if;

  if p_h_n < 2 or p_h_items <> p_h_n then
    raise exception 'V3i health check: % items written, % in v_health_items (%)', p_h_n, p_h_items, p_h_kinds; end if;
  if p_h_kinds !~ ('marker_task_orphan:' || v_orphan_link) or p_h_kinds !~ ('start_began_out_of_date:' || v_g_id) then
    raise exception 'V3i expected the orphan link and the heal error, got %', p_h_kinds; end if;
  if p_h_dup <> 0 then raise exception 'V3i duplicate item keys in ops.v_health_items'; end if;

  -- V4. The probe left nothing behind.
  if not exists (select 1 from ops.calendar_day_markers where id = 121 and minutes = v_121.minutes
                   and employee_id = v_121.employee_id and stale_reason is null) then
    raise exception 'V4 marker 121 changed'; end if;
  if (select start_at from public.visits where id = 5994) <> v_5994_start
     or (select deleted_at from public.visits where id = 5994) is not null then
    raise exception 'V4 visit 5994 changed'; end if;
  if (select value from public.app_config where key = 'start_heal_enabled') <> 'false' then
    raise exception 'V4 healing was left on'; end if;
  if exists (select 1 from ops.start_heal_attempts) or exists (select 1 from ops.marker_push_retries)
     or (select requested_at from ops.start_heal_kick) <> '-infinity' then
    raise exception 'V4 bookkeeping rows survived the rollback'; end if;
  if exists (select 1 from public.entity_source_links where source_id like 'probe-task-gid%') then
    raise exception 'V4 a probe link survived'; end if;
  if exists (select 1 from pg_trigger where tgname = 'trg_ab_marker_push_stamp' and tgenabled <> 'O') then
    raise exception 'V4 the push stamp trigger was left disabled'; end if;
end
$verify$;

commit;
