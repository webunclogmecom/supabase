-- 2026-07-14 — mirror visit_team -> visit_assignments (fill-empty) so DB-generated visits keep a driver
--
-- WHY: visit_assignments (which feeds the Calendar driver avatar + Admin Review "Driver") is populated
-- from Jobber assignedUsers by webhook-jobber handleVisit (index.ts ~L839). The 2026-06-27 DB-mastered
-- early-return (source IN ('supabase_cron','visit-calendar'), L707-712) mirrors crew into visit_team but
-- RETURNS before that L839 upsert, so DB-generated visits get visit_team but blank visit_assignments ->
-- driver "Unassigned" (7d driver coverage fell 100%->24% as visit-gen moved DB-side). visit_team and
-- visit_assignments are the SAME Jobber-crew source (96% identical), so we mirror.
--
-- This AFTER INSERT STATEMENT trigger on visit_team copies the crew into visit_assignments for any
-- touched visit that has NO visit_assignments yet (FILL-EMPTY: never overwrites an existing set, matching
-- the L839 "upsert-only, never deletes" semantics; leaves the 4% that legitimately differ untouched).
-- Path-independent: fires for the webhook sync, backfill_visit_assignments_from_jobber.js, and any future
-- writer. Uses a transition table so it sees the full inserted crew even for multi-row inserts. Idempotent
-- (ON CONFLICT DO NOTHING).
--
-- Audit (ADR-010): visit_assignments stays audit-opt-out (link table, no human-editable field); this
-- trigger adds none. Backfill of existing driverless visits already done 2026-07-14
-- (backups/2026-07-14_visit_assignments_backfill_from_team.json). Rollback: DROP TRIGGER + DROP FUNCTION.

CREATE OR REPLACE FUNCTION public.fn_mirror_visit_team_to_assignments()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO public.visit_assignments (visit_id, employee_id)
  SELECT vt.visit_id, vt.employee_id
  FROM public.visit_team vt
  WHERE vt.visit_id IN (SELECT DISTINCT visit_id FROM newrows)
    AND NOT EXISTS (SELECT 1 FROM public.visit_assignments va WHERE va.visit_id = vt.visit_id)
  ON CONFLICT (visit_id, employee_id) DO NOTHING;
  RETURN NULL;  -- AFTER STATEMENT trigger
END;
$$;

DROP TRIGGER IF EXISTS trg_zz_mirror_team_to_assignments ON public.visit_team;
CREATE TRIGGER trg_zz_mirror_team_to_assignments
  AFTER INSERT ON public.visit_team
  REFERENCING NEW TABLE AS newrows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.fn_mirror_visit_team_to_assignments();
