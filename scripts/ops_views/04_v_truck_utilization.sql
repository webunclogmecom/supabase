-- ============================================================================
-- ops.v_truck_utilization — per-truck 30-day utilization (visits, hours, revenue)
-- ----------------------------------------------------------------------------
-- RESYNCED 2026-06-09 to the LIVE view definition. The prior version in this file
-- was a stale older design (per vehicle×date rows, capacity-proxy utilization %,
-- referencing veh.short_code / tank_capacity_gallons / primary_use) that used
-- v.visit_status = 'COMPLETED' (UPPERCASE — matches 0 rows; canonical lowercase
-- 'completed'). The live view was rewritten (per-truck 30-day aggregates: visits,
-- clients, hours on-site, revenue) and its casing fixed by
-- 2026-05-23c_ops_views_completed_casing_fix.sql; this file was never resynced.
-- The live def below is correct (verified lowercase).
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_truck_utilization AS
WITH truck_stats AS (
  SELECT v.vehicle_id,
         count(DISTINCT v.id)         AS visits_completed,
         count(DISTINCT v.client_id)  AS unique_clients,
         count(DISTINCT v.visit_date) AS active_days,
         sum(i.total)                 AS attributed_revenue,
         round(sum(EXTRACT(epoch FROM v.end_at - v.start_at))
               FILTER (WHERE v.start_at IS NOT NULL AND v.end_at IS NOT NULL) / 3600.0, 1) AS total_hours_onsite
    FROM visits v
    LEFT JOIN invoices i ON i.id = v.invoice_id
   WHERE v.visit_status = 'completed'::text
     AND v.visit_date >= (CURRENT_DATE - '30 days'::interval)
   GROUP BY v.vehicle_id
)
SELECT veh.id   AS vehicle_id,
       veh.name AS truck,
       veh.make,
       veh.model,
       veh.year,
       veh.grease_tank_capacity_gallons,
       veh.fuel_tank_capacity_gallons,
       veh.status AS truck_status,
       COALESCE(ts.visits_completed, 0::bigint)    AS visits_30d,
       COALESCE(ts.unique_clients, 0::bigint)      AS clients_served_30d,
       COALESCE(ts.active_days, 0::bigint)         AS active_days_30d,
       COALESCE(ts.total_hours_onsite, 0::numeric) AS hours_onsite_30d,
       COALESCE(ts.attributed_revenue, 0::numeric) AS revenue_30d,
       round(COALESCE(ts.visits_completed, 0::bigint)::numeric / NULLIF(ts.active_days, 0)::numeric, 1) AS visits_per_active_day,
       round(COALESCE(ts.attributed_revenue, 0::numeric) / NULLIF(ts.active_days, 0)::numeric, 2)        AS revenue_per_active_day
  FROM vehicles veh
  LEFT JOIN truck_stats ts ON ts.vehicle_id = veh.id
 ORDER BY COALESCE(ts.visits_completed, 0::bigint) DESC;
