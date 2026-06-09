-- ============================================================================
-- ops.v_revenue_summary — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_revenue_summary AS
SELECT date_trunc('month'::text, v.visit_date::timestamp with time zone)::date AS month,
    v.service_type,
    p.zone,
    veh.name AS truck,
    count(DISTINCT v.id) AS visit_count,
    count(DISTINCT v.client_id) AS client_count,
    sum(i.total) AS gross_revenue,
    sum(i.outstanding_amount) AS outstanding_ar,
    sum(i.total - i.outstanding_amount) AS collected_revenue,
    round(100.0 * sum(i.total - i.outstanding_amount) / NULLIF(sum(i.total), 0::numeric), 1) AS collection_rate_pct
   FROM visits v
     JOIN invoices i ON i.id = v.invoice_id
     LEFT JOIN properties p ON p.id = v.property_id
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
  WHERE v.visit_status = 'completed'::text AND v.visit_date >= (CURRENT_DATE - '1 year'::interval)
  GROUP BY (date_trunc('month'::text, v.visit_date::timestamp with time zone)), v.service_type, p.zone, veh.name
  ORDER BY (date_trunc('month'::text, v.visit_date::timestamp with time zone)::date) DESC, (sum(i.total)) DESC;
