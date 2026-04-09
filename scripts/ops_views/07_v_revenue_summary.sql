-- ============================================================================
-- ops.v_revenue_summary — Monthly revenue (invoiced vs collected)
-- ----------------------------------------------------------------------------
-- One row per (month, invoice_status_bucket).
-- Invoiced = SUM(total) of invoices created in month.
-- Collected = SUM(total - outstanding) for invoices in month.
-- Last 18 months.
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_revenue_summary AS
WITH inv AS (
  SELECT
    date_trunc('month', COALESCE(i.sent_at, i.created_at))::date AS month,
    COUNT(*)                                                     AS invoice_count,
    SUM(i.total)                                                 AS invoiced_total,
    SUM(COALESCE(i.total,0) - COALESCE(i.outstanding,0))         AS collected_total,
    SUM(COALESCE(i.outstanding,0))                               AS outstanding_total,
    COUNT(*) FILTER (WHERE i.invoice_status = 'paid')            AS paid_count,
    COUNT(*) FILTER (WHERE i.invoice_status IN ('past_due','awaiting_payment')) AS open_count
  FROM public.invoices i
  WHERE COALESCE(i.sent_at, i.created_at) >= CURRENT_DATE - INTERVAL '18 months'
    AND i.invoice_status NOT IN ('void','draft')
  GROUP BY 1
)
SELECT
  month,
  invoice_count,
  invoiced_total,
  collected_total,
  outstanding_total,
  paid_count,
  open_count,
  CASE WHEN invoiced_total > 0
       THEN ROUND((collected_total / invoiced_total) * 100, 1)
       ELSE NULL END AS collection_rate_pct,
  (SELECT MAX(updated_at) FROM public.invoices) AS data_as_of
FROM inv
ORDER BY month DESC;

COMMENT ON VIEW ops.v_revenue_summary IS
  'Monthly revenue: invoiced vs collected vs outstanding, last 18 months. Excludes void/draft.';
