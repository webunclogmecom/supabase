-- =====================================================================
-- 2026-08-03_2015  Guard rails for a custom invoice schedule (invoice_rrule)
-- =====================================================================
-- WHY
--   Fred wants the Client App job editor to set "invoice on the 10th of the month",
--   with full parity to Jobber's builder (day / week / day-of-month / nth-weekday /
--   year). The plumbing already exists: jobs_invoice_frequency_chk already permits
--   'custom', and save-client-job already shape-validates a caller-supplied RRULE and
--   forwards it to Jobber as invoicing.recurrence. So the feature itself is a UI change.
--
--   But an audit of the columns found two holes that the feature would make
--   load-bearing, and 'custom' has NEVER been used in production (0 of 1799 jobs), so
--   this path is entirely unexercised.
--
-- HOLE 1 — 'custom' with NO rule is accepted, and renders as an EMPTY schedule.
--   Measured by rolled-back probe: fn_record_client_job accepted
--   invoice_frequency='custom' with invoice_rrule NULL. Nothing errors; the job just
--   claims a custom schedule that says nothing. Now rejected.
--
-- HOLE 2 — invoice_rrule accepted literal junk.
--   Measured: invoice_rrule='NOT-AN-RRULE-AT-ALL' was stored happily. The ONLY shape
--   gate was the TypeScript regex inside save-client-job, so anything arriving by
--   another route (service_role, a backfill script, plain SQL) could persist a value
--   that no consumer can parse. Now shape-checked in the database too.
--
-- SHAPE
--   ^RRULE:FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(;[A-Z]+=[A-Za-z0-9,+-]+)*$
--   Deliberately the SAME pattern save-client-job uses, so the two cannot disagree,
--   and deliberately ESCAPE-FREE (no backslash classes) — per the workspace CLAUDE.md
--   regex lesson, a pattern whose bytes can be mangled in transit is a pattern that
--   silently matches nothing. It admits every shape the new UI can emit:
--     FREQ=DAILY;INTERVAL=3
--     FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE
--     FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=10        <- Fred's case
--     FREQ=MONTHLY;BYMONTHDAY=-1                   <- the 3 existing rows
--     FREQ=MONTHLY;INTERVAL=2;BYDAY=2TU            <- nth weekday
--     FREQ=YEARLY;INTERVAL=1
--
-- ⚠ WHAT THIS DOES NOT GUARD: semantic nonsense that is still well-formed, e.g.
--   BYMONTHDAY=99 or FREQ=DAILY;BYMONTHDAY=10. A CHECK cannot reasonably carry a full
--   RFC 5545 validator. Those are the UI's job and Jobber's job to reject, and the
--   post-mutation verify in save-client-job now asserts the day actually landed by
--   parsing invoiceSchedule.scheduleSummary.
--
-- EXISTING DATA: 3 rows carry invoice_rrule, all 'RRULE:FREQ=MONTHLY;BYMONTHDAY=-1'
--   (jobs 67 / 1782 / 1783), and 0 rows use invoice_frequency='custom'. Both
--   constraints are therefore added VALID, not NOT VALID — asserted below.
--
-- AUDIT OPT-IN (rule #8): no new table; public.jobs is already audited. Unchanged.
-- REVERSIBLE: yes, drop either constraint.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Prove the existing 1799 rows satisfy both rules BEFORE adding them, so the
--    ALTER cannot fail halfway and so neither has to be NOT VALID.
-- ---------------------------------------------------------------------
do $$
declare n_custom_norule int; n_badshape int;
begin
  select count(*) into n_custom_norule from public.jobs
   where invoice_frequency = 'custom' and invoice_rrule is null;
  if n_custom_norule > 0 then
    raise exception 'REFUSING: % job(s) already have invoice_frequency=custom with no rule. Fix the data first.', n_custom_norule;
  end if;

  select count(*) into n_badshape from public.jobs
   where invoice_rrule is not null
     and invoice_rrule !~ '^RRULE:FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(;[A-Z]+=[A-Za-z0-9,+-]+)*$';
  if n_badshape > 0 then
    raise exception 'REFUSING: % existing invoice_rrule value(s) do not match the shape. Inspect before constraining.', n_badshape;
  end if;

  raise notice 'pre-flight OK: 0 custom-without-rule, 0 malformed rrule';
end $$;

-- ---------------------------------------------------------------------
-- 1. A custom schedule must actually carry a rule.
-- ---------------------------------------------------------------------
alter table public.jobs drop constraint if exists jobs_custom_needs_rrule_chk;
alter table public.jobs add constraint jobs_custom_needs_rrule_chk check (
  invoice_frequency is distinct from 'custom' or invoice_rrule is not null
);

-- ---------------------------------------------------------------------
-- 2. An rrule, when present, must be shaped like one.
-- ---------------------------------------------------------------------
alter table public.jobs drop constraint if exists jobs_invoice_rrule_shape_chk;
alter table public.jobs add constraint jobs_invoice_rrule_shape_chk check (
  invoice_rrule is null
  or invoice_rrule ~ '^RRULE:FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(;[A-Z]+=[A-Za-z0-9,+-]+)*$'
);

-- ---------------------------------------------------------------------
-- 3. ASSERTIONS — with live probes, because asserting on the constraint TEXT only
--    proves the text changed, not that it enforces. Every probe runs inside a
--    BEGIN..EXCEPTION block, which establishes an implicit savepoint; raising out of
--    it rolls the write back, so nothing is committed. (Explicit SAVEPOINT is not
--    permitted inside PL/pgSQL.)
-- ---------------------------------------------------------------------
do $$
declare v_job bigint; v_con text; n int;
begin
  select count(*) into n from pg_constraint
   where conname in ('jobs_custom_needs_rrule_chk','jobs_invoice_rrule_shape_chk')
     and convalidated;
  if n <> 2 then raise exception 'expected 2 validated constraints, found %', n; end if;

  select id into v_job from public.jobs where invoice_rrule is null and job_status <> 'archived' limit 1;
  if v_job is null then raise exception 'CONTROL FAILED: no job to probe with'; end if;

  -- (a) the real target shape must be ACCEPTED
  begin
    update public.jobs set invoice_frequency='custom',
           invoice_rrule='RRULE:FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=10' where id=v_job;
    raise exception using errcode='ZZ001', message='ok';
  exception
    when sqlstate 'ZZ001' then null;                      -- accepted, rolled back
    when check_violation then
      get stacked diagnostics v_con = constraint_name;
      raise exception 'CONTROL FAILED: the target rule was rejected by %', v_con;
  end;

  -- (b) nth-weekday and weekly must also be accepted (full Jobber parity)
  begin
    update public.jobs set invoice_frequency='custom',
           invoice_rrule='RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE' where id=v_job;
    raise exception using errcode='ZZ001', message='ok';
  exception
    when sqlstate 'ZZ001' then null;
    when check_violation then raise exception 'CONTROL FAILED: a WEEKLY BYDAY rule was rejected';
  end;
  begin
    update public.jobs set invoice_frequency='custom',
           invoice_rrule='RRULE:FREQ=MONTHLY;INTERVAL=2;BYDAY=2TU' where id=v_job;
    raise exception using errcode='ZZ001', message='ok';
  exception
    when sqlstate 'ZZ001' then null;
    when check_violation then raise exception 'CONTROL FAILED: an nth-weekday rule was rejected';
  end;

  -- (c) NEGATIVE: custom with no rule must now be REJECTED by the right constraint
  begin
    update public.jobs set invoice_frequency='custom', invoice_rrule=null where id=v_job;
    raise exception using errcode='ZZ002', message='custom_without_rule_accepted';
  exception
    when check_violation then
      get stacked diagnostics v_con = constraint_name;
      if v_con is distinct from 'jobs_custom_needs_rrule_chk' then
        raise exception 'CONTROL INVALID: rejected by % instead', v_con;
      end if;
      null;                                               -- expected
    when sqlstate 'ZZ002' then
      raise exception 'CONTROL FAILED: custom with a NULL rule is still accepted';
  end;

  -- (d) NEGATIVE: junk must now be REJECTED by the shape constraint
  begin
    update public.jobs set invoice_rrule='NOT-AN-RRULE-AT-ALL' where id=v_job;
    raise exception using errcode='ZZ003', message='junk_accepted';
  exception
    when check_violation then
      get stacked diagnostics v_con = constraint_name;
      if v_con is distinct from 'jobs_invoice_rrule_shape_chk' then
        raise exception 'CONTROL INVALID: junk rejected by % instead', v_con;
      end if;
      null;                                               -- expected
    when sqlstate 'ZZ003' then
      raise exception 'CONTROL FAILED: a junk invoice_rrule is still accepted';
  end;

  raise notice 'INVOICE RRULE GUARDS OK - target/weekly/nth-weekday accepted, custom-without-rule and junk rejected';
end $$;

commit;
