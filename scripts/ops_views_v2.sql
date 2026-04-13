-- ============================================================================
-- ops_views_v2.sql — All 8 operational views rebuilt for v2 schema
-- Source: Viktor (Dev) drafts, reviewed & corrected by Claude
-- Corrections applied:
--   1. c.status='active' → c.status IN ('ACTIVE','Recuring') (actual data values)
--   2. visits.notes removed (column doesn't exist in v2)
--   3. HTML entities fixed (Slack encoding)
--   4. Split CTEs recombined into single statements
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS ops;

-- ============================================================
-- 1. v_ar_aging
--    AR ~$115K / 179 open invoices. Sorted by zone then age.
-- ============================================================
CREATE OR REPLACE VIEW ops.v_ar_aging AS
SELECT
    c.id               AS client_id,
    c.client_code,
    c.name             AS client_name,
    c.status           AS client_status,
    p.zone,
    p.address,
    p.city,
    p.county,
    cc.name            AS contact_name,
    cc.email           AS primary_email,
    cc.phone           AS primary_phone,
    i.id               AS invoice_id,
    i.invoice_number,
    i.due_date,
    i.total,
    i.outstanding_amount AS balance_due,
    i.invoice_status,
    (CURRENT_DATE - i.due_date)               AS days_overdue,
    CASE
        WHEN i.outstanding_amount <= 0                             THEN 'paid'
        WHEN i.due_date >= CURRENT_DATE                     THEN 'current'
        WHEN (CURRENT_DATE - i.due_date) BETWEEN 1  AND 30  THEN '1-30_days'
        WHEN (CURRENT_DATE - i.due_date) BETWEEN 31 AND 60  THEN '31-60_days'
        WHEN (CURRENT_DATE - i.due_date) BETWEEN 61 AND 90  THEN '61-90_days'
        ELSE '90+_days'
    END AS aging_bucket
FROM invoices i
JOIN clients c ON c.id = i.client_id
LEFT JOIN client_contacts cc
    ON cc.client_id = c.id AND cc.contact_role = 'primary'
LEFT JOIN properties p
    ON p.client_id = c.id AND p.is_primary = true
WHERE i.outstanding_amount > 0
ORDER BY p.zone NULLS LAST, days_overdue DESC NULLS LAST;


-- ============================================================
-- 2. v_derm_compliance
--    DERM 90-day mandate tracking + missing manifest detection
-- ============================================================
CREATE OR REPLACE VIEW ops.v_derm_compliance AS
WITH last_manifest AS (
    SELECT
        client_id,
        MAX(service_date) AS last_manifest_date,
        COUNT(*)          AS total_manifests
    FROM derm_manifests
    GROUP BY client_id
),
unmatched_visits AS (
    SELECT v.client_id, COUNT(*) AS missing_manifests
    FROM visits v
    WHERE v.service_type = 'GT'
      AND v.visit_status = 'COMPLETED'
      AND v.visit_date >= CURRENT_DATE - INTERVAL '120 days'
      AND NOT EXISTS (
          SELECT 1 FROM derm_manifests dm
          WHERE dm.client_id = v.client_id
            AND dm.service_date = v.visit_date
      )
    GROUP BY v.client_id
)
SELECT
    c.id, c.client_code, c.name AS client_name, c.status AS client_status,
    p.zone, p.address, p.city, p.county,
    cc.name AS contact_name, cc.email, cc.phone,
    sc.permit_number, sc.permit_expiration,
    sc.equipment_size_gallons, sc.frequency_days,
    lm.last_manifest_date, lm.total_manifests,
    COALESCE(uv.missing_manifests, 0)        AS missing_manifest_count,
    CASE WHEN COALESCE(uv.missing_manifests,0)>0 THEN true ELSE false
    END                                      AS has_missing_manifests,
    (CURRENT_DATE - lm.last_manifest_date)   AS days_since_last_manifest,
    CASE
        WHEN lm.last_manifest_date IS NULL                                  THEN 'no_service_record'
        WHEN (CURRENT_DATE - lm.last_manifest_date) > 90                   THEN 'derm_violation'
        WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days,90)     THEN 'overdue'
        WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days,90)-14  THEN 'due_soon'
        ELSE 'compliant'
    END AS compliance_status
FROM clients c
JOIN service_configs sc ON sc.client_id=c.id AND sc.service_type='GT'
LEFT JOIN client_contacts cc ON cc.client_id=c.id AND cc.contact_role='primary'
LEFT JOIN properties p ON p.client_id=c.id AND p.is_primary=true
LEFT JOIN last_manifest lm ON lm.client_id=c.id
LEFT JOIN unmatched_visits uv ON uv.client_id=c.id
WHERE c.status IN ('ACTIVE','Recuring')
ORDER BY
    CASE
        WHEN (CURRENT_DATE-lm.last_manifest_date)>90                             THEN 1
        WHEN lm.last_manifest_date IS NULL                                       THEN 2
        WHEN (CURRENT_DATE-lm.last_manifest_date)>COALESCE(sc.frequency_days,90) THEN 3
        WHEN (CURRENT_DATE-lm.last_manifest_date)>COALESCE(sc.frequency_days,90)-14 THEN 4
        ELSE 5
    END,
    COALESCE(uv.missing_manifests,0) DESC,
    days_since_last_manifest DESC NULLS LAST;


-- ============================================================
-- 3. v_driver_kpi (rolling 30 days)
-- ============================================================
CREATE OR REPLACE VIEW ops.v_driver_kpi AS
WITH driver_visits AS (
    SELECT
        va.employee_id,
        COUNT(DISTINCT v.id)         AS visits_completed,
        COUNT(DISTINCT v.client_id)  AS unique_clients,
        COUNT(DISTINCT v.visit_date) AS active_days,
        SUM(i.total)                 AS attributed_revenue
    FROM visit_assignments va
    JOIN visits v ON v.id = va.visit_id
    LEFT JOIN invoices i ON i.id = v.invoice_id
    WHERE v.visit_status = 'COMPLETED'
      AND v.visit_date >= CURRENT_DATE - INTERVAL '30 days'
    GROUP BY va.employee_id
),
inspection_stats AS (
    SELECT
        employee_id,
        COUNT(*) FILTER (WHERE inspection_type='PRE')  AS pre_count,
        COUNT(*) FILTER (WHERE inspection_type='POST') AS post_count,
        COUNT(DISTINCT shift_date)                     AS shifts_with_any,
        COUNT(*) FILTER (WHERE has_issue=true)         AS shifts_with_issues
    FROM inspections
    WHERE shift_date >= CURRENT_DATE - INTERVAL '30 days'
    GROUP BY employee_id
)
SELECT
    e.id, e.full_name AS driver_name, e.role, e.shift, e.status AS employee_status,
    COALESCE(dv.visits_completed,0)   AS visits_30d,
    COALESCE(dv.unique_clients,0)     AS clients_served_30d,
    COALESCE(dv.active_days,0)        AS active_days_30d,
    COALESCE(dv.attributed_revenue,0) AS revenue_30d,
    COALESCE(ins.pre_count,0)         AS pre_inspections_30d,
    COALESCE(ins.post_count,0)        AS post_inspections_30d,
    COALESCE(ins.shifts_with_any,0)   AS inspection_shifts_30d,
    COALESCE(ins.shifts_with_issues,0) AS shifts_with_issues_30d,
    -- Inspection compliance: % of active days where both pre+post were filed
    -- Note: Kevis/night crew will show near-zero visits_30d until Jobber backfilled from GPS
    ROUND(
        100.0 * LEAST(COALESCE(ins.pre_count,0), COALESCE(ins.post_count,0))
        / NULLIF(COALESCE(dv.active_days, ins.shifts_with_any, 0), 0), 0
    ) AS inspection_compliance_pct
FROM employees e
LEFT JOIN driver_visits dv    ON dv.employee_id = e.id
LEFT JOIN inspection_stats ins ON ins.employee_id = e.id
WHERE e.status = 'ACTIVE'
ORDER BY visits_30d DESC;


-- ============================================================
-- 4. v_gdo_expiry
--    GDO permits expiring within 30/60/90 days
-- ============================================================
CREATE OR REPLACE VIEW ops.v_gdo_expiry AS
SELECT
    c.id, c.client_code, c.name AS client_name, c.status AS client_status,
    p.zone, p.address, p.city, p.county,
    cc.name AS contact_name, cc.email, cc.phone,
    sc.service_type, sc.permit_number, sc.permit_expiration,
    sc.equipment_size_gallons, sc.frequency_days,
    (sc.permit_expiration - CURRENT_DATE) AS days_until_expiry,
    CASE
        WHEN sc.permit_expiration IS NULL                        THEN 'no_permit'
        WHEN sc.permit_expiration < CURRENT_DATE                 THEN 'expired'
        WHEN (sc.permit_expiration - CURRENT_DATE) <= 30         THEN 'expiring_30d'
        WHEN (sc.permit_expiration - CURRENT_DATE) <= 60         THEN 'expiring_60d'
        WHEN (sc.permit_expiration - CURRENT_DATE) <= 90         THEN 'expiring_90d'
        ELSE 'valid'
    END AS permit_status
FROM service_configs sc
JOIN clients c ON c.id = sc.client_id
LEFT JOIN client_contacts cc ON cc.client_id=c.id AND cc.contact_role='primary'
LEFT JOIN properties p ON p.client_id=c.id AND p.is_primary=true
WHERE c.status IN ('ACTIVE','Recuring') AND sc.service_type='GT'
ORDER BY
    CASE
        WHEN sc.permit_expiration IS NULL                THEN 2
        WHEN sc.permit_expiration < CURRENT_DATE         THEN 1
        WHEN (sc.permit_expiration-CURRENT_DATE) <= 30   THEN 3
        WHEN (sc.permit_expiration-CURRENT_DATE) <= 60   THEN 4
        WHEN (sc.permit_expiration-CURRENT_DATE) <= 90   THEN 5
        ELSE 6
    END,
    days_until_expiry ASC NULLS LAST;


-- ============================================================
-- 5. v_revenue_summary (last 12 months)
--    Groups by month + service_type + zone + truck
-- ============================================================
CREATE OR REPLACE VIEW ops.v_revenue_summary AS
SELECT
    DATE_TRUNC('month', v.visit_date)::date  AS month,
    v.service_type,
    p.zone,
    veh.name                                 AS truck,
    COUNT(DISTINCT v.id)                     AS visit_count,
    COUNT(DISTINCT v.client_id)              AS client_count,
    SUM(i.total)                             AS gross_revenue,
    SUM(i.outstanding_amount)                       AS outstanding_ar,
    SUM(i.total - i.outstanding_amount)             AS collected_revenue,
    ROUND(
        100.0 * SUM(i.total - i.outstanding_amount)
        / NULLIF(SUM(i.total), 0), 1
    )                                        AS collection_rate_pct
FROM visits v
JOIN invoices i ON i.id = v.invoice_id
LEFT JOIN properties p ON p.id = v.property_id
LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
WHERE v.visit_status = 'COMPLETED'
  AND v.visit_date >= CURRENT_DATE - INTERVAL '12 months'
GROUP BY DATE_TRUNC('month', v.visit_date), v.service_type, p.zone, veh.name
ORDER BY month DESC, gross_revenue DESC;


-- ============================================================
-- 6. v_route_today
--    Today's scheduled visits with address, zone, truck, crew
--    Uses visit's property first, falls back to client primary property
-- ============================================================
CREATE OR REPLACE VIEW ops.v_route_today AS
SELECT
    v.id AS visit_id, v.visit_date, v.start_at, v.end_at,
    v.visit_status, v.service_type, v.is_complete, v.is_gps_confirmed,
    c.id AS client_id, c.client_code, c.name AS client_name,
    COALESCE(vp.zone,     pp.zone)     AS zone,
    COALESCE(vp.address,  pp.address)  AS address,
    COALESCE(vp.city,     pp.city)     AS city,
    COALESCE(vp.county,   pp.county)   AS county,
    COALESCE(vp.latitude, pp.latitude) AS latitude,
    COALESCE(vp.longitude,pp.longitude)AS longitude,
    COALESCE(vp.access_hours_start,pp.access_hours_start) AS access_hours_start,
    COALESCE(vp.access_hours_end,  pp.access_hours_end)   AS access_hours_end,
    cc.name AS contact_name, cc.phone AS contact_phone,
    sc.equipment_size_gallons, sc.permit_number,
    veh.name AS truck, veh.tank_capacity_gallons,
    STRING_AGG(e.full_name, ', ' ORDER BY e.full_name) AS crew,
    v.duration_minutes
FROM visits v
JOIN clients c ON c.id = v.client_id
LEFT JOIN properties vp ON vp.id = v.property_id
LEFT JOIN properties pp ON pp.client_id=c.id AND pp.is_primary=true
LEFT JOIN client_contacts cc ON cc.client_id=c.id AND cc.contact_role='primary'
LEFT JOIN service_configs sc ON sc.client_id=c.id AND sc.service_type=v.service_type
LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
LEFT JOIN visit_assignments va ON va.visit_id = v.id
LEFT JOIN employees e ON e.id = va.employee_id
WHERE v.visit_date = CURRENT_DATE
  AND v.visit_status IN ('UPCOMING','LATE','COMPLETED')
GROUP BY
    v.id, v.visit_date, v.start_at, v.end_at, v.visit_status,
    v.service_type, v.is_complete, v.is_gps_confirmed,
    c.id, c.client_code, c.name,
    vp.zone, vp.address, vp.city, vp.county,
    vp.latitude, vp.longitude,
    vp.access_hours_start, vp.access_hours_end,
    pp.zone, pp.address, pp.city, pp.county,
    pp.latitude, pp.longitude,
    pp.access_hours_start, pp.access_hours_end,
    cc.name, cc.phone,
    sc.equipment_size_gallons, sc.permit_number,
    veh.name, veh.tank_capacity_gallons,
    v.duration_minutes
ORDER BY
    v.start_at ASC NULLS LAST,
    COALESCE(vp.zone, pp.zone) NULLS LAST,
    c.name;


-- ============================================================
-- 7. v_service_due
--    Diego's main dispatch view. DERM violations float to top.
--    Shows clients due or overdue for GT/CL service.
-- ============================================================
CREATE OR REPLACE VIEW ops.v_service_due AS
WITH actual_last_visit AS (
    SELECT client_id, MAX(visit_date) AS last_visit_actual
    FROM visits
    WHERE visit_status = 'COMPLETED'
    GROUP BY client_id
)
SELECT
    c.id, c.client_code, c.name AS client_name, c.status AS client_status,
    p.zone, p.address, p.city, p.county,
    p.access_hours_start, p.access_hours_end,
    cc.name AS contact_name, cc.email, cc.phone,
    sc.service_type, sc.frequency_days, sc.equipment_size_gallons,
    sc.permit_number, sc.price_per_visit,
    COALESCE(sc.last_visit, alv.last_visit_actual)       AS last_service_date,
    sc.next_visit                                        AS scheduled_next_visit,
    (CURRENT_DATE - COALESCE(sc.last_visit,alv.last_visit_actual)) AS days_since_service,
    CASE
        WHEN COALESCE(sc.last_visit,alv.last_visit_actual) IS NULL          THEN 'never_serviced'
        WHEN (CURRENT_DATE-COALESCE(sc.last_visit,alv.last_visit_actual))>90 THEN 'derm_violation'
        WHEN (CURRENT_DATE-COALESCE(sc.last_visit,alv.last_visit_actual))>=sc.frequency_days THEN 'overdue'
        WHEN ((COALESCE(sc.last_visit,alv.last_visit_actual)+sc.frequency_days)-CURRENT_DATE)<=14 THEN 'due_soon'
        ELSE 'on_schedule'
    END AS service_status
FROM clients c
JOIN service_configs sc ON sc.client_id=c.id AND sc.service_type IN ('GT','CL')
LEFT JOIN client_contacts cc ON cc.client_id=c.id AND cc.contact_role='primary'
LEFT JOIN properties p ON p.client_id=c.id AND p.is_primary=true
LEFT JOIN actual_last_visit alv ON alv.client_id=c.id
WHERE c.status IN ('ACTIVE','Recuring')
  AND (COALESCE(sc.last_visit,alv.last_visit_actual) IS NULL
       OR (CURRENT_DATE-COALESCE(sc.last_visit,alv.last_visit_actual))>=COALESCE(sc.frequency_days,90)-14)
ORDER BY
    CASE WHEN (CURRENT_DATE-COALESCE(sc.last_visit,alv.last_visit_actual))>90 THEN 1 ELSE 2 END,
    p.zone NULLS LAST,
    CASE
        WHEN COALESCE(sc.last_visit,alv.last_visit_actual) IS NULL THEN 1
        WHEN (CURRENT_DATE-COALESCE(sc.last_visit,alv.last_visit_actual))>=sc.frequency_days THEN 2
        ELSE 3
    END,
    days_since_service DESC NULLS LAST;


-- ============================================================
-- 8. v_truck_utilization (rolling 30 days)
--    Hours from start_at/end_at, revenue per truck
-- ============================================================
CREATE OR REPLACE VIEW ops.v_truck_utilization AS
WITH truck_stats AS (
    SELECT
        v.vehicle_id,
        COUNT(DISTINCT v.id)         AS visits_completed,
        COUNT(DISTINCT v.client_id)  AS unique_clients,
        COUNT(DISTINCT v.visit_date) AS active_days,
        SUM(i.total)                 AS attributed_revenue,
        ROUND(
            SUM(EXTRACT(EPOCH FROM (v.end_at - v.start_at)))
            FILTER (WHERE v.start_at IS NOT NULL AND v.end_at IS NOT NULL)
            / 3600.0, 1
        )                            AS total_hours_onsite
    FROM visits v
    LEFT JOIN invoices i ON i.id = v.invoice_id
    WHERE v.visit_status = 'COMPLETED'
      AND v.visit_date >= CURRENT_DATE - INTERVAL '30 days'
    GROUP BY v.vehicle_id
)
SELECT
    veh.id AS vehicle_id,
    veh.name AS truck, veh.make, veh.model, veh.year,
    veh.tank_capacity_gallons, veh.status AS truck_status,
    COALESCE(ts.visits_completed,0)    AS visits_30d,
    COALESCE(ts.unique_clients,0)      AS clients_served_30d,
    COALESCE(ts.active_days,0)         AS active_days_30d,
    COALESCE(ts.total_hours_onsite,0)  AS hours_onsite_30d,
    COALESCE(ts.attributed_revenue,0)  AS revenue_30d,
    ROUND(COALESCE(ts.visits_completed,0)::numeric / NULLIF(ts.active_days,0), 1)
                                       AS visits_per_active_day,
    ROUND(COALESCE(ts.attributed_revenue,0) / NULLIF(ts.active_days,0), 2)
                                       AS revenue_per_active_day
FROM vehicles veh
LEFT JOIN truck_stats ts ON ts.vehicle_id = veh.id
ORDER BY visits_30d DESC;
