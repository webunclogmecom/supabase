-- ============================================================================
-- 2026-07-02 — Gate #4 drift reconciler: stop HEAL from reverting human Jobber edits
-- ============================================================================
-- INCIDENT: On 2026-07-02, visit 6356 (152-DAV) "moved by itself" in Jobber, repeatedly,
-- while Yannick was editing it overnight. Root cause: the reconciler's HEAL classifier
-- (edge fn sync-jobber-visit-drift) was DATE-ONLY. Visit 6356's DB<->Jobber disagreement
-- was a 1-hour TIME gap on the SAME day (DB 15:30 ET vs Jobber 14:30 ET), so the HEAL
-- guard `last.new_date===c.visit_date && last.old_date===jDate` passed trivially (every
-- value was "2026-07-01") and re-pushed our DB time onto Jobber every 30 min — reverting
-- Yannick's manual moves. Worse, `visit_last_schedule_edit` returned 6356's "last edit"
-- as an INBOUND Jobber start_at FILL (app_source='jobber', 06-30 20:30, NULL->19:30Z),
-- misread as an OUR-side office edit whose push "failed". The re-push changed no business
-- column, so audit.log_change() skipped it (no audit row = a "ghost" move).
--
-- FIX (two parts):
--   1. THIS RPC — visit_last_schedule_edit now (a) EXCLUDES app_source='jobber' rows (an
--      inbound Jobber fill/adopt is never "our edit"), and (b) also returns the pre-edit
--      start_at (old_start_at/new_start_at) so the reconciler can match on TIME, not just date.
--   2. Edge fn sync-jobber-visit-drift/index.ts — HEAL now fires ONLY when Jobber still holds
--      our EXACT pre-edit value (date AND, for a timed pre-edit, the ET clock time; an untimed
--      pre-edit must still be all-day/midnight in Jobber). Any other Jobber value => a human
--      moved it after our push => SURFACE, never auto-revert. (Deployed same day.)
--
-- Verified against all 17 then-drifting visits: NEW classification = 0 HEAL, all SURFACE
-- (6356 => SURFACE). Genuine failed pushes (Jobber literally still holds our pre-edit value)
-- still HEAL. Live synchronous invoke of the deployed fn: healable=0, healed=0, 6356 untouched.
--
-- Audit (ADR 010): this is a function, not a table — no audit trigger change. Idempotent
-- (CREATE OR REPLACE after a DROP for the return-type change). Applied to Prod via the
-- Management API on 2026-07-02; this file is the tracked record.
-- ============================================================================

DROP FUNCTION IF EXISTS public.visit_last_schedule_edit(bigint);

CREATE OR REPLACE FUNCTION public.visit_last_schedule_edit(p_visit_id bigint)
  RETURNS TABLE(old_date text, new_date text, old_start_at text, new_start_at text, changed_at timestamptz, app_source text)
  LANGUAGE sql
  STABLE SECURITY DEFINER
  SET search_path TO 'public', 'audit'
AS $function$
  SELECT l.old_row->>'visit_date', l.new_row->>'visit_date',
         l.old_row->>'start_at',   l.new_row->>'start_at',
         l.changed_at, l.app_source
  FROM audit.logs l
  WHERE l.table_name = 'visits'
    AND (l.record_pk->>'id') = p_visit_id::text
    AND l.operation = 'UPDATE'
    -- Inbound Jobber rows (fills / adopt-from-Jobber) are NOT our office edits — excluding
    -- them is what stops a Jobber start_at FILL being misread as an "our failed push".
    AND l.app_source IS DISTINCT FROM 'jobber'
    AND ( (l.new_row->>'visit_date') IS DISTINCT FROM (l.old_row->>'visit_date')
       OR (l.new_row->>'start_at')   IS DISTINCT FROM (l.old_row->>'start_at')
       OR (l.new_row->>'end_at')     IS DISTINCT FROM (l.old_row->>'end_at') )
  ORDER BY l.changed_at DESC
  LIMIT 1;
$function$;
