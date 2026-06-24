-- 2026-06-24  Stop soft-deleted visits leaking through ops.* views (audit follow-up #2)
-- ============================================================================================
-- WHY: 66 soft-deleted visits (deleted_at NOT NULL, set by cron_jobber_reconcile_anomalies) were
-- leaking through 6 ops views that read bare public.visits with no deleted_at filter — inflating
-- revenue sums, driver/truck KPIs, route lists, service-due, and the ops.visits passthrough.
-- FIX: a single canonical base view public.v_visits_live (= visits WHERE deleted_at IS NULL); the 6
-- ops views are re-pointed at it (aliased as 'visits'/'v' so all internal column refs are unchanged).
-- Future ops/app views should read v_visits_live, not public.visits, to prevent re-introducing the leak.
-- Verified: ops.visits 813->747 (=66 removed); aggregate views' row counts stable but now exclude
-- soft-deleted from their sums/counts. Smoke-tested 10/10 (incl. dynamic soft-delete).
-- AUDIT (ADR 010): views only — no table or data change.
-- ============================================================================================

CREATE OR REPLACE VIEW public.v_visits_live AS
  SELECT * FROM public.visits WHERE deleted_at IS NULL;
GRANT SELECT ON public.v_visits_live TO anon, authenticated, service_role;

CREATE OR REPLACE VIEW ops.v_driver_kpi AS
 WITH driver_visits AS (
         SELECT va.employee_id,
            count(DISTINCT v.id) AS visits_completed,
            count(DISTINCT v.client_id) AS unique_clients,
            count(DISTINCT v.visit_date) AS active_days,
            sum(i.total) AS attributed_revenue
           FROM visit_assignments va
             JOIN v_visits_live v ON v.id = va.visit_id
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
   FROM v_visits_live v
     JOIN invoices i ON i.id = v.invoice_id
     LEFT JOIN properties p ON p.id = v.property_id
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
  WHERE v.visit_status = 'completed'::text AND v.visit_date >= (CURRENT_DATE - '1 year'::interval)
  GROUP BY (date_trunc('month'::text, v.visit_date::timestamp with time zone)), v.service_type, p.zone, veh.name
  ORDER BY (date_trunc('month'::text, v.visit_date::timestamp with time zone)::date) DESC, (sum(i.total)) DESC;

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
    COALESCE(( SELECT g.gdo_number
           FROM gdos g
          WHERE g.property_id = v.property_id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1), ( SELECT g.gdo_number
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1)) AS permit_number,
    veh.name AS truck,
    veh.grease_tank_capacity_gallons,
    string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS crew,
    v.duration_minutes
   FROM v_visits_live v
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN properties vp ON vp.id = v.property_id
     LEFT JOIN properties pp ON pp.client_id = c.id AND pp.is_primary = true
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = v.service_type
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
     LEFT JOIN visit_assignments va ON va.visit_id = v.id
     LEFT JOIN employees e ON e.id = va.employee_id
  WHERE v.visit_date = CURRENT_DATE AND (v.visit_status = ANY (ARRAY['UPCOMING'::text, 'LATE'::text, 'completed'::text]))
  GROUP BY v.id, v.visit_date, v.start_at, v.end_at, v.visit_status, v.service_type, v.is_gps_confirmed, c.id, c.client_code, c.name, vp.zone, vp.address, vp.city, vp.county, vp.latitude, vp.longitude, vp.access_hours_start, vp.access_hours_end, pp.zone, pp.address, pp.city, pp.county, pp.latitude, pp.longitude, pp.access_hours_start, pp.access_hours_end, cc.name, cc.phone, sc.equipment_size_gallons, v.property_id, veh.name, veh.grease_tank_capacity_gallons, v.duration_minutes
  ORDER BY v.start_at, (COALESCE(vp.zone, pp.zone)), c.name;

CREATE OR REPLACE VIEW ops.v_service_due AS
 WITH actual_last_visit AS (
         SELECT visits.client_id,
            max(visits.visit_date) AS last_visit_actual
           FROM v_visits_live visits
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
    ( SELECT g.gdo_number
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_number,
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

CREATE OR REPLACE VIEW ops.v_truck_utilization AS
 WITH truck_stats AS (
         SELECT v.vehicle_id,
            count(DISTINCT v.id) AS visits_completed,
            count(DISTINCT v.client_id) AS unique_clients,
            count(DISTINCT v.visit_date) AS active_days,
            sum(i.total) AS attributed_revenue,
            round(sum(EXTRACT(epoch FROM v.end_at - v.start_at)) FILTER (WHERE v.start_at IS NOT NULL AND v.end_at IS NOT NULL) / 3600.0, 1) AS total_hours_onsite
           FROM v_visits_live v
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

CREATE OR REPLACE VIEW ops.visits AS
 SELECT id,
    client_id,
    property_id,
    job_id,
    vehicle_id,
    visit_date,
    start_at,
    end_at,
    completed_at,
    duration_minutes,
    title,
    service_type,
    visit_status,
    actual_arrival_at,
    actual_departure_at,
    is_gps_confirmed,
    created_at,
    updated_at,
    invoice_id,
    completed_by,
    source,
    manhole_count,
    manhole_breakdown,
    ticket_number,
    trap_condition_notes,
    derm_required,
    service_line_item_id
   FROM v_visits_live visits;

