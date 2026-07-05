-- 2026-07-04_stamp_candidates_window_fix.sql
-- Fred UX report: every card's Link popover showed "No candidate visits" even on
-- LINKED cards. Root cause: v_stamp_row_candidate_visits used ±4 days around the
-- manifest service_date — real linked visits drift further (e.g. 827989 rows:
-- manifest 2026-06-23, linked visit 2026-06-18 = 5 days). Fix:
--   * window widened to ±14 days (matches the DERM 2-week-rule tolerance), and
--   * visits ALREADY LINKED to the row's manifest are always included,
--     regardless of date (so a linked card always shows its linked visit ✓).
-- Same column list/order (CREATE OR REPLACE safe).

BEGIN;

CREATE OR REPLACE VIEW derm.v_stamp_row_candidate_visits AS
SELECT DISTINCT ON (row_id, visit_id)
       row_id, visit_id, visit_date, service_type, assigned_driver_id,
       driver_name, already_linked
FROM (
  -- candidates by proximity: the client's completed visits near the manifest date
  SELECT r.id AS row_id, v.id AS visit_id, v.visit_date, v.service_type,
         v.assigned_driver_id,
         (SELECT e.full_name FROM public.employees e WHERE e.id = v.assigned_driver_id) AS driver_name,
         EXISTS (SELECT 1 FROM public.manifest_visits mv
                  WHERE mv.manifest_id = r.matched_manifest_id AND mv.visit_id = v.id) AS already_linked
  FROM derm.address_row_map r
  JOIN public.derm_manifests m ON m.id = r.matched_manifest_id
  JOIN public.visits v ON v.client_id = r.matched_client_id
     AND v.deleted_at IS NULL
     AND v.visit_status = 'completed'
     AND v.visit_date BETWEEN m.service_date - INTERVAL '14 days' AND m.service_date + INTERVAL '14 days'
  WHERE r.matched_client_id IS NOT NULL
  UNION ALL
  -- always include what's already linked to this row's manifest (any date)
  SELECT r.id, v.id, v.visit_date, v.service_type, v.assigned_driver_id,
         (SELECT e.full_name FROM public.employees e WHERE e.id = v.assigned_driver_id),
         true
  FROM derm.address_row_map r
  JOIN public.manifest_visits mv ON mv.manifest_id = r.matched_manifest_id
  JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
  WHERE r.matched_client_id IS NOT NULL
) u
ORDER BY row_id, visit_id, already_linked DESC;

GRANT SELECT ON derm.v_stamp_row_candidate_visits TO anon, authenticated;

COMMIT;
