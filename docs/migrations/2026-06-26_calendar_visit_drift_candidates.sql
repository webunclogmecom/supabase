-- ============================================================================
-- 2026-06-26_calendar_visit_drift_candidates.sql
-- ADR 010: read-only SECURITY DEFINER function over already-audited tables; no
--          new table, no writes -> audit OPT-OUT (nothing to audit).
-- ----------------------------------------------------------------------------
-- Gate #4 (Calendar->Jobber schedule-drift watchdog) candidate set.
--
-- A Calendar/cron visit edit (incl. ripple_reschedule_visit cascades) pushes to
-- Jobber FIRE-AND-FORGET via trg_push_visit_update -> fn_push_visit_to_jobber ->
-- net.http_post -> jobber-push-visit. If that push silently fails (Jobber
-- userError / token / pg_net drop), the DB shows date X while Jobber stays on
-- date Y, and NOTHING is recorded (the update path writes no visit_sync_flags
-- row; net._http_response is unmappable to a visit + purges in ~6h). The inbound
-- poll never clobbers a calendar/cron visit's schedule (webhook-jobber loop-guard),
-- so the DB stays the correct master and the divergence is invisible from DB
-- columns alone -> it can ONLY be detected by reading Jobber's actual startAt.
--
-- This function returns the bounded set the sync-jobber-visit-drift Edge Function
-- compares against Jobber: calendar/cron-mastered, scheduled, Jobber-LINKED,
-- live (not soft-deleted) visits in a [today - p_back_days, today + p_fwd_days]
-- window. The window is RE-SCANNED in full every run (level-triggered, no moving
-- cursor) so a skipped run is self-healing — the next run re-checks everything.
-- The today-7 back edge catches recently-moved near-past visits (inbound GAP-1).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.calendar_visit_drift_candidates(
  p_back_days int DEFAULT 7,
  p_fwd_days  int DEFAULT 184
)
RETURNS TABLE(id bigint, visit_date date, start_at timestamptz, end_at timestamptz, jobber_gid text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT v.id, v.visit_date, v.start_at, v.end_at, esl.source_id AS jobber_gid
  FROM public.v_visits_live v          -- canonical soft-delete-filtered base
  JOIN public.entity_source_links esl
    ON esl.entity_type = 'visit'
   AND esl.source_system = 'jobber'
   AND esl.entity_id = v.id            -- only visits already LINKED to Jobber
  WHERE v.source IN ('visit-calendar', 'supabase_cron')   -- DB-mastered visits only
    AND v.visit_status = 'scheduled'
    AND v.visit_date BETWEEN (CURRENT_DATE - p_back_days) AND (CURRENT_DATE + p_fwd_days);
$function$;

REVOKE ALL  ON FUNCTION public.calendar_visit_drift_candidates(int, int) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.calendar_visit_drift_candidates(int, int) TO service_role;

NOTIFY pgrst, 'reload schema';
