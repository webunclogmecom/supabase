-- ============================================================================
-- ops.invoice_locations — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.invoice_locations AS
WITH inv_locs AS (
         SELECT i_1.id AS invoice_id,
            cl_1.id AS client_location_id
           FROM invoices i_1
             JOIN client_locations cl_1 ON cl_1.client_id = i_1.client_id
          WHERE (( SELECT count(*) AS count
                   FROM client_locations x
                  WHERE x.client_id = i_1.client_id)) = 1
        UNION
         SELECT DISTINCT i_1.id,
            vl.client_location_id
           FROM invoices i_1
             JOIN visits v ON v.invoice_id = i_1.id AND v.deleted_at IS NULL
             JOIN visit_locations vl ON vl.visit_id = v.id
          WHERE (( SELECT count(*) AS count
                   FROM client_locations x
                  WHERE x.client_id = i_1.client_id)) > 1
        UNION
         SELECT i_1.id,
            cl_1.id
           FROM invoices i_1
             JOIN client_locations cl_1 ON cl_1.client_id = i_1.client_id
          WHERE (( SELECT count(*) AS count
                   FROM client_locations x
                  WHERE x.client_id = i_1.client_id)) > 1 AND NOT (EXISTS ( SELECT 1
                   FROM visits v
                     JOIN visit_locations vl ON vl.visit_id = v.id
                  WHERE v.invoice_id = i_1.id AND v.deleted_at IS NULL))
        ), counts AS (
         SELECT inv_locs.invoice_id,
            count(*) AS location_count
           FROM inv_locs
          GROUP BY inv_locs.invoice_id
        )
 SELECT il.invoice_id,
    i.invoice_number,
    il.client_location_id,
    cl.name AS location_name,
    i.client_id,
    c.client_code,
    c.name AS client_name,
    cnt.location_count,
    i.total AS invoice_total,
    round(i.total / cnt.location_count::numeric, 2) AS amount_share,
    round(COALESCE(i.outstanding_amount, 0::numeric) / cnt.location_count::numeric, 2) AS outstanding_share,
    i.invoice_status,
    i.due_date,
    i.sent_at,
    i.paid_at
   FROM inv_locs il
     JOIN counts cnt ON cnt.invoice_id = il.invoice_id
     JOIN invoices i ON i.id = il.invoice_id
     JOIN client_locations cl ON cl.id = il.client_location_id
     JOIN clients c ON c.id = i.client_id;
