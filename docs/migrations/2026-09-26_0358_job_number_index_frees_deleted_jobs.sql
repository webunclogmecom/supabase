-- ============================================================================
-- 2026-09-26_0358 · jobs_active_job_number_uniq: a job Jobber DELETED no longer holds its number
-- ============================================================================
-- ASK (Fred, 2026-09-26): after 2026-09-26_0313 made a recycled job number refuse cleanly inside
-- fn_jobber_resolve_job, "do a check on it first before fixing it" on narrowing the index.
--
-- CHANGE: the partial unique index predicate
--   was   WHERE job_number IS NOT NULL AND job_status <> 'archived'
--   now   WHERE job_number IS NOT NULL AND job_status NOT IN ('archived', 'destroyed')
-- Same name, swapped in ONE transaction (DROP + CREATE, not CONCURRENTLY; about 1,900 rows, a brief
-- ACCESS EXCLUSIVE lock), so the constraint is never missing. 'destroyed' now matches the 2026-09-15 rule
-- ("destroyed is terminal wherever archived is"). 'closed' is deliberately NOT excluded: a 'closed' row was a
-- job still alive in Jobber, and 2026-09-15_1100 keeps 'closed' out of every terminal list.
--
-- WHY. Jobber assigns a new job number by counting up from the highest number in the account, so deleting
-- the top job frees its number, and the next job reuses it (both recycled pairs, 99901013 and 99901068,
-- were reused after the original was deleted; neither original exists in Jobber). JOB_DESTROY writes
-- 'destroyed', which the old index still covered, so:
--   1. the new job with the reused number was refused until sync-jobber-job-drift's gone arm archived the
--      old row (measured 20 to 42 min, 8 of 8 destroyed rows ever); and
--   2. a JOB_DESTROY on an ARCHIVED row whose number a live job holds failed with 23505 (half of all real
--      'destroyed' writes started from 'archived': 4 of 8), because the flip put the row back into the index.
-- Both stop. ⚠ The delay is removed only when JOB_DESTROY lands before the new job's create; a destroy that
-- arrives late or never (job 1850 went straight to 'archived') still waits for the drift, as before.
--
-- CHECKED FIRST (3 read-only reviewers, 2026-09-26):
--   * nothing uses this index as an ON CONFLICT arbiter (catalogue + repo sweeps, positive controls);
--   * no reader looks jobs up by job_number assuming one live row;
--   * the new predicate implies the old, so the build cannot fail on existing rows (491 rows either way,
--     0 duplicates when checked; re-asserted below);
--   * two LIVE jobs still cannot share a number, and a destroyed row coming back to life while its number is
--     taken is refused (23505). No destroyed row has ever come back: all 8 went only to 'archived', and
--     Jobber has no job undelete (assumption recorded: if one ever appears, sync-jobber-job-drift's status
--     patch would hit that 23505, and it does not check its UPDATE errors).
-- PROOF (rolled back, scratchpad ix/): the same case set under the OLD index (control) and the NEW one:
--   live+live refused/refused; archived+live allowed/allowed; destroyed+live REFUSED/ALLOWED;
--   closed+live refused/refused; NULL-shell+live allowed/allowed; archived->destroyed with a live holder
--   REFUSED/ALLOWED; destroyed->live with a live holder refused/refused. Mutation: asserting the NEW outcomes
--   against the OLD index fails on exactly the two rows that change.
--
-- ALSO: public.fn_jobber_resolve_job is re-created COMMENT-ONLY (two lines added after its 0313 correction,
-- body copied from pg_get_functiondef; same signature, so its service_role-only ACL is kept).
-- RULE 8: no table change; public.jobs stays audited.
-- RUN AS ONE QUERY (Management API) or psql -1: the DROP must not commit alone.
-- ROLLBACK (unsafe to do blindly once live): a destroyed row and a live row can now legitimately share a
--   number for up to ~42 min, and the old index would then fail to build. First confirm
--     select job_number from public.jobs where job_number is not null and job_status <> 'archived'
--      group by 1 having count(*) > 1;
--   returns nothing (or wait for the drift to archive the destroyed holders), then swap the index back.
-- ============================================================================

-- 0. the new predicate must hold no duplicates (it is a subset of the old one, so this is a tripwire)
do $$
begin
  if exists (select 1 from public.jobs
              where job_number is not null and job_status not in ('archived', 'destroyed')
              group by job_number having count(*) > 1) then
    raise exception 'pre-check: duplicate live job numbers exist; not swapping the index';
  end if;
end $$;

-- 1. swap the index, same name, one transaction
drop index public.jobs_active_job_number_uniq;
create unique index jobs_active_job_number_uniq on public.jobs (job_number)
  where job_number is not null and job_status not in ('archived', 'destroyed');

-- 2. fn_jobber_resolve_job: comment-only (copied body, two comment lines added)
CREATE OR REPLACE FUNCTION public.fn_jobber_resolve_job(p_gid text, p_job_number text DEFAULT NULL::text, p_job_status text DEFAULT NULL::text)
 RETURNS TABLE(entity_id bigint, was_created boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_id bigint;
begin
  if p_gid is null or pg_catalog.btrim(p_gid) = '' then
    raise exception 'fn_jobber_resolve_job: p_gid is required';
  end if;

  -- ---- FAST PATH: already linked. No lock. -------------------------------------------------
  -- 437 JOB_UPDATEs against 55 creates. Only the create path pays.
  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'job' and l.source_system = 'jobber' and l.source_id = p_gid;
  if v_id is not null then
    return query select v_id, false;
    return;
  end if;

  -- ---- SLOW PATH: serialise every creator of THIS gid ---------------------------------------
  -- ⚠ Key must be byte-identical to fn_record_client_job's or the two writers do not serialise.
  perform pg_catalog.pg_advisory_xact_lock(
            pg_catalog.hashtextextended('jobber:job:' || p_gid, 0));

  -- 🛑 THIS RE-READ IS THE FIX. The first read happened BEFORE the lock and saw the world as it was
  -- before the winner committed. This one happens after, and it is the only reason the loser stops
  -- instead of inserting a duplicate.
  select l.entity_id into v_id
    from public.entity_source_links l
   where l.entity_type = 'job' and l.source_system = 'jobber' and l.source_id = p_gid;
  if v_id is not null then
    return query select v_id, false;
    return;
  end if;

  -- Only `id` is NOT NULL on public.jobs, and its ONLY insert trigger is audit.log_change, which is
  -- column-agnostic -- checked, because that is exactly what made the bare shell unsafe on
  -- public.visits (see _1200: trg_visit_default_locations is AFTER INSERT and early-returns on a
  -- NULL client_id). handleJob fills the rest of the payload in the UPDATE immediately after.
  --
  -- 🛑 job_number IS THE ONE EXCEPTION, AND IT IS ABOUT WHERE A FAILURE LANDS, NOT ABOUT DATA.
  --    jobs_active_job_number_uniq can refuse a GENUINE job because Jobber recycles job_number
  --    (99901013 and 99901068 each map to two different GIDs). If job_number arrived only in the
  --    caller's UPDATE, that refusal would fire in a SECOND transaction -- after the shell row and
  --    its entity_source_links row had already committed -- leaving a permanently linked, entirely
  --    NULL job that every later delivery resolves onto and re-fails. Writing it here keeps the
  --    refusal inside this transaction, so the shell and its link roll back together and the
  --    pre-change all-or-nothing behaviour is preserved.
  -- 🛑 CORRECTED 2026-09-26: job_number ALONE NEVER DID THAT. The index is
  --    UNIQUE (job_number) WHERE job_number IS NOT NULL AND job_status <> 'archived', and a shell
  --    written with job_status NULL makes (NULL <> 'archived') NULL, so the shell was never in the
  --    index and could not collide here. The refusal fired in the caller's UPDATE one transaction
  --    later, stranding a linked NULL-status job. So the caller now passes Jobber's status too
  --    (p_job_status) and the shell carries it: a live recycled number now refuses HERE (23505, shell
  --    and link roll back together), while an ARCHIVED import of a recycled number still succeeds,
  --    exactly as the index intends. NULL (a caller that does not pass it) keeps the old behaviour.
  -- ⚠ Since 2026-09-26_0358 the index is WHERE job_number IS NOT NULL AND job_status NOT IN ('archived',
  --    'destroyed'): a job Jobber deleted no longer holds its number. A NULL-status shell is still outside it.
  insert into public.jobs (job_number, job_status)
       values (p_job_number, pg_catalog.lower(p_job_status)) returning id into v_id;

  -- Same transaction as the row above: if this fails the job goes with it and the caller gets an
  -- error instead of an orphan.
  insert into public.entity_source_links
         (entity_type, entity_id, source_system, source_id,
          match_method, match_confidence, synced_at)
       values ('job', v_id, 'jobber', p_gid, 'webhook', 1.0, pg_catalog.now());

  return query select v_id, true;
end
$function$
;

-- VERIFY. Every case inserts FAKE job numbers ('T-IX-...') inside a subtransaction that is always rolled back.
create or replace function pg_temp.ix_case(p_first text, p_second text) returns text language plpgsql as $$
begin
  begin
    insert into public.jobs (job_number, job_status) values ('T-IX-CASE', p_first);
    insert into public.jobs (job_number, job_status) values ('T-IX-CASE', p_second);
    raise exception 'ix-allowed';
  exception
    when unique_violation then return 'refused';
    when others then if sqlerrm = 'ix-allowed' then return 'allowed'; end if; raise;
  end;
end $$;

create or replace function pg_temp.ix_flip(p_holder text, p_live text, p_to text) returns text language plpgsql as $$
declare v bigint;
begin
  begin
    insert into public.jobs (job_number, job_status) values ('T-IX-FLIP', p_holder) returning id into v;
    insert into public.jobs (job_number, job_status) values ('T-IX-FLIP', p_live);
    update public.jobs set job_status = p_to where id = v;
    raise exception 'ix-allowed';
  exception
    when unique_violation then return 'refused';
    when others then if sqlerrm = 'ix-allowed' then return 'allowed'; end if; raise;
  end;
end $$;

do $$
declare r text; bad text := ''; v_id bigint; v_created boolean;
begin
  if (select indexdef from pg_indexes where schemaname = 'public' and indexname = 'jobs_active_job_number_uniq')
     <> 'CREATE UNIQUE INDEX jobs_active_job_number_uniq ON public.jobs USING btree (job_number) WHERE ((job_number IS NOT NULL) AND (job_status <> ALL (ARRAY[''archived''::text, ''destroyed''::text])))' then
    raise exception 'verify: unexpected index definition: %', (select indexdef from pg_indexes where indexname = 'jobs_active_job_number_uniq');
  end if;
  r := pg_temp.ix_case('upcoming', 'active');   if r <> 'refused' then bad := bad || ' live+live=' || r; end if;
  r := pg_temp.ix_case('archived', 'upcoming'); if r <> 'allowed' then bad := bad || ' archived+live=' || r; end if;
  r := pg_temp.ix_case('destroyed', 'upcoming'); if r <> 'allowed' then bad := bad || ' destroyed+live=' || r; end if;
  r := pg_temp.ix_case('closed', 'upcoming');   if r <> 'refused' then bad := bad || ' closed+live=' || r; end if;
  r := pg_temp.ix_case(null, 'upcoming');       if r <> 'allowed' then bad := bad || ' null+live=' || r; end if;
  r := pg_temp.ix_flip('archived', 'upcoming', 'destroyed'); if r <> 'allowed' then bad := bad || ' archived->destroyed=' || r; end if;
  r := pg_temp.ix_flip('destroyed', 'upcoming', 'upcoming'); if r <> 'refused' then bad := bad || ' destroyed->live=' || r; end if;
  if bad <> '' then raise exception 'verify: index cases FAILED:%', bad; end if;
  -- through the resolve: a destroyed holder no longer blocks a new live job with its number
  begin
    insert into public.jobs (job_number, job_status) values ('T-IX-RES', 'destroyed');
    select entity_id, was_created into v_id, v_created
      from public.fn_jobber_resolve_job(p_gid => 'Z2lkOi8vSm9iYmVyL0pvYi85OTk5OTk5MDI=', p_job_number => 'T-IX-RES', p_job_status => 'upcoming');
    if not v_created then raise exception 'verify: resolve did not import over a destroyed holder'; end if;
    raise exception 'rb-res';
  exception when others then if sqlerrm <> 'rb-res' then raise; end if;
  end;
  if (select proacl::text from pg_proc where oid = 'public.fn_jobber_resolve_job(text,text,text)'::regprocedure)
     <> '{postgres=X/postgres,service_role=X/postgres}' then
    raise exception 'verify: fn_jobber_resolve_job ACL changed';
  end if;
  if pg_get_functiondef('public.fn_jobber_resolve_job(text,text,text)'::regprocedure) !~ 'Since 2026-09-26_0358 the index is' then
    raise exception 'verify: function comment not updated';
  end if;
  if exists (select 1 from public.jobs where job_number like 'T-IX-%') then raise exception 'verify: a test row persisted'; end if;
end $$;
