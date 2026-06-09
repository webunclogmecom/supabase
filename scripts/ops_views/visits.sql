-- ============================================================================
-- ops.visits — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.visits AS
SELECT id,
    client_id,
    property_id,
    job_id,
    vehicle_id,
    visit_date,
    start_at,
    end_at,
    completed_at,
    duration_minutes,
    title,
    service_type,
    visit_status,
    actual_arrival_at,
    actual_departure_at,
    is_gps_confirmed,
    created_at,
    updated_at,
    invoice_id,
    completed_by,
    source,
    manhole_count,
    manhole_breakdown,
    ticket_number,
    trap_condition_notes,
    derm_required,
    service_line_item_id
   FROM visits;
