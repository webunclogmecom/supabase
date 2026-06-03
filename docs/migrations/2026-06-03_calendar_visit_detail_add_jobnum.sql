-- Migration: ops.v_calendar_visit_detail — add jobber_job_number (for the drawer "Job #" link)
-- Date:   2026-06-03
-- Author: Claude, directed by Fred — Service Agreement visit-generation §10 (drawer redesign)
--
-- Adds the Jobber JOB NUMBER (jobs.job_number, e.g. 11100534) so the drawer can show a
-- "Job #" row linking to the Jobber job. New column appended at the end -> CREATE OR REPLACE safe.
-- 3NF: derived (job_number is a referenced job attribute), read-only view, no audit impact.

CREATE OR REPLACE VIEW ops.v_calendar_visit_detail AS
SELECT
  v.id            AS visit_id,
  v.job_id,
  v.client_id,
  v.title,
  v.visit_date,
  v.visit_status,
  v.derm_required,
  CASE
    WHEN j.title ILIKE 'Service Agreement%' THEN 'service_agreement'
    WHEN j.title ILIKE 'Service Call%'      THEN 'service_call'
    ELSE NULL
  END AS service_kind,
  j.frequency_days AS agreement_frequency_days,
  CASE WHEN esl.source_id IS NOT NULL
    THEN 'https://secure.getjobber.com/work_orders/' ||
         split_part(convert_from(decode(esl.source_id, 'base64'), 'UTF8'), '/', -1)
    ELSE NULL
  END AS jobber_job_url,
  COALESCE(jli.items, '[]'::json) AS line_items,
  j.job_number AS jobber_job_number
FROM visits v
LEFT JOIN jobs j ON j.id = v.job_id
LEFT JOIN entity_source_links esl
  ON esl.entity_type = 'job' AND esl.source_system = 'jobber' AND esl.entity_id = v.job_id
LEFT JOIN LATERAL (
  SELECT json_agg(
           json_build_object('name', li.name, 'description', li.description, 'quantity', li.quantity)
           ORDER BY li.name
         ) AS items
  FROM line_items li
  WHERE li.job_id = v.job_id AND li.invoice_id IS NULL
) jli ON true
WHERE v.deleted_at IS NULL;

GRANT SELECT ON ops.v_calendar_visit_detail TO anon, authenticated;

NOTIFY pgrst, 'reload schema';
