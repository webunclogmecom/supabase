-- ============================================================================
-- ops.v_driver_kpi — per-driver 30-day KPIs (visits, clients, revenue, inspections)
-- ----------------------------------------------------------------------------
-- RESYNCED 2026-06-09 to the LIVE view definition. The prior version in this file
-- was a stale older design (visits assigned/completed + on-time/inspection placeholders)
-- that used v.visit_status = 'COMPLETED' (UPPERCASE — matches 0 rows; canonical is the
-- lowercase 'completed'). The live view was rewritten (visit/client/revenue + PRE/POST
-- inspection stats) and its casing fixed by 2026-05-23c_ops_views_completed_casing_fix.sql;
-- this file was never resynced. The live def below is correct (verified lowercase).
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_driver_kpi AS
WITH driver_visits AS (
  SELECT va.employee_id,
         count(DISTINCT v.id)         AS visits_completed,
         count(DISTINCT v.client_id)  AS unique_clients,
         count(DISTINCT v.visit_date) AS active_days,
         sum(i.total)                 AS attributed_revenue
    FROM visit_assignments va
    JOIN visits v   ON v.id = va.visit_id
    LEFT JOIN invoices i ON i.id = v.invoice_id
   WHERE v.visit_status = 'completed'::text
     AND v.visit_date >= (CURRENT_DATE - '30 days'::interval)
   GROUP BY va.employee_id
),
inspection_stats AS (
  SELECT inspections.employee_id,
         count(*) FILTER (WHERE inspections.inspection_type = 'PRE'::text)  AS pre_count,
         count(*) FILTER (WHERE inspections.inspection_type = 'POST'::text) AS post_count,
         count(DISTINCT inspections.shift_date)                            AS shifts_with_any,
         count(*) FILTER (WHERE inspections.has_issue = true)               AS shifts_with_issues
    FROM inspections
   WHERE inspections.shift_date >= (CURRENT_DATE - '30 days'::interval)
   GROUP BY inspections.employee_id
)
SELECT e.id,
       e.full_name AS driver_name,
       e.role,
       e.shift,
       e.status AS employee_status,
       COALESCE(dv.visits_completed, 0::bigint)   AS visits_30d,
       COALESCE(dv.unique_clients, 0::bigint)     AS clients_served_30d,
       COALESCE(dv.active_days, 0::bigint)        AS active_days_30d,
       COALESCE(dv.attributed_revenue, 0::numeric) AS revenue_30d,
       COALESCE(ins.pre_count, 0::bigint)         AS pre_inspections_30d,
       COALESCE(ins.post_count, 0::bigint)        AS post_inspections_30d,
       COALESCE(ins.shifts_with_any, 0::bigint)   AS inspection_shifts_30d,
       COALESCE(ins.shifts_with_issues, 0::bigint) AS shifts_with_issues_30d,
       round(100.0 * LEAST(COALESCE(ins.pre_count, 0::bigint), COALESCE(ins.post_count, 0::bigint))::numeric
             / NULLIF(COALESCE(dv.active_days, ins.shifts_with_any, 0::bigint), 0)::numeric, 0) AS inspection_compliance_pct
  FROM employees e
  LEFT JOIN driver_visits dv    ON dv.employee_id = e.id
  LEFT JOIN inspection_stats ins ON ins.employee_id = e.id
 WHERE e.status = 'ACTIVE'::text
 ORDER BY COALESCE(dv.visits_completed, 0::bigint) DESC;
