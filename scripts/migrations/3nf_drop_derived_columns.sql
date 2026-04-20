-- ============================================================================
-- Migration: Drop stored derived columns (3NF cleanup)
-- ============================================================================
-- Purpose:
--   Remove three columns that violate 3NF by storing values derivable
--   from other columns in the same or related rows. Rebuild dependent
--   views with the derivations inline.
--
-- Columns dropped:
--
--   1. visits.is_complete
--      = (visit_status = 'COMPLETED')
--      Pure duplication. Verified 2026-04-20: every row with
--      visit_status='COMPLETED' has is_complete=true; every other
--      row has is_complete=false. Zero drift today, but nothing
--      prevents future drift.
--
--   2. service_configs.next_visit
--      = last_visit + (frequency_days) days
--      Derived from other columns in the same row + a scalar day count.
--      Verified 2026-04-20: column is NULL in all 202 rows — nothing
--      populates it currently, so drop is zero-impact to live data.
--      View consumers recompute on read.
--
--   3. service_configs.status
--      = derived from (next_visit, CURRENT_DATE, stop_date).
--      Triple 3NF violation: depends on another derived column, on the
--      current date (not a table column at all), and on stop_date in
--      the same row. Verified 2026-04-20: NULL in all 202 rows.
--
-- Dependent views (5) must be dropped and recreated:
--   public.clients_due_service     (uses sc.next_visit, sc.status)
--   public.client_services_flat    (pivots sc.next_visit, sc.status)
--   public.visits_with_status      (selects v.is_complete)
--   ops.v_route_today              (selects v.is_complete)
--   ops.v_service_due              (uses sc.next_visit; self-computes service_status)
--
-- Rewritten views compute next_visit and service status from base
-- columns inline, matching the semantics of the dropped columns as
-- closely as the data allows.
--
-- NOTE for populate.js:
--   populate.js at lines 668, 680, 882, 923, 938, 1361 references
--   next_visit / is_complete columns. The accompanying populate.js
--   update removes those references. Both changes ship together.
-- ============================================================================

BEGIN;

-- -------------------------------------------------------------------
-- 1. Drop dependent views
-- -------------------------------------------------------------------
DROP VIEW IF EXISTS public.clients_due_service;
DROP VIEW IF EXISTS public.client_services_flat;
DROP VIEW IF EXISTS public.visits_with_status;
DROP VIEW IF EXISTS ops.v_route_today;
DROP VIEW IF EXISTS ops.v_service_due;

-- -------------------------------------------------------------------
-- 2. Drop the derived columns
-- -------------------------------------------------------------------
ALTER TABLE visits          DROP COLUMN IF EXISTS is_complete;
ALTER TABLE service_configs DROP COLUMN IF EXISTS next_visit;
ALTER TABLE service_configs DROP COLUMN IF EXISTS status;

-- -------------------------------------------------------------------
-- 3. Recreate views with inline derivations
-- -------------------------------------------------------------------

-- 3a. clients_due_service — computes next_visit + status on the fly
CREATE VIEW public.clients_due_service AS
SELECT
  c.id,
  c.name,
  c.client_code,
  p.address,
  p.city,
  p.zone,
  s.service_type,
  s.last_visit,
  (s.last_visit + (s.frequency_days || ' days')::interval)::date AS next_visit,
  s.frequency_days,
  ((s.last_visit + (s.frequency_days || ' days')::interval)::date - CURRENT_DATE) AS days_until_due,
  CASE
    WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'
    WHEN (s.last_visit + (s.frequency_days || ' days')::interval)::date < CURRENT_DATE THEN 'OVERDUE'
    WHEN (s.last_visit + (s.frequency_days || ' days')::interval)::date <= (CURRENT_DATE + 14) THEN 'DUE_SOON'
    ELSE 'OK'
  END AS due_status
FROM clients c
JOIN service_configs s ON s.client_id = c.id
LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
WHERE c.status = ANY (ARRAY['ACTIVE','RECURRING'])
  AND (s.stop_date IS NULL OR s.stop_date > CURRENT_DATE)       -- replaces old status != 'Paused'
  AND s.last_visit IS NOT NULL
  AND s.frequency_days IS NOT NULL
ORDER BY (s.last_visit + (s.frequency_days || ' days')::interval)::date;

COMMENT ON VIEW public.clients_due_service IS
  'Overdue and due-soon clients. 3NF: next_visit and due_status computed on read. Replaces service_configs.{next_visit,status} column reads.';

-- 3b. client_services_flat — pivots with inline derivations per service type
CREATE VIEW public.client_services_flat AS
SELECT
  c.id,
  c.name,
  c.client_code,
  p.address,
  p.city,
  p.zone,
  c.status,
  -- GT
  max(CASE WHEN s.service_type = 'GT' THEN s.equipment_size_gallons END) AS gt_size_gallons,
  max(CASE WHEN s.service_type = 'GT' THEN s.frequency_days END)         AS gt_frequency_days,
  max(CASE WHEN s.service_type = 'GT' THEN s.price_per_visit END)        AS gt_price_per_visit,
  max(CASE WHEN s.service_type = 'GT' THEN s.last_visit END)             AS gt_last_visit,
  max(CASE WHEN s.service_type = 'GT'
           THEN (s.last_visit + (s.frequency_days || ' days')::interval)::date END) AS gt_next_visit,
  max(CASE WHEN s.service_type = 'GT'
           THEN CASE
             WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'
             WHEN (s.last_visit + (s.frequency_days || ' days')::interval)::date < CURRENT_DATE THEN 'OVERDUE'
             WHEN (s.last_visit + (s.frequency_days || ' days')::interval)::date <= CURRENT_DATE + 14 THEN 'DUE_SOON'
             ELSE 'OK'
           END END) AS gt_status,
  -- CL
  max(CASE WHEN s.service_type = 'CL' THEN s.frequency_days END)         AS cl_frequency_days,
  max(CASE WHEN s.service_type = 'CL' THEN s.price_per_visit END)        AS cl_price_per_visit,
  max(CASE WHEN s.service_type = 'CL' THEN s.last_visit END)             AS cl_last_visit,
  max(CASE WHEN s.service_type = 'CL'
           THEN (s.last_visit + (s.frequency_days || ' days')::interval)::date END) AS cl_next_visit,
  max(CASE WHEN s.service_type = 'CL'
           THEN CASE
             WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'
             WHEN (s.last_visit + (s.frequency_days || ' days')::interval)::date < CURRENT_DATE THEN 'OVERDUE'
             WHEN (s.last_visit + (s.frequency_days || ' days')::interval)::date <= CURRENT_DATE + 14 THEN 'DUE_SOON'
             ELSE 'OK'
           END END) AS cl_status,
  -- WD
  max(CASE WHEN s.service_type = 'WD' THEN s.frequency_days END)         AS wd_frequency_days,
  max(CASE WHEN s.service_type = 'WD' THEN s.price_per_visit END)        AS wd_price_per_visit,
  max(CASE WHEN s.service_type = 'WD' THEN s.last_visit END)             AS wd_last_visit,
  max(CASE WHEN s.service_type = 'WD'
           THEN (s.last_visit + (s.frequency_days || ' days')::interval)::date END) AS wd_next_visit,
  max(CASE WHEN s.service_type = 'WD'
           THEN CASE
             WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'
             WHEN (s.last_visit + (s.frequency_days || ' days')::interval)::date < CURRENT_DATE THEN 'OVERDUE'
             WHEN (s.last_visit + (s.frequency_days || ' days')::interval)::date <= CURRENT_DATE + 14 THEN 'DUE_SOON'
             ELSE 'OK'
           END END) AS wd_status
FROM clients c
LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN service_configs s ON s.client_id = c.id
GROUP BY c.id, p.address, p.city, p.zone;

COMMENT ON VIEW public.client_services_flat IS
  'Pivoted service config for operator lookup. 3NF: *_next_visit and *_status computed on read.';

-- 3c. visits_with_status — drops is_complete column, keeps computed_late_status
CREATE VIEW public.visits_with_status AS
SELECT
  v.id, v.client_id, v.property_id, v.job_id, v.vehicle_id,
  v.visit_date, v.start_at, v.end_at, v.completed_at,
  v.duration_minutes, v.title, v.service_type, v.visit_status,
  (v.visit_status = 'COMPLETED') AS is_complete,            -- computed, replaces dropped column
  v.actual_arrival_at, v.actual_departure_at, v.is_gps_confirmed,
  v.created_at, v.updated_at, v.invoice_id, v.truck, v.completed_by,
  c.name AS client_name,
  p.zone,
  veh.name AS vehicle_name,
  sc.frequency_days,
  CASE
    WHEN v.visit_status = 'COMPLETED' THEN 'completed'
    WHEN v.visit_date < CURRENT_DATE AND v.visit_status <> 'COMPLETED' THEN 'late'
    WHEN v.visit_date = CURRENT_DATE THEN 'today'
    ELSE 'upcoming'
  END AS computed_late_status
FROM visits v
LEFT JOIN clients c     ON c.id = v.client_id
LEFT JOIN properties p  ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN vehicles veh  ON veh.id = v.vehicle_id
LEFT JOIN service_configs sc ON sc.client_id = v.client_id AND sc.service_type = v.service_type;

COMMENT ON VIEW public.visits_with_status IS
  'Visits with derived status fields. is_complete computed on read (visit_status = COMPLETED).';

-- 3d. ops.v_route_today — drops v.is_complete column read, computes inline
CREATE VIEW ops.v_route_today AS
SELECT
  v.id AS visit_id,
  v.visit_date, v.start_at, v.end_at,
  v.visit_status, v.service_type,
  (v.visit_status = 'COMPLETED') AS is_complete,
  v.is_gps_confirmed,
  c.id AS client_id,
  c.client_code,
  c.name AS client_name,
  COALESCE(vp.zone, pp.zone) AS zone,
  COALESCE(vp.address, pp.address) AS address,
  COALESCE(vp.city, pp.city) AS city,
  COALESCE(vp.county, pp.county) AS county,
  COALESCE(vp.latitude, pp.latitude) AS latitude,
  COALESCE(vp.longitude, pp.longitude) AS longitude,
  COALESCE(vp.access_hours_start, pp.access_hours_start) AS access_hours_start,
  COALESCE(vp.access_hours_end, pp.access_hours_end) AS access_hours_end,
  cc.name AS contact_name,
  cc.phone AS contact_phone,
  sc.equipment_size_gallons,
  sc.permit_number,
  veh.name AS truck,
  veh.grease_tank_capacity_gallons,
  string_agg(e.full_name, ', ' ORDER BY e.full_name) AS crew,
  v.duration_minutes
FROM visits v
JOIN clients c ON c.id = v.client_id
LEFT JOIN properties vp ON vp.id = v.property_id
LEFT JOIN properties pp ON pp.client_id = c.id AND pp.is_primary = true
LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'
LEFT JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = v.service_type
LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
LEFT JOIN visit_assignments va ON va.visit_id = v.id
LEFT JOIN employees e ON e.id = va.employee_id
WHERE v.visit_date = CURRENT_DATE
  AND v.visit_status = ANY (ARRAY['UPCOMING','LATE','COMPLETED'])
GROUP BY v.id, v.visit_date, v.start_at, v.end_at, v.visit_status, v.service_type,
         v.is_gps_confirmed, c.id, c.client_code, c.name,
         vp.zone, vp.address, vp.city, vp.county, vp.latitude, vp.longitude,
         vp.access_hours_start, vp.access_hours_end,
         pp.zone, pp.address, pp.city, pp.county, pp.latitude, pp.longitude,
         pp.access_hours_start, pp.access_hours_end,
         cc.name, cc.phone, sc.equipment_size_gallons, sc.permit_number,
         veh.name, veh.grease_tank_capacity_gallons, v.duration_minutes
ORDER BY v.start_at, COALESCE(vp.zone, pp.zone), c.name;

-- 3e. ops.v_service_due — already self-computes service_status; just
--     rebuild without the dropped next_visit column (scheduled_next_visit
--     becomes an inline derivation)
CREATE VIEW ops.v_service_due AS
WITH actual_last_visit AS (
  SELECT visits.client_id,
         max(visits.visit_date) AS last_visit_actual
  FROM visits
  WHERE visits.visit_status = 'COMPLETED'
  GROUP BY visits.client_id
)
SELECT
  c.id, c.client_code, c.name AS client_name, c.status AS client_status,
  p.zone, p.address, p.city, p.county,
  p.access_hours_start, p.access_hours_end,
  cc.name AS contact_name, cc.email, cc.phone,
  sc.service_type, sc.frequency_days, sc.equipment_size_gallons,
  sc.permit_number, sc.price_per_visit,
  COALESCE(sc.last_visit, alv.last_visit_actual) AS last_service_date,
  (COALESCE(sc.last_visit, alv.last_visit_actual)
     + (sc.frequency_days || ' days')::interval)::date AS scheduled_next_visit,
  CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual) AS days_since_service,
  CASE
    WHEN COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL THEN 'never_serviced'
    WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90 THEN 'derm_violation'
    WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days THEN 'overdue'
    WHEN (COALESCE(sc.last_visit, alv.last_visit_actual) + sc.frequency_days - CURRENT_DATE) <= 14 THEN 'due_soon'
    ELSE 'on_schedule'
  END AS service_status
FROM clients c
JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = ANY (ARRAY['GT','CL'])
LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'
LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN actual_last_visit alv ON alv.client_id = c.id
WHERE c.status = ANY (ARRAY['ACTIVE','Recuring'])
  AND (COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL
    OR (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual))
       >= (COALESCE(sc.frequency_days, 90) - 14))
ORDER BY
  CASE WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90 THEN 1 ELSE 2 END,
  p.zone,
  CASE
    WHEN COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL THEN 1
    WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days THEN 2
    ELSE 3
  END,
  (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) DESC NULLS LAST;

COMMIT;
