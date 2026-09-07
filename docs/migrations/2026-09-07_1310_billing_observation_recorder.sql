-- ============================================================================================
-- 2026-09-07_1310_billing_observation_recorder.sql
--
-- The write path for phase A billing observation: one SECDEF RPC the edge function calls with a
-- batch of raw Jobber readings. Companion to 2026-09-07_1240.
--
-- WHY AN RPC AND NOT A DIRECT UPSERT FROM THE EDGE FUNCTION
-- --------------------------------------------------------
-- Normalisation must exist ONCE. save-client-job is the writer that gates every real billing write
-- and is implementation 1; the SQL normaliser is implementation 2. A third copy inside the edge
-- function is how two implementations drift, and drift here means the detector disagrees with the
-- writer and reports phantom findings forever. So the edge function ships RAW Jobber values and
-- this function does all mapping and all comparison.
--
-- 🛑 CHANGE-ONLY WRITES. The upsert's WHERE clause fires only when the NORMALISED triple actually
-- moves. That is what makes changed_at/prev_norm_* mean "Jobber moved, at this time, from this",
-- which is the attribution phase B needs and the reason the shadow lane is not used at all. It also
-- keeps the rule-8 audit cost proportional to real drift rather than writing ~486 rows a day of
-- churn. A no-op observation touches nothing, so an unchanged fleet leaves an empty audit trail.
--
-- 🛑 FRESHNESS IS NOT ON THIS TABLE. Do not add an observed_at column and touch it every run: that
-- is precisely the churn the change-only design exists to avoid, and it would write an audit row
-- per job per day. Per-row freshness comes from jobber_billing_observe_runs.observed_job_ids.
--
-- ⚠ AN UNMAPPABLE READING IS STILL RECORDED, with norm_ok=false and the reason, and its normalised
-- columns are NULL (the normaliser refuses to propose a partial triple). It is evidence of a shape
-- we cannot interpret, which is a finding in itself, and it must never be compared as if it were a
-- value. Callers gate on norm_ok.
--
-- ⚠ THE CALLER MUST NOT SEND A JOB JOBBER DID NOT ANSWER FOR. An absent node is NO OBSERVATION, not
-- an empty one. This function cannot tell the difference, so the edge function is responsible for
-- omitting it and counting it in unresolvable_gids. That asymmetry is deliberate: coercing a
-- missing answer into a value is the defect that armed a mass archive in sync-jobber-job-drift.
--
-- RULE 8: no schema change. Creates one SECURITY DEFINER function. The tables it writes were opted
-- in / out in 2026-09-07_1240 and are unchanged here.
-- ============================================================================================

BEGIN;

CREATE OR REPLACE FUNCTION sync.fn_record_billing_observations(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_received int;
  v_changed  bigint[];
  v_seen     bigint[];
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a jsonb array of observations' USING errcode = '22023';
  END IF;

  WITH src AS (
    SELECT (e->>'job_id')::bigint       AS job_id,
            e->>'jobber_gid'            AS gid,
            e->>'billing_type'          AS bt,
            e->>'billing_frequency'     AS bf,
            e->>'calendar_rule'         AS cr
      FROM jsonb_array_elements(p_rows) e
  ),
  norm AS (
    SELECT s.*, n.billing_type AS nb, n.invoice_frequency AS nf, n.invoice_rrule AS nr,
           n.periodic_class AS nc, n.ok AS nok, n.reason AS nre
      FROM src s
      CROSS JOIN LATERAL sync.fn_normalize_jobber_billing(s.bt, s.bf, s.cr) n
  ),
  ins AS (
    INSERT INTO sync.jobber_billing_observed AS o (
      job_id, jobber_gid, src_billing_type, src_billing_frequency, src_calendar_rule,
      norm_billing_type, norm_invoice_frequency, norm_invoice_rrule, norm_periodic_class,
      norm_ok, norm_reason)
    SELECT job_id, gid, bt, bf, cr, nb, nf, nr, nc, nok, nre FROM norm
    ON CONFLICT (job_id) DO UPDATE
      SET jobber_gid                  = excluded.jobber_gid,
          src_billing_type            = excluded.src_billing_type,
          src_billing_frequency       = excluded.src_billing_frequency,
          src_calendar_rule           = excluded.src_calendar_rule,
          prev_norm_billing_type      = o.norm_billing_type,
          prev_norm_invoice_frequency = o.norm_invoice_frequency,
          prev_norm_invoice_rrule     = o.norm_invoice_rrule,
          norm_billing_type           = excluded.norm_billing_type,
          norm_invoice_frequency      = excluded.norm_invoice_frequency,
          norm_invoice_rrule          = excluded.norm_invoice_rrule,
          norm_periodic_class         = excluded.norm_periodic_class,
          norm_ok                     = excluded.norm_ok,
          norm_reason                 = excluded.norm_reason,
          changed_at                  = now()
      -- CHANGE-ONLY: an unchanged reading writes nothing at all, so changed_at stays truthful and
      -- the audit trigger stays quiet.
      WHERE (o.norm_billing_type, o.norm_invoice_frequency, o.norm_invoice_rrule, o.norm_ok)
            IS DISTINCT FROM
            (excluded.norm_billing_type, excluded.norm_invoice_frequency,
             excluded.norm_invoice_rrule, excluded.norm_ok)
    RETURNING o.job_id
  )
  SELECT (SELECT count(*) FROM norm),
         coalesce((SELECT array_agg(job_id) FROM ins), '{}'),
         coalesce((SELECT array_agg(job_id) FROM norm), '{}')
    INTO v_received, v_changed, v_seen;

  RETURN jsonb_build_object(
    'received',      v_received,
    'changed',       coalesce(array_length(v_changed, 1), 0),
    'changed_ids',   to_jsonb(v_changed),
    'observed_ids',  to_jsonb(v_seen));
END
$fn$;

COMMENT ON FUNCTION sync.fn_record_billing_observations(jsonb) IS
  'Records a batch of RAW Jobber billing readings, normalising in SQL so the mapping exists once. '
  'Writes CHANGE-ONLY: an unchanged reading touches nothing, so changed_at means "Jobber moved". '
  'Returns observed_ids (everything seen, the freshness key) and changed_ids (what actually moved). '
  'The caller MUST omit any job Jobber did not answer for: an absent node is no observation, and '
  'this function cannot tell that from an empty one.';

REVOKE ALL ON FUNCTION sync.fn_record_billing_observations(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION sync.fn_record_billing_observations(jsonb) TO service_role;

-- ============================================================================================
-- VERIFY. Exercises the real emitted statement against arranged state, then rolls back.
-- ============================================================================================
DO $verify$
DECLARE
  v_job  bigint;
  r1     jsonb;
  r2     jsonb;
  r3     jsonb;
  v_row  record;
  v_aud  int;
BEGIN
  -- Borrow a real job id so the FK holds. Any live one will do; nothing about it is modified.
  SELECT id INTO v_job FROM public.jobs
   WHERE job_status NOT IN ('archived','closed','destroyed') ORDER BY id LIMIT 1;
  IF v_job IS NULL THEN
    RAISE EXCEPTION 'VERIFY CONTROL FAILED: no live job exists to arrange against.';
  END IF;

  -- 1. First observation inserts and normalises.
  r1 := sync.fn_record_billing_observations(jsonb_build_array(jsonb_build_object(
          'job_id', v_job, 'jobber_gid', 'gid://probe', 'billing_type', 'VISIT_BASED',
          'billing_frequency', 'PER_VISIT', 'calendar_rule', NULL)));
  IF (r1->>'received')::int <> 1 OR (r1->>'changed')::int <> 1 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: first observation did not insert: %', r1;
  END IF;

  -- 2. THE SAME reading again must write NOTHING. This is the change-only contract, and if it
  --    regresses the table writes ~486 audit rows a day and changed_at stops meaning anything.
  r2 := sync.fn_record_billing_observations(jsonb_build_array(jsonb_build_object(
          'job_id', v_job, 'jobber_gid', 'gid://probe', 'billing_type', 'VISIT_BASED',
          'billing_frequency', 'PER_VISIT', 'calendar_rule', NULL)));
  IF (r2->>'changed')::int <> 0 THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: an unchanged reading wrote a row (changed=%). '
                    'The change-only WHERE clause is not biting.', r2->>'changed';
  END IF;
  IF (r2->>'received')::int <> 1 THEN
    RAISE EXCEPTION 'VERIFY 2 CONTROL FAILED: received=% so the row never reached the function, '
                    'which would make the zero above meaningless.', r2->>'received';
  END IF;

  -- 3. A CHANGED reading moves the row and records where it came from.
  r3 := sync.fn_record_billing_observations(jsonb_build_array(jsonb_build_object(
          'job_id', v_job, 'jobber_gid', 'gid://probe', 'billing_type', 'FIXED_PRICE',
          'billing_frequency', 'PERIODIC', 'calendar_rule', 'FREQ=DAILY;INTERVAL=90')));
  IF (r3->>'changed')::int <> 1 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: a genuinely changed reading did not write: %', r3;
  END IF;
  SELECT * INTO v_row FROM sync.jobber_billing_observed WHERE job_id = v_job;
  IF v_row.norm_billing_type <> 'fixed'
     OR v_row.norm_invoice_frequency <> 'custom'
     OR v_row.norm_invoice_rrule <> 'RRULE:FREQ=DAILY;INTERVAL=90'
     OR v_row.prev_norm_billing_type <> 'visit_based' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: row or provenance wrong: % / % / % (prev %)',
      v_row.norm_billing_type, v_row.norm_invoice_frequency, v_row.norm_invoice_rrule,
      v_row.prev_norm_billing_type;
  END IF;

  -- 4. An UNMAPPABLE reading records the reason and proposes NO values.
  PERFORM sync.fn_record_billing_observations(jsonb_build_array(jsonb_build_object(
          'job_id', v_job, 'jobber_gid', 'gid://probe', 'billing_type', 'FIXED_PRICE',
          'billing_frequency', 'PERIODIC', 'calendar_rule', NULL)));
  SELECT * INTO v_row FROM sync.jobber_billing_observed WHERE job_id = v_job;
  IF v_row.norm_ok IS NOT FALSE OR v_row.norm_reason <> 'periodic_without_rule'
     OR v_row.norm_billing_type IS NOT NULL OR v_row.norm_invoice_frequency IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: unmappable reading did not record cleanly: ok=% reason=% bt=%',
      v_row.norm_ok, v_row.norm_reason, v_row.norm_billing_type;
  END IF;

  -- 5. Rule 8 in practice: the writes above are actually captured.
  SELECT count(*) INTO v_aud FROM audit.logs
   WHERE table_schema = 'sync' AND table_name = 'jobber_billing_observed'
     AND changed_at > now() - interval '2 minutes';
  IF v_aud = 0 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: no audit rows for the writes just made, so the trigger is '
                    'attached but not firing.';
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED (job %, audit rows %)', v_job, v_aud;
  -- Everything above is inside the migration transaction; the rehearsal rolls it back, and on a
  -- real apply the probe row is removed here so the table starts empty.
  DELETE FROM sync.jobber_billing_observed WHERE job_id = v_job AND jobber_gid = 'gid://probe';
END
$verify$;

COMMIT;
