-- ============================================================================
-- 2026-09-26_0313 · fn_jobber_resolve_job carries Jobber's status, so a recycled job number refuses INSIDE
-- ============================================================================
-- FOUND by the adversarial review of webhook-jobber v121 (Supabase e7cc440), which routed JOB_CLOSED
-- through handleJob and so added an entry point to this function.
--
-- THE DEFECT. The function's own comment (2026-09-09_1230) says it writes job_number into the shell so
-- that a jobs_active_job_number_uniq refusal fires INSIDE its transaction and the shell + its
-- entity_source_links row roll back together (Jobber RECYCLES job numbers: 99901013 on 1768/1769,
-- 99901068 on 1850/1851). It cannot: the index is
--     UNIQUE (job_number) WHERE job_number IS NOT NULL AND job_status <> 'archived'
-- and the shell is inserted with job_status NULL (no column default), so (NULL <> 'archived') is NULL and
-- the shell is never in the index. The refusal fires in handleJob's NEXT request (the UPDATE that sets
-- job_status), after the shell and link have committed: a linked, NULL-status job that every later
-- delivery resolves onto (fast path) and fails again, until the conflicting live job leaves the index.
--
-- THE FIX. A third parameter, p_job_status (default NULL), and the shell carries it. handleJob passes
-- Jobber's jobStatus (webhook-jobber v123), so a live recycled number now refuses here with 23505 and
-- nothing is left behind, while an ARCHIVED import of a recycled number still succeeds, exactly as the
-- index intends. A status-blind pre-check was rejected for that reason: it would refuse that legitimate
-- archived import. NULL (any caller not passing it) keeps the old behaviour byte for byte. The fast path
-- (gid already linked) is unchanged and ignores p_job_status.
--
-- BODY: copied from pg_get_functiondef and edited mechanically (two exact replacements, each asserted to
-- match once): the signature, and the shell INSERT plus a correcting comment. The other 63 lines are
-- identical. Adding a parameter makes a new signature, and CREATE OR REPLACE would leave an ambiguous
-- overload, so the (text, text) version is dropped in this same transaction. The deployed webhook-jobber
-- v122 passes {p_gid, p_job_number} by name, which resolves to the new function through the default.
--
-- PROOF before applying (rolled back; scripts/probes/resolve_job_number_guard/): with the OLD body as a
-- control, an unknown gid carrying the live recycled number 99901068 left 1 linked NULL-status job after
-- the caller's UPDATE hit 23505; the NEW body raised 23505 inside and left 0 rows, 0 links. Mutation
-- check: pointing that case at the old body fails it ("did not raise 23505").
-- CENSUS 2026-09-26 03:05 ET: 0 jobs with job_status NULL; the only real 23505 on record (363445,
-- 2026-09-08 20:15 ET) predates the atomic resolve (applied 2026-09-09 12:39 ET).
--
-- ⚠ ADDED AFTER REVIEW (the executable part of this file is unchanged):
--   * "A live recycled number" includes a holder in 'destroyed' or 'closed': the index excludes only
--     'archived', so those still hold the number and the new job is refused (now cleanly). Jobber reuses a
--     number after DELETING the job that held it (the originals of both 99901013 and 99901068 are gone in
--     Jobber), and JOB_DESTROY writes 'destroyed'. It heals: every row ever set to 'destroyed' (8 of 8) was
--     moved to 'archived' by sync-jobber-job-drift's gone arm 20 to 40 minutes later, after which a later
--     sync-jobber-poll replay (needs_populate stays TRUE on a failed replay) imports the job. Visits that
--     arrive for it in that window keep job_id NULL (inferred; never observed). Narrowing the index to
--     NOT IN ('archived','destroyed','closed') would remove the delay; not done here, it is a decision.
--   * A status-AWARE pre-check was also possible; it was not chosen because it would restate the index
--     predicate in a second place. Inserting the status lets the index stay the single rule.
--   * This file has no BEGIN/COMMIT: it was applied as ONE query through the Management API, which runs it
--     in one implicit transaction. Replaying it with psql needs -1 (--single-transaction), or the DROP
--     could commit alone.
--
-- RULE 8: no table change; public.jobs stays audited. GRANTS: service_role only, revoked BY NAME (a new
-- function in public gets EXECUTE for authenticated by default).
-- ROLLBACK: redeploy webhook-jobber v122 first, then drop function public.fn_jobber_resolve_job(text, text, text),
--           re-create the 2026-09-09_1230 body AND its revoke/grant lines (a re-created function in public
--           gets EXECUTE for authenticated again by default).
-- ============================================================================

drop function public.fn_jobber_resolve_job(text, text);

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

revoke all on function public.fn_jobber_resolve_job(text, text, text) from public, anon, authenticated;
grant execute on function public.fn_jobber_resolve_job(text, text, text) to service_role;
notify pgrst, 'reload schema';

-- VERIFY (every probe below is rolled back through a subtransaction sentinel)
do $$
declare v_id bigint; v_created boolean; v_ok boolean; g text := 'Z2lkOi8vSm9iYmVyL0pvYi85OTk5OTk5MDE=';  -- gid://Jobber/Job/999999901, fake
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'fn_jobber_resolve_job') <> 1 then
    raise exception 'verify: expected exactly one fn_jobber_resolve_job';
  end if;
  if not (select prosecdef from pg_proc where oid = 'public.fn_jobber_resolve_job(text,text,text)'::regprocedure) then
    raise exception 'verify: not SECURITY DEFINER';
  end if;
  if has_function_privilege('authenticated', 'public.fn_jobber_resolve_job(text,text,text)', 'execute')
     or has_function_privilege('anon', 'public.fn_jobber_resolve_job(text,text,text)', 'execute')
     or not has_function_privilege('service_role', 'public.fn_jobber_resolve_job(text,text,text)', 'execute') then
    raise exception 'verify: grants are not service_role only';
  end if;
  -- a live recycled number refuses inside, nothing left behind
  v_ok := false;
  begin
    perform * from public.fn_jobber_resolve_job(p_gid => g, p_job_number => '99901068', p_job_status => 'upcoming');
  exception when unique_violation then v_ok := true;
  end;
  if not v_ok then raise exception 'verify: a live recycled number did not refuse inside'; end if;
  if (select count(*) from public.entity_source_links where source_id = g) <> 0 then raise exception 'verify: link left behind'; end if;
  -- the two-argument named call the deployed webhook makes still resolves (NULL status, old behaviour)
  begin
    select entity_id, was_created into v_id, v_created from public.fn_jobber_resolve_job(p_gid => g, p_job_number => '99901068');
    if not v_created or (select job_status from public.jobs where id = v_id) is not null then raise exception 'verify: 2-arg call changed'; end if;
    raise exception 'rb-a';
  exception when others then if sqlerrm <> 'rb-a' then raise; end if;
  end;
  -- an archived import of a recycled number still succeeds
  begin
    select entity_id, was_created into v_id, v_created from public.fn_jobber_resolve_job(p_gid => g, p_job_number => '99901068', p_job_status => 'archived');
    if not v_created or (select job_status from public.jobs where id = v_id) is distinct from 'archived' then raise exception 'verify: archived import failed'; end if;
    raise exception 'rb-b';
  exception when others then if sqlerrm <> 'rb-b' then raise; end if;
  end;
  -- the fast path is unchanged
  select entity_id, was_created into v_id, v_created
    from public.fn_jobber_resolve_job(p_gid => 'Z2lkOi8vSm9iYmVyL0pvYi8xNDY2NTAxNDI=', p_job_number => '11100534', p_job_status => 'upcoming');
  if v_id <> 765 or v_created then raise exception 'verify: fast path changed'; end if;
end $$;
