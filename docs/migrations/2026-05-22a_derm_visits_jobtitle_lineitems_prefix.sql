-- 2026-05-22a_derm_visits_jobtitle_lineitems_prefix.sql
--
-- Per Fred 2026-05-22: line_items column should be prefixed with the
-- Jobber job title so a row reads "Service call - Hydrojet Unclogging
-- Commercial, Drain guards GDL 3000" instead of bare "Hydrojet...".
--
-- The job title gives the WHY ("Service call", "Scheduled GT",
-- "Emergency call"); the line items give the WHAT was billed.
--
-- Format precedence:
--   1. {jobs.title} - {invoice line items}    (full, when both exist)
--   2. {jobs.title}                            (no invoice yet)
--   3. {parsed title after " - "}              (no job/no title)
--
-- All branches resolve to clean TEXT. NULL kept when nothing usable.
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
  -- 2026-05-22a: prefix with job title when available; fallback to
  -- visit-title (more specific than job title for un-invoiced visits).
  COALESCE(
    -- Branch 1: job title + invoice line items (most complete)
    (SELECT NULLIF(TRIM(j.title), '') || ' - ' ||
            (SELECT string_agg(li.name, ', ' ORDER BY li.id)
               FROM line_items li
               WHERE li.invoice_id = v.invoice_id AND li.name IS NOT NULL)
       FROM jobs j
       WHERE j.id = v.job_id
         AND j.title IS NOT NULL AND TRIM(j.title) <> ''
         AND EXISTS (SELECT 1 FROM line_items li WHERE li.invoice_id = v.invoice_id AND li.name IS NOT NULL)),
    -- Branch 2: invoice line items only (no job title)
    (SELECT string_agg(li.name, ', ' ORDER BY li.id)
       FROM line_items li
       WHERE li.invoice_id = v.invoice_id AND li.name IS NOT NULL),
    -- Branch 3: parsed visit title (specific "what was done" per visit;
    -- e.g. "Grey water pumping" for a food-truck visit on a job categorized
    -- as "Grease trap pumping")
    NULLIF(TRIM(SPLIT_PART(v.title, ' - ', 2)), ''),
    -- Branch 4: job title only (last resort, when visit title has no " - ")
    (SELECT NULLIF(TRIM(j.title), '') FROM jobs j WHERE j.id = v.job_id)
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
--   SELECT id, line_items FROM derm.visits WHERE id IN (5085, 5079, 5081) ORDER BY id;
--   Expected:
--     5079 (Grease Trap Pumping job + invoice) → "Grease Trap Pumping - Grease Trap Pumping"
--     5081 (Service call job, no invoice)      → "Service call"
--     5085 (Service call job + invoice 1840)   → "Service call - Hydrojet Unclogging Commercial, Drain guards GDL 3000"
