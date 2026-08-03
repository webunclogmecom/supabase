-- ============================================================================
-- ops.client_locations — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.client_locations AS
SELECT id,
    client_id,
    name,
    property_id,
    status,
    notes,
    created_at,
    updated_at
   FROM client_locations;
