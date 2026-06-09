-- ============================================================================
-- ops.clients — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.clients AS
SELECT id,
    client_code,
    name,
    status,
    balance,
    notes,
    created_at,
    updated_at,
    group_id
   FROM clients;
