-- 2026-05-21a_customer_work_orders_hide_non_derm.sql
--
-- Field Portal is the DERM compliance portal. If a visit is explicitly
-- marked "DERM not required" (visits.derm_required = false), it has no
-- compliance proof to show, so hide it from the FP Service History list.
--
-- Semantics per Fred 2026-05-20: "all are DERM required unless we change
-- it manually". So:
--   derm_required = TRUE   → show (default, DERM needed)
--   derm_required = NULL   → show (treated as TRUE via COALESCE)
--   derm_required = FALSE  → HIDE (ops explicitly marked it not needed)
--
-- Same view shape as 2026-05-20k — only the WHERE changes.
-- Path C (multi-client manifest address-PDF hide) preserved.
--
-- Audit (Rule 8): view-only change, no audit trigger needed.

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
     FROM visit_assignments va JOIN employees e ON e.id = va.employee_id
     WHERE va.visit_id = v.id) AS driver,
  veh.name AS truck,
  veh.decal_number AS decal,
  v.manhole_count AS manholes,
  v.manhole_breakdown,
  v.ticket_number,
  v.trap_condition_notes AS trap_condition,
  row_number() OVER (PARTITION BY v.client_id, (EXTRACT(year FROM v.visit_date)) ORDER BY v.visit_date)::integer AS visit_num,
  (SELECT CASE WHEN sc.frequency_days IS NULL OR sc.frequency_days <= 0 THEN NULL::integer
               ELSE GREATEST(1::numeric, round(365.0 / sc.frequency_days::numeric))::integer END
     FROM service_configs sc
     WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type
     LIMIT 1) AS visit_total,
  v.title AS notes,
  dm.white_manifest_number AS derm_manifest_number,
  -- Path C: hide address PDF for multi-client dumps
  CASE
    WHEN dm.id IS NULL THEN NULL
    WHEN (SELECT COUNT(*) FROM public.derm_manifests dm2
            WHERE dm2.white_manifest_number = dm.white_manifest_number
              AND dm.white_manifest_number IS NOT NULL) > 1
      THEN NULL
    ELSE dm.derm_address_url
  END AS derm_manifest_url,
  COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number, dm.yellow_ticket_number) AS wwtp_receipt_number,
  dm.derm_manifest_url AS wwtp_receipt_url,
  dm.wwtp_ticket_number,
  v.created_at,
  COALESCE(v.completed_at, v.created_at) AS updated_at,
  COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS manifest_number,
  CASE
    WHEN dm.white_manifest_number IS NOT NULL THEN 'dade'
    WHEN dm.yellow_ticket_number  IS NOT NULL THEN 'broward'
    ELSE NULL
  END AS manifest_jurisdiction
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
WHERE v.visit_status = 'completed'
  AND v.client_id IS NOT NULL
  AND COALESCE(v.derm_required, TRUE) = TRUE;  -- 2026-05-21: hide non-DERM

COMMIT;

-- Verification:
--   Before:  SELECT COUNT(*) FROM customer.work_orders;            -- baseline
--   Flip:    UPDATE visits SET derm_required = false WHERE id = X;
--   After:   SELECT COUNT(*) FROM customer.work_orders WHERE id = customer.uuid_from_bigint(X);
--            -- should return 0 rows
--   Revert:  UPDATE visits SET derm_required = NULL WHERE id = X;
