-- 2026-05-20d_derm_documented_requires_pdf.sql
--
-- Tighten "Documented" further. Fred 2026-05-20:
-- "if it says documented it's because we have the PDF for it."
--
-- Previously (2026-05-20c): has_manifest = at least one of PDF / address PDF
-- / white # / yellow #. That still counted 3 visits as Documented when ops
-- had entered a manifest number but hadn't uploaded the PDF yet — which
-- looks misleading on the visit detail page (no PDF to show).
--
-- Now: has_manifest = at least one PDF (derm_manifest_url OR derm_address_url).
-- Manifest number alone doesn't qualify. Those rows surface as "Missing Docs"
-- with the OCR-proposal workflow available to upload the PDF.
--
-- Net effect:
--   Documented   352 (was 355, -3)
--   Missing Docs 185 (was 182, +3)
--   Not Required 0   (unchanged)
--
-- Audit (Rule 8): view-only change.

BEGIN;

CREATE OR REPLACE VIEW derm.visits AS
SELECT
  v.id,
  CASE
    WHEN c.client_code IS NOT NULL AND c.name NOT LIKE (c.client_code || '%')
      THEN c.client_code || ' ' || c.name
    ELSE c.name
  END                                       AS client_name,
  COALESCE(p.address, '')                   AS address,
  COALESCE(p.county,  '')                   AS county,
  v.visit_date::text                        AS visit_date,
  NULL::text                                AS technician,
  NULL::text                                AS notes,
  v.created_at::text                        AS created_at,
  v.client_id,
  v.service_type,
  EXISTS (
    SELECT 1 FROM public.manifest_visits mv
    JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
    WHERE mv.visit_id = v.id
      AND (dm.derm_manifest_url IS NOT NULL
        OR dm.derm_address_url  IS NOT NULL)
  )                                         AS has_manifest,
  v.derm_required,
  COALESCE(v.derm_required, TRUE)           AS needs_manifest,
  (SELECT STRING_AGG(li.name, ', ' ORDER BY li.id)
     FROM public.line_items li
     WHERE li.job_id = v.job_id AND li.name IS NOT NULL) AS line_items,
  (SELECT COALESCE(JSONB_AGG(JSONB_BUILD_OBJECT(
            'name',        li.name,
            'quantity',    li.quantity,
            'unit_price',  li.unit_price,
            'total_price', li.total_price
          ) ORDER BY li.id), '[]'::jsonb)
     FROM public.line_items li
     WHERE li.job_id = v.job_id) AS line_items_json
FROM public.visits v
JOIN public.clients c ON c.id = v.client_id
LEFT JOIN LATERAL (
  SELECT p2.address, p2.county
  FROM public.properties p2
  WHERE p2.client_id = c.id AND p2.is_billing = false
  ORDER BY p2.id LIMIT 1
) p ON true
WHERE v.visit_status = 'completed';

COMMIT;
