-- ============================================================================
-- ops.client_jobs — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.client_jobs AS
SELECT id AS job_id,
    client_id,
    title,
    job_number,
    job_status,
        CASE
            WHEN lower(btrim(title)) ~~ 'service agreement%'::text THEN 'Service Agreement'::text
            WHEN lower(btrim(title)) ~~ 'service call%'::text THEN 'Service Call'::text
            WHEN lower(btrim(title)) = 'credit card fee (3.53%)'::text THEN 'Credit card fee (3.53%)'::text
            WHEN lower(btrim(title)) = 'ach fee (1%)'::text THEN 'ACH Fee (1%)'::text
            WHEN lower(btrim(title)) = 'gdo online reporting'::text THEN 'GDO Online Reporting'::text
            ELSE NULL::text
        END AS category
   FROM jobs j
  WHERE job_status <> 'archived'::text AND (lower(btrim(title)) ~~ 'service agreement%'::text OR lower(btrim(title)) ~~ 'service call%'::text OR (lower(btrim(title)) = ANY (ARRAY['credit card fee (3.53%)'::text, 'ach fee (1%)'::text, 'gdo online reporting'::text])));
