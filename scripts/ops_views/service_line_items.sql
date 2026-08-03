-- ============================================================================
-- ops.service_line_items — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.service_line_items AS
SELECT id,
    code,
    title,
    requires_derm,
    reason,
    service_type AS service_kind,
    location_target,
    method,
    service_type,
    schedulable,
    active,
    created_at,
    updated_at,
    unit_price
   FROM service_line_items;
