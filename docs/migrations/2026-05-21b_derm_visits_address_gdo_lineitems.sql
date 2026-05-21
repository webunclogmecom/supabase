-- 2026-05-21b_derm_visits_address_gdo_lineitems.sql
--
-- Three DERM Visits-list fixes Fred flagged 2026-05-21:
--
-- 1) line_items: currently shows "GT"/"CL" code when no invoiced line items
--    exist for the job. Add title-after-dash fallback so visits like
--    "209-TRUE True Barista Truck - Grey water pumping" surface the actual
--    service name even before invoicing. Invoiced line_items still win.
--
-- 2) gdo_number: NEW column. Visits should show the GDO permit # for the
--    location. Sourced from gdos.client_id (since gdos.property_id is not
--    yet backfilled — happens in 2026-05-21c). When multi-GDO clients (e.g.
--    Casa Neos) gain property_id linkage, switch the join to property-level.
--
-- 3) address: current LATERAL join requires is_billing=false, which returns
--    NULL for clients whose only property is the billing property
--    (208-HUB, 209-TRUE, 214-PER, etc.). New priority: is_primary first,
--    then any non-billing, then any property as last resort.
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
  -- 2026-05-21b: title-after-dash fallback when no invoiced line items exist
  COALESCE(
    (SELECT string_agg(li.name, ', '::text ORDER BY li.id)
       FROM line_items li
       WHERE li.job_id = v.job_id AND li.name IS NOT NULL),
    NULLIF(TRIM(SPLIT_PART(v.title, ' - ', 2)), '')
  ) AS line_items,
  (SELECT COALESCE(jsonb_agg(
            jsonb_build_object(
              'name', li.name,
              'quantity', li.quantity,
              'unit_price', li.unit_price,
              'total_price', li.total_price
            ) ORDER BY li.id),
          '[]'::jsonb)
     FROM line_items li
     WHERE li.job_id = v.job_id) AS line_items_json,
  -- 2026-05-21b: new gdo_number column (client-level until property_id backfill)
  (SELECT g.gdo_number
     FROM gdos g
     WHERE g.client_id = c.id
       AND g.status = 'ACTIVE'
     ORDER BY g.id
     LIMIT 1) AS gdo_number
FROM visits v
JOIN clients c ON c.id = v.client_id
-- 2026-05-21b: address priority — is_primary → any non-billing → any
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
--   Line items fallback:
--     SELECT id, service_type, line_items FROM derm.visits WHERE id = 5028;
--     -- expect: line_items = 'Grey water pumping' (parsed from title)
--
--   Address fix:
--     SELECT id, client_name, address FROM derm.visits WHERE id IN (5028, 5043, 5086);
--     -- expect: all 3 now have addresses (was empty)
--
--   GDO column:
--     SELECT id, client_name, gdo_number FROM derm.visits WHERE gdo_number IS NOT NULL LIMIT 5;
--     -- expect: GDO-NNNNN values
