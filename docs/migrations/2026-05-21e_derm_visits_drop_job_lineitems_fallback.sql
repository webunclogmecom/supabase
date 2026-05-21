-- 2026-05-21e_derm_visits_drop_job_lineitems_fallback.sql
--
-- Refining 2026-05-21d. The job-level line_items fallback turns out to
-- be misleading on recurring/long-lived jobs.
--
-- Concrete example — Casa Neos job 132 has many historical invoices
-- (163, 222, 224, 501, 1840, ...) for different Service calls over time.
-- When a recent visit (5081, 5082) has no invoice of its own, joining
-- line_items by job_id surfaces items aggregated across ALL historical
-- invoices on that job — completely wrong for the visit being shown.
--
-- New priority:
--   1. line_items via v.invoice_id      (this visit's own invoice — accurate)
--   2. visit.title after " - "          (e.g. "Service call", "Grease trap")
--   3. NULL
--
-- The job-direct line_items (565 rows where li.job_id IS NOT NULL) are
-- quote-stage items, not invoiced. They were OK as a fallback for jobs
-- with ONE visit + ONE invoice, but they're wrong for the multi-visit
-- recurring case. The title is vague-but-correct; the job-aggregate
-- is precise-but-wrong. Always prefer the former.
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
  -- 2026-05-21e: invoice-only line_items, then title; NO job fallback
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

-- Verification: Casa Neos visits with no own invoice should now show
-- just "Service call" (parsed from title) instead of the wrong
-- 5-item aggregate.
--   SELECT id, visit_date, line_items FROM derm.visits WHERE id IN (5081, 5082, 5085) ORDER BY id;
--   Expected:
--     5081 (5/12, no invoice) → 'Service call'
--     5082 (5/12, no invoice) → 'Service call'
--     5085 (5/13, invoice 1840) → 'Hydrojet Unclogging Commercial, Drain guards GDL 3000'
