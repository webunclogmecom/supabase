-- ============================================================================
-- ops.v_driver_kpi — Per-employee KPIs (rolling 30 days)
-- ----------------------------------------------------------------------------
-- Visits assigned, visits completed, completion rate.
-- On-time % and inspection completion % are placeholders until
-- actual_arrival_at / Fillout inspections are wired to employees.
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_driver_kpi AS
WITH window_bounds AS (
  SELECT (CURRENT_DATE - INTERVAL '30 days')::date AS start_d,
         CURRENT_DATE                              AS end_d
),
assigned AS (
  SELECT
    va.employee_id,
    COUNT(*)                                                  AS visits_assigned,
    COUNT(*) FILTER (WHERE v.visit_status = 'COMPLETED')      AS visits_completed,
    COUNT(*) FILTER (WHERE v.actual_arrival_at IS NOT NULL
                       AND v.start_at IS NOT NULL
                       AND v.actual_arrival_at <= v.start_at + INTERVAL '15 minutes')
                                                              AS visits_on_time,
    COUNT(*) FILTER (WHERE v.actual_arrival_at IS NOT NULL)   AS visits_with_arrival
  FROM public.visit_assignments va
  JOIN public.visits v ON v.id = va.visit_id
  CROSS JOIN window_bounds wb
  WHERE v.visit_date BETWEEN wb.start_d AND wb.end_d
  GROUP BY va.employee_id
)
SELECT
  e.id                         AS employee_id,
  e.full_name,
  e.role,
  e.status                     AS employee_status,
  e.shift                      AS shift_classification,
  COALESCE(a.visits_assigned, 0)  AS visits_assigned,
  COALESCE(a.visits_completed, 0) AS visits_completed,
  CASE WHEN COALESCE(a.visits_assigned,0) > 0
       THEN ROUND((a.visits_completed::numeric / a.visits_assigned) * 100, 1)
       ELSE NULL END           AS completion_rate_pct,
  COALESCE(a.visits_on_time, 0) AS visits_on_time,
  CASE WHEN COALESCE(a.visits_with_arrival,0) > 0
       THEN ROUND((a.visits_on_time::numeric / a.visits_with_arrival) * 100, 1)
       ELSE NULL END           AS on_time_pct,
  (SELECT MAX(updated_at) FROM public.visits) AS data_as_of
FROM public.employees e
LEFT JOIN assigned a ON a.employee_id = e.id
WHERE e.status = 'ACTIVE'
ORDER BY visits_assigned DESC NULLS LAST, e.full_name;

COMMENT ON VIEW ops.v_driver_kpi IS
  'Per-employee KPIs (rolling 30 days): visits assigned/completed, completion rate, on-time rate. On-time threshold = actual_arrival_at <= start_at + 15min.';
