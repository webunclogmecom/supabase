CREATE FUNCTION pg_temp.resolve_old(p_gid text, p_job_number text DEFAULT NULL::text)
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
  insert into public.jobs (job_number) values (p_job_number) returning id into v_id;

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
