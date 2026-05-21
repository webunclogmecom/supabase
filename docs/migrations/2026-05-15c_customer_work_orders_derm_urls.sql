-- 2026-05-15c_customer_work_orders_derm_urls.sql
--
-- Surface the two new DERM-attachment URLs (added in 2026-05-15b) through the
-- customer.work_orders view, per Fred's 2026-05-15 UI-mapping decision:
--
--   UI "DERM FOG eManifest"   PDF ← AT "DERM Address"  attachment (canonical derm_address_url)
--   UI "WWTP Disposal Receipt" PDF ← AT "DERM Manifest" attachment (canonical derm_manifest_url)
--
-- The view's column names stay the same (Lovable's Field Portal app reads
-- `derm_manifest_url` and `wwtp_receipt_url`), but the SOURCE columns swap
-- compared to the literal canonical column names. The mapping is intentional
-- — see comments in the view body.
--
-- Prereq: 2026-05-15b_derm_manifest_documents.sql (creates the two source columns).

BEGIN;

CREATE OR REPLACE VIEW customer.work_orders AS
SELECT
  customer.uuid_from_bigint(v.id) AS id,
  customer.uuid_from_bigint(v.client_id) AS client_id,
  v.visit_date,
  CASE WHEN v.start_at IS NOT NULL
       THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text)
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
  (SELECT CASE WHEN sc.frequency_days IS NULL OR sc.frequency_days <= 0 THEN NULL::integer
              ELSE GREATEST(1::numeric, round(365.0 / sc.frequency_days::numeric))::integer END
     FROM service_configs sc
     WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type
     LIMIT 1) AS visit_total,  -- frequency_days IS NULL OR <=0 → NULL (was: only NULL — div-by-zero on 0)
  v.title AS notes,
  dm.white_manifest_number AS derm_manifest_number,
  -- INTENTIONAL inverse mapping: view's `derm_manifest_url` exposes the canonical
  -- `derm_address_url` because Fred's UI maps "DERM FOG eManifest" to AT's
  -- "DERM Address" attachment. See migration 2026-05-15c header for rationale.
  dm.derm_address_url AS derm_manifest_url,
  -- Fred 2026-05-15 'Option A' decision: the Field Portal UI is number-gated
  -- (won't render the URL when the number is NULL), so fall back to
  -- white_manifest_number when wwtp_receipt_number is still empty. When a real
  -- WWTP receipt # ever lands, it takes precedence over the DERM #.
  COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number) AS wwtp_receipt_number,
  -- INTENTIONAL inverse mapping: view's `wwtp_receipt_url` exposes the canonical
  -- `derm_manifest_url` because Fred's UI maps "WWTP Disposal Receipt" to AT's
  -- "DERM Manifest" attachment.
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
WHERE v.visit_status = 'completed'::text AND v.client_id IS NOT NULL;

COMMIT;
