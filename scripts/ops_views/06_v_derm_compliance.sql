-- ============================================================================
-- ops.v_derm_compliance — DERM manifest filing compliance
-- ----------------------------------------------------------------------------
-- Two parts unioned:
--   (A) Ready-to-file manifests: dump_ticket_date NOT NULL AND NOT sent_to_city
--       AND dump_ticket_date < first-of-current-month (prior-month batches only)
--   (B) Compliance risk rows: clients with a GT visit in the prior calendar
--       month but NO manifest at all for that month (service happened, no paperwork)
-- Linkage to visits is informational via visit_linked flag, NOT a gate.
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_derm_compliance AS
WITH prior_month_start AS (
  SELECT date_trunc('month', CURRENT_DATE - INTERVAL '1 month')::date AS d
),
current_month_start AS (
  SELECT date_trunc('month', CURRENT_DATE)::date AS d
),
ready AS (
  SELECT
    'ready_to_file'::text                              AS row_type,
    m.id                                               AS manifest_id,
    m.client_id,
    c.name                                             AS client_name,
    c.client_code,
    m.service_date,
    m.dump_ticket_date,
    m.white_manifest_num,
    m.yellow_ticket_num,
    m.sent_to_client,
    m.sent_to_city,
    EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.manifest_id = m.id) AS visit_linked,
    (CURRENT_DATE - m.dump_ticket_date)::int           AS days_since_dump,
    NULL::date                                         AS risk_service_date
  FROM public.derm_manifests m
  JOIN public.clients c ON c.id = m.client_id
  WHERE m.dump_ticket_date IS NOT NULL
    AND m.sent_to_city IS DISTINCT FROM TRUE
    AND m.dump_ticket_date < (SELECT d FROM current_month_start)
),
risk AS (
  SELECT DISTINCT
    'risk_no_manifest'::text                           AS row_type,
    NULL::bigint                                       AS manifest_id,
    v.client_id,
    c.name                                             AS client_name,
    c.client_code,
    v.visit_date                                       AS service_date,
    NULL::date                                         AS dump_ticket_date,
    NULL::text                                         AS white_manifest_num,
    NULL::text                                         AS yellow_ticket_num,
    NULL::boolean                                      AS sent_to_client,
    NULL::boolean                                      AS sent_to_city,
    FALSE                                              AS visit_linked,
    NULL::int                                          AS days_since_dump,
    v.visit_date                                       AS risk_service_date
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  WHERE v.service_type = 'GT'
    AND v.visit_status = 'COMPLETED'
    AND v.visit_date >= (SELECT d FROM prior_month_start)
    AND v.visit_date <  (SELECT d FROM current_month_start)
    AND NOT EXISTS (
      SELECT 1 FROM public.derm_manifests m
      WHERE m.client_id = v.client_id
        AND m.service_date >= (SELECT d FROM prior_month_start)
        AND m.service_date <  (SELECT d FROM current_month_start)
    )
)
SELECT *, (SELECT MAX(updated_at) FROM public.derm_manifests) AS data_as_of FROM ready
UNION ALL
SELECT *, (SELECT MAX(updated_at) FROM public.derm_manifests) AS data_as_of FROM risk
ORDER BY row_type, service_date NULLS LAST;

COMMENT ON VIEW ops.v_derm_compliance IS
  'DERM compliance: (A) ready-to-file manifests from prior months with dump_ticket but not yet sent_to_city, (B) risk rows where a GT visit happened last month with no manifest. visit_linked is informational only.';
