-- ============================================================================
-- ops.v_billing_by_location — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_billing_by_location AS
SELECT client_location_id,
    location_name,
    client_id,
    client_code,
    client_name,
    count(*) AS invoice_count,
    sum(amount_share) AS billed_total,
    sum(outstanding_share) AS outstanding_total,
    max(sent_at) AS last_invoiced_at
   FROM ops.invoice_locations il
  GROUP BY client_location_id, location_name, client_id, client_code, client_name;
