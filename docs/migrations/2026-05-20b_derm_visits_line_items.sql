-- 2026-05-20b_derm_visits_line_items.sql
--
-- Surfaces Jobber line items in the DERM Tracker. Fred 2026-05-20:
-- "I want to save the Line Items which you see in Jobber for the visit,
--  and I want to see it in the DERM app where in the listed table it says
--  Service Type, just show the Line item of that visit instead."
--
-- Data already present in public.line_items (Jobber-synced, 565 rows across
-- 448 jobs). 466 of 537 completed visits (87%) have at least one line item
-- via their parent job; the remaining 71 are either job-less or
-- pre-line-items-sync jobs. App should fall back to service_type when null.
--
-- Two flavors added so the UI can pick:
--   `line_items`        text — comma-separated names ("Grease Trap Pumping, Service Agreement")
--                       cheap to render in list rows.
--   `line_items_json`   jsonb — full array of {name, quantity, unit_price, total_price}
--                       for visit detail page where ops want the full receipt.
--
-- 3NF check (Rule 2): the view computes from public.line_items (FK via
-- visits.job_id → jobs.id → line_items.job_id). Nothing stored
-- redundantly. STRING_AGG / JSONB_AGG are computed on read.
--
-- Audit (Rule 8): view-only change. Underlying public.visits + line_items
-- are both audited (audit_visits since 2026-05-17). No trigger work.

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
  EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id) AS has_manifest,
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

-- Verification (run after deploy):
--   SELECT COUNT(*) FILTER (WHERE line_items IS NOT NULL AND line_items != '') AS with_line_items,
--          COUNT(*) AS total
--   FROM derm.visits;
-- Expected: with_line_items ≈ 466, total ≈ 537.
