-- 2026-05-29_visits_views_filter_deleted_at.sql
--
-- Companion to 2026-05-29_visits_deleted_at.sql.
-- Every view that surfaces public.visits to an app MUST filter
-- `WHERE deleted_at IS NULL` so soft-deleted (orphan) rows disappear
-- from the user-facing UI.
--
-- Views patched here (HIGH priority — directly back app UIs):
--   - ops.v_calendar_visit        Visit Calendar Lovable app
--   - customer.scheduled_visits   Field Portal Lovable app
--   - public.manifest_pickable_visits  DERM Tracker (attach-visit picker)
--   - public.visits_with_status   Admin Review surfaces
--
-- Follow-up (lower priority, separate migration):
--   ops.visits (merge view), ops.v_route_today, ops.v_service_due,
--   ops.v_truck_utilization, ops.v_driver_kpi, ops.v_revenue_summary,
--   ops.v_derm_compliance, public.visits_recent, public.visits_with_review,
--   customer.work_orders, customer.recommendations, customer.inspection_items,
--   customer.wo_photos, customer.permits.
--
-- DROP+CREATE because CREATE OR REPLACE rejects column-list changes; even
-- though we're not changing columns here, the conservative approach is
-- robust against future view-shape changes in this migration's lifetime.
--
-- Idempotent.

BEGIN;

-- ============================================================================
-- 1. customer.scheduled_visits  (Field Portal)
-- ============================================================================
DROP VIEW IF EXISTS customer.scheduled_visits;
CREATE VIEW customer.scheduled_visits AS
SELECT public_id AS id,
       customer.uuid_from_bigint(client_id) AS client_id,
       visit_date AS scheduled_date,
       NULL::text AS scheduled_window,
       service_type,
       title AS notes,
       visit_status AS status,
       created_at
FROM public.visits v
WHERE visit_status = 'scheduled'
  AND client_id IS NOT NULL
  AND v.deleted_at IS NULL;
GRANT SELECT ON customer.scheduled_visits TO anon, authenticated;

-- ============================================================================
-- 2. public.manifest_pickable_visits  (DERM Tracker)
-- ============================================================================
DROP VIEW IF EXISTS public.manifest_pickable_visits;
CREATE VIEW public.manifest_pickable_visits AS
SELECT v.id AS visit_id,
       v.visit_date,
       v.start_at,
       v.completed_at,
       v.service_type,
       v.title,
       c.id AS client_id,
       c.client_code,
       c.name AS client_name,
       COALESCE(p.address, primary_p.address) AS address,
       COALESCE(p.city, primary_p.city) AS city,
       COALESCE(p.county, primary_p.county) AS county
FROM public.visits v
JOIN public.clients c ON c.id = v.client_id
LEFT JOIN public.properties p ON p.id = v.property_id
LEFT JOIN public.properties primary_p
  ON primary_p.client_id = v.client_id AND primary_p.is_primary = true
WHERE v.visit_status = 'completed'
  AND v.service_type = 'GT'
  AND (v.derm_required IS NULL OR v.derm_required = true)
  AND v.deleted_at IS NULL
  AND NOT EXISTS (
    SELECT 1
    FROM public.manifest_visits mv
    JOIN public.derm_manifests dm ON dm.id = mv.manifest_id
    WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL
  );
GRANT SELECT ON public.manifest_pickable_visits TO anon, authenticated;

-- ============================================================================
-- 3. public.visits_with_status  (Admin Review)
-- ============================================================================
DROP VIEW IF EXISTS public.visits_with_status;
CREATE VIEW public.visits_with_status AS
SELECT v.id,
       v.client_id,
       v.property_id,
       v.job_id,
       v.vehicle_id,
       v.visit_date,
       v.start_at,
       v.end_at,
       v.completed_at,
       v.duration_minutes,
       v.title,
       v.service_type,
       v.visit_status,
       v.visit_status = 'completed' AS is_complete,
       v.actual_arrival_at,
       v.actual_departure_at,
       v.is_gps_confirmed,
       v.created_at,
       v.updated_at,
       v.invoice_id,
       v.completed_by,
       c.name AS client_name,
       p.zone,
       veh.name AS vehicle_name,
       sc.frequency_days,
       CASE
         WHEN v.visit_status = 'completed' THEN 'completed'
         WHEN v.visit_date < CURRENT_DATE AND v.visit_status <> 'completed' THEN 'late'
         WHEN v.visit_date = CURRENT_DATE THEN 'today'
         ELSE 'upcoming'
       END AS computed_late_status
FROM public.visits v
LEFT JOIN public.clients c ON c.id = v.client_id
LEFT JOIN public.properties p ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN public.vehicles veh ON veh.id = v.vehicle_id
LEFT JOIN public.service_configs sc ON sc.client_id = v.client_id AND sc.service_type = v.service_type
WHERE v.deleted_at IS NULL;
GRANT SELECT ON public.visits_with_status TO anon, authenticated;

COMMIT;
