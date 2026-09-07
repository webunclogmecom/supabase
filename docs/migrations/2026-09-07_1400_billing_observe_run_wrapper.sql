-- ============================================================================================
-- 2026-09-07_1400_billing_observe_run_wrapper.sql
--
-- A public wrapper so the observer can write its RUN row, and a freshness view over it.
--
-- 🛑 WHY THIS EXISTS, AND THE IRONY IS THE POINT. The first live run of
-- sync-jobber-billing-observe reported ok:true, 485 requested / 483 observed / 483 recorded, and
-- looked entirely healthy. It was not: the run row never landed, because supabase-js `.from()`
-- resolves through PostgREST in the EXPOSED schemas and `sync` is not one of them. Confirmed with
-- a control rather than inferred: GET /rest/v1/jobber_billing_observe_runs returns PGRST205
-- ("Could not find the table 'public.jobber_billing_observe_runs'") while GET /rest/v1/jobs on the
-- same client and headers returns 200.
--
-- The observation rows wrote fine because they go through a public RPC wrapper. The ONLY write that
-- silently failed was the one recording freshness and coverage, and the handler logs that failure
-- to console and returns 200 regardless. So the feature built to stop a silent observability gap
-- shipped with exactly one: a reader would have seen 483 fresh-looking rows and no way to tell when
-- they were read or whether the fleet was fully covered. Same class as the property sweep's
-- `catch { pulls[e] = -1; continue }` that kept pg_cron and sync_log green for two days.
--
-- ⇒ The lesson worth keeping: a health mechanism's OWN plumbing needs the same proof as the thing
--   it watches. "The run reported success" is not evidence the run recorded anything.
--
-- ALSO ADDS sync.v_billing_observation_freshness, so "is this evidence current, and how much of the
-- fleet does it cover" is one SELECT rather than a join a caller has to remember to write. It
-- reports NO EVIDENCE when the runs table is empty, never "clean": silence from an instrument that
-- never ran is indistinguishable from a healthy estate, which is the estate's most-repeated defect.
--
-- RULE 8: no schema change. One SECDEF function and one view.
-- ============================================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_record_billing_observe_run(
  p_started_at        timestamptz,
  p_jobs_requested    integer,
  p_jobs_returned     integer,
  p_jobs_upserted     integer,
  p_observed_job_ids  bigint[],
  p_unresolvable_gids jsonb,
  p_ok                boolean,
  p_error             text)
RETURNS bigint
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $fn$
  INSERT INTO sync.jobber_billing_observe_runs (
    started_at, finished_at, jobs_requested, jobs_returned, jobs_upserted,
    observed_job_ids, unresolvable_gids, ok, error)
  VALUES (
    coalesce(p_started_at, now()), now(),
    coalesce(p_jobs_requested, 0), coalesce(p_jobs_returned, 0), coalesce(p_jobs_upserted, 0),
    coalesce(p_observed_job_ids, '{}'), coalesce(p_unresolvable_gids, '[]'::jsonb),
    coalesce(p_ok, false), p_error)
  RETURNING run_id;
$fn$;

COMMENT ON FUNCTION public.fn_record_billing_observe_run(timestamptz, integer, integer, integer, bigint[], jsonb, boolean, text) IS
  'PostgREST-reachable wrapper recording one sync-jobber-billing-observe run. service_role only. '
  'Exists because supabase-js .from() cannot reach the sync schema, which made the observer''s '
  'freshness row fail silently on its first live run while the response still read ok:true.';

REVOKE ALL ON FUNCTION public.fn_record_billing_observe_run(timestamptz, integer, integer, integer, bigint[], jsonb, boolean, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_record_billing_observe_run(timestamptz, integer, integer, integer, bigint[], jsonb, boolean, text)
  TO service_role;

-- ── Freshness / coverage, in one place ──────────────────────────────────────────────────────
CREATE OR REPLACE VIEW sync.v_billing_observation_freshness AS
WITH last_ok AS (
  SELECT * FROM sync.jobber_billing_observe_runs
   WHERE ok ORDER BY run_id DESC LIMIT 1
),
last_any AS (
  SELECT * FROM sync.jobber_billing_observe_runs ORDER BY run_id DESC LIMIT 1
)
SELECT
  -- THREE verdicts, never two. NO_EVIDENCE is not a synonym for clean.
  CASE WHEN NOT EXISTS (SELECT 1 FROM sync.jobber_billing_observe_runs) THEN 'NO_EVIDENCE'
       WHEN NOT EXISTS (SELECT 1 FROM last_ok)                          THEN 'NO_EVIDENCE'
       WHEN (SELECT now() - finished_at FROM last_ok) > interval '26 hours' THEN 'STALE'
       WHEN (SELECT jobs_returned FROM last_ok) < (SELECT jobs_requested FROM last_ok) THEN 'PARTIAL'
       ELSE 'CURRENT' END                                        AS verdict,
  (SELECT run_id            FROM last_ok)                        AS last_ok_run_id,
  (SELECT finished_at       FROM last_ok)                        AS last_ok_at,
  (SELECT jobs_requested    FROM last_ok)                        AS jobs_requested,
  (SELECT jobs_returned     FROM last_ok)                        AS jobs_returned,
  (SELECT jobs_upserted     FROM last_ok)                        AS jobs_changed,
  (SELECT jsonb_array_length(unresolvable_gids) FROM last_ok)    AS unresolvable,
  (SELECT observed_job_ids  FROM last_ok)                        AS observed_job_ids,
  (SELECT ok                FROM last_any)                       AS last_run_ok,
  (SELECT error             FROM last_any)                       AS last_run_error;

COMMENT ON VIEW sync.v_billing_observation_freshness IS
  'Is the billing observation evidence current, and how much of the fleet does it cover? Three '
  'verdicts: CURRENT, PARTIAL (a short run), STALE (>26h), NO_EVIDENCE (never ran, or never '
  'succeeded). NO_EVIDENCE must never be read as clean. observed_job_ids is the PER-ROW freshness '
  'key: a job absent from it has no current observation whatever sync.jobber_billing_observed says.';

REVOKE ALL ON sync.v_billing_observation_freshness FROM PUBLIC, anon, authenticated;
GRANT SELECT ON sync.v_billing_observation_freshness TO service_role;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_run bigint;
  v     record;
BEGIN
  -- 1. Before any run exists this must say NO_EVIDENCE, not clean. Assert it FIRST, because after
  --    the probe run below the state is gone and this is the case that matters most.
  SELECT * INTO v FROM sync.v_billing_observation_freshness;
  IF (SELECT count(*) FROM sync.jobber_billing_observe_runs) = 0 AND v.verdict <> 'NO_EVIDENCE' THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: an empty runs table reports "%", not NO_EVIDENCE.', v.verdict;
  END IF;

  -- 2. The wrapper writes, and a full run reads CURRENT.
  v_run := public.fn_record_billing_observe_run(
             now() - interval '5 seconds', 100, 100, 3, ARRAY[1,2,3]::bigint[], '[]'::jsonb, true, NULL);
  IF v_run IS NULL THEN RAISE EXCEPTION 'VERIFY 2 FAILED: wrapper returned no run_id'; END IF;
  SELECT * INTO v FROM sync.v_billing_observation_freshness;
  IF v.verdict <> 'CURRENT' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: a complete fresh run reports "%", not CURRENT.', v.verdict;
  END IF;

  -- 3. A SHORT run must report PARTIAL. Without this a half-drained sweep reads as healthy, which
  --    is the exact silent failure this view exists to prevent.
  PERFORM public.fn_record_billing_observe_run(
            now(), 100, 40, 0, ARRAY[1]::bigint[], '[]'::jsonb, true, NULL);
  SELECT * INTO v FROM sync.v_billing_observation_freshness;
  IF v.verdict <> 'PARTIAL' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: a run covering 40 of 100 reports "%", not PARTIAL.', v.verdict;
  END IF;

  -- 4. A FAILED run must not be mistaken for evidence: with no ok run on record the verdict is
  --    NO_EVIDENCE even though the table is non-empty.
  DELETE FROM sync.jobber_billing_observe_runs;
  PERFORM public.fn_record_billing_observe_run(
            now(), 100, 0, 0, '{}'::bigint[], '[]'::jsonb, false, 'jobber unreachable');
  SELECT * INTO v FROM sync.v_billing_observation_freshness;
  IF v.verdict <> 'NO_EVIDENCE' THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: a failed-only history reports "%", not NO_EVIDENCE.', v.verdict;
  END IF;
  IF v.last_run_error IS DISTINCT FROM 'jobber unreachable' THEN
    RAISE EXCEPTION 'VERIFY 4 CONTROL FAILED: the failed run''s error is not surfaced, so the view '
                    'cannot explain itself.';
  END IF;

  -- 5. Grants, asserted by outcome rather than by reading the GRANT statements.
  IF has_function_privilege('anon', 'public.fn_record_billing_observe_run(timestamptz,integer,integer,integer,bigint[],jsonb,boolean,text)', 'EXECUTE')
  OR has_function_privilege('authenticated', 'public.fn_record_billing_observe_run(timestamptz,integer,integer,integer,bigint[],jsonb,boolean,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: anon or authenticated can EXECUTE the run recorder.';
  END IF;

  -- Leave the table as we found it: empty, so the first real run is the first row.
  DELETE FROM sync.jobber_billing_observe_runs;
  RAISE NOTICE 'ALL VERIFY PASSED';
END
$verify$;

COMMIT;
