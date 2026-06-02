-- 2026-06-02_client_jobs_canonical.sql
-- Rework ops.client_jobs to back the new Calendar form, where the JOB dropdown IS
-- the category (Service Agreement / Service Call / Credit card fee (3.53%) /
-- ACH Fee (1%) / GDO Online Reporting). Filters each client's Jobber jobs to ONLY
-- the canonical ones (legacy jobs like "Grease Trap Pumping" are hidden) and exposes
-- a normalized `category` so casing/spacing variants (e.g. "Service call") display
-- consistently. The form: pick Job -> derive category -> cascade Service type (L2)
-- + Detail (L3) from ops.service_options WHERE level1 = category.
-- Match is case-insensitive + trimmed; archived jobs excluded.
CREATE OR REPLACE VIEW ops.client_jobs AS
SELECT j.id AS job_id, j.client_id, j.title, j.job_number, j.job_status,
  CASE lower(btrim(j.title))
    WHEN 'service agreement'         THEN 'Service Agreement'
    WHEN 'service call'              THEN 'Service Call'
    WHEN 'credit card fee (3.53%)'   THEN 'Credit card fee (3.53%)'
    WHEN 'ach fee (1%)'              THEN 'ACH Fee (1%)'
    WHEN 'gdo online reporting'      THEN 'GDO Online Reporting'
  END AS category
FROM public.jobs j
WHERE j.job_status <> 'archived'
  AND lower(btrim(j.title)) IN (
    'service agreement','service call','credit card fee (3.53%)','ach fee (1%)','gdo online reporting');
GRANT SELECT ON ops.client_jobs TO anon, authenticated;
