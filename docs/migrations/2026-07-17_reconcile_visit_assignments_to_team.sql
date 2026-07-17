-- 2026-07-17 — visit_assignments FULL-SYNC to the authoritative current crew (visit_team)
--
-- WHY: the driver shown on a visit (Calendar avatar, Admin Review "Driver", FP work order,
-- ops.v_driver_kpi, ops.v_route_today, exports) is derived from public.visit_assignments. That
-- table is written UPSERT-ONLY / "never deletes" by webhook-jobber handleVisit (index.ts ~L851,
-- "historical crew record"), whereas public.visit_team is DELETE+INSERT of Jobber's CURRENT
-- assignedUsers (syncVisitTeamFromJobber, ~L514-531). So when a visit's Jobber crew is corrected
-- (e.g. Aaron was tentatively assigned, then it became just Mark), visit_team becomes {Mark} but
-- visit_assignments fossilizes {Aaron, Mark}. ops.v_calendar_visit.first_assignment then picks the
-- LOWEST employee_id (DISTINCT ON ... ORDER BY visit_id, employee_id), so the stale ghost wins
-- (Aaron 26 < Mark 35). Result: 186-PV visit 5843 showed driver "Aaron" though Jobber's
-- assignedUsers = only Mark (API-confirmed). DB-wide: 41 ghost rows / 36 visits.
--
-- The 2026-07-14 mirror trigger (fn_mirror_visit_team_to_assignments) was FILL-EMPTY
-- (ON CONFLICT DO NOTHING, only when assignments empty) — it fixed driver COVERAGE but never
-- removes a ghost. This migration changes it to FULL-SYNC: on any visit_team INSERT, make
-- visit_assignments EXACTLY equal visit_team for the touched visits (delete not-in-team + insert
-- missing). Because handleVisit upserts assignments (L851) THEN re-syncs visit_team (L869), the
-- trigger reconciles away any ghost the upsert just added — durable, path-independent (webhook,
-- backfill_visit_assignments_from_jobber.js, dump-visit-create, Calendar RPC), NO webhook change.
--
-- SAFE: visit_assignments carries NO independent data — it is 100% Jobber-assignedUsers-sourced
-- (same source as visit_team; verified 2026-07-14 audit + red-team: 0 GPS-confirmed ghosts, 0
-- GPS-confirmed assignments-only visits, no non-Jobber writer). No FK references visit_assignments.
-- The only other trigger on it is audit_visit_assignments (writes audit.logs; no recursion).
--
-- Companion one-time reconcile of the existing 41 ghost rows is applied in the same session
-- (backup backups/2026-07-17_visit_assignments_before_ghost_reconcile.json). The FILL-EMPTY-era
-- residual: if Jobber returns NO crew, syncVisitTeamFromJobber empties visit_team with no INSERT,
-- so the trigger does not fire and prior assignments are retained (keep-historical-driver) — rare,
-- intentional.
--
-- AUDIT (ADR-010): visit_assignments is already audited (trigger audit_visit_assignments). This
-- migration only replaces a function body and adds no new audited object.
-- ROLLBACK: restore backups/2026-07-17_fn_mirror_visit_team_to_assignments_before.sql (the
-- FILL-EMPTY body); the trigger name/definition is unchanged.

CREATE OR REPLACE FUNCTION public.fn_mirror_visit_team_to_assignments()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- (a) remove ghosts: any assignment for a touched visit that is NOT in the current crew
  DELETE FROM public.visit_assignments va
  USING (SELECT DISTINCT visit_id FROM newrows) t
  WHERE va.visit_id = t.visit_id
    AND NOT EXISTS (
      SELECT 1 FROM public.visit_team vt
      WHERE vt.visit_id = va.visit_id AND vt.employee_id = va.employee_id);

  -- (b) add any current-crew member missing from assignments (fill), idempotent
  INSERT INTO public.visit_assignments (visit_id, employee_id)
  SELECT vt.visit_id, vt.employee_id
  FROM public.visit_team vt
  WHERE vt.visit_id IN (SELECT DISTINCT visit_id FROM newrows)
  ON CONFLICT (visit_id, employee_id) DO NOTHING;

  RETURN NULL;  -- AFTER STATEMENT trigger
END;
$$;

-- trigger definition unchanged (AFTER INSERT STATEMENT on visit_team, transition table newrows);
-- recreated idempotently so a fresh apply is self-contained.
DROP TRIGGER IF EXISTS trg_zz_mirror_team_to_assignments ON public.visit_team;
CREATE TRIGGER trg_zz_mirror_team_to_assignments
  AFTER INSERT ON public.visit_team
  REFERENCING NEW TABLE AS newrows
  FOR EACH STATEMENT
  EXECUTE FUNCTION public.fn_mirror_visit_team_to_assignments();
