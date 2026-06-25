-- 2026-06-25_visit_team_backfill_from_driver.sql
-- Backfill public.visit_team from visits.assigned_driver_id for the handful of
-- pre-Team-feature visits that carried a single driver but no normalized team row.
--
-- Context: the Team feature (migration 2026-06-25_visit_team.sql) made the Calendar
-- drawer load a visit's crew from ops.v_visit_team. Visits created via the OLD
-- single-driver path have assigned_driver_id set but no visit_team row, so the drawer
-- would show an empty Team (and saving could clear the driver). This makes the
-- normalized table consistent with the existing assigned_driver_id.
--
-- Scope at apply time: 4 active visits (6805-6808). Non-recurring: only 4 of 1414
-- active visits ever had assigned_driver_id, so the Jobber inbound poll does NOT set
-- drivers and the gap will not grow. Re-run anytime; idempotent.
--
-- Safe: the Jobber push trigger lives on `visits` (trg_push_visit_update via team_rev),
-- NOT on visit_team, so these inserts do NOT re-push to Jobber. Only audit_visit_team
-- logs them.

INSERT INTO public.visit_team (visit_id, employee_id)
SELECT v.id, v.assigned_driver_id
FROM public.visits v
WHERE v.deleted_at IS NULL
  AND v.assigned_driver_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.visit_team vt WHERE vt.visit_id = v.id)
ON CONFLICT (visit_id, employee_id) DO NOTHING;

-- Verify: expect 0
-- SELECT count(*) FROM public.visits v
-- WHERE v.deleted_at IS NULL AND v.assigned_driver_id IS NOT NULL
--   AND NOT EXISTS (SELECT 1 FROM public.visit_team vt WHERE vt.visit_id = v.id);
