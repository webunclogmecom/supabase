-- =====================================================================================================
-- 2026-09-24_2100  Jobber-first day markers: one writer per marker, the commit step, the healer through it
-- =====================================================================================================
-- Fred, 2026-09-24, on the out-of-order Task push: "I was thinking that we do like with the visits, that it
-- first confirms the data was changed in jobber being reflected in the app/db".
-- Design: Building Apps/Visit Calendar/docs/specs/2026-09-24-jobber-first-day-markers-design.md
--
-- Until now a marker was written to ops.calendar_day_markers first and trg_push_marker_to_jobber then asked
-- jobber-push-task (pg_net, fire-and-forget) to copy it to Jobber. After this migration and the edge fns
-- deployed with it, a person's change (edge fn save-day-marker) and the Start healer's (heal-day-starts) are
-- pushed to Jobber, read back, and only then committed. The trigger push and start-push-retry stay, as the
-- net for anything that still writes the table in SQL.
--
-- ONE WRITER PER MARKER. Every writer of a marker's Jobber Task (save-day-marker, heal-day-starts,
-- jobber-push-task) first CLAIMS the marker (ops.claim_day_marker), and the commit that follows deletes the
-- claim in its own transaction. So no two Jobber writes to one Task can interleave, which is what left
-- Jobber a version behind (the adversarial review showed that a reconcile-after-commit could not close it).
-- A claim that is never committed (a crash, a Jobber call with no answer, a failed repair) is left behind,
-- EXPIRED, and that row is the "Jobber may differ" mark: start-push-retry repairs it within minutes and the
-- daily health check reports it after 20 minutes.
--
-- PART 1  fn_marker_push_stamp: a write made under app.marker_push_verified is stamped (its push is done).
-- PART 2  ops.apply_start_heal gains p_dry_run: plan the recompute without writing.
-- PART 3  ops.marker_jobber_claims + ops.claim_day_marker / ops.release_day_marker.
-- PART 4  ops.save_day_marker: the commit step (service_role only).
-- PART 5  ops.note_start_heal_attempt: record a heal that Jobber refused, so it backs off.
-- PART 6  ops.fn_judge_starts only flags; removal and the driver swap move to heal-day-starts.
-- PART 7  ops.start_heal_candidates returns a kind (remove, driver, recompute).
-- PART 8  public.fn_request_start_heal: the kick gate goes from 60 to 15 seconds.
-- PART 9  ops.retry_marker_pushes repairs a claim that was left behind.
-- PART 10 public.log_start_flags_health: jobber_failed, "not run since" for every kind, left-behind claims.
-- PART 11 grants.
-- VERIFY  rolled back inside the transaction (fixtures on 2031-01-14, fake Task ids, no Jobber call).
--
-- Every changed body is spliced from pg_get_functiondef (the live text), each anchor asserted to occur
-- exactly once, and the live md5 pinned first (Supabase CLAUDE.md: copy, never retype).
-- Rule 8: one new table, ops.marker_jobber_claims, bookkeeping: opt-out (a claim lives for seconds; the
-- markers themselves are audit opt-out, dispatch state).
-- The app's direct write grants are NOT revoked here: that is a later migration, after the Calendar calls
-- save-day-marker and its live bundle shows no direct marker write.
--
-- ROLLBACK (in this order): redeploy the previous heal-day-starts and jobber-push-task, then re-apply
-- PARTS 4-8 of 2026-09-24_0845 (fn_judge_starts, start_heal_candidates, apply_start_heal, the kick,
-- retry_marker_pushes) and PART 10 (log_start_flags_health), then drop the functions and the table added
-- here, put the marker_push_retries kind check back to ('delete','edit'), and fn_marker_push_stamp back to
-- its 0845 body.
-- =====================================================================================================

begin;

-- ---------------------------------------------------------------------------------------------------
-- PART 0. Pin the live bodies this migration splices
-- ---------------------------------------------------------------------------------------------------
do $$
begin
  if md5(pg_get_functiondef('ops.fn_marker_push_stamp()'::regprocedure)) <> '5093f6cfbea7b3682cb76c9011bbbee3'
  then raise exception 'fn_marker_push_stamp changed since this migration was written'; end if;
  if md5(pg_get_functiondef('ops.fn_judge_starts(date[])'::regprocedure)) <> '6fc899fa1c2efd6f277b2399c7517173'
  then raise exception 'fn_judge_starts changed since this migration was written'; end if;
  if md5(pg_get_functiondef('ops.apply_start_heal(bigint,bigint,timestamptz,bigint,integer)'::regprocedure)) <> '9da10df9b22d3fa8725046009b6719ce'
  then raise exception 'apply_start_heal changed since this migration was written'; end if;
  if md5(pg_get_functiondef('public.fn_request_start_heal()'::regprocedure)) <> 'f74796ed0002fb45e0199c9ab6b67676'
  then raise exception 'fn_request_start_heal changed since this migration was written'; end if;
  if md5(pg_get_functiondef('ops.retry_marker_pushes()'::regprocedure)) <> '258f3f56c7710efc31f958c83f5e0697'
  then raise exception 'retry_marker_pushes changed since this migration was written'; end if;
  if md5(pg_get_functiondef('public.log_start_flags_health()'::regprocedure)) <> 'a9429db5432bb2d0b95e3544894203b9'
  then raise exception 'log_start_flags_health changed since this migration was written'; end if;
end $$;

-- One helper for the splices below: replace ONE occurrence, refuse anything else.
create function pg_temp.splice_once(p_def text, p_from text, p_to text, p_what text)
returns text language plpgsql as $$
declare v_n int;
begin
  v_n := (length(p_def) - length(replace(p_def, p_from, ''))) / length(p_from);
  if v_n <> 1 then raise exception '%: expected 1 anchor, found %', p_what, v_n; end if;
  return replace(p_def, p_from, p_to);
end $$;

-- ---------------------------------------------------------------------------------------------------
-- PART 1. The stamp: a verified push is stamped like any Jobber-visible change
-- ---------------------------------------------------------------------------------------------------
-- ops.save_day_marker writes under app.suppress_marker_push (so the trigger does not push a second time)
-- AND app.marker_push_verified (the Task was already pushed and read back). Such a write gets the normal
-- stamp, and the RPC sets the link's synced_at to the same now(), so start-push-retry sees nothing to do.
do $$
declare v_def text := pg_get_functiondef('ops.fn_marker_push_stamp()'::regprocedure);
begin
  v_def := pg_temp.splice_once(v_def,
    'if coalesce(current_setting(''app.suppress_marker_push'', true), ''off'') = ''on'' then',
    'if coalesce(current_setting(''app.suppress_marker_push'', true), ''off'') = ''on''' || chr(10) ||
    '     and coalesce(current_setting(''app.marker_push_verified'', true), ''off'') <> ''on'' then   -- 2026-09-24_2100',
    'fn_marker_push_stamp');
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- PART 2. apply_start_heal(..., p_dry_run): the recompute's plan, without the write
-- ---------------------------------------------------------------------------------------------------
-- heal-day-starts asks for the plan (the minute, from SQL, as 13p), pushes it to Jobber, then commits
-- through ops.save_day_marker, which re-runs this dry run under the row lock and refuses if the plan moved.
-- A dry run returns outcome 'ready' where a real run would write; refusals are recorded as before.
-- The 5-argument form is dropped: a named call without p_dry_run (the heal-day-starts deployed before this
-- migration) resolves to the new one with p_dry_run false, i.e. exactly the old behaviour.
do $$
declare v_def text := pg_get_functiondef('ops.apply_start_heal(bigint,bigint,timestamptz,bigint,integer)'::regprocedure);
begin
  v_def := pg_temp.splice_once(v_def, 'p_eta_minutes integer)',
    'p_eta_minutes integer, p_dry_run boolean DEFAULT false)', 'apply_start_heal header');
  v_def := pg_temp.splice_once(v_def,
    '      -- The BEFORE trigger judges the row as written. If the verdict still is not NULL, undo the write',
    '      if p_dry_run then                -- 2026-09-24_2100: the plan only' || chr(10) ||
    '        v_outcome := ''ready'';' || chr(10) ||
    '      else' || chr(10) ||
    '      -- The BEFORE trigger judges the row as written. If the verdict still is not NULL, undo the write',
    'apply_start_heal dry run');
  v_def := pg_temp.splice_once(v_def,
    '        v_outcome := ''unresolvable'';' || chr(10) || '      end;' || chr(10),
    '        v_outcome := ''unresolvable'';' || chr(10) || '      end;' || chr(10) ||
    '      end if;                          -- 2026-09-24_2100: end of the dry-run branch' || chr(10),
    'apply_start_heal dry run end');
  v_def := pg_temp.splice_once(v_def,
    'if v_outcome not in (''gone'', ''changed'', ''off'', ''not_derived'', ''not_flagged'', ''frozen'') then',
    'if v_outcome not in (''gone'', ''changed'', ''off'', ''not_derived'', ''not_flagged'', ''frozen'', ''ready'') then',
    'apply_start_heal attempts');
  drop function ops.apply_start_heal(bigint, bigint, timestamptz, bigint, integer);
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- PART 3. The claim: one writer per marker
-- ---------------------------------------------------------------------------------------------------
create table ops.marker_jobber_claims (
  marker_id        bigint primary key,              -- no FK: the claim outlives a deleted marker until repaired
  token            uuid not null,
  holder           text not null,                   -- 'save-day-marker', 'heal-day-starts', 'jobber-push-task'
  until            timestamptz not null,            -- after this another writer may take the marker over
  first_claimed_at timestamptz not null default now()   -- kept across take-overs: how long Jobber has been in doubt
);
comment on table ops.marker_jobber_claims is
  'One row per day marker whose Jobber Task is being changed (2026-09-24_2100). ops.claim_day_marker writes it before the first Jobber call; ops.save_day_marker deletes it in the same transaction as the commit. A row whose until has passed is a change that was interrupted: Jobber may differ from the row. ops.retry_marker_pushes repairs it (jobber-push-task takes it over and reconciles) and public.log_start_flags_health reports it after 20 minutes. Bookkeeping; rule 8 opt-out.';
revoke all on ops.marker_jobber_claims from public, anon, authenticated, service_role, yannick_readonly;

-- Claims every id or none. ZZ004 when one is held by another writer and has not expired. An expired claim
-- is taken over (new token, new holder), keeping first_claimed_at.
create function ops.claim_day_marker(p_marker_ids bigint[], p_holder text, p_seconds integer default 120)
returns uuid
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare
  v_token uuid := gen_random_uuid();
  v_id    bigint;
  v_hit   integer;
begin
  if p_marker_ids is null or cardinality(p_marker_ids) = 0 or coalesce(p_holder, '') = ''
     or p_seconds is null or p_seconds < 10 or p_seconds > 600 then
    raise exception using errcode = '22023', message = 'Bad claim.', detail = 'blocker=bad_claim in ops.claim_day_marker';
  end if;
  foreach v_id in array (select array_agg(distinct x order by x) from unnest(p_marker_ids) x) loop
    insert into ops.marker_jobber_claims as c (marker_id, token, holder, until)
    values (v_id, v_token, p_holder, now() + make_interval(secs => p_seconds))
    on conflict (marker_id) do update
       set token = excluded.token, holder = excluded.holder, until = excluded.until
     where c.until < now();
    get diagnostics v_hit = row_count;
    if v_hit = 0 then
      raise exception using errcode = 'ZZ004',
        message = 'This marker is still being saved. Wait a moment and try again.',
        detail = format('blocker=busy (marker %s) in ops.claim_day_marker', v_id);
    end if;
  end loop;
  return v_token;
end
$$;

-- Gives the claim back without a commit. p_dirty = true when a Jobber write may have landed: the row stays,
-- expired, for start-push-retry to repair. false: nothing was sent to Jobber, the row goes.
create function ops.release_day_marker(p_token uuid, p_dirty boolean)
returns integer
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare v_n integer;
begin
  if p_dirty then
    update ops.marker_jobber_claims set until = least(until, now()) where token = p_token;
  else
    delete from ops.marker_jobber_claims where token = p_token;
  end if;
  get diagnostics v_n = row_count;
  return v_n;
end
$$;

-- ---------------------------------------------------------------------------------------------------
-- PART 4. ops.save_day_marker: the commit step of the Jobber-first saga
-- ---------------------------------------------------------------------------------------------------
-- The body. Callable only through ops.save_day_marker below, which sets the push suppression around it.
create function ops.save_day_marker_step(p_op text, p_marker_id bigint, p_token uuid, p_expect jsonb,
                                         p_values jsonb, p_task jsonb, p_heal jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare
  v       jsonb := coalesce(p_values, '{}'::jsonb);
  e       jsonb := coalesce(p_expect, '{}'::jsonb);
  v_kind  text  := p_heal->>'kind';
  v_keys  text[];
  v_bad   text;
  v_gid   text;
  v_plan  jsonb;
  m       ops.calendar_day_markers%rowtype;
  v_after ops.calendar_day_markers%rowtype;
  f       record;
begin
  -- ---- the call itself -------------------------------------------------------------------------------
  if p_op is null or p_op not in ('create', 'update', 'delete', 'relink') then
    raise exception using errcode = '22023', message = 'Unknown marker operation.',
      detail = format('blocker=bad_op (%s) in ops.save_day_marker', p_op);
  end if;
  if v_kind is not null and not ((v_kind = 'remove' and p_op = 'delete')
                                 or (v_kind in ('driver', 'recompute') and p_op = 'update')) then
    raise exception using errcode = '22023', message = 'Unknown automatic fix.',
      detail = format('blocker=bad_heal (%s for %s) in ops.save_day_marker', v_kind, p_op);
  end if;
  if jsonb_typeof(v) <> 'object' or jsonb_typeof(e) <> 'object' then
    raise exception using errcode = '22023', message = 'The marker values must be an object.',
      detail = 'blocker=bad_shape in ops.save_day_marker';
  end if;
  -- What a caller may write. Never the flags (the judge's), push_changed_at (the stamp's), the ids, or
  -- dump_visit_id (the Calendar sets it directly after create_dump_visit). A marker's type, truck and dump
  -- site never change after it is placed: a move of a dump marker is a delete and a new place.
  v_keys := case p_op
    when 'create' then array['marker_type', 'marker_date', 'minutes', 'dump_site', 'vehicle_id', 'employee_id',
                             'source_visit_id', 'eta_minutes', 'eta_computed_at']
    when 'update' then array['marker_date', 'minutes', 'employee_id', 'source_visit_id', 'eta_minutes', 'eta_computed_at']
    else array[]::text[] end;
  select string_agg(k, ', ' order by k) into v_bad from jsonb_object_keys(v) k where k <> all (v_keys);
  if v_bad is not null then
    raise exception using errcode = '22023', message = format('These marker fields cannot be written here: %s.', v_bad),
      detail = 'blocker=bad_field in ops.save_day_marker';
  end if;
  if v_kind = 'driver' and exists (select 1 from jsonb_object_keys(v) k where k <> 'employee_id') then
    raise exception using errcode = '22023', message = 'A driver fix may only change the driver.',
      detail = 'blocker=bad_heal_patch in ops.save_day_marker';
  end if;
  if p_task is not null and (jsonb_typeof(p_task) <> 'object'
                             or coalesce(p_task->>'gid', '') = '' or coalesce(p_task->>'title', '') = '') then
    raise exception using errcode = '22023', message = 'The Jobber Task must have an id and a title.',
      detail = 'blocker=bad_task in ops.save_day_marker';
  end if;

  -- ---- create -----------------------------------------------------------------------------------------
  if p_op = 'create' then
    insert into ops.calendar_day_markers (marker_type, marker_date, minutes, dump_site, vehicle_id, employee_id,
                                          source_visit_id, eta_minutes, eta_computed_at)
    values (v->>'marker_type', (v->>'marker_date')::date, (v->>'minutes')::smallint, v->>'dump_site',
            (v->>'vehicle_id')::bigint, (v->>'employee_id')::bigint, (v->>'source_visit_id')::bigint,
            (v->>'eta_minutes')::integer, (v->>'eta_computed_at')::timestamptz)
    returning * into v_after;
    m := v_after;
  else
    -- ---- the claim: only the writer holding it may commit (an existing marker has no other writer) ----
    if p_token is null or not exists (select 1 from ops.marker_jobber_claims c
                                       where c.marker_id = p_marker_id and c.token = p_token) then
      raise exception using errcode = 'ZZ005', message = 'This marker was taken over by another save.',
        detail = 'blocker=claim_lost in ops.save_day_marker';
    end if;
    -- ---- the row, locked, and the compare-and-swap ------------------------------------------------------
    select * into m from ops.calendar_day_markers where id = p_marker_id for update;
    if not found then
      if p_op = 'delete' then
        delete from ops.marker_jobber_claims where marker_id = p_marker_id and token = p_token;
        return jsonb_build_object('outcome', 'gone', 'marker_id', p_marker_id);
      end if;
      raise exception using errcode = 'P0002', message = 'This marker was already removed.',
        detail = 'blocker=gone in ops.save_day_marker';
    end if;
    select l.source_id into v_gid from public.entity_source_links l
     where l.entity_type = 'calendar_day_marker' and l.source_system = 'jobber' and l.entity_id = m.id;
    -- Each key present in p_expect must still hold: what the caller read before it pushed to Jobber. The
    -- claim keeps other savers out; this catches a direct SQL write in between (a script, an old Calendar
    -- tab until the revoke), and the caller then puts Jobber back to the committed row.
    if    (e ? 'marker_date' and m.marker_date is distinct from (e->>'marker_date')::date)
       or (e ? 'marker_type' and m.marker_type is distinct from e->>'marker_type')
       or (e ? 'minutes'     and m.minutes     is distinct from (e->>'minutes')::smallint)
       or (e ? 'vehicle_id'  and m.vehicle_id  is distinct from (e->>'vehicle_id')::bigint)
       or (e ? 'employee_id' and m.employee_id is distinct from (e->>'employee_id')::bigint)
       or (e ? 'dump_site'   and m.dump_site   is distinct from e->>'dump_site')
       or (e ? 'link_gid'    and v_gid         is distinct from e->>'link_gid') then
      raise exception using errcode = 'ZZ002',
        message = 'This marker was changed somewhere else while you were saving.',
        detail = 'blocker=changed_elsewhere in ops.save_day_marker';
    end if;

    -- ---- the healer: re-check the fix under the lock ------------------------------------------------
    if v_kind is not null then
      if not public.fn_start_heal_enabled() then
        return jsonb_build_object('outcome', 'off', 'marker_id', m.id);
      elsif m.marker_type <> 'start' or m.vehicle_id is null or m.employee_id is null then
        return jsonb_build_object('outcome', 'not_derived', 'marker_id', m.id);
      elsif public.fn_start_frozen(m.marker_date, m.minutes) is true then
        return jsonb_build_object('outcome', 'frozen', 'marker_id', m.id);
      end if;
      if v_kind = 'remove' then
        if public.fn_start_verdict(m.marker_date, m.vehicle_id, m.employee_id, m.source_visit_id, m.minutes,
                                   m.eta_minutes) is distinct from 'no timed visit' then
          return jsonb_build_object('outcome', 'changed', 'marker_id', m.id);
        end if;
      elsif v_kind = 'driver' then
        select * into f from public.fn_start_first_visit(m.marker_date, m.vehicle_id);
        if f.id is null or f.id is distinct from m.source_visit_id
           or f.id is distinct from (p_heal->>'first_visit_id')::bigint
           or f.driver_id is null or f.driver_id is distinct from (v->>'employee_id')::bigint then
          return jsonb_build_object('outcome', 'changed', 'marker_id', m.id);
        end if;
      else
        v_plan := ops.apply_start_heal(m.id, (p_heal->>'first_visit_id')::bigint,
                                       (p_heal->>'first_start_at')::timestamptz, (p_heal->>'driver_id')::bigint,
                                       (p_heal->>'eta_minutes')::integer, true);
        if v_plan->>'outcome' is distinct from 'ready' then return v_plan; end if;
        if (v_plan->>'to_minutes')::integer is distinct from (v->>'minutes')::integer
           or (v_plan->>'to_employee_id')::bigint is distinct from (v->>'employee_id')::bigint
           or (p_heal->>'first_visit_id')::bigint is distinct from (v->>'source_visit_id')::bigint
           or (p_heal->>'eta_minutes')::integer is distinct from (v->>'eta_minutes')::integer then
          return jsonb_build_object('outcome', 'changed', 'marker_id', m.id);
        end if;
      end if;
    end if;

    -- ---- delete -----------------------------------------------------------------------------------
    if p_op = 'delete' then
      delete from ops.calendar_day_markers where id = m.id;
      delete from public.entity_source_links
       where entity_type = 'calendar_day_marker' and source_system = 'jobber' and entity_id = m.id;
      delete from ops.marker_jobber_claims where marker_id = m.id and token = p_token;
      return jsonb_build_object('outcome', case when v_kind is null then 'deleted' else 'healed' end,
                                'marker', to_jsonb(m));
    end if;

    -- ---- update -------------------------------------------------------------------------------------
    if p_op = 'update' then
      begin
        update ops.calendar_day_markers
           set marker_date     = case when v ? 'marker_date'     then (v->>'marker_date')::date            else marker_date end,
               minutes         = case when v ? 'minutes'         then (v->>'minutes')::smallint            else minutes end,
               employee_id     = case when v ? 'employee_id'     then (v->>'employee_id')::bigint          else employee_id end,
               source_visit_id = case when v ? 'source_visit_id' then (v->>'source_visit_id')::bigint      else source_visit_id end,
               eta_minutes     = case when v ? 'eta_minutes'     then (v->>'eta_minutes')::integer         else eta_minutes end,
               eta_computed_at = case when v ? 'eta_computed_at' then (v->>'eta_computed_at')::timestamptz else eta_computed_at end
         where id = m.id
        returning * into v_after;
        -- The trigger judges the row as written: a fix that does not leave it fresh is undone (the block
        -- is a savepoint) and recorded, so the Start backs off instead of being tried on every kick.
        if v_kind is not null and v_after.stale_reason is not null then
          raise exception using message = 'START_HEAL_UNRESOLVABLE';
        end if;
      exception when raise_exception then
        if sqlerrm <> 'START_HEAL_UNRESOLVABLE' then raise; end if;
        insert into ops.start_heal_attempts (marker_id, first_visit_id, first_start_at, outcome, attempted_at)
        values (m.id, (p_heal->>'first_visit_id')::bigint, (p_heal->>'first_start_at')::timestamptz,
                'unresolvable', now())
        on conflict (marker_id) do update
           set first_visit_id = excluded.first_visit_id, first_start_at = excluded.first_start_at,
               outcome = excluded.outcome, attempted_at = excluded.attempted_at;
        return jsonb_build_object('outcome', 'unresolvable', 'marker_id', m.id);
      end;
      -- 🛑 A change Jobber can see is never committed without the Task that shows it. Under the
      -- suppression it would not be pushed, and unstamped it would never be retried: a silent divergence.
      if p_task is null and (v_after.marker_date is distinct from m.marker_date
                             or v_after.minutes is distinct from m.minutes
                             or v_after.employee_id is distinct from m.employee_id) then
        raise exception using errcode = 'ZZ003', message = 'A change Jobber can see needs its Jobber Task first.',
          detail = 'blocker=unpushed_change in ops.save_day_marker';
      end if;
    else
      v_after := m;                     -- relink: the row stays as it is
    end if;
    delete from ops.marker_jobber_claims where marker_id = m.id and token = p_token;
  end if;

  -- ---- the link, in the same transaction as the row -------------------------------------------------
  if p_task is not null then
    insert into public.entity_source_links (entity_type, entity_id, source_system, source_id, source_name,
                                            match_method, synced_at)
    values ('calendar_day_marker', v_after.id, 'jobber', p_task->>'gid', p_task->>'title', 'calendar_saga', now())
    on conflict (entity_type, entity_id, source_system) do update
       set source_id = excluded.source_id, source_name = excluded.source_name,
           match_method = excluded.match_method, synced_at = excluded.synced_at;
  elsif p_op = 'relink' then
    delete from public.entity_source_links
     where entity_type = 'calendar_day_marker' and source_system = 'jobber' and entity_id = v_after.id;
  end if;

  if v_kind is not null then
    insert into ops.start_heal_attempts (marker_id, first_visit_id, first_start_at, outcome, attempted_at)
    values (v_after.id, (p_heal->>'first_visit_id')::bigint, (p_heal->>'first_start_at')::timestamptz, 'healed', now())
    on conflict (marker_id) do update
       set first_visit_id = excluded.first_visit_id, first_start_at = excluded.first_start_at,
           outcome = excluded.outcome, attempted_at = excluded.attempted_at;
  end if;

  return jsonb_build_object('outcome', case when v_kind is not null then 'healed'
                                            when p_op = 'relink' then 'relinked' else 'saved' end,
                            'marker', to_jsonb(v_after),
                            'before', case when p_op = 'create' then null else to_jsonb(m) end);
end
$$;

-- The entry point. The trigger push is suppressed for this call only and a verified push is stamped; the
-- previous values are put back before it returns, so a SQL caller's later statements push as usual (a raise
-- undoes the settings with its subtransaction). A function SET clause cannot carry a custom setting here
-- (42501 on Supabase), hence the explicit save and restore.
create function ops.save_day_marker(p_op text, p_marker_id bigint, p_token uuid, p_expect jsonb,
                                    p_values jsonb, p_task jsonb, p_heal jsonb)
returns jsonb
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare
  v_s text := current_setting('app.suppress_marker_push', true);
  v_v text := current_setting('app.marker_push_verified', true);
  v_l text := current_setting('lock_timeout');
  r   jsonb;
begin
  perform set_config('app.suppress_marker_push', 'on', true);
  perform set_config('app.marker_push_verified', case when p_task is null then 'off' else 'on' end, true);
  perform set_config('lock_timeout', '3s', true);
  r := ops.save_day_marker_step(p_op, p_marker_id, p_token, p_expect, p_values, p_task, p_heal);
  perform set_config('app.suppress_marker_push', coalesce(v_s, ''), true);
  perform set_config('app.marker_push_verified', coalesce(v_v, ''), true);
  perform set_config('lock_timeout', v_l, true);
  return r;
end
$$;

comment on function ops.save_day_marker(text, bigint, uuid, jsonb, jsonb, jsonb, jsonb) is
  'The commit step of the Jobber-first marker saga (2026-09-24_2100): called by save-day-marker, heal-day-starts and jobber-push-task AFTER the Jobber Task was pushed and read back, holding the marker''s claim (ops.claim_day_marker; a create needs none). Row + entity_source_links link + the claim''s removal in one transaction, trigger push suppressed, push_changed_at stamped with the link''s synced_at. Refuses: ZZ005 claim lost, ZZ002 changed_elsewhere (p_expect), P0002 gone, ZZ003 an unpushed visible change, 22023 bad input, 23505 the slot is taken. Healer refusals are an outcome, not an error. service_role only.';

-- ---------------------------------------------------------------------------------------------------
-- PART 5. Record a heal Jobber refused, so the next kicks do not hit Jobber again at once
-- ---------------------------------------------------------------------------------------------------
create function ops.note_start_heal_attempt(p_marker_id bigint, p_first_visit_id bigint,
                                            p_first_start_at timestamptz, p_outcome text)
returns void
language sql security definer
set search_path = public, ops, pg_temp
as $$
  insert into ops.start_heal_attempts (marker_id, first_visit_id, first_start_at, outcome, attempted_at)
  select p_marker_id, p_first_visit_id, p_first_start_at, p_outcome, now()
   where p_outcome in ('jobber_failed')
  on conflict (marker_id) do update
     set first_visit_id = excluded.first_visit_id, first_start_at = excluded.first_start_at,
         outcome = excluded.outcome, attempted_at = excluded.attempted_at
$$;

-- ---------------------------------------------------------------------------------------------------
-- PART 6. The judge only flags
-- ---------------------------------------------------------------------------------------------------
do $$
declare
  v_def  text := pg_get_functiondef('ops.fn_judge_starts(date[])'::regprocedure);
  v_from text := '      -- PHASE 2: heal what needs no drive time. Only a Start whose Jobber link exists and is older than';
  v_to   text := '      if v_reason is distinct from r.stale_reason then';
  v_s    int;
  v_e    int;
begin
  -- the removed span runs from the first anchor up to (not including) the second; both must be unique
  perform pg_temp.splice_once(v_def, v_from, '', 'fn_judge_starts start');
  perform pg_temp.splice_once(v_def, v_to, '', 'fn_judge_starts end');
  v_s := position(v_from in v_def);
  v_e := position(v_to in v_def);
  if v_s = 0 or v_e <= v_s then raise exception 'fn_judge_starts: anchors out of order'; end if;
  v_def := substr(v_def, 1, v_s - 1) ||
    '      -- 2026-09-24_2100: removal and the driver swap moved to heal-day-starts, which changes the Jobber' || chr(10) ||
    '      -- Task first and commits through ops.save_day_marker. The judge only flags.' || chr(10) || chr(10) ||
    substr(v_def, v_e);
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- PART 7. The candidates, now of three kinds
-- ---------------------------------------------------------------------------------------------------
-- The output gains a leading `kind`; the heal-day-starts deployed before this migration reads by name and
-- passes every row to apply_start_heal, which answers 'not_flagged' for the two new kinds (harmless).
drop function ops.start_heal_candidates();
create function ops.start_heal_candidates()
returns table (kind text, marker_id bigint, marker_date date, vehicle_id bigint, employee_id bigint, minutes smallint,
               eta_minutes integer, first_visit_id bigint, first_start_at timestamptz,
               latitude numeric, longitude numeric, driver_id bigint, driver_name text, client_code text)
language sql stable security definer
set search_path = public, ops, pg_temp
as $$
  -- Truck Starts the healer can fix, not frozen, whose link is older than 10 s:
  --   remove     flagged 'no timed visit'; with a link, or never linked and older than 10 minutes (then
  --              there is no Task to delete).
  --   driver     flagged 'driver changed', and its first visit is still the one it was made for, with a driver.
  --   recompute  a derived Start flagged 'first visit changed'.
  -- A refused Start waits while its first visit (same id and start) is unchanged: 10 minutes for a missing
  -- driver or a Jobber refusal, 1 hour for a drive time that could not be computed, and until the first
  -- visit changes for a refusal that cannot improve. A marker another writer is changing is left for the
  -- next run. At most 10 per run.
  select case m.stale_reason when 'no timed visit' then 'remove' when 'driver changed' then 'driver'
                             else 'recompute' end,
         m.id, m.marker_date, m.vehicle_id, m.employee_id, m.minutes, m.eta_minutes,
         f.id, f.start_at, f.latitude, f.longitude, f.driver_id, f.driver_name, f.client_code
    from ops.calendar_day_markers m
    left join public.entity_source_links l
      on l.entity_type = 'calendar_day_marker' and l.source_system = 'jobber' and l.entity_id = m.id
    left join lateral public.fn_start_first_visit(m.marker_date, m.vehicle_id) f on true
   where public.fn_start_heal_enabled()
     and m.marker_type = 'start' and m.vehicle_id is not null and m.employee_id is not null
     and public.fn_start_frozen(m.marker_date, m.minutes) is not true
     and not exists (select 1 from ops.marker_jobber_claims c where c.marker_id = m.id and c.until >= now())
     and (   (m.stale_reason = 'no timed visit'
              and ((l.id is not null and l.synced_at < now() - interval '10 seconds')
                   or (l.id is null and m.created_at < now() - interval '10 minutes')))
          or (m.stale_reason = 'driver changed' and l.synced_at < now() - interval '10 seconds'
              and f.id = m.source_visit_id and f.driver_id is not null)
          or (m.stale_reason = 'first visit changed' and m.eta_minutes is not null and f.id is not null
              and l.synced_at < now() - interval '10 seconds'))
     and not exists (select 1 from ops.start_heal_attempts a
                      where a.marker_id = m.id and a.outcome <> 'healed'
                        and a.attempted_at > now() - case a.outcome
                                                       when 'no_driver' then interval '10 minutes'
                                                       when 'jobber_failed' then interval '10 minutes'
                                                       when 'eta_unknown' then interval '1 hour'
                                                       when 'eta_implausible' then interval '1 hour'
                                                       else interval '100 years' end
                        and a.first_visit_id is not distinct from f.id
                        and a.first_start_at is not distinct from f.start_at)
   order by m.marker_date, m.id
   limit 10
$$;

-- ---------------------------------------------------------------------------------------------------
-- PART 8. The kick gate: 15 seconds (a removal now waits for heal-day-starts)
-- ---------------------------------------------------------------------------------------------------
do $$
declare v_def text := pg_get_functiondef('public.fn_request_start_heal()'::regprocedure);
begin
  v_def := pg_temp.splice_once(v_def, 'requested_at < now() - interval ''60 seconds''',
    'requested_at < now() - interval ''15 seconds''', 'fn_request_start_heal gate');
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- PART 9. start-push-retry repairs a claim that was left behind
-- ---------------------------------------------------------------------------------------------------
-- An expired claim = a change that may have reached Jobber without its commit. jobber-push-task takes the
-- claim over and makes the Task match the row (or deletes it when the marker is gone), then the claim goes.
-- Same ledger and cadence as the other re-sends: 3 tries 5 minutes apart, then one every 6 hours; a take-over
-- that fails again sets a new expiry, i.e. a new ledger row.
alter table ops.marker_push_retries drop constraint marker_push_retries_kind_check;
alter table ops.marker_push_retries add constraint marker_push_retries_kind_check
  check (kind in ('delete', 'edit', 'claim'));
do $$
declare v_def text := pg_get_functiondef('ops.retry_marker_pushes()'::regprocedure);
begin
  v_def := pg_temp.splice_once(v_def,
    'is not true   -- its time has passed: leave the Task' || chr(10) || '  loop',
    'is not true   -- its time has passed: leave the Task' || chr(10) ||
    '    union all' || chr(10) ||
    '    -- c) a claim left behind (2026-09-24_2100): a change that may have reached Jobber without its commit.' || chr(10) ||
    '    select ''claim'', c.marker_id, c.until, c.marker_id,' || chr(10) ||
    '           case when exists (select 1 from ops.calendar_day_markers m where m.id = c.marker_id)' || chr(10) ||
    '                then ''upsert'' else ''delete'' end' || chr(10) ||
    '      from ops.marker_jobber_claims c' || chr(10) ||
    '     where c.until < now() - interval ''1 minute''' || chr(10) ||
    '  loop',
    'retry_marker_pushes claim arm');
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- PART 10. The health check: jobber_failed, "not run since" for every kind, and left-behind claims
-- ---------------------------------------------------------------------------------------------------
do $$
declare v_def text := pg_get_functiondef('public.log_start_flags_health()'::regprocedure);
begin
  v_def := pg_temp.splice_once(v_def,
    'when a.outcome = ''unresolvable'' then '', and the recompute could not make it match its first visit''' || chr(10) ||
    '                                   when mk.stale_reason = ''first visit changed''' || chr(10) ||
    '                                        and not exists (select 1 from public.sync_log s',
    'when a.outcome = ''unresolvable'' then '', and the recompute could not make it match its first visit''' || chr(10) ||
    '                                   when a.outcome = ''jobber_failed'' then '', and Jobber did not accept the change (it is tried again every 10 minutes)''' || chr(10) ||
    '                                   when not exists (select 1 from public.sync_log s',
    'log_start_flags_health outcomes');
  v_def := pg_temp.splice_once(v_def, ''', and the automatic recompute has not run since',
    ''', and the automatic fixing has not run since', 'log_start_flags_health wording');
  v_def := pg_temp.splice_once(v_def,
    '    union all' || chr(10) || '    -- 5. errors in the last 26 hours',
    '    union all' || chr(10) ||
    '    -- 4b. a change sent to Jobber and never committed, still not repaired after 20 minutes (2026-09-24_2100)' || chr(10) ||
    '    select jsonb_build_object(' || chr(10) ||
    '             ''kind'', ''marker_sync_interrupted:'' || c.marker_id,' || chr(10) ||
    '             ''issue'', ''marker_sync_interrupted'',' || chr(10) ||
    '             ''reason'', case when mk.id is null' || chr(10) ||
    '                           then format(''A marker (id %s) was removed while its Jobber Task was being changed, at %s ET, and the Task may still be on the crew''''s Jobber schedule.'',' || chr(10) ||
    '                                       c.marker_id, to_char(c.first_claimed_at at time zone ''America/New_York'', ''FMHH12:MI AM''))' || chr(10) ||
    '                           else format(''A change to the %s on %s (%s, %s) was being sent to Jobber at %s ET and did not finish, so Jobber may show another version than the Calendar.'',' || chr(10) ||
    '                                       mk.what, mk.day, mk.truck, coalesce(mk.driver, ''no driver''),' || chr(10) ||
    '                                       to_char(c.first_claimed_at at time zone ''America/New_York'', ''FMHH12:MI AM'')) end,' || chr(10) ||
    '             ''what_to_do'', ''Open that day in the Calendar and check the marker against Jobber; save it again if they differ. If it keeps happening, tell Fred.'',' || chr(10) ||
    '             ''marker_id'', c.marker_id)' || chr(10) ||
    '      from ops.marker_jobber_claims c' || chr(10) ||
    '      left join mk on mk.id = c.marker_id' || chr(10) ||
    '     where c.first_claimed_at < now() - interval ''20 minutes''' || chr(10) ||
    '    union all' || chr(10) || '    -- 5. errors in the last 26 hours',
    'log_start_flags_health claims');
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------------------------------
-- PART 11. Grants: service_role only, revoked by name (Supabase default privileges grant EXECUTE by name)
-- ---------------------------------------------------------------------------------------------------
revoke all on function ops.save_day_marker(text, bigint, uuid, jsonb, jsonb, jsonb, jsonb)      from public, anon, authenticated;
revoke all on function ops.save_day_marker_step(text, bigint, uuid, jsonb, jsonb, jsonb, jsonb) from public, anon, authenticated, service_role;
revoke all on function ops.claim_day_marker(bigint[], text, integer)                            from public, anon, authenticated;
revoke all on function ops.release_day_marker(uuid, boolean)                                    from public, anon, authenticated;
revoke all on function ops.note_start_heal_attempt(bigint, bigint, timestamptz, text)           from public, anon, authenticated;
revoke all on function ops.start_heal_candidates()                                              from public, anon, authenticated;
revoke all on function ops.apply_start_heal(bigint, bigint, timestamptz, bigint, integer, boolean) from public, anon, authenticated;
grant execute on function ops.save_day_marker(text, bigint, uuid, jsonb, jsonb, jsonb, jsonb)   to service_role;
grant execute on function ops.claim_day_marker(bigint[], text, integer)                         to service_role;
grant execute on function ops.release_day_marker(uuid, boolean)                                 to service_role;
grant execute on function ops.note_start_heal_attempt(bigint, bigint, timestamptz, text)        to service_role;
grant execute on function ops.start_heal_candidates()                                           to service_role;
grant execute on function ops.apply_start_heal(bigint, bigint, timestamptz, bigint, integer, boolean) to service_role;

-- =====================================================================================================
-- VERIFY (fixtures on 2031-01-14 with fake Task ids; the whole block rolls back through VERIFY_OK)
-- =====================================================================================================
do $verify$
declare
  d      date := date '2031-01-14';
  fn     text;
  q0     bigint;
  q1     bigint;
  r      jsonb;
  id1    bigint;
  id2    bigint;
  t1     uuid;
  t2     uuid;
  m      record;
  l      record;
  sixA   jsonb;
begin
  -- V1 grants: nobody but service_role (and the owner) may call the new or re-created functions
  foreach fn in array array['ops.save_day_marker(text,bigint,uuid,jsonb,jsonb,jsonb,jsonb)',
                            'ops.claim_day_marker(bigint[],text,integer)',
                            'ops.release_day_marker(uuid,boolean)',
                            'ops.note_start_heal_attempt(bigint,bigint,timestamptz,text)',
                            'ops.start_heal_candidates()',
                            'ops.apply_start_heal(bigint,bigint,timestamptz,bigint,integer,boolean)'] loop
    if has_function_privilege('authenticated', fn, 'execute') or has_function_privilege('anon', fn, 'execute')
       or not has_function_privilege('service_role', fn, 'execute') then
      raise exception 'V1 grants wrong on %', fn;
    end if;
  end loop;
  if has_function_privilege('service_role', 'ops.save_day_marker_step(text,bigint,uuid,jsonb,jsonb,jsonb,jsonb)', 'execute')
     or has_function_privilege('authenticated', 'ops.save_day_marker_step(text,bigint,uuid,jsonb,jsonb,jsonb,jsonb)', 'execute')
     or has_table_privilege('service_role', 'ops.marker_jobber_claims', 'select')
     or has_table_privilege('authenticated', 'ops.marker_jobber_claims', 'select') then
    raise exception 'V1b the body or the claims table is reachable directly';
  end if;
  if exists (select 1 from pg_proc where oid::regprocedure::text = 'ops.apply_start_heal(bigint,bigint,timestamp with time zone,bigint,integer)') then
    raise exception 'V1c the 5-argument apply_start_heal is still there';
  end if;
  if pg_get_functiondef('public.fn_request_start_heal()'::regprocedure) !~ 'interval ''15 seconds''' then
    raise exception 'V1d the kick gate is not 15 seconds';
  end if;

  select count(*) into q0 from net.http_request_queue;

  -- V2 create with a Task (no claim needed for a new row): row + link, stamp = synced_at, no push queued
  r := ops.save_day_marker('create', null, null, null,
         jsonb_build_object('marker_type', 'end', 'marker_date', d, 'minutes', 600, 'employee_id', 2),
         '{"gid":"TEST-GID-A","title":"Day End (Fred)"}', null);
  id1 := (r->'marker'->>'id')::bigint;
  select * into m from ops.calendar_day_markers where id = id1;
  select * into l from public.entity_source_links
   where entity_type = 'calendar_day_marker' and source_system = 'jobber' and entity_id = id1;
  if r->>'outcome' <> 'saved' or m.minutes <> 600 or l.source_id is distinct from 'TEST-GID-A'
     or l.match_method <> 'calendar_saga' or m.push_changed_at is null or m.push_changed_at <> l.synced_at then
    raise exception 'V2 create: % / % / %', r, to_jsonb(m), to_jsonb(l);
  end if;
  sixA := jsonb_build_object('marker_date', d, 'marker_type', 'end', 'minutes', 600, 'vehicle_id', null,
                             'employee_id', 2, 'dump_site', null, 'link_gid', 'TEST-GID-A');

  -- V3 the claim: a second claim is busy; an update without the token is refused
  t1 := ops.claim_day_marker(array[id1], 'verify');
  begin
    perform ops.claim_day_marker(array[id1], 'verify-2');
    raise exception 'V3 second claim not refused';
  exception when sqlstate 'ZZ004' then null;
  end;
  begin
    perform ops.save_day_marker('update', id1, gen_random_uuid(), sixA, '{"minutes":630}',
                                '{"gid":"TEST-GID-A","title":"Day End (Fred)"}', null);
    raise exception 'V3b wrong token not refused';
  exception when sqlstate 'ZZ005' then null;
  end;

  -- V4 update with the claim and a Task: committed, stamped, the claim is gone, nothing pushed
  r := ops.save_day_marker('update', id1, t1, sixA, '{"minutes":630}',
                           '{"gid":"TEST-GID-A","title":"Day End (Fred)"}', null);
  select * into m from ops.calendar_day_markers where id = id1;
  if r->>'outcome' <> 'saved' or m.minutes <> 630 or (r->'before'->>'minutes')::int <> 600
     or exists (select 1 from ops.marker_jobber_claims where marker_id = id1) then
    raise exception 'V4 update: %', r;
  end if;
  select count(*) into q1 from net.http_request_queue;
  if q1 <> q0 then raise exception 'V2/V4 queued % push(es) under the suppression', q1 - q0; end if;

  -- V5 compare-and-swap: a stale expectation refuses (minutes is 630 now), and so does a stale link
  t1 := ops.claim_day_marker(array[id1], 'verify');
  begin
    perform ops.save_day_marker('update', id1, t1, sixA, '{"minutes":640}',
                                '{"gid":"TEST-GID-A","title":"Day End (Fred)"}', null);
    raise exception 'V5 no refusal';
  exception when sqlstate 'ZZ002' then null;
  end;
  begin
    perform ops.save_day_marker('delete', id1, t1, '{"link_gid":"SOMETHING-ELSE"}', null, null, null);
    raise exception 'V5b no refusal on the link';
  exception when sqlstate 'ZZ002' then null;
  end;

  -- V6 a visible change without a Task refuses; a non-visible one without a Task is fine and unstamped
  begin
    perform ops.save_day_marker('update', id1, t1, null, '{"minutes":650}', null, null);
    raise exception 'V6 no refusal';
  exception when sqlstate 'ZZ003' then null;
  end;
  select * into l from public.entity_source_links
   where entity_type = 'calendar_day_marker' and source_system = 'jobber' and entity_id = id1;
  r := ops.save_day_marker('update', id1, t1, null, '{"eta_minutes":12}', null, null);
  select * into m from ops.calendar_day_markers where id = id1;
  if m.eta_minutes <> 12 or m.minutes <> 630 or m.push_changed_at <> l.synced_at then
    raise exception 'V6b eta-only update: %', to_jsonb(m);
  end if;

  -- V7 fields a caller may not write (checked before the claim)
  begin
    perform ops.save_day_marker('update', id1, null, null, '{"stale_reason":"no timed visit"}', null, null);
    raise exception 'V7 no refusal';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform ops.save_day_marker('update', id1, null, null, '{"vehicle_id":3}', null, null);
    raise exception 'V7b no refusal';
  exception when sqlstate '22023' then null;
  end;

  -- V8 the slot rule still holds (a second End for Fred that day)
  begin
    perform ops.save_day_marker('create', null, null, null,
              jsonb_build_object('marker_type', 'end', 'marker_date', d, 'minutes', 700, 'employee_id', 2),
              '{"gid":"TEST-GID-B","title":"Day End (Fred)"}', null);
    raise exception 'V8 no refusal';
  exception when unique_violation then null;
  end;

  -- V9 relink (a re-created Task) and unlink
  t1 := ops.claim_day_marker(array[id1], 'verify');
  r := ops.save_day_marker('relink', id1, t1, '{"link_gid":"TEST-GID-A","minutes":630}', null,
                           '{"gid":"TEST-GID-A2","title":"Day End (Fred)"}', null);
  if r->>'outcome' <> 'relinked' or not exists (select 1 from public.entity_source_links
       where entity_type = 'calendar_day_marker' and entity_id = id1 and source_id = 'TEST-GID-A2') then
    raise exception 'V9 relink: %', r;
  end if;
  t1 := ops.claim_day_marker(array[id1], 'verify');
  r := ops.save_day_marker('relink', id1, t1, '{"link_gid":"TEST-GID-A2"}', null, null, null);
  if exists (select 1 from public.entity_source_links where entity_type = 'calendar_day_marker' and entity_id = id1) then
    raise exception 'V9b unlink left the link';
  end if;

  -- V10 the suppression is scoped to the call: a plain UPDATE afterwards pushes (and proves the queue counts)
  select count(*) into q0 from net.http_request_queue;
  update ops.calendar_day_markers set minutes = 631 where id = id1;
  select count(*) into q1 from net.http_request_queue;
  if q1 <> q0 + 1 then raise exception 'V10 expected one push after the RPC returned, got %', q1 - q0; end if;

  -- V11 a claim left behind is repaired by start-push-retry (a push is queued), and reported after 20 min
  t2 := ops.claim_day_marker(array[id1], 'verify');
  perform ops.release_day_marker(t2, true);
  update ops.marker_jobber_claims set until = now() - interval '2 minutes',
                                      first_claimed_at = now() - interval '25 minutes' where marker_id = id1;
  select count(*) into q0 from net.http_request_queue;
  perform ops.retry_marker_pushes();
  select count(*) into q1 from net.http_request_queue;
  if q1 < q0 + 1 or not exists (select 1 from ops.marker_push_retries where kind = 'claim' and ref_id = id1) then
    raise exception 'V11 the left-behind claim was not re-sent (% pushes)', q1 - q0;
  end if;
  perform public.log_start_flags_health();
  if not exists (select 1 from public.sync_log s where s.sync_source = 'start-flags-health'
                   and s.started_at >= now() - interval '1 second'
                   and exists (select 1 from jsonb_array_elements(s.details->'items') i
                                where i->>'kind' = 'marker_sync_interrupted:' || id1)) then
    raise exception 'V11b the health check did not report the left-behind claim';
  end if;
  -- an expired claim is taken over by the next writer
  t1 := ops.claim_day_marker(array[id1], 'verify');
  -- a clean release deletes it
  perform ops.release_day_marker(t1, false);
  if exists (select 1 from ops.marker_jobber_claims where marker_id = id1) then
    raise exception 'V11c a clean release left the claim';
  end if;

  -- V12 delete: row, link and claim go; a second delete is 'gone'
  t1 := ops.claim_day_marker(array[id1], 'verify');
  perform ops.save_day_marker('relink', id1, t1, null, null, '{"gid":"TEST-GID-A3","title":"Day End (Fred)"}', null);
  t1 := ops.claim_day_marker(array[id1], 'verify');
  r := ops.save_day_marker('delete', id1, t1, '{"link_gid":"TEST-GID-A3"}', null, null, null);
  if r->>'outcome' <> 'deleted' or exists (select 1 from ops.calendar_day_markers where id = id1)
     or exists (select 1 from public.entity_source_links where entity_type = 'calendar_day_marker' and entity_id = id1)
     or exists (select 1 from ops.marker_jobber_claims where marker_id = id1) then
    raise exception 'V12 delete: %', r;
  end if;
  t1 := ops.claim_day_marker(array[id1], 'verify');
  r := ops.save_day_marker('delete', id1, t1, null, null, null, null);
  if r->>'outcome' <> 'gone' or exists (select 1 from ops.marker_jobber_claims where marker_id = id1) then
    raise exception 'V12b second delete: %', r;
  end if;

  -- V13 a truck Start with no visit that day: flagged 'no timed visit', and the judge no longer removes it
  r := ops.save_day_marker('create', null, null, null,
         jsonb_build_object('marker_type', 'start', 'marker_date', d, 'minutes', 300, 'vehicle_id', 3,
                            'employee_id', 2, 'eta_minutes', 40, 'eta_computed_at', now()),
         '{"gid":"TEST-GID-C","title":"Day Start (David, Fred)"}', null);
  id2 := (r->'marker'->>'id')::bigint;
  if r->'marker'->>'stale_reason' is distinct from 'no timed visit' then
    raise exception 'V13 expected the new Start flagged no timed visit: %', r;
  end if;
  update public.entity_source_links set synced_at = now() - interval '1 minute'
   where entity_type = 'calendar_day_marker' and entity_id = id2;
  perform ops.fn_judge_starts(array[d]);
  if not exists (select 1 from ops.calendar_day_markers where id = id2 and stale_reason = 'no timed visit') then
    raise exception 'V13b the judge removed or cleared the Start (it must only flag)';
  end if;

  -- V14 it is a 'remove' candidate (healing is on in Prod), and not while another writer holds it
  if public.fn_start_heal_enabled() then
    if not exists (select 1 from ops.start_heal_candidates() c where c.marker_id = id2 and c.kind = 'remove') then
      raise exception 'V14 not offered as a remove candidate';
    end if;
    t2 := ops.claim_day_marker(array[id2], 'verify');
    if exists (select 1 from ops.start_heal_candidates() c where c.marker_id = id2) then
      raise exception 'V14b offered while claimed';
    end if;
  else
    t2 := ops.claim_day_marker(array[id2], 'verify');
  end if;

  -- V15 the healer's remove: refused when switched off (claim kept for the caller), done when on
  update public.app_config set value = 'false' where key = 'start_heal_enabled';
  r := ops.save_day_marker('delete', id2, t2, '{"link_gid":"TEST-GID-C"}', null, null, '{"kind":"remove"}');
  if r->>'outcome' <> 'off' or not exists (select 1 from ops.calendar_day_markers where id = id2) then
    raise exception 'V15 remove with healing off: %', r;
  end if;
  update public.app_config set value = 'true' where key = 'start_heal_enabled';
  r := ops.save_day_marker('delete', id2, t2, '{"link_gid":"TEST-GID-C"}', null, null, '{"kind":"remove"}');
  if r->>'outcome' <> 'healed' or exists (select 1 from ops.calendar_day_markers where id = id2) then
    raise exception 'V15b remove: %', r;
  end if;

  -- V16 a heal kind on the wrong operation refuses
  begin
    perform ops.save_day_marker('update', id2, null, null, '{"minutes":1}', null, '{"kind":"remove"}');
    raise exception 'V16 no refusal';
  exception when sqlstate '22023' then null;
  end;

  -- V17 the dry run writes nothing (a Start not flagged 'first visit changed' answers not_flagged)
  r := ops.save_day_marker('create', null, null, null,
         jsonb_build_object('marker_type', 'start', 'marker_date', d, 'minutes', 300, 'vehicle_id', 2,
                            'employee_id', 2, 'eta_minutes', 40, 'eta_computed_at', now()),
         '{"gid":"TEST-GID-D","title":"Day Start (Cloggy, Fred)"}', null);
  id2 := (r->'marker'->>'id')::bigint;
  r := ops.apply_start_heal(id2, null, null, null, 30, true);
  if r->>'outcome' not in ('not_flagged', 'changed')
     or not exists (select 1 from ops.calendar_day_markers where id = id2 and minutes = 300) then
    raise exception 'V17 dry run: %', r;
  end if;

  raise exception 'VERIFY_OK';
exception when raise_exception then
  if sqlerrm <> 'VERIFY_OK' then raise; end if;
end
$verify$;

commit;
