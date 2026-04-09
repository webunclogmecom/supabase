-- ============================================================================
-- ops.v_service_due — Next-due service per (client, service_type)
-- ----------------------------------------------------------------------------
-- One row per service_configs record (client × service_type).
-- Uses denormalized service_configs.last_visit / next_visit when present.
-- Fallback: first_visit_date + frequency_days when no visit history.
-- needs_baseline = TRUE when no next_visit and no fallback available.
-- Active clients only (status ACTIVE or Recuring — typo preserved from source).
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_service_due AS
WITH base AS (
  SELECT
    sc.id                 AS service_config_id,
    sc.client_id,
    c.name                AS client_name,
    c.client_code,
    c.status              AS client_status,
    sc.service_type,
    sc.frequency_days,
    sc.first_visit_date,
    sc.last_visit,
    sc.next_visit,
    sc.stop_date,
    COALESCE(
      sc.next_visit,
      CASE
        WHEN sc.last_visit IS NOT NULL AND sc.frequency_days IS NOT NULL
          THEN sc.last_visit + sc.frequency_days
        WHEN sc.first_visit_date IS NOT NULL AND sc.frequency_days IS NOT NULL
          THEN sc.first_visit_date + sc.frequency_days
      END
    ) AS effective_next_visit
  FROM public.service_configs sc
  JOIN public.clients c ON c.id = sc.client_id
  WHERE c.status IN ('ACTIVE','Recuring')
    AND (sc.stop_date IS NULL OR sc.stop_date > CURRENT_DATE)
)
SELECT
  service_config_id,
  client_id,
  client_name,
  client_code,
  client_status,
  service_type,
  frequency_days,
  first_visit_date,
  last_visit,
  next_visit,
  effective_next_visit,
  CASE
    WHEN effective_next_visit IS NULL THEN NULL
    ELSE (CURRENT_DATE - effective_next_visit)::int
  END AS days_overdue,
  (effective_next_visit IS NOT NULL AND effective_next_visit <= CURRENT_DATE) AS is_overdue,
  (effective_next_visit IS NULL) AS needs_baseline,
  (SELECT MAX(updated_at) FROM public.service_configs) AS data_as_of
FROM base
ORDER BY effective_next_visit NULLS LAST;

COMMENT ON VIEW ops.v_service_due IS
  'Next-due service per (client, service_type). Uses service_configs.next_visit; falls back to last_visit/first_visit_date + frequency_days. needs_baseline flags rows with no computable due date.';
