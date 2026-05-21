-- 2026-05-20k_customer_work_orders_jurisdiction_columns.sql
--
-- Fix the "Awaiting Paperwork" chip showing on Broward visits that
-- actually had complete paperwork. Fred 2026-05-20:
-- "i see visits that already have paperwork (the pdfs) with all the
--  data, but i still see things like `awaiting paperwork`..."
--
-- Root cause: customer.work_orders.derm_manifest_number returned
-- dm.white_manifest_number only. For Broward visits, white is NULL
-- (correctly) and the relevant identifier is yellow_ticket_number.
-- The Field Portal chip logic checks `derm_manifest_number IS NULL`
-- → Awaiting Paperwork, so all 62 Broward visits flipped wrong.
--
-- Also: wwtp_receipt_number had the same gap — COALESCE skipped
-- yellow_ticket_number. Both fixed.
--
-- Strategy: keep existing columns same (no breakage), append two
-- jurisdiction-aware columns at the end:
--   manifest_number       = COALESCE(white, yellow)
--   manifest_jurisdiction = 'dade' | 'broward' | NULL
-- Field Portal UI should use these for the chip + label.
--
-- Net effect: 369 of 547 visits now have manifest_number (was 307).
-- 62 Broward visits will flip from "Awaiting" → "Documented" on
-- next Lovable UI build.
--
-- Audit (Rule 8): view-only change.
-- Path C from 2026-05-20j (hide address PDF for multi-client manifests)
-- preserved in this rewrite.

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
  -- Path C (2026-05-20j): hide address PDF for multi-client dumps
  CASE
    WHEN dm.id IS NULL THEN NULL
    WHEN (SELECT COUNT(*) FROM public.derm_manifests dm2
            WHERE dm2.white_manifest_number = dm.white_manifest_number
              AND dm.white_manifest_number IS NOT NULL) > 1
      THEN NULL
    ELSE dm.derm_address_url
  END AS derm_manifest_url,
  -- 2026-05-20k: include yellow_ticket_number in COALESCE so Broward
  -- visits return their identifier instead of NULL
  COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number, dm.yellow_ticket_number) AS wwtp_receipt_number,
  dm.derm_manifest_url AS wwtp_receipt_url,
  dm.wwtp_ticket_number,
  v.created_at,
  COALESCE(v.completed_at, v.created_at) AS updated_at,
  -- 2026-05-20k NEW: jurisdiction-agnostic columns for UI display
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
WHERE v.visit_status = 'completed' AND v.client_id IS NOT NULL;

COMMIT;

-- Verification:
--   SELECT COUNT(*) FILTER (WHERE manifest_number IS NOT NULL) AS with_num,
--          COUNT(*) FILTER (WHERE manifest_jurisdiction='dade') AS dade,
--          COUNT(*) FILTER (WHERE manifest_jurisdiction='broward') AS broward
--   FROM customer.work_orders;
-- Expected: with_num ≈ 369, dade ≈ 307, broward ≈ 62.
