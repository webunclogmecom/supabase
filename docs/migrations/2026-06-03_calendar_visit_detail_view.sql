-- Migration: ops.v_calendar_visit_detail — Visit Calendar drawer detail
-- Date:   2026-06-03
-- Author: Claude, directed by Fred — Service Agreement visit-generation (§9)
-- Spec:   Supabase/docs/service-agreement-visit-generation.md
--
-- Purpose: the per-visit fields the grid view (ops.v_calendar_visit) doesn't carry, for
--   the right-side drawer: service_kind (Service Agreement vs Service Call), the agreement
--   frequency (jobs.frequency_days), the Jobber job deep-link (work_orders URL decoded from
--   the job GID), and the job's line items as JSON. The Lovable drawer fetches ONE row by
--   visit_id when a visit is opened (keeps line-item aggregation off the full grid).
--
-- 3NF: every added column is DERIVED (title -> service_kind; job GID -> URL; job ->
--   frequency; line_items via job_id) — nothing is stored. Read-only view, no audit impact.

CREATE OR REPLACE VIEW ops.v_calendar_visit_detail AS
SELECT
  v.id            AS visit_id,
  v.job_id,
  v.client_id,
  v.title,
  v.visit_date,
  v.visit_status,
  v.derm_required,
  -- service_kind comes from the JOB title (authoritative), not the visit title:
  -- visit titles vary (a manual Service Call visit may be titled by its line item,
  -- e.g. "17 - Service Call - Unclogging ..."), but the job title is canonical.
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
  COALESCE(jli.items, '[]'::json) AS line_items
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
