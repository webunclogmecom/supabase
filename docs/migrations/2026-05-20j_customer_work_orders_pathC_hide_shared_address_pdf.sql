-- 2026-05-20j_customer_work_orders_pathC_hide_shared_address_pdf.sql
--
-- Path C from Fred 2026-05-20 chat:
-- "we as a company still needs to see the Addresses, so either we need to
--  have a new box in the DERM app where it shows the new image with the
--  blackouts of the addresses or think of other alternatives. But we could
--  go with Path C meanwhile, hiding the addresses."
--
-- The Field Portal serves the DERM "address sheet" via
--   customer.work_orders.derm_manifest_url ← canonical derm_manifests.derm_address_url
-- That sheet lists ALL clients on the dump run (6 rows per page), so a
-- customer viewing their own visit would see other clients' names+addresses.
-- Privacy leak.
--
-- Fix: only expose the address PDF when the underlying derm_manifests row's
-- white_manifest_number is unique (single-client dump). For shared dumps
-- (multi-client), return NULL — Field Portal hides the doc naturally.
-- The actual manifest receipt (wwtp_receipt_url ← derm_manifests.derm_manifest_url
-- in the intentional inverse mapping) stays exposed for all visits.
--
-- Net effect: 277 of 351 work_orders that previously exposed the address PDF
-- now return NULL for that column (was leaking other clients' info).
-- 74 work_orders (single-client manifests) keep the address PDF.
--
-- Future Path B follow-up: build per-client redacted versions of multi-client
-- sheets in DERM Tracker (ops still needs to see the full sheet); store
-- under derm/<id>/address-<client_id>.jpg and serve the client-specific URL.
-- Until then, customers don't see the address sheet for shared dumps.
--
-- Audit (Rule 8): view change only — no triggers needed. Both
-- derm_manifests + manifest_visits already audited.

BEGIN;

CREATE OR REPLACE VIEW customer.work_orders AS
SELECT
  customer.uuid_from_bigint(v.id) AS id,
  customer.uuid_from_bigint(v.client_id) AS client_id,
  v.visit_date,
  CASE
    WHEN v.start_at IS NOT NULL
      THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text)
    ELSE NULL::text
  END AS visit_time,
  (SELECT string_agg(e.full_name, ', '::text ORDER BY e.full_name)
     FROM visit_assignments va
     JOIN employees e ON e.id = va.employee_id
     WHERE va.visit_id = v.id) AS driver,
  veh.name AS truck,
  veh.decal_number AS decal,
  v.manhole_count AS manholes,
  v.manhole_breakdown,
  v.ticket_number,
  v.trap_condition_notes AS trap_condition,
  row_number() OVER (PARTITION BY v.client_id, (EXTRACT(year FROM v.visit_date)) ORDER BY v.visit_date)::integer AS visit_num,
  (SELECT CASE
            WHEN sc.frequency_days IS NULL OR sc.frequency_days <= 0 THEN NULL::integer
            ELSE GREATEST(1::numeric, round(365.0 / sc.frequency_days::numeric))::integer
          END AS greatest
     FROM service_configs sc
     WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type
     LIMIT 1) AS visit_total,
  v.title AS notes,
  dm.white_manifest_number AS derm_manifest_number,
  -- Path C: hide address PDF when the manifest is shared across multiple
  -- clients (privacy — sheet lists ALL clients on the dump). Customers
  -- still see their own per-visit receipt via wwtp_receipt_url below.
  CASE
    WHEN dm.id IS NULL THEN NULL
    WHEN (SELECT COUNT(*) FROM public.derm_manifests dm2
            WHERE dm2.white_manifest_number = dm.white_manifest_number
              AND dm.white_manifest_number IS NOT NULL) > 1
      THEN NULL
    ELSE dm.derm_address_url
  END AS derm_manifest_url,
  COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number) AS wwtp_receipt_number,
  dm.derm_manifest_url AS wwtp_receipt_url,
  dm.wwtp_ticket_number,
  v.created_at,
  COALESCE(v.completed_at, v.created_at) AS updated_at
FROM visits v
LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
LEFT JOIN properties prop ON prop.id = v.property_id
LEFT JOIN LATERAL (
  SELECT dm_inner.*
  FROM derm_manifests dm_inner
  JOIN manifest_visits mv ON mv.manifest_id = dm_inner.id
  WHERE mv.visit_id = v.id
  ORDER BY dm_inner.service_date DESC NULLS LAST
  LIMIT 1
) dm ON true
WHERE v.visit_status = 'completed' AND v.client_id IS NOT NULL;

COMMIT;

-- Verification:
--   SELECT COUNT(*) FILTER (WHERE derm_manifest_url IS NOT NULL) AS with_addr,
--          COUNT(*) FILTER (WHERE wwtp_receipt_url IS NOT NULL)  AS with_manif
--   FROM customer.work_orders;
-- Expected: with_addr ≈ 74 (was 351), with_manif ≈ 351 (unchanged).
