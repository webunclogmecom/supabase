-- 2026-05-23c_ops_views_completed_casing_fix.sql
--
-- Fix `visit_status = 'COMPLETED'` typo in 6 ops.v_* analytics views.
--
-- Per Supabase CLAUDE.md column-name gotchas: the canonical value for
-- visits.visit_status is lowercase 'completed' (verified 2026-05-18).
-- However the original 3nf_drop_derived_columns.sql (pre-rename era)
-- wrote 'COMPLETED' (uppercase) in 6 of the 8 ops.v_* views. The string
-- was never updated when the canonical value flipped to lowercase, so
-- these views have been silently returning incorrect data:
--
--   ops.v_derm_compliance  — unmatched_visits CTE empty → all clients
--                            report missing_manifests=0 regardless
--   ops.v_driver_kpi       — driver_visits CTE empty → visits_30d,
--                            clients_served_30d, revenue_30d all = 0
--                            for every employee
--   ops.v_revenue_summary  — revenue subquery empty → all rows = 0
--   ops.v_route_today      — is_complete column always FALSE (any
--                            consumer treating it as filter sees no
--                            completed visits today)
--   ops.v_service_due      — actual_last_visit CTE empty → fallback
--                            never triggers; 2 clients without
--                            sc.last_visit silently mis-classified
--   ops.v_truck_utilization— truck visit aggregates empty → visits_30d,
--                            revenue_30d = 0 for every truck
--
-- Other views unaffected:
--   ops.v_ar_aging          — reads invoices, not visits
--   ops.v_gdo_expiry        — reads gdos/service_configs only
--
-- This migration uses CREATE OR REPLACE VIEW with the FULL current
-- deployed definition (captured via pg_get_viewdef on 2026-05-23) with
-- only the 'COMPLETED' → 'completed' string replaced. No other logic
-- changes. The deployed views had drifted from
-- scripts/migrations/3nf_drop_derived_columns.sql (which used 'Recuring'
-- typo for clients.status, since fixed in deployed); this migration also
-- formally documents that drift.
--
-- Audit (Rule 8): VIEW only, no triggers needed.
-- Idempotent (Rule 5): CREATE OR REPLACE. Re-runnable.
-- Source-of-truth (Rule 4): only consumes canonical tables. No new sources.

BEGIN;

-- ----------------------------------------------------------------
-- ops.v_derm_compliance
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW ops.v_derm_compliance AS
WITH last_manifest AS (
         SELECT derm_manifests.client_id,
            max(derm_manifests.service_date) AS last_manifest_date,
            count(*) AS total_manifests
           FROM derm_manifests
          GROUP BY derm_manifests.client_id
        ), unmatched_visits AS (
         SELECT v.client_id,
            count(*) AS missing_manifests
           FROM visits v
          WHERE v.service_type = 'GT'::text AND v.visit_status = 'completed'::text AND v.visit_date >= (CURRENT_DATE - '120 days'::interval) AND NOT (EXISTS ( SELECT 1
                   FROM derm_manifests dm
                  WHERE dm.client_id = v.client_id AND dm.service_date = v.visit_date))
          GROUP BY v.client_id
        )
 SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p.zone,
    p.address,
    p.city,
    p.county,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    sc.permit_number,
    sc.permit_expiration,
    sc.equipment_size_gallons,
    sc.frequency_days,
    lm.last_manifest_date,
    lm.total_manifests,
    COALESCE(uv.missing_manifests, 0::bigint) AS missing_manifest_count,
        CASE
            WHEN COALESCE(uv.missing_manifests, 0::bigint) > 0 THEN true
            ELSE false
        END AS has_missing_manifests,
    CURRENT_DATE - lm.last_manifest_date AS days_since_last_manifest,
        CASE
            WHEN lm.last_manifest_date IS NULL THEN 'no_service_record'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 'derm_violation'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 'overdue'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 'due_soon'::text
            ELSE 'compliant'::text
        END AS compliance_status
   FROM clients c
     JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = 'GT'::text
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN last_manifest lm ON lm.client_id = c.id
     LEFT JOIN unmatched_visits uv ON uv.client_id = c.id
  WHERE c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])
  ORDER BY (
        CASE
            WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 1
            WHEN lm.last_manifest_date IS NULL THEN 2
            WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 3
            WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 4
            ELSE 5
        END), (COALESCE(uv.missing_manifests, 0::bigint)) DESC, (CURRENT_DATE - lm.last_manifest_date) DESC NULLS LAST;

-- ----------------------------------------------------------------
-- ops.v_driver_kpi
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW ops.v_driver_kpi AS
WITH driver_visits AS (
         SELECT va.employee_id,
            count(DISTINCT v.id) AS visits_completed,
            count(DISTINCT v.client_id) AS unique_clients,
            count(DISTINCT v.visit_date) AS active_days,
            sum(i.total) AS attributed_revenue
           FROM visit_assignments va
             JOIN visits v ON v.id = va.visit_id
             LEFT JOIN invoices i ON i.id = v.invoice_id
          WHERE v.visit_status = 'completed'::text AND v.visit_date >= (CURRENT_DATE - '30 days'::interval)
          GROUP BY va.employee_id
        ), inspection_stats AS (
         SELECT inspections.employee_id,
            count(*) FILTER (WHERE inspections.inspection_type = 'PRE'::text) AS pre_count,
            count(*) FILTER (WHERE inspections.inspection_type = 'POST'::text) AS post_count,
            count(DISTINCT inspections.shift_date) AS shifts_with_any,
            count(*) FILTER (WHERE inspections.has_issue = true) AS shifts_with_issues
           FROM inspections
          WHERE inspections.shift_date >= (CURRENT_DATE - '30 days'::interval)
          GROUP BY inspections.employee_id
        )
 SELECT e.id,
    e.full_name AS driver_name,
    e.role,
    e.shift,
    e.status AS employee_status,
    COALESCE(dv.visits_completed, 0::bigint) AS visits_30d,
    COALESCE(dv.unique_clients, 0::bigint) AS clients_served_30d,
    COALESCE(dv.active_days, 0::bigint) AS active_days_30d,
    COALESCE(dv.attributed_revenue, 0::numeric) AS revenue_30d,
    COALESCE(ins.pre_count, 0::bigint) AS pre_inspections_30d,
    COALESCE(ins.post_count, 0::bigint) AS post_inspections_30d,
    COALESCE(ins.shifts_with_any, 0::bigint) AS inspection_shifts_30d,
    COALESCE(ins.shifts_with_issues, 0::bigint) AS shifts_with_issues_30d,
    round(100.0 * LEAST(COALESCE(ins.pre_count, 0::bigint), COALESCE(ins.post_count, 0::bigint))::numeric / NULLIF(COALESCE(dv.active_days, ins.shifts_with_any, 0::bigint), 0)::numeric, 0) AS inspection_compliance_pct
   FROM employees e
     LEFT JOIN driver_visits dv ON dv.employee_id = e.id
     LEFT JOIN inspection_stats ins ON ins.employee_id = e.id
  WHERE e.status = 'ACTIVE'::text
  ORDER BY (COALESCE(dv.visits_completed, 0::bigint)) DESC;

-- ----------------------------------------------------------------
-- ops.v_revenue_summary
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW ops.v_revenue_summary AS
SELECT date_trunc('month'::text, v.visit_date::timestamp with time zone)::date AS month,
    v.service_type,
    p.zone,
    veh.name AS truck,
    count(DISTINCT v.id) AS visit_count,
    count(DISTINCT v.client_id) AS client_count,
    sum(i.total) AS gross_revenue,
    sum(i.outstanding_amount) AS outstanding_ar,
    sum(i.total - i.outstanding_amount) AS collected_revenue,
    round(100.0 * sum(i.total - i.outstanding_amount) / NULLIF(sum(i.total), 0::numeric), 1) AS collection_rate_pct
   FROM visits v
     JOIN invoices i ON i.id = v.invoice_id
     LEFT JOIN properties p ON p.id = v.property_id
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
  WHERE v.visit_status = 'completed'::text AND v.visit_date >= (CURRENT_DATE - '1 year'::interval)
  GROUP BY (date_trunc('month'::text, v.visit_date::timestamp with time zone)), v.service_type, p.zone, veh.name
  ORDER BY (date_trunc('month'::text, v.visit_date::timestamp with time zone)::date) DESC, (sum(i.total)) DESC;

-- ----------------------------------------------------------------
-- ops.v_route_today
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW ops.v_route_today AS
SELECT v.id AS visit_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.visit_status,
    v.service_type,
    v.visit_status = 'completed'::text AS is_complete,
    v.is_gps_confirmed,
    c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    COALESCE(vp.zone, pp.zone) AS zone,
    COALESCE(vp.address, pp.address) AS address,
    COALESCE(vp.city, pp.city) AS city,
    COALESCE(vp.county, pp.county) AS county,
    COALESCE(vp.latitude, pp.latitude) AS latitude,
    COALESCE(vp.longitude, pp.longitude) AS longitude,
    COALESCE(vp.access_hours_start, pp.access_hours_start) AS access_hours_start,
    COALESCE(vp.access_hours_end, pp.access_hours_end) AS access_hours_end,
    cc.name AS contact_name,
    cc.phone AS contact_phone,
    sc.equipment_size_gallons,
    sc.permit_number,
    veh.name AS truck,
    veh.grease_tank_capacity_gallons,
    string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS crew,
    v.duration_minutes
   FROM visits v
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN properties vp ON vp.id = v.property_id
     LEFT JOIN properties pp ON pp.client_id = c.id AND pp.is_primary = true
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = v.service_type
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
     LEFT JOIN visit_assignments va ON va.visit_id = v.id
     LEFT JOIN employees e ON e.id = va.employee_id
  WHERE v.visit_date = CURRENT_DATE AND (v.visit_status = ANY (ARRAY['UPCOMING'::text, 'LATE'::text, 'completed'::text]))
  GROUP BY v.id, v.visit_date, v.start_at, v.end_at, v.visit_status, v.service_type, v.is_gps_confirmed, c.id, c.client_code, c.name, vp.zone, vp.address, vp.city, vp.county, vp.latitude, vp.longitude, vp.access_hours_start, vp.access_hours_end, pp.zone, pp.address, pp.city, pp.county, pp.latitude, pp.longitude, pp.access_hours_start, pp.access_hours_end, cc.name, cc.phone, sc.equipment_size_gallons, sc.permit_number, veh.name, veh.grease_tank_capacity_gallons, v.duration_minutes
  ORDER BY v.start_at, (COALESCE(vp.zone, pp.zone)), c.name;

-- ----------------------------------------------------------------
-- ops.v_service_due
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW ops.v_service_due AS
WITH actual_last_visit AS (
         SELECT visits.client_id,
            max(visits.visit_date) AS last_visit_actual
           FROM visits
          WHERE visits.visit_status = 'completed'::text
          GROUP BY visits.client_id
        )
 SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p.zone,
    p.address,
    p.city,
    p.county,
    p.access_hours_start,
    p.access_hours_end,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    sc.service_type,
    sc.frequency_days,
    sc.equipment_size_gallons,
    sc.permit_number,
    sc.price_per_visit,
    COALESCE(sc.last_visit, alv.last_visit_actual) AS last_service_date,
    (COALESCE(sc.last_visit, alv.last_visit_actual) + ((sc.frequency_days || ' days'::text)::interval))::date AS scheduled_next_visit,
    CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual) AS days_since_service,
        CASE
            WHEN COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL THEN 'never_serviced'::text
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90 THEN 'derm_violation'::text
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days THEN 'overdue'::text
            WHEN (COALESCE(sc.last_visit, alv.last_visit_actual) + sc.frequency_days - CURRENT_DATE) <= 14 THEN 'due_soon'::text
            ELSE 'on_schedule'::text
        END AS service_status
   FROM clients c
     JOIN service_configs sc ON sc.client_id = c.id AND (sc.service_type = ANY (ARRAY['GT'::text, 'CL'::text]))
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN actual_last_visit alv ON alv.client_id = c.id
  WHERE (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AND (COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL OR (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= (COALESCE(sc.frequency_days, 90) - 14))
  ORDER BY (
        CASE
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90 THEN 1
            ELSE 2
        END), p.zone, (
        CASE
            WHEN COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL THEN 1
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days THEN 2
            ELSE 3
        END), (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) DESC NULLS LAST;

-- ----------------------------------------------------------------
-- ops.v_truck_utilization
-- ----------------------------------------------------------------
CREATE OR REPLACE VIEW ops.v_truck_utilization AS
WITH truck_stats AS (
         SELECT v.vehicle_id,
            count(DISTINCT v.id) AS visits_completed,
            count(DISTINCT v.client_id) AS unique_clients,
            count(DISTINCT v.visit_date) AS active_days,
            sum(i.total) AS attributed_revenue,
            round(sum(EXTRACT(epoch FROM v.end_at - v.start_at)) FILTER (WHERE v.start_at IS NOT NULL AND v.end_at IS NOT NULL) / 3600.0, 1) AS total_hours_onsite
           FROM visits v
             LEFT JOIN invoices i ON i.id = v.invoice_id
          WHERE v.visit_status = 'completed'::text AND v.visit_date >= (CURRENT_DATE - '30 days'::interval)
          GROUP BY v.vehicle_id
        )
 SELECT veh.id AS vehicle_id,
    veh.name AS truck,
    veh.make,
    veh.model,
    veh.year,
    veh.grease_tank_capacity_gallons,
    veh.fuel_tank_capacity_gallons,
    veh.status AS truck_status,
    COALESCE(ts.visits_completed, 0::bigint) AS visits_30d,
    COALESCE(ts.unique_clients, 0::bigint) AS clients_served_30d,
    COALESCE(ts.active_days, 0::bigint) AS active_days_30d,
    COALESCE(ts.total_hours_onsite, 0::numeric) AS hours_onsite_30d,
    COALESCE(ts.attributed_revenue, 0::numeric) AS revenue_30d,
    round(COALESCE(ts.visits_completed, 0::bigint)::numeric / NULLIF(ts.active_days, 0)::numeric, 1) AS visits_per_active_day,
    round(COALESCE(ts.attributed_revenue, 0::numeric) / NULLIF(ts.active_days, 0)::numeric, 2) AS revenue_per_active_day
   FROM vehicles veh
     LEFT JOIN truck_stats ts ON ts.vehicle_id = veh.id
  ORDER BY (COALESCE(ts.visits_completed, 0::bigint)) DESC;

COMMIT;

-- ============================================================
-- VERIFICATION (run after apply)
-- ============================================================
-- 1. Driver KPIs should now show non-zero visits_30d for active drivers:
--    SELECT driver_name, visits_30d, revenue_30d FROM ops.v_driver_kpi
--    WHERE visits_30d > 0 ORDER BY visits_30d DESC LIMIT 5;
--
-- 2. Revenue summary should show 30d activity:
--    SELECT month, SUM(visit_count), SUM(gross_revenue)
--    FROM ops.v_revenue_summary
--    WHERE month >= CURRENT_DATE - INTERVAL '90 days' GROUP BY 1 ORDER BY 1 DESC;
--
-- 3. Route today is_complete should flip TRUE for completed visits today:
--    SELECT COUNT(*) FILTER (WHERE is_complete) AS done_today FROM ops.v_route_today;
--
-- 4. v_service_due classification of 2 affected clients should change
--    (clients with no sc.last_visit but completed visits in the table).
