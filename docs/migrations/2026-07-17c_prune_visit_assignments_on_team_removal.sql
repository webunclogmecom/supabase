-- 2026-07-17c — clear visit_assignments when Jobber REMOVES a (non-completed) visit's crew
--
-- WHY (Fred: "how can a Team member be added if Jobber has none? if not via the Calendar that's a bug"):
-- 9 future SCHEDULED SA visits showed a driver (Anthony/Mark) though Jobber's assignedUsers was empty.
-- Audit trace: Jobber HAD a crew -> webhook mirrored it into visit_team AND visit_assignments -> Jobber
-- later UNassigned the crew -> syncVisitTeamFromJobber DELETEd the visit_team row (no INSERT) -> but
-- visit_assignments kept the stale driver. The 2026-07-14 FILL-EMPTY and the 2026-07-17 FULL-SYNC triggers
-- both only fire on visit_team INSERT, so a crew REMOVAL (DELETE-only) slipped past -> the "empty-crew
-- residual". NOT a Calendar assignment; a genuine append-only leftover.
--
-- FIX: AFTER DELETE STATEMENT trigger on visit_team that, for each touched NON-completed visit, deletes any
-- visit_assignments row no longer present in visit_team. Combined with the existing AFTER-INSERT FULL-SYNC
-- trigger this makes visit_assignments == visit_team an invariant in BOTH directions for pending visits:
--   * crew CHANGE (webhook does DELETE then INSERT as separate txns): DELETE prunes -> INSERT re-syncs -> va = new crew.
--   * crew REMOVAL (DELETE only): va cleared -> the visit shows no driver until Jobber crews it (then the
--     INSERT trigger repopulates). This is correct: a future visit Jobber hasn't crewed has no driver.
-- GUARD: visit_status <> 'completed' — a COMPLETED visit keeps its historical actual-driver even if Jobber
-- later clears the crew (we don't erase who did the job). Visits that NEVER had a mirrored visit_team (the
-- ~154 pre-mirror historical former-driver rows) never fire a visit_team DELETE, so they are untouched.
--
-- AUDIT (ADR-010): visit_assignments is audited; the trigger's DELETEs are captured. Companion one-time
-- cleanup of the 9 existing scheduled orphans runs this session (backup
-- backups/2026-07-17c_visit_assignments_orphan_cleanup_before.json).
-- ROLLBACK: DROP TRIGGER trg_zz_prune_assignments_on_team_delete ON public.visit_team; DROP FUNCTION
-- public.fn_prune_visit_assignments_on_team_delete().

CREATE OR REPLACE FUNCTION public.fn_prune_visit_assignments_on_team_delete()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM public.visit_assignments va
  USING (
    SELECT DISTINCT o.visit_id
    FROM oldrows o
    JOIN public.visits v ON v.id = o.visit_id
    WHERE v.visit_status <> 'completed'
  ) t
  WHERE va.visit_id = t.visit_id
    AND NOT EXISTS (
      SELECT 1 FROM public.visit_team vt
      WHERE vt.visit_id = va.visit_id AND vt.employee_id = va.employee_id);
  RETURN NULL;  -- AFTER STATEMENT trigger
END;
$$;

DROP TRIGGER IF EXISTS trg_zz_prune_assignments_on_team_delete ON public.visit_team;
CREATE TRIGGER trg_zz_prune_assignments_on_team_delete
  AFTER DELETE ON public.visit_team
  REFERENCING OLD TABLE AS oldrows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.fn_prune_visit_assignments_on_team_delete();
