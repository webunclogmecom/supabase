-- ============================================================================
-- Drop 3NF-violating dead columns: 2026-05-04
-- Audited 2026-05-04: zero rows populated across all three columns.
-- Photos for visits/manifests live exclusively in photo_links polymorphic
-- (entity_type='visit' or 'derm_manifest'). Truck name is derivable via
-- visits.vehicle_id → vehicles.name.
-- ============================================================================

-- Step 1: drop view that depends on visits.truck (passes the column through;
-- already exposes vehicle_name via JOIN to vehicles which is the right way).
-- Caught an incidental casing bug: the OLD view compared visit_status to
-- 'COMPLETED' (uppercase) but our actual data uses 'completed' (lowercase),
-- so computed_late_status was always 'late' for finished visits. Fixed in
-- the recreate below.
DROP VIEW IF EXISTS visits_with_status;

-- Step 2: drop the dead columns.
ALTER TABLE visits          DROP COLUMN IF EXISTS truck;             -- 0/564 rows; derivable from vehicle_id
ALTER TABLE derm_manifests  DROP COLUMN IF EXISTS manifest_images;   -- 0/972 rows; vestigial, photos via photo_links
ALTER TABLE derm_manifests  DROP COLUMN IF EXISTS address_images;    -- 0/972 rows; same

-- Step 3: recreate visits_with_status without v.truck. Truck name is
-- exposed as vehicle_name via JOIN. Also fix the casing bug in
-- computed_late_status while we're here.
-- WITH (security_invoker = true) so RLS on visits/clients/properties applies
-- to the caller, not the view's creator. Supabase advisor flagged the
-- DEFINER variant as CRITICAL (RLS bypass).
CREATE VIEW visits_with_status WITH (security_invoker = true) AS
SELECT v.id, v.client_id, v.property_id, v.job_id, v.vehicle_id,
  v.visit_date, v.start_at, v.end_at, v.completed_at, v.duration_minutes,
  v.title, v.service_type, v.visit_status,
  (v.visit_status = 'completed'::text) AS is_complete,
  v.actual_arrival_at, v.actual_departure_at, v.is_gps_confirmed,
  v.created_at, v.updated_at, v.invoice_id, v.completed_by,
  c.name AS client_name, p.zone, veh.name AS vehicle_name,
  sc.frequency_days,
  CASE
    WHEN v.visit_status = 'completed' THEN 'completed'
    WHEN v.visit_date < CURRENT_DATE AND v.visit_status <> 'completed' THEN 'late'
    WHEN v.visit_date = CURRENT_DATE THEN 'today'
    ELSE 'upcoming'
  END AS computed_late_status
FROM visits v
LEFT JOIN clients c ON c.id = v.client_id
LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
LEFT JOIN service_configs sc ON sc.client_id = v.client_id AND sc.service_type = v.service_type;
