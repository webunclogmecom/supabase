-- 2026-06-27_jobber_scope_60d.sql
-- ============================================================================
-- Jobber visit horizon = next 60 days + the single next visit (Task 3).
-- ----------------------------------------------------------------------------
-- Per Fred: the Calendar/DB holds 6 months of SA visits, but JOBBER should only
-- carry the next 60 days. If a job's frequency is so long that NO visit falls in
-- the next 60 days (e.g. 364-day SAs), Jobber still gets that job's single NEXT visit.
--
-- fn_visit_in_jobber_scope(visit_id): TRUE if the visit belongs in Jobber.
--   * non-cron (manual Calendar) visits  -> always TRUE (intentional, push them)
--   * cron (supabase_cron) visits        -> visit_date <= GREATEST(today+60,
--                                             job's earliest future scheduled visit_date)
--     GREATEST gives the "next visit" fallback for free: when the job has a visit
--     within 60d, the cap is today+60 (normal window); when the job's soonest visit
--     is beyond 60d, the cap is that soonest date, so ONLY that one next visit is in scope.
-- Used by jobber-push-visit (CREATE gate) AND the generator's daily promote step, so
-- the two can never drift. STABLE; today is ET.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_visit_in_jobber_scope(p_visit_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN v.source IS DISTINCT FROM 'supabase_cron' THEN true   -- manual/Calendar visits always go to Jobber
    WHEN v.visit_date IS NULL THEN true
    ELSE v.visit_date <= GREATEST(
           ((now() AT TIME ZONE 'America/New_York')::date + 60),
           COALESCE(
             (SELECT min(v2.visit_date)
                FROM visits v2
               WHERE v2.job_id = v.job_id
                 AND v2.visit_status = 'scheduled'
                 AND v2.deleted_at IS NULL
                 AND v2.visit_date >= (now() AT TIME ZONE 'America/New_York')::date),
             v.visit_date)
         )
  END
  FROM visits v
  WHERE v.id = p_visit_id;
$function$;
