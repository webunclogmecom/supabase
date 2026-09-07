-- ============================================================================================
-- 2026-09-07_0430_backfill_seven_null_billing_jobs.sql
--
-- Fill billing_type / invoice_frequency on SEVEN of the eight live jobs that hold NULL.
-- Job 576 is deliberately EXCLUDED. See "WHY 576 IS REFUSED" below; it is not an oversight.
--
-- WHY (Fred, 2026-09-06: "go ahead")
-- ----------------------------------
-- 8 live jobs carried billing_type IS NULL, accreting at ~5/month with nothing watching. These
-- columns are the PREFILL for an outbound write to Jobber, which is the billing master.
--
-- WHAT IS WRITTEN, and it is a faithful read of Jobber (re-fetched immediately before applying):
--   349, 1074, 1816, 1836, 1838, 1839, 1840  ->  visit_based / per_visit / rrule stays NULL
-- Jobber holds VISIT_BASED + PER_VISIT with no recurrenceSchedule on all seven, and that is
-- byte-identical to what supabase/functions/_shared/service-call-job.ts already writes for every
-- Service Call created since 2026-08-20. So this aligns the stragglers with the current writer.
--
-- 🛑 WHY 576 IS REFUSED, AND IT INVERTS THE STATED PURPOSE OF THIS TASK
-- ---------------------------------------------------------------------
-- Job 576 (110-CLA, "Quaterly Hydrojet cleaning") holds FIXED_PRICE / PERIODIC /
-- FREQ=DAILY;INTERVAL=90 in Jobber, so the "obvious" fill is fixed / custom / RRULE:...
-- FILLING IT WOULD CREATE THE EXACT HARM THIS TASK EXISTS TO PREVENT.
--
-- The live Client App bundle (r_clients._id-C16KdM-s.js) derives the billing value it SENDS from
-- the job TITLE, not from what we store:
--     R  = (title ?? "").trim().toLowerCase().startsWith("service agreement") ? "SA" : "SC"
--     ot = E === "SC" ? "visit_based" : S          <- the wire value, overriding the stored one
--     <Radio value:"fixed" id:"bt-fixed" disabled:E === "SC">
-- So for ANY job not titled "Service Agreement...", the dialog forces visit_based and disables the
-- fixed option. Tracing job 576 through it:
--
--   | 576 state                     | Save on open | patch emits             | outcome            |
--   | NULL (today)                  | DISABLED     | nothing                 | 1 click to push    |
--   | filled fixed/custom           | ENABLED      | billing_type visit_based| 0 clicks to push   |
--   | filled visit_based/per_visit  | enabled      | nothing                 | inert              |
--
-- Filling 576 converts a one-click destructive push into a ZERO-click one, with no backstop, on a
-- live 90-day fixed-price customer schedule. The seven Service Calls are the third row: after the
-- write, ot === stored and the patch memo emits no billing keys at all, so they are provably inert.
-- 576 is a question for Fred (retitle to "Service Agreement - ..." and fill, or deliberately push
-- visit_based if Jobber is wrong), not a row to fill unattended.
--
-- ⚠ RELATED AND MORE URGENT, NOT FIXED HERE: job 1720 (000-DH Homestead Dump, 99900969, 30 live
-- visits) already holds fixed / once_closed under a "Service Call" title, so it is ARMED TODAY at
-- zero clicks. Measured: 26 live jobs hold billing_type='fixed', 25 are SA-titled, and 1720 is the
-- only one that is not (control: 440 live visit_based jobs, so that 1 is a real count, not a blind
-- zero). Flagged to Fred; deliberately out of scope for this migration.
--
-- WHY A DIRECT UPDATE AND NOT public.fn_record_client_job
-- -------------------------------------------------------
-- 🛑 That RPC is FAIL-OPEN ON IDENTITY: a gid resolving to no entity_source_links row does not
-- raise, it takes the INSERT branch and creates a job with client_id, property_id, job_number,
-- title and job_status all NULL, then returns created:true. scripts/backfill_job_billing.js
-- discards the return value, so a phantom job reports as a successful backfill. Proven in a
-- rolled-back probe (jobs 1841 -> 1842, phantom row id 1875 with every identity column NULL).
-- The branch is unreachable for these 8 (all gids round-trip byte-identical, 0 duplicate
-- source_ids), so this is a latent hazard rather than an incident, but there is no reason to
-- route a 7-row update through it.
-- 🛑 DO NOT RUN scripts/backfill_job_billing.js. Besides the above it clears invoice_rrule
-- unconditionally, interpolates SQL as strings, and its header asserts Jobber "never" exposes the
-- underlying RRULE, which is FALSE: job.invoiceSchedule.recurrenceSchedule.calendarRule returns it
-- (job 576 reads FREQ=DAILY;INTERVAL=90). That false premise is why 576 was never filled.
-- ⚠ The path is invoiceSchedule.recurrenceSchedule, NOT job.recurrenceSchedule, which does not
-- exist on type Job and returns undefinedField. An errors-only reply has no `data` key, so a
-- caller reading res.data.job sees undefined and reports "not in Jobber": a silent no-op that
-- looks like a clean run. calendarRule also exists on visitSchedule, and taking that one would
-- write a VISIT cadence into a BILLING column. For 576, visitSchedule.recurrenceSchedule is null.
--
-- RULE 8 (audit trail): NO SCHEMA CHANGE. public.jobs already carries an audit trigger, verified,
-- so every row here is recoverable from audit.logs.old_row.
-- ⚠ Read audit rows back with record_pk->>'id'. record_pk is JSONB holding {"id": 1840}, so
-- record_pk::text matches nothing and returns a confident zero.
--
-- BLAST RADIUS, measured: the write cannot reach Jobber. sync.outbound_queue gained 0 rows against
-- a control that moved 1, because the enqueue trigger requires auth.uid() IS NOT NULL and a
-- Management API write carries no JWT. No customer-facing view moves, no revenue projection moves,
-- and fn_generate_sa_visits keys on job_status and frequency_days, not billing.
-- ⚠ These 7 will land as app_source='sql' with no actor, so they surface in the Client App activity
-- feed as System edits. That is deliberate: faking a JWT email would misattribute a script write to
-- a person in the one trail that is supposed to be honest.
-- ============================================================================================

BEGIN;

DO $backfill$
DECLARE
  n integer;
BEGIN
  WITH upd AS (
    UPDATE public.jobs j
       SET billing_type      = 'visit_based',
           invoice_frequency = 'per_visit'
      FROM (VALUES
        (349::bigint , '10000115'),
        (1074        , '10000843'),
        (1816        , '99901051'),
        (1836        , '99901055'),
        (1838        , '99901056'),
        (1839        , '99901057'),
        (1840        , '99901058')
      ) AS v(id, job_number)
     WHERE j.id                = v.id
       AND j.job_number        = v.job_number    -- identity cross-check, never the id alone
       AND j.billing_type      IS NULL           -- re-assert the eligibility predicate so a staff
       AND j.invoice_frequency IS NULL           -- member who filled one in between the Jobber
       AND j.invoice_rrule     IS NULL           -- read and this write wins instead of being
       AND j.job_status <> 'archived'            -- silently overwritten
    RETURNING j.id
  )
  SELECT count(*) INTO n FROM upd;

  IF n <> 7 THEN
    RAISE EXCEPTION 'REFUSED: expected 7 rows, updated %. The world changed since the Jobber read; '
                    're-read Jobber and re-check the eligibility predicate before retrying.', n;
  END IF;
  RAISE NOTICE 'backfilled % rows', n;
END
$backfill$;

-- ============================================================================================
-- VERIFY. Each assertion carries a control, because "0 findings" and "structurally incapable of
-- finding anything" look identical.
-- ============================================================================================
DO $verify$
DECLARE
  v_filled   int;
  v_576      record;
  v_left     int;
  v_ctl      int;
  v_outbound int;
BEGIN
  -- 1. The seven now hold exactly the intended pair, and nothing else moved into a bad state.
  SELECT count(*) INTO v_filled FROM public.jobs
   WHERE id IN (349,1074,1816,1836,1838,1839,1840)
     AND billing_type = 'visit_based' AND invoice_frequency = 'per_visit'
     AND invoice_rrule IS NULL;
  IF v_filled <> 7 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: % of 7 rows hold the intended pair', v_filled;
  END IF;

  -- 2. 576 MUST be untouched. This is the whole point of the exclusion, so assert it rather than
  --    trusting that it was simply left out of the VALUES list.
  SELECT billing_type, invoice_frequency, invoice_rrule INTO v_576
    FROM public.jobs WHERE id = 576;
  IF v_576.billing_type IS NOT NULL OR v_576.invoice_frequency IS NOT NULL
     OR v_576.invoice_rrule IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: job 576 was written (%/%/%). It must stay NULL pending Fred.',
      v_576.billing_type, v_576.invoice_frequency, v_576.invoice_rrule;
  END IF;

  -- 3. The remaining live NULL population is exactly 576 and nothing else.
  --    CONTROL: the populated count must be non-zero, or this reader proves nothing.
  SELECT count(*) INTO v_left FROM public.jobs
   WHERE billing_type IS NULL AND job_status NOT IN ('archived','closed','destroyed');
  SELECT count(*) INTO v_ctl FROM public.jobs
   WHERE billing_type IS NOT NULL AND job_status NOT IN ('archived','closed','destroyed');
  IF v_ctl = 0 THEN
    RAISE EXCEPTION 'VERIFY 3 CONTROL FAILED: zero populated live jobs, so the reader is untrusted.';
  END IF;
  IF v_left <> 1 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: % live jobs still NULL, expected exactly 1 (job 576)', v_left;
  END IF;

  -- 4. NOTHING WAS ENQUEUED TO JOBBER. The single most important negative assertion here: this
  --    backfill must not push anything outbound. The enqueue trigger requires a real JWT and this
  --    transaction has none, but assert the outcome rather than the reasoning.
  SELECT count(*) INTO v_outbound FROM sync.outbound_queue
   WHERE created_at > now() - interval '5 minutes';
  IF v_outbound <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: % outbound row(s) queued. This backfill is pushing to Jobber.',
      v_outbound;
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: 7 filled, 576 untouched, 1 live NULL remains, 0 outbound queued';
END
$verify$;

COMMIT;
