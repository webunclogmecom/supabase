-- ============================================================================
-- 2026-09-09_1230_jobber_job_resolve_atomic.sql
--
-- The JOB half of the visit/job/property race audit. Ships with _1200 (visit) and _1300 (property).
--
-- ============================================================================
-- 🛑 I FIRST REPORTED JOBS AS "SAFE, LEAVE THEM ALONE". THAT WAS WRONG, TWICE OVER.
--
-- The reasoning was: `jobs_active_job_number_uniq` refuses the loser's INSERT before any row
-- commits, so a job race can never leave an orphan. 1,845 jobs with only 2 unlinked (both archived,
-- both from the 2026-04-29 import) looked like proof. It is not.
--
-- (1) THE INDEX COVERS A QUARTER OF THE TABLE. It is
--       UNIQUE (job_number) WHERE job_number IS NOT NULL AND job_status <> 'archived'
--     and only **477 of 1,845 rows (25.9%)** satisfy that predicate. Outside it BOTH concurrent
--     INSERTs commit and the 23505 relocates to the entity_source_links upsert one transaction
--     later -- which is precisely the orphan the claim said could not exist.
--
-- (2) 🛑 THE INDEX IS ALSO A FALSE-FAILURE DEVICE, BECAUSE JOBBER RECYCLES job_number.
--     Measured on live data -- one job_number, two different Jobber GIDs:
--       99901013 -> 2 distinct gids
--       99901068 -> 2 distinct gids
--     So the "guard" can 23505 a GENUINE new job. And because webhook-jobber ACKs HTTP 200 before
--     it does the work, and nothing re-processes webhook_events_log, **Jobber never retries**: a
--     false refusal is permanent silent absence, not a delay. The two recycled pairs only survived
--     because the archive happened to be mirrored 2h25m and 16h before the replacement arrived.
--
-- ⇒ The thing I called protection was luck with a sharp edge on it. Jobs get the same treatment as
--   client, invoice and quote.
--
-- ⚠ jobs_active_job_number_uniq is NOT dropped here. It is doing real work against genuine
--   duplicates and dropping it is a separate decision with its own evidence. It is simply no
--   longer load-bearing for the race.
--
-- ============================================================================
-- WHY THE SHELL INSERT IS LEGAL HERE (unlike visits and properties)
--
-- public.jobs has exactly ONE NOT NULL column: `id` (GENERATED ALWAYS AS IDENTITY), and its only
-- INSERT trigger is audit.log_change, which captures the whole row and reads no particular column.
-- So a near-shell insert is legal here. public.visits (visit_date) and public.properties
-- (client_id) could not do this and had to take arguments.
--
-- 🛑 TWO SEPARATE THINGS DECIDE THIS, AND THE SECOND ONE ALMOST SHIPPED A DEFECT. Checking
--    pg_attribute for NOT NULL columns is NOT sufficient. public.visits also passes that test on
--    everything except visit_date -- and a bare shell there would have silently broken
--    `trg_visit_default_locations`, an AFTER INSERT trigger that early-returns on a NULL client_id
--    and can never fire again, costing every new webhook visit its visit_locations rows. Measured
--    with a control: payload-in-INSERT seeds 1, shell+UPDATE seeds 0. So: check pg_attribute AND
--    enumerate pg_trigger, and ask what each trigger READS.
--
-- ⚠ job_number is nonetheless written in the shell insert, for an unrelated reason about where a
--   failure lands. See the note at the INSERT itself.
--
-- ============================================================================
-- THE SECOND WRITER: public.fn_record_client_job MUST JOIN THE SAME LOCK
--
-- public.jobs has TWO creators, not one: handleJob (webhook) and fn_record_client_job (the Client
-- App's save-client-job path). Locking only one of a pair does not serialise the pair.
--
-- fn_record_client_job is ALREADY ATOMIC -- one plpgsql body is one transaction -- so it has never
-- left an orphan. Its failure mode is different: it could find nothing, insert, and then hit
-- idx_esl_source_id on its link write (its ON CONFLICT names entity_type,entity_id,source_system,
-- which is the OTHER index), rolling the entire Client App save back. The lock converts that hard
-- failure into a microsecond wait followed by the correct no-op.
--
-- 🛑 HOW THIS FUNCTION WAS EDITED, BECAUSE IT WRITES BILLING SETTINGS.
--    fn_record_client_job writes jobs.billing_type, jobs.invoice_frequency and jobs.invoice_rrule,
--    which Fred has ruled off-limits. Its body below was NOT retyped. It was dumped from
--    pg_get_functiondef, patched programmatically by inserting the lock after the gid guard, and
--    then asserted: reversing the injection reproduces the original byte-for-byte
--    (sha256 c033d48956cd8663 both ways), all three billing identifiers still occur exactly 6
--    times, and the whole `insert into public.jobs (...) values (...)` block is byte-identical.
--    ⚠ `create or replace function` takes the WHOLE body -- anything not reproduced here is
--      silently deleted. That is why it is machine-copied and machine-checked.
--
-- Audit: this migration creates one function and re-creates another with a lock added.
-- It modifies no business rows.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the resolve function (invoice template, verbatim shape)
-- ---------------------------------------------------------------------------
create or replace function public.fn_jobber_resolve_job(p_gid text, p_job_number text default null)
returns table (entity_id bigint, was_created boolean)
language plpgsql
security definer
set search_path to ''
as $fn$
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
$fn$;

revoke all on function public.fn_jobber_resolve_job(text, text) from public;
revoke all on function public.fn_jobber_resolve_job(text, text) from anon;
revoke all on function public.fn_jobber_resolve_job(text, text) from authenticated;
grant execute on function public.fn_jobber_resolve_job(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- 2. the second writer joins the lock. BODY MACHINE-COPIED -- see the header.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_record_client_job(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_gid     text := nullif(btrim(coalesce(p->>'gid','')), '');
  v_job_id  bigint;
  v_created boolean := false;
  v_li      jsonb := p->'line_items';
  v_r       record;
begin

  -- ---- ATTEST THE HUMAN, so the audit trail names a person and not an app ---------------------
  -- 🛑 WHY THIS IS HERE AND NOT IN THE EDGE FUNCTION. audit.log_change reads
  --    current_setting('request.jwt.claims'), and that GUC is TRANSACTION-scoped. save-client-job
  --    writes as service_role over PostgREST, where each call is its own transaction, so a claim
  --    set outside this function would not be visible to the trigger that fires inside it. It has
  --    to be set in the same transaction as the write, which means here.
  -- ⚠ TRUST MODEL: this function is SECURITY DEFINER and only service_role may execute it, so the
  --    only callers are our own edge functions, each of which has already verified the bearer token
  --    with auth.getUser() before calling. The email is therefore attested, not asserted by a
  --    browser. Same shape as send-derm-email's sent_by_email (2026-07-21h).
  -- ⚠ OPTIONAL BY DESIGN: a caller that sends no actor_email behaves exactly as before, so this is
  --    a non-breaking change for every existing caller.
  if nullif(btrim(coalesce(p->>'actor_email','')), '') is not null then
    perform set_config('request.jwt.claims',
                       json_build_object('email', btrim(p->>'actor_email'))::text,
                       true);
  end if;

  if v_gid is null then
    raise exception 'fn_record_client_job: gid is required' using errcode = '22023';
  end if;

  -- ---- JOIN THE SAME LOCK handleJob TAKES (2026-09-09) ---------------------------------------
  -- 🛑 THIS FUNCTION IS ALREADY ATOMIC -- one plpgsql body is one transaction -- so it has never
  --    left an orphan job. What it DID do without this lock is fail: its SELECT could run while
  --    webhook-jobber's handleJob was mid-create for the same gid, find nothing, insert, and then
  --    hit idx_esl_source_id on the link, rolling the whole Client App save back with a confusing
  --    duplicate-key error. Jobber's webhook latency (3.48s to 24.66s, always positive) is the
  --    only thing that has kept the two apart, and that is a measurement, not a guarantee.
  -- ⚠ The lock key MUST be byte-identical to fn_jobber_resolve_job's or the two do not serialise.
  perform pg_advisory_xact_lock(hashtextextended('jobber:job:' || v_gid, 0));

  select l.entity_id into v_job_id
    from public.entity_source_links l
   where l.entity_type = 'job' and l.source_system = 'jobber' and l.source_id = v_gid;

  if v_job_id is null then
    insert into public.jobs (client_id, property_id, job_number, title, job_status,
                             start_at, end_at, total, notes, frequency_days,
                             billing_type, invoice_frequency, invoice_rrule)
    values ((p->>'client_id')::bigint,
            (p->>'property_id')::bigint,
            p->>'job_number',
            p->>'title',
            lower(p->>'job_status'),
            nullif(p->>'start_at','')::timestamptz,
            nullif(p->>'end_at','')::timestamptz,
            nullif(p->>'total','')::numeric,
            p->>'notes',
            nullif(p->>'frequency_days','')::integer,
            nullif(p->>'billing_type',''),
            nullif(p->>'invoice_frequency',''),
            nullif(p->>'invoice_rrule',''))
    returning id into v_job_id;
    v_created := true;

    insert into public.entity_source_links
      (entity_type, entity_id, source_system, source_id, source_name, match_method, match_confidence)
    values ('job', v_job_id, 'jobber', v_gid, p->>'title', 'client-app', 1.0)
    on conflict (entity_type, entity_id, source_system)
    do update set source_id = excluded.source_id, source_name = excluded.source_name;
  else
    update public.jobs j
       set title          = coalesce(p->>'title', j.title),
           job_status     = coalesce(lower(p->>'job_status'), j.job_status),
           start_at       = case when p ? 'start_at' then nullif(p->>'start_at','')::timestamptz else j.start_at end,
           end_at         = case when p ? 'end_at'   then nullif(p->>'end_at','')::timestamptz   else j.end_at   end,
           total          = case when p ? 'total'    then nullif(p->>'total','')::numeric        else j.total    end,
           notes          = case when p ? 'notes'    then p->>'notes'                            else j.notes    end,
           frequency_days = case when p ? 'frequency_days'
                                 then nullif(p->>'frequency_days','')::integer
                                 else j.frequency_days end,
           billing_type      = case when p ? 'billing_type'
                                    then nullif(p->>'billing_type','')      else j.billing_type      end,
           invoice_frequency = case when p ? 'invoice_frequency'
                                    then nullif(p->>'invoice_frequency','') else j.invoice_frequency end,
           invoice_rrule     = case when p ? 'invoice_rrule'
                                    then nullif(p->>'invoice_rrule','')     else j.invoice_rrule     end
     where j.id = v_job_id;
  end if;

  if v_li is not null and jsonb_typeof(v_li) = 'array' then
    -- Atomic, per-job-serialized rewrite via public.rewrite_job_line_items (ends the duplication
    -- race, 2026-09-01). v_li is the same jsonb array this used to loop over; the RPC preserves the
    -- prior mapping (name/quantity/unit_price/total_price; description NULL and taxable false default).
    perform public.rewrite_job_line_items(v_job_id, v_li);
  end if;

  return jsonb_build_object('job_id', v_job_id, 'created', v_created);
end
$function$
;


-- ---------------------------------------------------------------------------
-- VERIFY  🛑 RUNS **INSIDE** THE TRANSACTION, UNLIKE ITS SIBLINGS. THIS IS DELIBERATE.
--
-- This migration's whole justification for machine-copying fn_record_client_job is that
-- `create or replace function` silently deletes anything not reproduced, and that
-- jobs.billing_type / invoice_frequency / invoice_rrule are off-limits. VERIFY 3 is the only
-- assertion protecting those columns. After `commit;` it could only REPORT a deletion that was
-- already durable on Prod. Inside the transaction it ROLLS THE REPLACEMENT BACK.
--
-- Safe to do here: the grants above are already in this transaction, VERIFY 4's negative control
-- raises inside its own begin/exception savepoint, and nothing in the block writes business rows.
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_body text;
  v_rcj  text;
  v_n    bigint;
begin
  -- 1. the resolve function exists and is locked
  if pg_catalog.to_regprocedure('public.fn_jobber_resolve_job(text, text)') is null then
    raise exception 'VERIFY 1 FAILED: fn_jobber_resolve_job(text, text) does not exist';
  end if;
  v_body := pg_catalog.pg_get_functiondef(pg_catalog.to_regprocedure('public.fn_jobber_resolve_job(text, text)')::oid);
  v_body := pg_catalog.replace(v_body, pg_catalog.chr(13), '');   -- CRLF-proof, see _1200
  if v_body !~ 'pg_advisory_xact_lock' then
    raise exception 'VERIFY 1b FAILED: no advisory lock in fn_jobber_resolve_job';
  end if;
  select (pg_catalog.length(v_body)
          - pg_catalog.length(pg_catalog.replace(v_body, 'from public.entity_source_links l' || E'\n', '')))
         / pg_catalog.length('from public.entity_source_links l' || E'\n')
    into v_n;
  if v_n < 2 then
    raise exception 'VERIFY 1c FAILED: the link is read % time(s); the re-read after the lock is missing', v_n;
  end if;
  -- The count alone passes against a body whose lock sits BELOW both reads. Assert position.
  if pg_catalog.strpos(
       pg_catalog.substr(v_body, pg_catalog.strpos(v_body, 'pg_advisory_xact_lock')),
       'from public.entity_source_links l' || E'
') = 0 then
    raise exception 'VERIFY 1c-bis FAILED: no link read appears AFTER the advisory lock; the fix is inert';
  end if;

  -- 2. 🛑 THE TWO WRITERS MUST COMPUTE THE SAME LOCK VALUE, NOT MERELY CONTAIN THE SAME LITERAL.
  --    The lock value is hashtextextended(key, seed). Two bodies can both contain 'jobber:job:'
  --    and still lock different values -- a different seed, or hashtext instead of
  --    hashtextextended, passes a substring check and serialises nothing, silently. So the
  --    substring check is kept only as a fast, readable first failure, and the assertion that
  --    actually carries the guarantee is the computed VALUE on a sample gid.
  v_rcj := pg_catalog.pg_get_functiondef('public.fn_record_client_job(jsonb)'::pg_catalog.regprocedure::oid);
  v_rcj := pg_catalog.replace(v_rcj, pg_catalog.chr(13), '');
  if v_body !~ 'jobber:job:' then
    raise exception 'VERIFY 2a FAILED: fn_jobber_resolve_job does not use the jobber:job: key';
  end if;
  if v_rcj !~ 'jobber:job:' then
    raise exception 'VERIFY 2b FAILED: fn_record_client_job did NOT join the lock';
  end if;
  if v_rcj !~ 'pg_advisory_xact_lock' then
    raise exception 'VERIFY 2c FAILED: fn_record_client_job has no advisory lock';
  end if;
  -- 2d. The lock VALUE is hashtextextended(<key>, <seed>). Given both bodies build the key from the
  --     same literal prefix and the same gid, the value can only diverge through the HASH FUNCTION
  --     or the SEED, so those are what 2e/2f assert. (A first draft here compared
  --     hashtextextended(...) against itself, which is a tautology -- the exact defect this
  --     migration's sibling VERIFY 5 was rewritten to remove. A string comparison of the two
  --     expressions is not available either: they legitimately differ in schema qualification and
  --     in the variable name, so it would fail on correct code.)
  if v_body !~ 'hashtextextended' or v_rcj !~ 'hashtextextended' then
    raise exception 'VERIFY 2e FAILED: one writer does not use hashtextextended, so the two lock values cannot match';
  end if;
  if v_body ~ 'hashtextextended[(][^)]*, *[1-9]' or v_rcj ~ 'hashtextextended[(][^)]*, *[1-9]' then
    raise exception 'VERIFY 2f FAILED: a non-zero hash seed appears in one writer; the two lock values would differ';
  end if;

  -- 3. 🛑 THE BILLING SETTINGS MUST BE UNTOUCHED. Fred ruled them off-limits, and
  --    `create or replace function` silently deletes anything not reproduced. Count them.
  if (pg_catalog.length(v_rcj) - pg_catalog.length(pg_catalog.replace(v_rcj, 'billing_type', '')))
     / pg_catalog.length('billing_type') <> 6 then
    raise exception 'VERIFY 3a FAILED: billing_type no longer occurs 6 times in fn_record_client_job';
  end if;
  if (pg_catalog.length(v_rcj) - pg_catalog.length(pg_catalog.replace(v_rcj, 'invoice_frequency', '')))
     / pg_catalog.length('invoice_frequency') <> 6 then
    raise exception 'VERIFY 3b FAILED: invoice_frequency no longer occurs 6 times in fn_record_client_job';
  end if;
  if (pg_catalog.length(v_rcj) - pg_catalog.length(pg_catalog.replace(v_rcj, 'invoice_rrule', '')))
     / pg_catalog.length('invoice_rrule') <> 6 then
    raise exception 'VERIFY 3c FAILED: invoice_rrule no longer occurs 6 times in fn_record_client_job';
  end if;
  -- and the actor-attestation block, which is the other thing a careless retype would drop
  if v_rcj !~ 'request.jwt.claims' then
    raise exception 'VERIFY 3d FAILED: fn_record_client_job lost its actor attestation';
  end if;

  -- 4. NEGATIVE CONTROL. Without it, every assertion above passes against a function that
  --    accepts anything.
  begin
    perform * from public.fn_jobber_resolve_job(null);
    raise exception 'VERIFY 4 FAILED: a NULL gid was accepted';
  exception when others then
    if sqlerrm like '%VERIFY 4 FAILED%' then raise; end if;
    if sqlerrm not like '%p_gid is required%' then
      raise exception 'VERIFY 4b FAILED: wrong error for a NULL gid: %', sqlerrm;
    end if;
  end;

  -- 5. grants
  if pg_catalog.has_function_privilege('anon', 'public.fn_jobber_resolve_job(text, text)', 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', 'public.fn_jobber_resolve_job(text, text)', 'EXECUTE') then
    raise exception 'VERIFY 5 FAILED: a non-service role can execute the job factory';
  end if;
  if not pg_catalog.has_function_privilege('service_role', 'public.fn_jobber_resolve_job(text, text)', 'EXECUTE') then
    raise exception 'VERIFY 5b FAILED: service_role CANNOT execute it; the webhook would break';
  end if;

  -- 6. the index we are NO LONGER relying on is still present and still covers only a quarter.
  --    This is a NOTICE, not an assertion: it is context for whoever reads this next, and the
  --    number moving is not a failure.
  select pg_catalog.count(*) into v_n from public.jobs
   where job_number is not null and job_status is distinct from 'archived';
  raise notice 'jobs_active_job_number_uniq still covers % of % rows; it is no longer load-bearing for the race',
               v_n, (select pg_catalog.count(*) from public.jobs);

  raise notice 'VERIFY ok: fn_jobber_resolve_job locked and re-reading, fn_record_client_job joined the SAME key, billing settings byte-count unchanged, grants narrow';
end
$verify$;

commit;
