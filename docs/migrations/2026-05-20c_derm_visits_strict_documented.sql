-- 2026-05-20c_derm_visits_strict_documented.sql
--
-- Fix false-positive "Documented" badges. Fred 2026-05-20: "I see some
-- visits with Documented but when I go inside I don't see any PDF, like
-- 084-ULT."
--
-- Cause: 2026-05-19c defined derm.visits.has_manifest as plain
-- EXISTS in manifest_visits. The backfill from 2026-05-19 paired each
-- DERM record to the nearest completed GT visit within a ±2 to ±10 day
-- window — and AT has 84 empty-placeholder DERM rows (no PDFs, no
-- manifest number, no dump date) that ops created but never filled in.
-- 22 visits ended up linked to these empty placeholders → showed
-- "Documented" in the DERM Tracker but had nothing to display.
--
-- Fix: tighten has_manifest to require the linked DERM has at least one
-- of: derm_manifest_url, derm_address_url, white_manifest_number,
-- yellow_ticket_number. Empty-placeholder links no longer count as
-- documented.
--
-- Net effect on counters:
--   Documented   355 (was 377, -22)
--   Missing Docs 182 (was 160, +22)
--   Not Required 0   (unchanged)
--
-- Audit (Rule 8): view-only change. Underlying public.derm_manifests +
-- public.manifest_visits are both audited. No trigger work.

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
      AND (dm.derm_manifest_url      IS NOT NULL
        OR dm.derm_address_url       IS NOT NULL
        OR dm.white_manifest_number  IS NOT NULL
        OR dm.yellow_ticket_number   IS NOT NULL)
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

-- Follow-up: the 84 empty-placeholder DERM rows are still in the DB.
-- Ops can either fill them in (via DERM Tracker upload flow) or we can
-- clean them up via derm.manifest_health view (health_state='empty_placeholder')
-- in a separate migration once Fred confirms.
