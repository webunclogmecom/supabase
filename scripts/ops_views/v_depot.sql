-- ============================================================================
-- ops.v_depot — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_depot AS
SELECT p.id AS property_id,
    c.name AS depot_name,
    p.address,
    p.city,
    p.state,
    p.zip,
    p.latitude,
    p.longitude
   FROM app_config cfg
     JOIN properties p ON p.id = cfg.value::bigint
     JOIN clients c ON c.id = p.client_id
  WHERE cfg.key = 'depot_property_id'::text AND p.latitude IS NOT NULL AND p.longitude IS NOT NULL;
