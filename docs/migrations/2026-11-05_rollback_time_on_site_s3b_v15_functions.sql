-- ============================================================================
-- 2026-11-05_rollback_time_on_site_s3b_v15_functions  Undoes 2026-11-05_1125
-- ============================================================================
-- Order (runbook 10.4): redeploy v14 first, then this. Part 1 (the overrides table, the stage CHECK, Viktor) stays.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $pin$
DECLARE s text;
BEGIN
  FOREACH s IN ARRAY ARRAY['public.fn_time_on_site_recheck_visits(date,date)', 'public.fn_time_on_site_recheck_fixes(jsonb)', 'public.fn_save_time_on_site_stay(bigint,timestamptz,timestamptz,integer,text,text,jsonb)', 'public.fn_close_time_on_site(jsonb,date)'] LOOP
    IF to_regprocedure(s) IS NULL THEN RAISE EXCEPTION 'rollback: % does not exist', s; END IF;
  END LOOP;
END $pin$;
DROP FUNCTION public.fn_time_on_site_recheck_visits(date, date);
DROP FUNCTION public.fn_time_on_site_recheck_fixes(jsonb);
DROP FUNCTION public.fn_save_time_on_site_stay(bigint, timestamptz, timestamptz, integer, text, text, jsonb);
DROP FUNCTION public.fn_close_time_on_site(jsonb, date);
COMMIT;
