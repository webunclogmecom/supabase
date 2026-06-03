-- Migration: relax ops.client_jobs to PREFIX-match Service Agreement / Service Call jobs
-- Date:   2026-06-03
-- Author: Claude, directed by Fred
--
-- The calendar "New Visit" form sources a client's selectable jobs from ops.client_jobs.
-- It previously matched job titles EXACTLY against the category list, which HID
-- descriptive titles like "Service Agreement - Pumping" (112-YA's correct SA job) while
-- the bare "Service Call" passed. Per Fred's decision (descriptive job titles, recreated
-- per client), match SA/SC jobs by TITLE PREFIX so "Service Agreement - <anything>" and
-- "Service Call - <anything>" are recognized. This also lets one client carry multiple
-- Service Agreement jobs at different frequencies.
--
-- Unchanged: fee/reporting categories keep their EXACT match; archived jobs stay excluded;
-- output columns are identical (CREATE OR REPLACE preserves existing GRANTs to anon/auth).

CREATE OR REPLACE VIEW ops.client_jobs AS
  SELECT id AS job_id,
         client_id,
         title,
         job_number,
         job_status,
         CASE
           WHEN lower(btrim(title)) LIKE 'service agreement%'   THEN 'Service Agreement'
           WHEN lower(btrim(title)) LIKE 'service call%'        THEN 'Service Call'
           WHEN lower(btrim(title)) = 'credit card fee (3.53%)' THEN 'Credit card fee (3.53%)'
           WHEN lower(btrim(title)) = 'ach fee (1%)'            THEN 'ACH Fee (1%)'
           WHEN lower(btrim(title)) = 'gdo online reporting'    THEN 'GDO Online Reporting'
           ELSE NULL
         END AS category
  FROM jobs j
  WHERE job_status <> 'archived'
    AND (
      lower(btrim(title)) LIKE 'service agreement%'
      OR lower(btrim(title)) LIKE 'service call%'
      OR lower(btrim(title)) = ANY (ARRAY['credit card fee (3.53%)', 'ach fee (1%)', 'gdo online reporting'])
    );

NOTIFY pgrst, 'reload schema';
