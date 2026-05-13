-- ============================================================================
-- Sandbox view sync — 2026-05-05
-- ============================================================================
-- The sandbox_refresh.sh script does pg_dump --data-only, so views (DDL) are
-- never synced. Today's refresh propagated the visits.truck drop into Sandbox,
-- breaking the Lovable app's queries that select `truck`. Recreating the
-- missing view here so Lovable can switch its `.from('visits')` calls to
-- `.from('visits_with_status')` and read `vehicle_name` instead of `truck`.
--
-- Mirrors what's in Prod (drop_dead_3nf_columns_2026_05_04.sql + later fixes).
-- Idempotent — uses CREATE OR REPLACE / IF EXISTS.
-- ============================================================================

CREATE OR REPLACE VIEW visits_with_status WITH (security_invoker = true) AS
SELECT v.id, v.client_id, v.property_id, v.job_id, v.vehicle_id,
  v.visit_date, v.start_at, v.end_at, v.completed_at, v.duration_minutes,
  v.title, v.service_type, v.visit_status,
  (v.visit_status = 'completed'::text) AS is_complete,
  v.actual_arrival_at, v.actual_departure_at, v.is_gps_confirmed,
  v.created_at, v.updated_at, v.invoice_id, v.completed_by,
  c.name AS client_name, p.zone, veh.name AS vehicle_name,
  sc.frequency_days,
  CASE
    WHEN v.visit_status = 'completed' THEN 'completed'
    WHEN v.visit_date < CURRENT_DATE AND v.visit_status <> 'completed' THEN 'late'
    WHEN v.visit_date = CURRENT_DATE THEN 'today'
    ELSE 'upcoming'
  END AS computed_late_status
FROM visits v
LEFT JOIN clients c ON c.id = v.client_id
LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
LEFT JOIN service_configs sc ON sc.client_id = v.client_id AND sc.service_type = v.service_type;

GRANT SELECT ON visits_with_status TO authenticated, anon, service_role;
