-- =====================================================================
-- 2026-08-04_1330  Backfill job billing from Jobber (the 25 NULL rows)
-- =====================================================================
-- WHY
--   Jobber held 28 recurring invoice schedules; public.jobs recorded 4. The gap is
--   25 live jobs whose billing_type / invoice_frequency / invoice_rrule are all NULL,
--   mostly TCE warranty agreements invoiced "every 2 months on the 22nd". They were
--   left NULL deliberately: the old invoice_frequency vocabulary could not express a
--   day-of-month rule, so backfill_job_billing.js skipped them rather than store a
--   guess that could shift an invoice date.
--
--   That constraint is gone. 'custom' + invoice_rrule expresses them exactly, and
--   Job.invoiceSchedule.recurrenceSchedule.calendarRule returns the rule VERBATIM, so
--   this backfill copies Jobber's own value rather than inferring one.
--
-- SOURCE OF TRUTH
--   A live read of all 444 non-archived jobs: Job.billingType + Job.invoiceSchedule
--   { billingFrequency, scheduleSummary, recurrenceSchedule { calendarRule } },
--   Jobber GraphQL 2026-04-16. 444 read, 0 unlinked, 0 failed, 0 unmappable.
--   Jobber is 100% canonical for billing (rule #4), so its value wins by definition.
--
-- MAPPING (the full enum, not only the cases present here)
--   billingType   FIXED_PRICE -> fixed          VISIT_BASED -> visit_based
--   billingFrequency
--     PER_VISIT     -> per_visit          ON_COMPLETION -> once_closed
--     NEVER         -> as_needed
--     PERIODIC      -> monthly_last_day   iff the rule is exactly
--                                         FREQ=MONTHLY;BYMONTHDAY=-1
--                   -> custom             otherwise, storing 'RRULE:' || calendarRule
--   Jobber omits the RRULE: prefix on read and drops a redundant INTERVAL=1; we store
--   its canonical form, so our value and theirs stay byte-comparable for drift checks.
--
-- WHAT LANDS (25 rows)
--   22  fixed       / custom    / RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22
--    1  visit_based / custom    / RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22   169-TCE
--    1  fixed       / custom    / RRULE:FREQ=MONTHLY;BYMONTHDAY=18              031-KRU
--    1  visit_based / per_visit / NULL                                          job 99901050
--
-- SAFETY
--   * Every target is currently all-three-NULL, verified at generation time AND
--     re-checked in the UPDATE's WHERE clause, so this only ever FILLS BLANKS. It can
--     never overwrite a value someone else confirmed, and re-running it is a no-op.
--   * No existing non-NULL billing value in the table disagrees with Jobber, so there
--     is nothing to reconcile beyond these 25.
--   * public.jobs carries exactly TWO triggers (generated from pg_trigger, not a
--     hand-list): audit_jobs and trg_jobs_updated_at. NEITHER pushes to Jobber, and
--     there is no outbound push/queue table on this table. So this write CANNOT ripple
--     back into Jobber. Direction matters: this pulls FROM Jobber, and routing it
--     through save-client-job (which pushes) would have been wrong.
--   * Only TWO objects in the whole database read these columns: fn_record_client_job
--     (the writer) and the passthrough view client.jobs. No view or function does money
--     math on them, so no revenue or projection figure moves. (The sweep carried a
--     positive control: the same query finds 18 views + 9 functions for frequency_days.)
--   * Both CHECK constraints apply: jobs_custom_needs_rrule_chk (custom needs a rule)
--     and jobs_invoice_rrule_shape_chk. Every value below satisfies them, asserted.
--
-- AUDIT (rule #8): public.jobs is already audited; these 25 UPDATEs land in audit.logs
--   with app_source='sql'. No new table, no trigger change. Opt-in unchanged.
-- REVERSIBLE: yes. Set the three columns back to NULL for these 25 ids
--   (audit.logs.old_row holds the pre-state either way).
--
-- 🛑 ADDENDUM (added post-apply, same day, from an adversarial review of this file)
--   THIS MAPPING IS A ONE-SHOT BACKFILL. NEVER WIRE IT INTO A RECONCILER, AND NEVER
--   RE-RUN IT OVER ROWS WHERE billing_type IS NOT NULL.
--
--   The rule -> frequency direction is NOT injective. 'RRULE:FREQ=MONTHLY;BYMONTHDAY=-1'
--   has TWO legal encodings that are byte-identical:
--     invoice_frequency='monthly_last_day'  - resolveBilling hard-codes exactly that
--                                             string (save-client-job index.ts ~209)
--     invoice_frequency='custom'            - the Client App's custom builder emits the
--                                             same string from Month / "On a date" /
--                                             "Last day" at interval 1 (INTERVAL=1 is
--                                             omitted, so the strings match exactly)
--   The second encoding did not exist before the custom-schedule builder shipped
--   earlier the same day, which is why this was safe to write now and would not be
--   safe to re-run later. A reconciler applying this mapping to a non-NULL row would
--   silently relabel a user who deliberately chose "Last day" INSIDE the custom builder
--   from 'custom' to 'monthly_last_day'. Both produce the same Jobber state, so nothing
--   would error and no invoice would move - only the control the dialog shows selected
--   would change under the user, with no record that we did it.
--
--   ⇒ invoice_frequency is NOT derivable from invoice_rrule. Both columns are the
--     record, which is why both are stored rather than one computed from the other.
--   ⇒ Applying this to billing_type IS NULL rows only, as it does, is unambiguous:
--     a NULL row has no user intent to overwrite.
-- =====================================================================

begin;

create temp table _bf(job_id bigint primary key, billing_type text, invoice_frequency text, invoice_rrule text) on commit drop;

insert into _bf(job_id, billing_type, invoice_frequency, invoice_rrule) values
  (100, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (111, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (112, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (113, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (114, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (115, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (116, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (117, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (118, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (119, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (120, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (121, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (122, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (123, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (124, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (125, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (126, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (127, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (128, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (129, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (392, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (500, 'visit_based', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (1765, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22'),
  (1777, 'fixed', 'custom', 'RRULE:FREQ=MONTHLY;BYMONTHDAY=18'),
  (1814, 'visit_based', 'per_visit', null);

-- ---------------------------------------------------------------------
-- 0. PRE-FLIGHT. Refuse rather than half-apply.
-- ---------------------------------------------------------------------
do $$
declare n_missing int; n_dirty int; n int;
begin
  select count(*) into n from _bf;
  if n <> 25 then raise exception 'expected 25 backfill rows, got %', n; end if;

  select count(*) into n_missing from _bf b
   where not exists (select 1 from public.jobs j where j.id=b.job_id and j.job_status <> 'archived');
  if n_missing > 0 then
    raise exception 'REFUSING: % target job(s) no longer exist or were archived since the Jobber read', n_missing;
  end if;

  -- The whole safety story: every target must still be a blank row.
  select count(*) into n_dirty from _bf b join public.jobs j on j.id=b.job_id
   where j.billing_type is not null or j.invoice_frequency is not null or j.invoice_rrule is not null;
  if n_dirty > 0 then
    raise exception 'REFUSING: % target(s) already carry billing values, so someone confirmed them since the read. Re-run the reconcile.', n_dirty;
  end if;
  raise notice 'pre-flight OK: 25 targets, all present, all blank';
end $$;

-- ---------------------------------------------------------------------
-- 1. Fill the blanks, and ASSERT ON THE ROW COUNT.
--
--    ⚠ The row count is the assertion that matters here, which is why the UPDATE is
--    wrapped rather than run bare. An earlier version of this migration instead
--    asserted, after the fact, that public.jobs matched _bf column by column. That was
--    a TAUTOLOGY: the UPDATE copies _bf into the table, so the comparison could never
--    fail. Proven by mutation - corrupting job 100's expected billing_type in _bf still
--    passed, because the corrupt value was simply written and then found. A check that
--    cannot fail is not a check.
--
--    The WHERE clause repeats the all-NULL guard so the statement is idempotent and
--    cannot clobber a concurrent confirmation. That also means a silent no-op is a real
--    possible outcome (if another writer filled these rows between pre-flight and here),
--    and the row count is what catches it.
--
--    ⚠ WHAT THIS FILE CANNOT PROVE: that the stored values match JOBBER. SQL has no
--    access to Jobber, so agreement is verified OUT OF BAND by re-running the
--    reconciliation (scratchpad/recon.mjs) after commit and asserting 0 diffs across all
--    444 live jobs. Do not read the assertions below as evidence of that.
-- ---------------------------------------------------------------------
do $$
declare n_updated int;
begin
  update public.jobs j
     set billing_type      = b.billing_type,
         invoice_frequency = b.invoice_frequency,
         invoice_rrule     = b.invoice_rrule
    from _bf b
   where j.id = b.job_id
     and j.billing_type is null
     and j.invoice_frequency is null
     and j.invoice_rrule is null;
  get diagnostics n_updated = row_count;
  if n_updated <> 25 then
    raise exception 'expected to fill 25 rows, filled % - aborting rather than half-applying', n_updated;
  end if;
  raise notice 'filled % rows', n_updated;
end $$;

-- ---------------------------------------------------------------------
-- 2. ASSERTIONS (each one able to fail; mutation-tested)
-- ---------------------------------------------------------------------
do $$
declare n_left int; n_shape int; n_custom_norule int; n_other_null int;
begin
  -- 2a. no target left blank
  select count(*) into n_left from _bf b join public.jobs j on j.id=b.job_id
   where j.billing_type is null or j.invoice_frequency is null;
  if n_left > 0 then raise exception '% target(s) still blank', n_left; end if;

  -- 2b. the shape rule holds for EVERY row in the table, not just ours. Belt and braces:
  --     a CHECK can be NOT VALID and therefore unenforced on pre-existing rows, so
  --     re-test the predicate rather than trusting the constraint's existence.
  select count(*) into n_shape from public.jobs
   where invoice_rrule is not null
     and invoice_rrule !~ '^RRULE:FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(;[A-Z]+=[A-Za-z0-9,+-]+)*$';
  if n_shape > 0 then raise exception '% row(s) hold a malformed invoice_rrule', n_shape; end if;

  select count(*) into n_custom_norule from public.jobs
   where invoice_frequency = 'custom' and invoice_rrule is null;
  if n_custom_norule > 0 then raise exception '% custom row(s) carry no rule', n_custom_norule; end if;

  -- 2c. the point of the exercise: no live job left without billing.
  select count(*) into n_other_null from public.jobs
   where job_status <> 'archived' and billing_type is null;
  if n_other_null <> 0 then
    raise exception 'expected 0 live jobs without billing_type, found %', n_other_null;
  end if;

  raise notice 'BILLING BACKFILL OK - 25 rows filled from Jobber, 0 live jobs left without billing';
end $$;

commit;
