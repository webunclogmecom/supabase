-- =====================================================================
-- 2026-08-04_1450  Correct the billing column comments (they are now false)
-- =====================================================================
-- WHY
--   `billing_type`'s comment says "Written ONLY by fn_record_client_job from the
--   verified Jobber read", and `invoice_frequency` inherits it by reference. As of
--   migration 2026-08-04_1330 that is FALSE: 25 rows were written by a direct UPDATE
--   (app_source='sql', one transaction, txid 1891170). Leaving the comment as-is would
--   tell the next auditor that any non-RPC provenance in audit.logs is unexplained -
--   exactly the false-anomaly this repo keeps generating for itself.
--
--   Two other things are worth saying in the comment rather than only in a migration
--   nobody will grep:
--     * NULL is a live UI sentinel, not merely absent data. The Client App renders
--       "Not recorded yet - Jobber holds the current setting" from it, so a NULL is a
--       question the dialog asks. As of 2026-08-04 no LIVE job is NULL any more, so
--       that notice now only appears for archived jobs and newly-created ones.
--     * invoice_frequency is NOT derivable from invoice_rrule. Both are the record.
--
--   The half of the old comment that is STILL TRUE is kept verbatim and deliberately:
--   no inbound sync writes these columns, and a change made in Jobber's own UI does
--   NOT flow back, so a stored value can go stale silently and nothing refreshes it.
--   Verified today: the 17:15Z Jobber poll touched public.jobs twice and changed only
--   job_status, never a billing column.
--
-- AUDIT (rule #8): comments only, no data and no DDL on the table itself. N/A.
-- REVERSIBLE: yes, comments are text.
-- =====================================================================

begin;

comment on column public.jobs.billing_type is
  'visit_based | fixed. Jobber invoicingType VISIT_BASED / FIXED_PRICE. '
  'Written from a VERIFIED Jobber read - normally by fn_record_client_job (the save-client-job saga), '
  'and additionally by the one-shot backfill 2026-08-04_1330 which copied Jobber''s own values into the '
  '25 live jobs that were still NULL (direct UPDATE, app_source=''sql'', txid 1891170). '
  'NULL = never confirmed by us; the app must ASK rather than assume, and renders "Not recorded yet". '
  'Since 2026-08-04 no LIVE job is NULL, so that notice now only appears for archived or brand-new jobs. '
  'Must be set together with invoice_frequency (jobs_billing_pair_chk). '
  'No inbound sync writes this, and a change made in Jobber''s own UI does NOT flow back - '
  'the drift reconciler does not compare it, so a stored value can go stale silently.';

comment on column public.jobs.invoice_frequency is
  'per_visit | monthly_last_day | once_closed | as_needed | custom. Maps to Jobber invoicingSchedule '
  'PER_VISIT / PERIODIC / ON_COMPLETION / NEVER. Same provenance and same staleness caveat as billing_type, '
  'and must be set together with it (jobs_billing_pair_chk). '
  'NOT derivable from invoice_rrule: RRULE:FREQ=MONTHLY;BYMONTHDAY=-1 is emitted BOTH by '
  'monthly_last_day (hard-coded in resolveBilling) AND by custom (the Client App builder''s '
  'Month / "On a date" / "Last day" at interval 1). Both columns are the record; never reconcile one '
  'from the other or you will silently relabel a user''s choice.';

comment on column public.jobs.invoice_rrule is
  'The RRULE behind a PERIODIC invoice schedule, e.g. RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=22. '
  'NULL for non-periodic schedules; REQUIRED when invoice_frequency = ''custom'' (jobs_custom_needs_rrule_chk), '
  'and shape-checked by jobs_invoice_rrule_shape_chk. '
  'Stored in JOBBER''S canonical form: no INTERVAL=1 (it omits the default on read-back) and the '
  '''RRULE:'' prefix re-added (Jobber returns recurrenceSchedule.calendarRule without it), so our value '
  'and theirs stay byte-comparable for drift checks.';

do $$
declare n int;
begin
  select count(*) into n
    from pg_attribute a
   where a.attrelid = 'public.jobs'::regclass
     and a.attname in ('billing_type','invoice_frequency','invoice_rrule')
     and col_description(a.attrelid, a.attnum) is not null
     and col_description(a.attrelid, a.attnum) not like '%Written ONLY by fn_record_client_job%';
  if n <> 3 then
    raise exception 'expected 3 corrected comments, found % (the stale "Written ONLY" wording may survive)', n;
  end if;
  raise notice 'billing column comments corrected on all 3 columns';
end $$;

commit;
