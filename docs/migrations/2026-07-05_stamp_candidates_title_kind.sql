-- 2026-07-05_stamp_candidates_title_kind.sql
-- Fred: the Link popover showed raw service_type codes (GT/CL); it should show
-- the visit's TITLE and whether it's SA (service agreement) or SC (service call),
-- like the Calendar does. Appends visit_title + service_kind to
-- derm.v_stamp_row_candidate_visits (same leading columns, CREATE OR REPLACE safe).
--   * visit_title: the job title when present, else the visit title with the
--     redundant "CODE Client - " prefix stripped (the card already names the client).
--   * service_kind: lightweight replica of ops.v_calendar_visit's derivation —
--     'SC' on service-call/emergency titles; 'SA' when the job is recurring
--     (2+ visits on the same job ≈ the Calendar's median-gap signal) or the title
--     says grease/grey water/service agreement; else 'SC'. Deliberately NOT a
--     dependency on ops.v_calendar_visit (a view dependency would block the other
--     session's frequent CREATE OR REPLACE of it).

BEGIN;

CREATE OR REPLACE VIEW derm.v_stamp_row_candidate_visits AS
SELECT DISTINCT ON (row_id, visit_id)
       row_id, visit_id, visit_date, service_type, assigned_driver_id,
       driver_name, already_linked, visit_title, service_kind
FROM (
  SELECT r.id AS row_id, v.id AS visit_id, v.visit_date, v.service_type,
         v.assigned_driver_id,
         (SELECT e.full_name FROM public.employees e WHERE e.id = v.assigned_driver_id) AS driver_name,
         EXISTS (SELECT 1 FROM public.manifest_visits mv
                  WHERE mv.manifest_id = r.matched_manifest_id AND mv.visit_id = v.id) AS already_linked,
         coalesce(nullif(btrim(j.title), ''),
                  nullif(substring(v.title from ' - (.*)$'), ''),
                  v.title) AS visit_title,
         CASE
           WHEN lower(coalesce(j.title, v.title, '')) ~ '(service call|emergency)' THEN 'SC'
           WHEN (SELECT count(*) FROM public.visits v2
                  WHERE v2.job_id = v.job_id AND v.job_id IS NOT NULL) > 1
             OR lower(coalesce(j.title, v.title, '')) ~ '(grease|grey water|service agreement)'
           THEN 'SA'
           ELSE 'SC'
         END AS service_kind
  FROM derm.address_row_map r
  JOIN public.derm_manifests m ON m.id = r.matched_manifest_id
  JOIN public.visits v ON v.client_id = r.matched_client_id
     AND v.deleted_at IS NULL
     AND v.visit_status = 'completed'
     AND v.visit_date BETWEEN m.service_date - INTERVAL '14 days' AND m.service_date + INTERVAL '14 days'
  LEFT JOIN public.jobs j ON j.id = v.job_id
  WHERE r.matched_client_id IS NOT NULL
  UNION ALL
  SELECT r.id, v.id, v.visit_date, v.service_type, v.assigned_driver_id,
         (SELECT e.full_name FROM public.employees e WHERE e.id = v.assigned_driver_id),
         true,
         coalesce(nullif(btrim(j.title), ''),
                  nullif(substring(v.title from ' - (.*)$'), ''),
                  v.title),
         CASE
           WHEN lower(coalesce(j.title, v.title, '')) ~ '(service call|emergency)' THEN 'SC'
           WHEN (SELECT count(*) FROM public.visits v2
                  WHERE v2.job_id = v.job_id AND v.job_id IS NOT NULL) > 1
             OR lower(coalesce(j.title, v.title, '')) ~ '(grease|grey water|service agreement)'
           THEN 'SA'
           ELSE 'SC'
         END
  FROM derm.address_row_map r
  JOIN public.manifest_visits mv ON mv.manifest_id = r.matched_manifest_id
  JOIN public.visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL
  LEFT JOIN public.jobs j ON j.id = v.job_id
  WHERE r.matched_client_id IS NOT NULL
) u
ORDER BY row_id, visit_id, already_linked DESC;

GRANT SELECT ON derm.v_stamp_row_candidate_visits TO anon, authenticated;

COMMIT;
