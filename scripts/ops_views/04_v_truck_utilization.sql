-- ============================================================================
-- ops.v_truck_utilization — Per-truck, per-day visit volume & capacity %
-- ----------------------------------------------------------------------------
-- Rolling 30-day window ending today.
-- One row per (vehicle × date-with-visits). Actual gallons pumped is not
-- directly tracked per visit, so utilization uses visit_count vs a rough
-- daily capacity proxy (5 visits/day for overnight trucks, 8 for Cloggy).
-- This view is intentionally conservative — refine once gallons-per-visit
-- is captured from Fillout post-shift inspections.
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_truck_utilization AS
WITH daily AS (
  SELECT
    v.vehicle_id,
    v.visit_date,
    COUNT(*) FILTER (WHERE v.visit_status = 'COMPLETED') AS completed_visits,
    COUNT(*)                                             AS scheduled_visits
  FROM public.visits v
  WHERE v.vehicle_id IS NOT NULL
    AND v.visit_date BETWEEN CURRENT_DATE - INTERVAL '30 days' AND CURRENT_DATE
  GROUP BY v.vehicle_id, v.visit_date
)
SELECT
  d.visit_date,
  veh.id                    AS vehicle_id,
  veh.name                  AS vehicle_name,
  veh.short_code,
  veh.tank_capacity_gallons,
  veh.primary_use,
  d.scheduled_visits,
  d.completed_visits,
  CASE
    WHEN veh.name = 'Cloggy' THEN 8
    ELSE 5
  END                       AS daily_capacity_visits,
  ROUND(
    (d.scheduled_visits::numeric
     / CASE WHEN veh.name = 'Cloggy' THEN 8 ELSE 5 END) * 100,
    1
  )                         AS utilization_pct,
  (SELECT MAX(updated_at) FROM public.visits) AS data_as_of
FROM daily d
JOIN public.vehicles veh ON veh.id = d.vehicle_id
ORDER BY d.visit_date DESC, veh.name;

COMMENT ON VIEW ops.v_truck_utilization IS
  'Per-truck daily visit count and utilization % (rolling 30 days). Capacity proxy: 8/day for Cloggy, 5/day for overnight trucks. Refine when gallons-per-visit is captured.';
