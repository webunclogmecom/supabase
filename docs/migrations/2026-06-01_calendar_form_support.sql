-- ============================================================================
-- 2026-06-01_calendar_form_support.sql
-- Backend support for the Calendar visit-creation form (Jobber write-back).
--
-- 1) visits.service_line_item_id — the 27-service classification (replaces the
--    coarse GT/CL/WD service_type as the per-visit service). FK -> service_line_items.
--    visits is already audited (Rule 8) so the new column is auto-captured.
--    3NF: the service of a visit depends on the visit (whole key) -> OK.
--    service_type (GT/CL/WD) is now deprecated-legacy, kept only for existing ops views.
--
-- 2) ops.client_jobs — read view of each client's ACTIVE jobs, for the form's "Job"
--    picker (which sets visits.job_id, the keystone for the Jobber push). Exposed to
--    the Calendar Lovable app (anon/authenticated), same as ops.v_calendar_visit.
-- ============================================================================

ALTER TABLE public.visits
  ADD COLUMN IF NOT EXISTS service_line_item_id BIGINT REFERENCES public.service_line_items(id);
CREATE INDEX IF NOT EXISTS visits_service_line_item_id_idx ON public.visits (service_line_item_id);

CREATE OR REPLACE VIEW ops.client_jobs AS
  SELECT j.id AS job_id, j.client_id, j.title, j.job_number, j.job_status
  FROM public.jobs j
  WHERE j.job_status <> 'archived';

GRANT SELECT ON ops.client_jobs TO anon, authenticated;
