-- 2026-06-23_client_service_options_view.sql
-- Purpose: back the Calendar App's redesigned "Create Visit" form. One row per
--   (client, non-archived Service Call / Service Agreement job), with the job kind,
--   frequency, property, and — for SA jobs — the agreed SERVICES (line_items joined to the
--   canonical service_line_items taxonomy by the leading "NN -" code). The form reads this to
--   know, per client, whether they go SC or SA and what services apply.
-- Audit (ADR 010): VIEW — no audit trigger (views are not audited; underlying tables already
--   carry their own audit posture). Read-only, anon + authenticated SELECT.
-- Depends on: public.jobs, public.clients, public.line_items (job-scoped, freshened by
--   scripts/sync/sync_job_line_items.js), public.service_line_items.

CREATE OR REPLACE VIEW ops.client_service_options AS
SELECT
  c.id            AS client_id,
  c.client_code,
  c.name          AS client_name,
  j.id            AS job_id,
  j.job_number,
  CASE WHEN j.title ILIKE 'Service Agreement%' THEN 'SA' ELSE 'SC' END AS job_kind,
  j.title         AS job_title,
  j.frequency_days,
  j.property_id,
  COALESCE(svc.services, '[]'::json) AS services
FROM public.jobs j
JOIN public.clients c ON c.id = j.client_id
LEFT JOIN LATERAL (
  SELECT json_agg(
           json_build_object(
             'service_line_item_id', sli.id,
             'code',          sli.code,
             'title',         sli.title,
             'requires_derm', sli.requires_derm,
             'service_type',  sli.service_type,
             'unit_price',    li.unit_price
           ) ORDER BY sli.code
         ) AS services
  FROM public.line_items li
  JOIN public.service_line_items sli
    ON sli.code = lpad(substring(btrim(li.name) FROM '^([0-9]+)'), 2, '0')
  WHERE li.job_id = j.id
    AND sli.schedulable = true       -- real services only (excludes fees 25/26 + GDO 27)
) svc ON true
WHERE j.job_status <> 'archived'
  AND (j.title ILIKE 'Service Agreement%' OR j.title = 'Service Call')
  AND j.title NOT ILIKE '%[OLD]%';

GRANT SELECT ON ops.client_service_options TO anon, authenticated;
