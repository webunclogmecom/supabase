-- =====================================================================================================
-- 2026-09-24_2145  Jobber-first day markers: the code review's fixes to the claims
-- =====================================================================================================
-- Follows 2026-09-24_2100 (the Jobber-first marker saga) and 2026-09-24_2140 (the revoke). An adversarial
-- review of the deployed code found ways a "Jobber may differ from the row" state could be lost without a
-- trace. The database half of the fixes (the edge fns change in the same commit):
--
-- 1. A claim remembers that it is DIRTY (`dirty`). A save that takes over an interrupted save's claim and then
--    commits only to the database (a change Jobber cannot see, so no Task was pushed) used to delete the claim,
--    and with it the only record that Jobber may still show the interrupted change. Now such a commit leaves
--    the claim expired and dirty for start-push-retry; only a commit that carries a verified Task (or a delete,
--    whose Task was proven gone) clears a dirty claim.
-- 2. The commit locks its claim row (FOR UPDATE), so a take-over and a commit cannot interleave.
-- 3. A dirty release that finds no claim of its own (a slow save whose claim was taken over, or a commit that
--    landed although its reply was lost) leaves an expired dirty claim for each marker it touched, so the retry
--    still compares Jobber with the row. ops.release_day_marker gains p_marker_ids (default null keeps the
--    old two-argument calls working).
-- 4. start-push-retry's claim arm counts attempts per INCIDENT (first_claimed_at, kept across take-overs), not
--    per expiry, so "3 tries 5 minutes apart, then every 6 hours" applies; before, every take-over was a new
--    ledger row and a failure that never clears was re-sent every 5 minutes for ever.
-- 5. A heal that fails for any reason other than Jobber (a database error, a refused value) is recorded as
--    'failed' and backs off 10 minutes, like 'jobber_failed'; the health check names it.
--
-- Every changed body is spliced from pg_get_functiondef, each anchor asserted to occur once, md5s pinned.
-- Rule 8: one new column on a bookkeeping table (opt-out, as the table).
-- =====================================================================================================

begin;

do $$
begin
  if md5(pg_get_functiondef('ops.save_day_marker_step(text,bigint,uuid,jsonb,jsonb,jsonb,jsonb)'::regprocedure)) <> '6dd442c6935e4551edd81e0008e0eb22'
  then raise exception 'save_day_marker_step changed'; end if;
  if md5(pg_get_functiondef('ops.release_day_marker(uuid,boolean)'::regprocedure)) <> 'c92307ea874804311aa05e35e109f3e2'
  then raise exception 'release_day_marker changed'; end if;
  if md5(pg_get_functiondef('ops.retry_marker_pushes()'::regprocedure)) <> '51ad7d9bf195d4c89f57d6018b104b0e'
  then raise exception 'retry_marker_pushes changed'; end if;
  if md5(pg_get_functiondef('ops.start_heal_candidates()'::regprocedure)) <> '6cb16553485866f4c71a168ae28b71b4'
  then raise exception 'start_heal_candidates changed'; end if;
  if md5(pg_get_functiondef('ops.note_start_heal_attempt(bigint,bigint,timestamptz,text)'::regprocedure)) <> '30ff8fae558508d8520255c4164cb868'
  then raise exception 'note_start_heal_attempt changed'; end if;
  if md5(pg_get_functiondef('public.log_start_flags_health()'::regprocedure)) <> 'c00cf31a9b8d170ebbc407c086563d50'
  then raise exception 'log_start_flags_health changed'; end if;
end $$;

create function pg_temp.splice_once(p_def text, p_from text, p_to text, p_what text)
returns text language plpgsql as $$
declare v_n int;
begin
  v_n := (length(p_def) - length(replace(p_def, p_from, ''))) / length(p_from);
  if v_n <> 1 then raise exception '%: expected 1 anchor, found %', p_what, v_n; end if;
  return replace(p_def, p_from, p_to);
end $$;

-- ---- 1. the dirty mark --------------------------------------------------------------------------
alter table ops.marker_jobber_claims add column dirty boolean not null default false;
comment on column ops.marker_jobber_claims.dirty is
  'A save holding (or having held) this claim may have changed the Jobber Task without its commit. Kept across take-overs; cleared only by a commit that carries a verified Task, or a delete. 2026-09-24_2145.';

-- ---- 1+2. the commit: lock the claim; keep a dirty claim unless this commit verified the Task ------
do $$
declare v_def text := pg_get_functiondef('ops.save_day_marker_step(text,bigint,uuid,jsonb,jsonb,jsonb,jsonb)'::regprocedure);
begin
  v_def := pg_temp.splice_once(v_def,
    '    if p_token is null or not exists (select 1 from ops.marker_jobber_claims c' || chr(10) ||
    '                                       where c.marker_id = p_marker_id and c.token = p_token) then',
    '    -- 2026-09-24_2145: the claim row is LOCKED, so a take-over waits for this commit and vice versa.' || chr(10) ||
    '    perform 1 from ops.marker_jobber_claims c where c.marker_id = p_marker_id and c.token = p_token for update;' || chr(10) ||
    '    if p_token is null or not found then',
    'step claim check');
  v_def := pg_temp.splice_once(v_def,
    '      v_after := m;                     -- relink: the row stays as it is' || chr(10) ||
    '    end if;' || chr(10) ||
    '    delete from ops.marker_jobber_claims where marker_id = m.id and token = p_token;' || chr(10),
    '      v_after := m;                     -- relink: the row stays as it is' || chr(10) ||
    '    end if;' || chr(10) ||
    '    -- 2026-09-24_2145: a DIRTY claim (an interrupted save may have changed the Task) survives a commit that' || chr(10) ||
    '    -- did not verify the Task: it is left expired for start-push-retry, the only thing that can repair it.' || chr(10) ||
    '    if p_task is null and exists (select 1 from ops.marker_jobber_claims c' || chr(10) ||
    '                                   where c.marker_id = m.id and c.token = p_token and c.dirty) then' || chr(10) ||
    '      update ops.marker_jobber_claims set until = least(until, now()) where marker_id = m.id and token = p_token;' || chr(10) ||
    '    else' || chr(10) ||
    '      delete from ops.marker_jobber_claims where marker_id = m.id and token = p_token;' || chr(10) ||
    '    end if;' || chr(10),
    'step claim release');
  execute v_def;
end $$;

-- ---- 3. release: dirty sets the mark; a dirty release that finds no claim of its own leaves one ----
drop function ops.release_day_marker(uuid, boolean);
create function ops.release_day_marker(p_token uuid, p_dirty boolean, p_marker_ids bigint[] default null)
returns integer
language plpgsql security definer
set search_path = public, ops, pg_temp
as $$
declare v_n integer;
begin
  if p_dirty then
    update ops.marker_jobber_claims set until = least(until, now()), dirty = true where token = p_token;
    get diagnostics v_n = row_count;
    -- Our claim is gone: a slower save of ours was taken over, or our commit landed although its reply was
    -- lost. Jobber may still differ, so leave an expired dirty claim (or mark the one another writer holds):
    -- start-push-retry then compares Jobber with the row whatever happened.
    if v_n = 0 and p_marker_ids is not null then
      insert into ops.marker_jobber_claims as c (marker_id, token, holder, until, dirty)
      select x, gen_random_uuid(), 'released-dirty', now(), true from unnest(p_marker_ids) x
      on conflict (marker_id) do update set dirty = true;
      get diagnostics v_n = row_count;
    end if;
  else
    delete from ops.marker_jobber_claims where token = p_token;
    get diagnostics v_n = row_count;
  end if;
  return v_n;
end
$$;
revoke all on function ops.release_day_marker(uuid, boolean, bigint[]) from public, anon, authenticated;
grant execute on function ops.release_day_marker(uuid, boolean, bigint[]) to service_role;

-- ---- 4. the retry counts attempts per incident ---------------------------------------------------
do $$
declare v_def text := pg_get_functiondef('ops.retry_marker_pushes()'::regprocedure);
begin
  v_def := pg_temp.splice_once(v_def,
    'select ''claim'', c.marker_id, c.until, c.marker_id,',
    'select ''claim'', c.marker_id, c.first_claimed_at, c.marker_id,   -- per incident (2026-09-24_2145)',
    'retry claim arm');
  execute v_def;
end $$;

-- ---- 5. any failed heal backs off -------------------------------------------------------------------
do $$
declare v_def text;
begin
  v_def := pg_get_functiondef('ops.note_start_heal_attempt(bigint,bigint,timestamptz,text)'::regprocedure);
  v_def := pg_temp.splice_once(v_def, 'where p_outcome in (''jobber_failed'')',
    'where p_outcome in (''jobber_failed'', ''failed'')', 'note outcomes');
  execute v_def;
  v_def := pg_get_functiondef('ops.start_heal_candidates()'::regprocedure);
  v_def := pg_temp.splice_once(v_def, 'when ''jobber_failed'' then interval ''10 minutes''',
    'when ''jobber_failed'' then interval ''10 minutes''' || chr(10) ||
    '                                                       when ''failed'' then interval ''10 minutes''', 'candidates backoff');
  execute v_def;
  v_def := pg_get_functiondef('public.log_start_flags_health()'::regprocedure);
  v_def := pg_temp.splice_once(v_def,
    'when a.outcome = ''jobber_failed'' then '', and Jobber did not accept the change (it is tried again every 10 minutes)''',
    'when a.outcome = ''jobber_failed'' then '', and Jobber did not accept the change (it is tried again every 10 minutes)''' || chr(10) ||
    '                                   when a.outcome = ''failed'' then '', and the automatic fix failed (sync_log start-flags-heal has the error; it is tried again every 10 minutes)''',
    'health failed outcome');
  execute v_def;
end $$;

-- =====================================================================================================
-- VERIFY (fixtures on 2031-01-14; rolled back through VERIFY_OK)
-- =====================================================================================================
do $verify$
declare
  d   date := date '2031-01-14';
  r   jsonb;
  id1 bigint;
  t1  uuid;
  t2  uuid;
  q0  bigint;
  q1  bigint;
  n   integer;
begin
  if has_function_privilege('authenticated', 'ops.release_day_marker(uuid,boolean,bigint[])', 'execute')
     or not has_function_privilege('service_role', 'ops.release_day_marker(uuid,boolean,bigint[])', 'execute') then
    raise exception 'V0 grants';
  end if;

  r := ops.save_day_marker('create', null, null, null,
         jsonb_build_object('marker_type', 'end', 'marker_date', d, 'minutes', 600, 'employee_id', 2),
         '{"gid":"TEST-GID-R1","title":"Day End (Fred)"}', null);
  id1 := (r->'marker'->>'id')::bigint;

  -- V1 a dirty claim survives a database-only commit made by the save that took it over
  t1 := ops.claim_day_marker(array[id1], 'verify');
  perform ops.release_day_marker(t1, true, array[id1]);
  if not exists (select 1 from ops.marker_jobber_claims where marker_id = id1 and dirty and until <= now()) then
    raise exception 'V1a a dirty release did not mark the claim';
  end if;
  -- (now() is fixed inside a transaction: backdate the expiry so the take-over is possible here)
  update ops.marker_jobber_claims set until = now() - interval '1 second' where marker_id = id1;
  t2 := ops.claim_day_marker(array[id1], 'verify-2');                       -- take-over
  r := ops.save_day_marker('update', id1, t2, null, '{"eta_minutes":5}', null, null);
  if not exists (select 1 from ops.marker_jobber_claims where marker_id = id1 and dirty and until <= now()) then
    raise exception 'V1b a database-only commit wiped the dirty claim';
  end if;
  -- ...and a commit that carries a verified Task clears it
  update ops.marker_jobber_claims set until = now() - interval '1 second' where marker_id = id1;
  t2 := ops.claim_day_marker(array[id1], 'verify-3');
  r := ops.save_day_marker('update', id1, t2, null, '{"minutes":610}', '{"gid":"TEST-GID-R1","title":"Day End (Fred)"}', null);
  if exists (select 1 from ops.marker_jobber_claims where marker_id = id1) then
    raise exception 'V1c a verified commit left the claim';
  end if;
  -- a clean claim still goes on a database-only commit
  t2 := ops.claim_day_marker(array[id1], 'verify-4');
  r := ops.save_day_marker('update', id1, t2, null, '{"eta_minutes":6}', null, null);
  if exists (select 1 from ops.marker_jobber_claims where marker_id = id1) then
    raise exception 'V1d a clean claim was kept';
  end if;

  -- V2 a dirty release whose claim is gone leaves an expired dirty claim
  n := ops.release_day_marker(gen_random_uuid(), true, array[id1]);
  if n <> 1 or not exists (select 1 from ops.marker_jobber_claims where marker_id = id1 and dirty and holder = 'released-dirty') then
    raise exception 'V2 no claim left by a lost dirty release (%)', n;
  end if;
  -- the old two-argument call still resolves
  perform ops.release_day_marker(gen_random_uuid(), false);

  -- V3 the retry counts one incident once, across a take-over and a new expiry
  update ops.marker_jobber_claims set until = now() - interval '2 minutes' where marker_id = id1;
  perform ops.retry_marker_pushes();
  t2 := ops.claim_day_marker(array[id1], 'verify-5');
  perform ops.release_day_marker(t2, true, array[id1]);
  update ops.marker_jobber_claims set until = now() - interval '3 minutes' where marker_id = id1;
  select count(*) into q0 from net.http_request_queue;
  perform ops.retry_marker_pushes();
  select count(*) into q1 from net.http_request_queue;
  select count(*) into n from ops.marker_push_retries where kind = 'claim' and ref_id = id1;
  if n <> 1 or q1 <> q0 then
    raise exception 'V3 the claim incident was counted % times and re-sent % more time(s) within 4 minutes', n, q1 - q0;
  end if;

  -- V4 'failed' is accepted and backs off
  perform ops.note_start_heal_attempt(id1, null, null, 'failed');
  if not exists (select 1 from ops.start_heal_attempts where marker_id = id1 and outcome = 'failed') then
    raise exception 'V4 failed not recorded';
  end if;
  if pg_get_functiondef('ops.start_heal_candidates()'::regprocedure) !~ 'when ''failed'' then interval ''10 minutes''' then
    raise exception 'V4b no backoff for failed';
  end if;
  perform public.log_start_flags_health();

  raise exception 'VERIFY_OK';
exception when raise_exception then
  if sqlerrm <> 'VERIFY_OK' then raise; end if;
end
$verify$;

commit;
