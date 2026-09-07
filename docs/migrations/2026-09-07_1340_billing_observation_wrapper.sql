-- ============================================================================================
-- 2026-09-07_1340_billing_observation_wrapper.sql
--
-- A public wrapper so the edge function can reach sync.fn_record_billing_observations.
--
-- WHY: PostgREST resolves db.rpc('name') in the EXPOSED schemas, which do not include `sync`. The
-- first live invocation failed with "Could not find the function public.fn_record_billing_
-- observations(p_rows) in the schema cache" after successfully reading 100 jobs from Jobber, so the
-- reader was correct and only the call target was wrong.
--
-- This follows the pattern already used for the outbound custom-field push (the four
-- public.fn_outbound_* wrappers). The alternative, exposing `sync` to PostgREST, would put every
-- object in that schema one grant mistake away from the API surface for no benefit.
--
-- ⚠ The wrapper is SECURITY DEFINER with a pinned search_path and is granted to service_role ONLY.
-- Supabase's ALTER DEFAULT PRIVILEGES makes a new public function `authenticated`-EXECUTABLE on
-- creation, so the REVOKE is not decoration: without it any signed-in browser could write the
-- observation table through PostgREST.
--
-- RULE 8: no schema change, one function. The tables it reaches were opted in/out in
-- 2026-09-07_1240 and are untouched here.
-- ============================================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.fn_record_billing_observations(p_rows jsonb)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $fn$
  SELECT sync.fn_record_billing_observations(p_rows);
$fn$;

COMMENT ON FUNCTION public.fn_record_billing_observations(jsonb) IS
  'PostgREST-reachable wrapper for sync.fn_record_billing_observations. service_role only; the '
  'observation lane has no app-facing caller. All logic lives in the sync function.';

REVOKE ALL ON FUNCTION public.fn_record_billing_observations(jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.fn_record_billing_observations(jsonb) TO service_role;

-- ============================================================================================
-- VERIFY
-- ============================================================================================
DO $verify$
DECLARE
  v_job bigint;
  r     jsonb;
BEGIN
  -- 1. The wrapper reaches the real function and returns its shape.
  SELECT id INTO v_job FROM public.jobs
   WHERE job_status NOT IN ('archived','closed','destroyed') ORDER BY id LIMIT 1;
  r := public.fn_record_billing_observations(jsonb_build_array(jsonb_build_object(
        'job_id', v_job, 'jobber_gid', 'gid://wrapper-probe', 'billing_type', 'VISIT_BASED',
        'billing_frequency', 'PER_VISIT', 'calendar_rule', NULL)));
  IF (r->>'received')::int <> 1 THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: wrapper did not reach the sync function: %', r;
  END IF;
  DELETE FROM sync.jobber_billing_observed
   WHERE job_id = v_job AND jobber_gid = 'gid://wrapper-probe';

  -- 2. GRANTS. Assert the outcome with has_function_privilege, which does not depend on who is
  --    asking. The Management API runs as postgres (owner, rolbypassrls) so a "it worked" probe
  --    would prove nothing about anon or authenticated.
  IF has_function_privilege('anon',          'public.fn_record_billing_observations(jsonb)', 'EXECUTE')
  OR has_function_privilege('authenticated', 'public.fn_record_billing_observations(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: anon or authenticated can EXECUTE the observation writer.';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.fn_record_billing_observations(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 2 CONTROL FAILED: service_role cannot execute it either, so the check '
                    'above is not discriminating between roles.';
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED';
END
$verify$;

COMMIT;
