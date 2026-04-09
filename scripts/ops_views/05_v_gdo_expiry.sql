-- ============================================================================
-- ops.v_gdo_expiry — Grease Disposal Operator permit expiry tracker
-- ----------------------------------------------------------------------------
-- One row per active client with GDO data.
-- Buckets: expired | 0-30d | 31-60d | 61-90d | ok | no_gdo
-- Highest-used compliance view per Viktor — Yan checks constantly.
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_gdo_expiry AS
SELECT
  c.id                       AS client_id,
  c.name                     AS client_name,
  c.client_code,
  c.status                   AS client_status,
  c.gdo_number,
  c.gdo_expiration_date,
  c.gdo_frequency,
  c.city_email,
  c.operation_email,
  CASE
    WHEN c.gdo_expiration_date IS NULL THEN NULL
    ELSE (c.gdo_expiration_date - CURRENT_DATE)::int
  END                        AS days_until_expiry,
  CASE
    WHEN c.gdo_number IS NULL AND c.gdo_expiration_date IS NULL       THEN 'no_gdo'
    WHEN c.gdo_expiration_date IS NULL                                THEN 'no_date'
    WHEN c.gdo_expiration_date < CURRENT_DATE                         THEN 'expired'
    WHEN c.gdo_expiration_date <= CURRENT_DATE + INTERVAL '30 days'   THEN '0-30d'
    WHEN c.gdo_expiration_date <= CURRENT_DATE + INTERVAL '60 days'   THEN '31-60d'
    WHEN c.gdo_expiration_date <= CURRENT_DATE + INTERVAL '90 days'   THEN '61-90d'
    ELSE                                                                   'ok'
  END                        AS expiry_bucket,
  (SELECT MAX(updated_at) FROM public.clients) AS data_as_of
FROM public.clients c
WHERE c.status IN ('ACTIVE','Recuring')
ORDER BY
  CASE
    WHEN c.gdo_expiration_date IS NULL THEN 9
    WHEN c.gdo_expiration_date < CURRENT_DATE THEN 0
    ELSE 1
  END,
  c.gdo_expiration_date NULLS LAST;

COMMENT ON VIEW ops.v_gdo_expiry IS
  'GDO permit expiry buckets (expired/0-30d/31-60d/61-90d/ok/no_gdo/no_date) for active clients. Most-used compliance view.';
