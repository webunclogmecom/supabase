-- ============================================================================
-- ops.v_ar_aging — Accounts receivable aging buckets
-- ----------------------------------------------------------------------------
-- One row per open invoice (invoice_status NOT IN paid/void/draft/bad_debt).
-- Net-of-credits: includes negative outstanding (customer credits).
-- Bucket by due_date if present, else sent_at, else created_at.
-- Consumers: Yan (collections), Fred (ops dashboard).
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS ops;

CREATE OR REPLACE VIEW ops.v_ar_aging AS
WITH base AS (
  SELECT
    i.id                         AS invoice_id,
    i.invoice_number,
    i.invoice_status,
    i.client_id,
    c.name                       AS client_name,
    c.client_code,
    c.accounting_email,
    c.accounting_phone,
    c.acct_name,
    c.status                     AS client_status,
    i.total,
    i.outstanding,
    i.deposit_amount,
    i.due_date,
    i.sent_at,
    i.created_at                 AS invoice_created_at,
    COALESCE(i.due_date, i.sent_at::date, i.created_at::date) AS reference_date
  FROM public.invoices i
  LEFT JOIN public.clients c ON c.id = i.client_id
  WHERE i.invoice_status NOT IN ('paid','void','draft','bad_debt')
    AND i.outstanding IS NOT NULL
)
SELECT
  invoice_id,
  invoice_number,
  invoice_status,
  client_id,
  client_name,
  client_code,
  client_status,
  acct_name,
  accounting_email,
  accounting_phone,
  total,
  outstanding,
  deposit_amount,
  due_date,
  sent_at,
  invoice_created_at,
  reference_date,
  GREATEST(0, (CURRENT_DATE - reference_date))::int AS days_outstanding,
  CASE
    WHEN outstanding < 0                                      THEN 'credit'
    WHEN (CURRENT_DATE - reference_date) <= 30                THEN '0-30'
    WHEN (CURRENT_DATE - reference_date) <= 60                THEN '31-60'
    WHEN (CURRENT_DATE - reference_date) <= 90                THEN '61-90'
    ELSE                                                            '90+'
  END AS aging_bucket,
  (SELECT MAX(updated_at) FROM public.invoices) AS data_as_of
FROM base
ORDER BY reference_date NULLS LAST, outstanding DESC;

COMMENT ON VIEW ops.v_ar_aging IS
  'Open A/R aging (0-30, 31-60, 61-90, 90+, credit). Net-of-credits. Filter excludes paid/void/draft/bad_debt.';
