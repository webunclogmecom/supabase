-- =====================================================================
-- 2026-08-04_1420  billing_type and invoice_frequency must be set together
-- =====================================================================
-- WHY
--   `NULL` on these columns carries meaning: it is "we have never confirmed this
--   job's billing", and the Client App is required to ASK rather than pre-select a
--   guess (Client App CLAUDE.md rule 2c). A HALF-written pair breaks that contract
--   silently: the job looks unconfirmed on one axis and confirmed on the other, so
--   the UI shows a frequency for a job with no billing type.
--
--   Nothing prevented it. Measured by rolled-back probe:
--     update public.jobs set billing_type=null, invoice_frequency='custom' ...
--     -> ACCEPTED, landing billing_type=NULL / invoice_frequency='custom'
--   None of the five existing CHECKs ties the two together: jobs_custom_needs_rrule_chk
--   only enforces custom -> rrule IS NOT NULL.
--
--   The same shape is reachable through fn_record_client_job, which is worse because it
--   looks deliberate: the RPC does nullif(p->>'billing_type',''), so a payload carrying
--   billing_type as an EMPTY STRING writes NULL rather than erroring. A caller that
--   builds the payload from partially-populated variables gets a half pair and no
--   complaint. save-client-job itself is safe (resolveBilling refuses unless both
--   resolve), and backfill_job_billing.js guards with `if (!btype || !bfreq) continue`,
--   but neither guard is in the database, so neither protects the next writer.
--
-- WHAT
--   CHECK ((billing_type IS NULL) = (invoice_frequency IS NULL))
--   Both set, or both absent. Deliberately says nothing about invoice_rrule, which is
--   legitimately NULL for per_visit / once_closed / as_needed and is already governed
--   by jobs_custom_needs_rrule_chk and jobs_invoice_rrule_shape_chk.
--
-- WHY IT CAN GO IN **VALID**, NOT NOT VALID
--   Measured against untouched data BEFORE any probe write (ordering matters - a first
--   attempt at this probe did the half-write first and then blamed the ALTER for the
--   row it had just created itself):
--     existing half-pairs        0
--     rows WITH billing        444   <- exactly the live jobs, after 2026-08-04_1330
--     rows WITHOUT billing    1355   <- archived jobs, all-NULL, still legal
--   and the constraint was proven to bite (half-write REJECTED) while still allowing a
--   full clear (both NULL ACCEPTED), so it cannot block un-confirming a job.
--
-- AUDIT (rule #8): no new table, public.jobs already audited. Unchanged.
-- REVERSIBLE: yes, drop the constraint.
-- =====================================================================

begin;

do $$
declare n int;
begin
  select count(*) into n from public.jobs
   where (billing_type is null) <> (invoice_frequency is null);
  if n > 0 then
    raise exception 'REFUSING: % job(s) already carry a half-written billing pair. Fix the data first.', n;
  end if;
end $$;

alter table public.jobs drop constraint if exists jobs_billing_pair_chk;
alter table public.jobs add constraint jobs_billing_pair_chk
  check ((billing_type is null) = (invoice_frequency is null));

-- ---------------------------------------------------------------------
-- ASSERTIONS. Probing, not just reading pg_constraint: asserting the constraint
-- EXISTS proves the DDL ran, not that it enforces. Each probe runs in a
-- BEGIN..EXCEPTION block (implicit savepoint) and raises to roll itself back.
-- ---------------------------------------------------------------------
do $$
declare v_job bigint; n int;
begin
  select count(*) into n from pg_constraint
   where conname = 'jobs_billing_pair_chk' and convalidated;
  if n <> 1 then raise exception 'constraint missing or not validated'; end if;

  select id into v_job from public.jobs
   where billing_type is not null and job_status <> 'archived' limit 1;
  if v_job is null then raise exception 'CONTROL FAILED: no job with billing to probe with'; end if;

  -- (a) NEGATIVE: a half pair must now be rejected, in BOTH directions
  begin
    update public.jobs set billing_type = null where id = v_job;
    raise exception using errcode='ZZ001', message='half_pair_accepted';
  exception
    when check_violation then null;                       -- expected
    when sqlstate 'ZZ001' then
      raise exception 'CONTROL FAILED: clearing billing_type alone is still accepted';
  end;
  begin
    update public.jobs set invoice_frequency = null where id = v_job;
    raise exception using errcode='ZZ002', message='half_pair_accepted';
  exception
    when check_violation then null;                       -- expected
    when sqlstate 'ZZ002' then
      raise exception 'CONTROL FAILED: clearing invoice_frequency alone is still accepted';
  end;

  -- (b) POSITIVE: clearing BOTH must still work, or we have blocked un-confirming a job
  begin
    update public.jobs set billing_type = null, invoice_frequency = null, invoice_rrule = null
     where id = v_job;
    raise exception using errcode='ZZ003', message='ok';
  exception
    when sqlstate 'ZZ003' then null;                      -- accepted, rolled back
    when check_violation then
      raise exception 'CONTROL FAILED: clearing the whole pair is rejected - too strict';
  end;

  -- (c) POSITIVE: a normal full write must still work
  begin
    update public.jobs set billing_type='visit_based', invoice_frequency='per_visit', invoice_rrule=null
     where id = v_job;
    raise exception using errcode='ZZ004', message='ok';
  exception
    when sqlstate 'ZZ004' then null;
    when check_violation then
      raise exception 'CONTROL FAILED: a normal full billing write is rejected';
  end;

  raise notice 'BILLING PAIR CHK OK - half pairs rejected both ways, full write and full clear still allowed';
end $$;

commit;
