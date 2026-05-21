-- 2026-05-21d_derm_visits_invoice_lineitems_priority.sql
--
-- Fix wrong line_items on the DERM Visits list. The view was joining
-- line_items via v.job_id, but in Jobber:
--   * Job → multiple Visits, ONE set of "planned/quote" line items per Job
--   * Visit → ONE Invoice with its own ACTUAL billed line items
--
-- So `WHERE li.job_id = v.job_id` returns OLD planned items, identical for
-- every visit on the same job. Fred's example:
--   Casa Neos 5/13 (visit 5085, job 132, invoice 1840):
--     job-path  → 5 items: "Water supply line connection..." x3,
--                  "Install drain guards", "Faucet installation"  ← WRONG
--     invoice-path → 2 items: "Hydrojet Unclogging Commercial",
--                  "Drain guards GDL 3000"                         ← RIGHT
--
-- Counts in DB: 565 line_items by job, 2,827 by invoice. The invoice path
-- is the source of truth, the job path is the fallback for un-invoiced
-- (e.g. recent) visits.
--
-- New priority: invoice_id → job_id → title-after-dash → NULL.
-- Path C (Path-style filter on multi-client manifests) doesn't apply here.
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
  -- 2026-05-21d: invoice-first priority, job-fallback, title-fallback
  COALESCE(
    (SELECT string_agg(li.name, ', '::text ORDER BY li.id)
       FROM line_items li
       WHERE li.invoice_id = v.invoice_id AND li.name IS NOT NULL),
    (SELECT string_agg(li.name, ', '::text ORDER BY li.id)
       FROM line_items li
       WHERE li.job_id = v.job_id AND li.name IS NOT NULL),
    NULLIF(TRIM(SPLIT_PART(v.title, ' - ', 2)), '')
  ) AS line_items,
  -- JSON: prefer invoice line_items (with prices), else job's
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
    (SELECT NULLIF(jsonb_agg(
              jsonb_build_object(
                'name', li.name,
                'quantity', li.quantity,
                'unit_price', li.unit_price,
                'total_price', li.total_price
              ) ORDER BY li.id), '[]'::jsonb)
       FROM line_items li
       WHERE li.job_id = v.job_id),
    '[]'::jsonb
  ) AS line_items_json,
  (SELECT g.gdo_number
     FROM gdos g
     WHERE g.client_id = c.id
       AND g.status = 'ACTIVE'
     ORDER BY g.id
     LIMIT 1) AS gdo_number
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
--   SELECT id, visit_date, line_items FROM derm.visits WHERE id = 5085;
--   -- expect: 'Hydrojet Unclogging Commercial, Drain guards GDL 3000'
--
-- Audit how many visits get line_items from each source:
--   SELECT
--     COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM line_items li WHERE li.invoice_id = v.invoice_id)) AS via_invoice,
--     COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM line_items li WHERE li.invoice_id = v.invoice_id)
--                          AND EXISTS (SELECT 1 FROM line_items li WHERE li.job_id = v.job_id)) AS via_job,
--     COUNT(*) FILTER (WHERE v.title LIKE '% - %') AS could_use_title_fallback
--   FROM visits v WHERE v.visit_status='completed';
