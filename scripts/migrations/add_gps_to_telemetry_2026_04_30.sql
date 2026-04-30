-- ============================================================================
-- Migration: add GPS columns + idempotency constraint to vehicle_telemetry_readings
-- ============================================================================
-- 2026-04-30 — Fred decided to start collecting Samsara telemetry now (vs.
-- defer until fuel-burn model is built) so we have historical data ready when
-- modeling begins. See ADR 011 update for rationale.
--
-- Changes:
--   1. ADD latitude (NUMERIC 9,6) — direct observation from Samsara gps stat
--   2. ADD longitude (NUMERIC 9,6)
--   3. ADD speed_meters_per_sec (NUMERIC) — speed at sample time
--   4. ADD heading_degrees (NUMERIC) — direction of travel
--   5. ADD UNIQUE (vehicle_id, recorded_at) — for ON CONFLICT idempotency in
--      the polling cron. Prevents dup rows if two cron fires race or Samsara
--      returns the same sample twice.
--   6. UPDATE v_vehicle_telemetry_latest view to include the new columns.
--
-- Safe because: table currently has 0 rows. Schema-only change.
-- ============================================================================

BEGIN;

ALTER TABLE vehicle_telemetry_readings
  ADD COLUMN IF NOT EXISTS latitude              NUMERIC(9,6),
  ADD COLUMN IF NOT EXISTS longitude             NUMERIC(9,6),
  ADD COLUMN IF NOT EXISTS speed_meters_per_sec  NUMERIC(7,3),
  ADD COLUMN IF NOT EXISTS heading_degrees       NUMERIC(6,2);

-- Idempotency: each (vehicle, sample-time) combination is unique.
-- Polling cron uses INSERT ... ON CONFLICT (vehicle_id, recorded_at) DO NOTHING.
ALTER TABLE vehicle_telemetry_readings
  ADD CONSTRAINT vehicle_telemetry_readings_vehicle_time_uniq
  UNIQUE (vehicle_id, recorded_at);

COMMENT ON COLUMN vehicle_telemetry_readings.latitude  IS 'GPS latitude at sample time (degrees, 6dp ≈ 10cm precision).';
COMMENT ON COLUMN vehicle_telemetry_readings.longitude IS 'GPS longitude at sample time.';
COMMENT ON COLUMN vehicle_telemetry_readings.speed_meters_per_sec IS 'Vehicle speed at sample time. Multiply by 2.237 for mph.';
COMMENT ON COLUMN vehicle_telemetry_readings.heading_degrees IS 'Direction of travel in degrees clockwise from true north (0–359).';

-- Refresh the latest-telemetry view to surface the new columns
DROP VIEW IF EXISTS v_vehicle_telemetry_latest;

CREATE VIEW v_vehicle_telemetry_latest AS
SELECT DISTINCT ON (vtr.vehicle_id)
  vtr.vehicle_id,
  v.name                                                      AS vehicle_name,
  vtr.fuel_percent,
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
  vtr.latitude,
  vtr.longitude,
  vtr.speed_meters_per_sec,
  ROUND(vtr.speed_meters_per_sec * 2.237, 1)                  AS speed_mph,
  vtr.heading_degrees,
  vtr.recorded_at,
  ROUND(EXTRACT(EPOCH FROM (now() - vtr.recorded_at)) / 60)   AS minutes_ago
FROM vehicle_telemetry_readings vtr
JOIN vehicles v ON v.id = vtr.vehicle_id
ORDER BY vtr.vehicle_id, vtr.recorded_at DESC;

COMMENT ON VIEW v_vehicle_telemetry_latest IS
  'Latest telemetry snapshot per vehicle. fuel_gallons + speed_mph computed on read (3NF). GPS columns added 2026-04-30.';

COMMIT;
