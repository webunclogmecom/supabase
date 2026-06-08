-- ============================================================================
-- 2026-06-08c — Billing managed per location (ops.invoice_locations + rollup)
-- ============================================================================
-- Per Fred 2026-06-08: invoices are MANAGED per location (each carries the
-- location/manhole it bills) but SENT to the client (the recipient).
--
-- Invoices sync FROM Jobber at the CLIENT grain, so an invoice's location is DERIVED,
-- not stored (Rule 2 / ADR 005 — derivable data is a view, never a copy):
--   * single-site client            -> its one location (exact; ~95% of invoices)
--   * multi-site, has billed visits  -> the locations of those visits (via visit_locations)
--   * multi-site, no linked visit    -> spread across the client's locations
-- amount_share / outstanding_share apportion the invoice across its location(s): EXACT for
-- single-location invoices; EQUAL-SPLIT approximation for multi-location (exact per-manhole $
-- needs line-item->location tagging, a later step). SUM(amount_share) per location = correct
-- per-location billing with NO double-count. When invoicing goes NATIVE (post-Jobber), the
-- location becomes a stored column on the invoice.
-- ============================================================================

CREATE OR REPLACE VIEW ops.invoice_locations AS
WITH inv_locs AS (
  -- single-location client -> its one location
  SELECT i.id AS invoice_id, cl.id AS client_location_id
  FROM public.invoices i
  JOIN public.client_locations cl ON cl.client_id = i.client_id
  WHERE (SELECT count(*) FROM public.client_locations x WHERE x.client_id = i.client_id) = 1
  UNION
  -- multi-location client WITH billed visits -> those visits' locations
  SELECT DISTINCT i.id, vl.client_location_id
  FROM public.invoices i
  JOIN public.visits v ON v.invoice_id = i.id AND v.deleted_at IS NULL
  JOIN public.visit_locations vl ON vl.visit_id = v.id
  WHERE (SELECT count(*) FROM public.client_locations x WHERE x.client_id = i.client_id) > 1
  UNION
  -- multi-location client WITHOUT any linked visit -> spread across all its locations
  SELECT i.id, cl.id
  FROM public.invoices i
  JOIN public.client_locations cl ON cl.client_id = i.client_id
  WHERE (SELECT count(*) FROM public.client_locations x WHERE x.client_id = i.client_id) > 1
    AND NOT EXISTS (
      SELECT 1 FROM public.visits v JOIN public.visit_locations vl ON vl.visit_id = v.id
      WHERE v.invoice_id = i.id AND v.deleted_at IS NULL
    )
),
counts AS (SELECT invoice_id, count(*) AS location_count FROM inv_locs GROUP BY invoice_id)
SELECT
  il.invoice_id,
  i.invoice_number,
  il.client_location_id,
  cl.name                                          AS location_name,
  i.client_id,
  c.client_code,
  c.name                                           AS client_name,        -- recipient
  cnt.location_count,
  i.total                                          AS invoice_total,
  round(i.total / cnt.location_count, 2)           AS amount_share,
  round(COALESCE(i.outstanding_amount,0) / cnt.location_count, 2) AS outstanding_share,
  i.invoice_status,
  i.due_date,
  i.sent_at,
  i.paid_at
FROM inv_locs il
JOIN counts cnt           ON cnt.invoice_id = il.invoice_id
JOIN public.invoices i    ON i.id = il.invoice_id
JOIN public.client_locations cl ON cl.id = il.client_location_id
JOIN public.clients c     ON c.id = i.client_id;

-- Per-location billing rollup ("manage billing per location").
CREATE OR REPLACE VIEW ops.v_billing_by_location AS
SELECT
  il.client_location_id,
  il.location_name,
  il.client_id,
  il.client_code,
  il.client_name,
  count(*)                    AS invoice_count,
  sum(il.amount_share)        AS billed_total,
  sum(il.outstanding_share)   AS outstanding_total,
  max(il.sent_at)             AS last_invoiced_at
FROM ops.invoice_locations il
GROUP BY 1,2,3,4,5;

GRANT SELECT ON ops.invoice_locations    TO anon, authenticated, service_role, yannick_readonly;
GRANT SELECT ON ops.v_billing_by_location TO anon, authenticated, service_role, yannick_readonly;

-- Verify:
-- SELECT count(DISTINCT invoice_id) FROM ops.invoice_locations;                 -- ~2000
-- SELECT round(sum(amount_share),2) FROM ops.invoice_locations;                 -- ~= SUM(invoices.total)
-- SELECT * FROM ops.v_billing_by_location ORDER BY billed_total DESC LIMIT 5;
