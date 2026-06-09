-- ============================================================================
-- ops.v_calendar_truck — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_calendar_truck AS
SELECT id,
    name,
    status,
    make,
    model,
    year,
    grease_tank_capacity_gallons,
    fuel_tank_capacity_gallons,
    license_plate,
    decal_number,
    notes,
    created_at,
    updated_at
   FROM vehicles
  ORDER BY (
        CASE status
            WHEN 'ACTIVE'::text THEN 0
            ELSE 1
        END), name;
