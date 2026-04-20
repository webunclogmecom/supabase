-- ============================================================================
-- Migration: split vehicles.tank_capacity_gallons into grease + fuel tanks
-- ============================================================================
-- Context (Unclogme is a commercial grease-trap service company):
--   Vacuum trucks have TWO independent tanks:
--     1. GREASE tank  — the waste/vacuum tank that holds collected grease.
--                       Drives route capacity + dump scheduling (126–9000 gal).
--     2. FUEL tank    — the diesel/gas tank that powers the truck (26–90 gal).
--                       Samsara's fuelPercent reports on THIS tank.
--
-- The existing column `tank_capacity_gallons` stored GREASE capacity, but was
-- misnamed. The telemetry view I just created computed fuel_gallons using that
-- column, which gave garbage (e.g. 82% of a 9000gal "tank" = 7380 gallons of
-- diesel — nonsensical).
--
-- Fix: rename to `grease_tank_capacity_gallons`, add separate
-- `fuel_tank_capacity_gallons`, populate known values, repoint dependent views.
--
-- 3NF check: both columns are direct attributes of a vehicle, no transitive
-- dependencies, no derivation — clean 3NF.
--
-- Fuel tank values provided by Fred (2026-04-14):
--   Cloggy (Toyota Tundra)       : 26 gal
--   David  (International MA025) : 66 gal
--   Moises (Kenworth T880)       : 90 gal
--   Goliath                      : NULL (vehicle inactive)
-- ============================================================================

BEGIN;

-- 1. Drop the 3 dependent views so we can rename the column
DROP VIEW IF EXISTS public.v_vehicle_telemetry_latest;
DROP VIEW IF EXISTS ops.v_route_today;
DROP VIEW IF EXISTS ops.v_truck_utilization;

-- 2. Rename the column to reflect what it actually stores
ALTER TABLE vehicles RENAME COLUMN tank_capacity_gallons TO grease_tank_capacity_gallons;

COMMENT ON COLUMN vehicles.grease_tank_capacity_gallons IS
  'Grease/waste vacuum tank capacity in gallons. Drives route planning and dump scheduling. Unrelated to fuel_tank_capacity_gallons.';

-- 3. Add the fuel tank column (direct attribute, 3NF-clean)
ALTER TABLE vehicles ADD COLUMN IF NOT EXISTS fuel_tank_capacity_gallons NUMERIC;

COMMENT ON COLUMN vehicles.fuel_tank_capacity_gallons IS
  'Diesel/gas fuel tank capacity in gallons. Used with Samsara fuelPercent to compute fuel_gallons on read. NULL for inactive vehicles.';

-- 4. Populate known fuel tank values
UPDATE vehicles SET fuel_tank_capacity_gallons = 26 WHERE name = 'Cloggy';
UPDATE vehicles SET fuel_tank_capacity_gallons = 66 WHERE name = 'David';
UPDATE vehicles SET fuel_tank_capacity_gallons = 90 WHERE name = 'Moises';
-- Goliath is inactive; leave fuel_tank_capacity_gallons NULL and flag status
UPDATE vehicles SET status = 'INACTIVE' WHERE name = 'Goliath';

-- 5. Recreate v_vehicle_telemetry_latest with fuel_tank_capacity_gallons
CREATE OR REPLACE VIEW public.v_vehicle_telemetry_latest AS
SELECT DISTINCT ON (vtr.vehicle_id)
  vtr.vehicle_id,
  v.name                                                        AS vehicle_name,
  vtr.fuel_percent,
  -- Derived, not stored: computes gallons from fuel_percent × fuel tank capacity
  CASE
    WHEN vtr.fuel_percent IS NOT NULL AND v.fuel_tank_capacity_gallons IS NOT NULL
    THEN ROUND(vtr.fuel_percent * v.fuel_tank_capacity_gallons / 100, 2)
    ELSE NULL
  END                                                           AS fuel_gallons_computed,
  v.fuel_tank_capacity_gallons,
  v.grease_tank_capacity_gallons,
  vtr.odometer_meters,
  ROUND(vtr.odometer_meters / 1609.34)                          AS odometer_miles,
  vtr.engine_state,
  vtr.engine_hours_seconds,
  ROUND(vtr.engine_hours_seconds / 3600.0, 1)                   AS engine_hours,
  vtr.recorded_at,
  ROUND(EXTRACT(EPOCH FROM (now() - vtr.recorded_at)) / 60)     AS minutes_ago
FROM vehicle_telemetry_readings vtr
JOIN vehicles v ON v.id = vtr.vehicle_id
ORDER BY vtr.vehicle_id, vtr.recorded_at DESC;

COMMENT ON VIEW public.v_vehicle_telemetry_latest IS
  'Latest telemetry per vehicle. fuel_gallons_computed derived from fuel_tank_capacity_gallons on read (3NF). Exposes both grease and fuel tank sizes.';

-- 6. Recreate ops.v_route_today with the renamed column
CREATE OR REPLACE VIEW ops.v_route_today AS
SELECT v.id AS visit_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.visit_status,
    v.service_type,
    v.is_complete,
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
    string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS crew,
    v.duration_minutes
   FROM ((((((((visits v
     JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties vp ON ((vp.id = v.property_id)))
     LEFT JOIN properties pp ON (((pp.client_id = c.id) AND (pp.is_primary = true))))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text))))
     LEFT JOIN service_configs sc ON (((sc.client_id = c.id) AND (sc.service_type = v.service_type))))
     LEFT JOIN vehicles veh ON ((veh.id = v.vehicle_id)))
     LEFT JOIN visit_assignments va ON ((va.visit_id = v.id)))
     LEFT JOIN employees e ON ((e.id = va.employee_id)))
  WHERE ((v.visit_date = CURRENT_DATE) AND (v.visit_status = ANY (ARRAY['UPCOMING'::text, 'LATE'::text, 'COMPLETED'::text])))
  GROUP BY v.id, v.visit_date, v.start_at, v.end_at, v.visit_status, v.service_type, v.is_complete, v.is_gps_confirmed, c.id, c.client_code, c.name, vp.zone, vp.address, vp.city, vp.county, vp.latitude, vp.longitude, vp.access_hours_start, vp.access_hours_end, pp.zone, pp.address, pp.city, pp.county, pp.latitude, pp.longitude, pp.access_hours_start, pp.access_hours_end, cc.name, cc.phone, sc.equipment_size_gallons, sc.permit_number, veh.name, veh.grease_tank_capacity_gallons, v.duration_minutes
  ORDER BY v.start_at, COALESCE(vp.zone, pp.zone), c.name;

-- 7. Recreate ops.v_truck_utilization with the renamed column
CREATE OR REPLACE VIEW ops.v_truck_utilization AS
 WITH truck_stats AS (
         SELECT v.vehicle_id,
            count(DISTINCT v.id) AS visits_completed,
            count(DISTINCT v.client_id) AS unique_clients,
            count(DISTINCT v.visit_date) AS active_days,
            sum(i.total) AS attributed_revenue,
            round((sum(EXTRACT(epoch FROM (v.end_at - v.start_at))) FILTER (WHERE ((v.start_at IS NOT NULL) AND (v.end_at IS NOT NULL))) / 3600.0), 1) AS total_hours_onsite
           FROM (visits v
             LEFT JOIN invoices i ON ((i.id = v.invoice_id)))
          WHERE ((v.visit_status = 'COMPLETED'::text) AND (v.visit_date >= (CURRENT_DATE - '30 days'::interval)))
          GROUP BY v.vehicle_id
        )
 SELECT veh.id AS vehicle_id,
    veh.name AS truck,
    veh.make,
    veh.model,
    veh.year,
    veh.grease_tank_capacity_gallons,
    veh.fuel_tank_capacity_gallons,
    veh.status AS truck_status,
    COALESCE(ts.visits_completed, (0)::bigint) AS visits_30d,
    COALESCE(ts.unique_clients, (0)::bigint) AS clients_served_30d,
    COALESCE(ts.active_days, (0)::bigint) AS active_days_30d,
    COALESCE(ts.total_hours_onsite, (0)::numeric) AS hours_onsite_30d,
    COALESCE(ts.attributed_revenue, (0)::numeric) AS revenue_30d,
    round(((COALESCE(ts.visits_completed, (0)::bigint))::numeric / (NULLIF(ts.active_days, 0))::numeric), 1) AS visits_per_active_day,
    round((COALESCE(ts.attributed_revenue, (0)::numeric) / (NULLIF(ts.active_days, 0))::numeric), 2) AS revenue_per_active_day
   FROM (vehicles veh
     LEFT JOIN truck_stats ts ON ((ts.vehicle_id = veh.id)))
  ORDER BY COALESCE(ts.visits_completed, (0)::bigint) DESC;

COMMIT;
