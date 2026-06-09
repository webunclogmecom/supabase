-- ============================================================================
-- ops.vehicles — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.vehicles AS
SELECT id,
    name,
    make,
    model,
    year,
    vin,
    license_plate,
    grease_tank_capacity_gallons,
    status,
    notes,
    created_at,
    updated_at,
    fuel_tank_capacity_gallons,
    decal_number
   FROM vehicles;
