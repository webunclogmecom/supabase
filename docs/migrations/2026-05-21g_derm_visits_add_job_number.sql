-- 2026-05-21g_derm_visits_add_job_number.sql
--
-- Surface the Jobber Job Number on the DERM Visits list so ops can
-- cross-reference each visit with Jobber easily. Per Fred 2026-05-21:
-- "have an ID that could help us identify easier which visit we're
-- working on".
--
-- Data source: jobs.job_number (already populated by webhook-jobber,
-- 579 of 580 jobs have it). visits.job_id → jobs.job_number.
--
-- The Jobber UI shows this as "Job # 10000121". Adding job_number
-- column to derm.visits; Lovable will render it as a chip.
--
-- Audit (Rule 8): view-only change.

BEGIN;

CREATE OR REPLACE VIEW derm.visits AS
SELECT
  v.id,
  CASE
    WHEN c.client_code IS NOT NULL AND c.name !~~ (c.client_code || '%'::text)
      THEN (c.client_code || ' '::text) || c.name
    ELSE c.name
  END AS client_name,
  COALESCE(p.address, ''::text) AS address,
  COALESCE(p.county, ''::text) AS county,
  v.visit_date::text AS visit_date,
  NULL::text AS technician,
  NULL::text AS notes,
  v.created_at::text AS created_at,
  v.client_id,
  v.service_type,
  (EXISTS (
    SELECT 1
    FROM manifest_visits mv
    JOIN derm_manifests dm ON dm.id = mv.manifest_id
    WHERE mv.visit_id = v.id
      AND (dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL)
  )) AS has_manifest,
  v.derm_required,
  COALESCE(v.derm_required, true) AS needs_manifest,
  COALESCE(
    (SELECT string_agg(li.name, ', '::text ORDER BY li.id)
       FROM line_items li
       WHERE li.invoice_id = v.invoice_id AND li.name IS NOT NULL),
    NULLIF(TRIM(SPLIT_PART(v.title, ' - ', 2)), '')
  ) AS line_items,
  COALESCE(
    (SELECT NULLIF(jsonb_agg(
              jsonb_build_object(
                'name', li.name,
                'quantity', li.quantity,
                'unit_price', li.unit_price,
                'total_price', li.total_price
              ) ORDER BY li.id), '[]'::jsonb)
       FROM line_items li
       WHERE li.invoice_id = v.invoice_id),
    '[]'::jsonb
  ) AS line_items_json,
  (SELECT g.gdo_number
     FROM gdos g
     WHERE g.client_id = c.id
       AND g.status = 'ACTIVE'
     ORDER BY g.id
     LIMIT 1) AS gdo_number,
  -- 2026-05-21g: surface Jobber job_number as recognizable visit identifier
  (SELECT j.job_number FROM jobs j WHERE j.id = v.job_id) AS job_number
FROM visits v
JOIN clients c ON c.id = v.client_id
LEFT JOIN LATERAL (
  SELECT p2.address, p2.county
  FROM properties p2
  WHERE p2.client_id = c.id
  ORDER BY
    p2.is_primary DESC NULLS LAST,
    (p2.is_billing IS NOT TRUE) DESC,
    p2.id
  LIMIT 1
) p ON true
WHERE v.visit_status = 'completed'::text;

COMMIT;

-- Verification:
--   SELECT id, visit_date, job_number FROM derm.visits WHERE id IN (5085, 5079) ORDER BY id;
--   Expected:
--     5079 → 901
--     5085 → 10000121
