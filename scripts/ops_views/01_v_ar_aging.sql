-- ============================================================================
-- ops.v_ar_aging — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_ar_aging AS
SELECT c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p_z.code AS zone,
    p.address,
    p.city,
    p.county,
    cc.name AS contact_name,
    cc.email AS primary_email,
    cc.phone AS primary_phone,
    i.id AS invoice_id,
    i.invoice_number,
    i.due_date,
    i.total,
    i.outstanding_amount AS balance_due,
    i.invoice_status,
    CURRENT_DATE - i.due_date AS days_overdue,
        CASE
            WHEN i.outstanding_amount <= 0::numeric THEN 'paid'::text
            WHEN i.due_date >= CURRENT_DATE THEN 'current'::text
            WHEN (CURRENT_DATE - i.due_date) >= 1 AND (CURRENT_DATE - i.due_date) <= 30 THEN '1-30_days'::text
            WHEN (CURRENT_DATE - i.due_date) >= 31 AND (CURRENT_DATE - i.due_date) <= 60 THEN '31-60_days'::text
            WHEN (CURRENT_DATE - i.due_date) >= 61 AND (CURRENT_DATE - i.due_date) <= 90 THEN '61-90_days'::text
            ELSE '90+_days'::text
        END AS aging_bucket
   FROM invoices i
     JOIN clients c ON c.id = i.client_id
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN zones p_z ON p_z.id = p.zone_id
  WHERE i.outstanding_amount > 0::numeric
  ORDER BY p_z.code, (CURRENT_DATE - i.due_date) DESC NULLS LAST;
