-- ============================================================================
-- Migration: vehicle_fuel_readings → vehicle_telemetry_readings (3NF)
-- ============================================================================
-- Purpose:
--   Bring the Samsara telemetry table into strict 3NF compliance.
--
-- Changes:
--   1. DROP column fuel_gallons
--      - Was a transitive dependency: fuel_percent × vehicles.fuel_tank_capacity_gallons / 100
--      - Storing a derived value violates 3NF. Reference all data via FK; compute
--        on read in a view instead of snapshotting.
--   2. RENAME table vehicle_fuel_readings → vehicle_telemetry_readings
--      - Table already stores odometer_meters + engine_state; name was lying.
--      - Every column depends on (vehicle_id, recorded_at) — direct observations
--        of the vehicle at a moment. 3NF-clean under the new name.
--   3. ADD column engine_hours_seconds
--      - Direct observation from Samsara stats feed. 3NF-clean (depends on key,
--        nothing else). Nullable because not every reading ships engine hours.
--   4. REPLACE view v_vehicle_fuel_latest → v_vehicle_telemetry_latest
--      - Computes fuel_gallons on read: fuel_percent × fuel_tank_capacity_gallons / 100
--      - JOIN to vehicles for fuel_tank_capacity_gallons + name (referenced, never copied)
--
-- Safe because: table has 0 rows (no data loss possible).
-- ============================================================================

BEGIN;

-- 0. Drop old view first — it depends on fuel_gallons column
DROP VIEW IF EXISTS v_vehicle_fuel_latest;

-- 1. Drop the derived column (3NF violation)
ALTER TABLE vehicle_fuel_readings DROP COLUMN IF EXISTS fuel_gallons;

-- 2. Rename the table to reflect what it actually stores
ALTER TABLE vehicle_fuel_readings RENAME TO vehicle_telemetry_readings;

-- Rename indexes to match new table name
ALTER INDEX IF EXISTS idx_vfr_vehicle_time RENAME TO idx_vtr_vehicle_time;
ALTER INDEX IF EXISTS idx_vfr_recorded     RENAME TO idx_vtr_recorded;

-- 3. Add engine hours column (direct observation, 3NF-clean)
ALTER TABLE vehicle_telemetry_readings
  ADD COLUMN IF NOT EXISTS engine_hours_seconds bigint;

COMMENT ON TABLE vehicle_telemetry_readings IS
  'Append-only Samsara vehicle telemetry snapshots. 3NF: each row is one observation of vehicle_id at recorded_at. No derived columns — fuel_gallons is computed in v_vehicle_telemetry_latest.';

COMMENT ON COLUMN vehicle_telemetry_readings.engine_hours_seconds IS
  'Lifetime engine hours at observation time (seconds). Samsara reports in seconds; divide by 3600 for hours.';

-- 4. Create the replacement view (computes fuel_gallons on read — not stored)
CREATE OR REPLACE VIEW v_vehicle_telemetry_latest AS
SELECT DISTINCT ON (vtr.vehicle_id)
  vtr.vehicle_id,
  v.name                                                      AS vehicle_name,
  vtr.fuel_percent,
  -- Derived, not stored: fuel_percent × fuel_tank_capacity_gallons / 100
  CASE
    WHEN vtr.fuel_percent IS NOT NULL AND v.fuel_tank_capacity_gallons IS NOT NULL
    THEN ROUND(vtr.fuel_percent * v.fuel_tank_capacity_gallons / 100, 2)
    ELSE NULL
  END                                                         AS fuel_gallons_computed,
  v.fuel_tank_capacity_gallons,
  vtr.odometer_meters,
  ROUND(vtr.odometer_meters / 1609.34)                        AS odometer_miles,
  vtr.engine_state,
  vtr.engine_hours_seconds,
  ROUND(vtr.engine_hours_seconds / 3600.0, 1)                 AS engine_hours,
  vtr.recorded_at,
  ROUND(EXTRACT(EPOCH FROM (now() - vtr.recorded_at)) / 60)   AS minutes_ago
FROM vehicle_telemetry_readings vtr
JOIN vehicles v ON v.id = vtr.vehicle_id
ORDER BY vtr.vehicle_id, vtr.recorded_at DESC;

COMMENT ON VIEW v_vehicle_telemetry_latest IS
  'Latest telemetry snapshot per vehicle. fuel_gallons computed on read, not stored (3NF). Joins vehicles for fuel_tank_capacity_gallons + name.';

COMMIT;
