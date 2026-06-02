-- 2026-05-25t_rewire_views_from_gdos.sql
--
-- Phase 4a of the GDO migration plan: rewire all 6 views that still read
-- permit fields from public.service_configs.permit_* to read from
-- public.gdos (canonical) instead. After this lands, no view depends on
-- the legacy permit_* columns, and Phase 4b (drop the columns + remove
-- legacy write from webhook) can safely follow after an observation
-- period.
--
-- VIEWS REWIRED
--   1. customer.clients         — replaces sc_gt.permit_document_path
--                                 with gdos.permit_document_path
--   2. ops.service_configs      — pass-through view; permit_* columns now
--                                 synthesized from gdos via subqueries
--                                 (maintains the column contract while
--                                 the underlying table loses them)
--   3. ops.v_derm_compliance    — permit_number + permit_expiration from
--                                 gdos via LATERAL pick-one-per-client
--   4. ops.v_gdo_expiry         — granularity change: was 1 row per GT
--                                 client, now 1 row per ACTIVE gdo
--                                 (multi-permit clients like Casa Neos
--                                 return 3 rows — correct for an
--                                 expiry-tracking view)
--   5. ops.v_route_today        — permit_number from gdos via subquery
--   6. ops.v_service_due        — permit_number from gdos via subquery
--
-- COLUMN CONTRACT
-- Every view keeps the SAME column names + types + order as before. The
-- only ROW-count change is in ops.v_gdo_expiry (intentional, per above).
--
-- IDEMPOTENT (Rule 5): CREATE OR REPLACE VIEW everywhere. Safe to re-run.
-- AUDIT (Rule 8): views don't generate audit rows; no underlying data is
-- modified by this migration.
--
-- NOTE: CREATE OR REPLACE VIEW cannot rename or reorder columns. All view
-- bodies below preserve the existing column order verbatim. New columns
-- are not added by this migration.

BEGIN;

-- ============================================================
-- 1. customer.clients
-- ============================================================
-- Only `gdo_permit_url` changes source: sc_gt.permit_document_path → gdos.permit_document_path
CREATE OR REPLACE VIEW customer.clients AS
SELECT customer.uuid_from_bigint(c.id) AS id,
    lower(c.client_code) AS slug,
    c.name,
    c.client_code,
    cg.name AS group_name,
    p.address AS address1,
    NULLIF(TRIM(BOTH ' ,'::text FROM concat_ws(', '::text,
        NULLIF(p.city, ''::text),
        NULLIF(concat_ws(' '::text, NULLIF(p.state, ''::text), NULLIF(p.zip, ''::text)), ''::text)
    )), ''::text) AS address2,
    CASE WHEN sc_gt.equipment_size_gallons IS NOT NULL
         THEN (sc_gt.equipment_size_gallons::text || ' gal grease trap')
         ELSE NULL END AS container_type,
    CASE WHEN sc_gt.equipment_size_gallons IS NOT NULL
         THEN (sc_gt.equipment_size_gallons::text || ' gal')
         ELSE NULL END AS trap_capacity,
    sc_gt.material_type AS material,
    df.name AS disposal_facility,
    -- Phase 4a: read permit_document_path from gdos (canonical) instead of service_configs
    (SELECT g.permit_document_path
     FROM public.gdos g
     WHERE g.client_id = c.id AND g.status = 'ACTIVE'
     ORDER BY g.id
     LIMIT 1) AS gdo_permit_url,
    p.access_notes,
    c.created_at,
    c.status,
    (c.status = ANY (ARRAY['ACTIVE','RECURRING'])) AS is_active
FROM public.clients c
LEFT JOIN public.client_groups cg ON cg.id = c.group_id
LEFT JOIN public.properties p ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN public.service_configs sc_gt ON sc_gt.client_id = c.id AND sc_gt.service_type = 'GT'
LEFT JOIN public.disposal_facilities df ON df.id = p.default_disposal_facility_id;

-- ============================================================
-- 2. ops.service_configs (pass-through with synthesized permit_*)
-- ============================================================
-- This view previously SELECT *'d from service_configs. After Phase 4b
-- drops the legacy permit_* columns, this view would break unless we
-- synthesize the columns from gdos here. So even though it's a "passthrough"
-- view, the permit_* columns now go through a per-row subquery on gdos.
CREATE OR REPLACE VIEW ops.service_configs AS
SELECT
    sc.id,
    sc.client_id,
    sc.service_type,
    sc.frequency_days,
    sc.first_visit,
    sc.last_visit,
    sc.stop_date,
    sc.price_per_visit,
    sc.schedule_notes,
    sc.created_at,
    sc.updated_at,
    sc.equipment_size_gallons,
    -- Phase 4a synthesized columns (one permit per client; client with no
    -- ACTIVE gdos returns NULL):
    (SELECT g.gdo_number FROM public.gdos g
     WHERE g.client_id = sc.client_id AND g.status = 'ACTIVE'
     ORDER BY g.id LIMIT 1) AS permit_number,
    (SELECT g.permit_expiration FROM public.gdos g
     WHERE g.client_id = sc.client_id AND g.status = 'ACTIVE'
     ORDER BY g.id LIMIT 1) AS permit_expiration,
    sc.material_type,
    (SELECT g.permit_document_path FROM public.gdos g
     WHERE g.client_id = sc.client_id AND g.status = 'ACTIVE'
     ORDER BY g.id LIMIT 1) AS permit_document_path,
    sc.property_id
FROM public.service_configs sc;

-- ============================================================
-- 3. ops.v_derm_compliance
-- ============================================================
-- Same row granularity (1 row per ACTIVE/RECURRING client with GT service_config).
-- permit_number + permit_expiration now picked from gdos.
CREATE OR REPLACE VIEW ops.v_derm_compliance AS
WITH last_manifest AS (
    SELECT client_id, MAX(service_date) AS last_manifest_date, COUNT(*) AS total_manifests
    FROM public.derm_manifests
    GROUP BY client_id
),
unmatched_visits AS (
    SELECT v.client_id, COUNT(*) AS missing_manifests
    FROM public.visits v
    WHERE v.service_type = 'GT'
      AND v.visit_status = 'completed'
      AND v.visit_date >= (CURRENT_DATE - INTERVAL '120 days')
      AND NOT EXISTS (
        SELECT 1 FROM public.derm_manifests dm
        WHERE dm.client_id = v.client_id AND dm.service_date = v.visit_date
      )
    GROUP BY v.client_id
)
SELECT
    c.id,
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
    -- Phase 4a: source from gdos (one ACTIVE permit per client)
    (SELECT g.gdo_number FROM public.gdos g
     WHERE g.client_id = c.id AND g.status = 'ACTIVE'
     ORDER BY g.id LIMIT 1) AS permit_number,
    (SELECT g.permit_expiration FROM public.gdos g
     WHERE g.client_id = c.id AND g.status = 'ACTIVE'
     ORDER BY g.id LIMIT 1) AS permit_expiration,
    sc.equipment_size_gallons,
    sc.frequency_days,
    lm.last_manifest_date,
    lm.total_manifests,
    COALESCE(uv.missing_manifests, 0::bigint) AS missing_manifest_count,
    CASE WHEN COALESCE(uv.missing_manifests, 0::bigint) > 0 THEN true ELSE false END AS has_missing_manifests,
    (CURRENT_DATE - lm.last_manifest_date) AS days_since_last_manifest,
    CASE
        WHEN lm.last_manifest_date IS NULL THEN 'no_service_record'
        WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 'derm_violation'
        WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 'overdue'
        WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 'due_soon'
        ELSE 'compliant'
    END AS compliance_status
FROM public.clients c
JOIN public.service_configs sc ON sc.client_id = c.id AND sc.service_type = 'GT'
LEFT JOIN public.client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'
LEFT JOIN public.properties p ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN last_manifest lm ON lm.client_id = c.id
LEFT JOIN unmatched_visits uv ON uv.client_id = c.id
WHERE c.status IN ('ACTIVE','RECURRING')
ORDER BY
    CASE
        WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 1
        WHEN lm.last_manifest_date IS NULL THEN 2
        WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 3
        WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 4
        ELSE 5
    END,
    COALESCE(uv.missing_manifests, 0::bigint) DESC,
    (CURRENT_DATE - lm.last_manifest_date) DESC NULLS LAST;

-- ============================================================
-- 4. ops.v_gdo_expiry (GRANULARITY CHANGE)
-- ============================================================
-- BEFORE: 1 row per (client × GT service_config). Multi-permit clients
--         like Casa Neos appeared once with whatever permit the webhook
--         happened to write (the bug we just fixed).
-- AFTER:  1 row per ACTIVE gdo. Casa Neos now returns 3 rows
--         (KITCHENS / BARS / LOUNGE) — correct, since each permit has
--         its own expiration date.
-- Joins:  properties via gdo.property_id (not client primary property),
--         so multi-property clients also resolve correctly.
CREATE OR REPLACE VIEW ops.v_gdo_expiry AS
SELECT
    c.id,
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
    'GT'::text AS service_type,
    g.gdo_number AS permit_number,
    g.permit_expiration,
    sc.equipment_size_gallons,
    sc.frequency_days,
    (g.permit_expiration - CURRENT_DATE) AS days_until_expiry,
    CASE
        WHEN g.permit_expiration IS NULL THEN 'no_permit'
        WHEN g.permit_expiration < CURRENT_DATE THEN 'expired'
        WHEN (g.permit_expiration - CURRENT_DATE) <= 30 THEN 'expiring_30d'
        WHEN (g.permit_expiration - CURRENT_DATE) <= 60 THEN 'expiring_60d'
        WHEN (g.permit_expiration - CURRENT_DATE) <= 90 THEN 'expiring_90d'
        ELSE 'valid'
    END AS permit_status
FROM public.gdos g
JOIN public.clients c ON c.id = g.client_id
LEFT JOIN public.properties p ON p.id = g.property_id
LEFT JOIN public.client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'
LEFT JOIN public.service_configs sc ON sc.client_id = c.id AND sc.service_type = 'GT'
WHERE g.status = 'ACTIVE'
  AND c.status IN ('ACTIVE','RECURRING')
ORDER BY
    CASE
        WHEN g.permit_expiration IS NULL THEN 2
        WHEN g.permit_expiration < CURRENT_DATE THEN 1
        WHEN (g.permit_expiration - CURRENT_DATE) <= 30 THEN 3
        WHEN (g.permit_expiration - CURRENT_DATE) <= 60 THEN 4
        WHEN (g.permit_expiration - CURRENT_DATE) <= 90 THEN 5
        ELSE 6
    END,
    (g.permit_expiration - CURRENT_DATE);

-- ============================================================
-- 5. ops.v_route_today
-- ============================================================
-- Per-visit view. permit_number is shown for context (display only). Use
-- a subquery to pick one ACTIVE permit per client.
CREATE OR REPLACE VIEW ops.v_route_today AS
SELECT
    v.id AS visit_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.visit_status,
    v.service_type,
    (v.visit_status = 'completed') AS is_complete,
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
    -- Phase 4a: source from gdos. If the visit has a property, prefer the
    -- gdo at that property; otherwise fall back to any ACTIVE gdo for the client.
    COALESCE(
        (SELECT g.gdo_number FROM public.gdos g
         WHERE g.property_id = v.property_id AND g.status = 'ACTIVE'
         ORDER BY g.id LIMIT 1),
        (SELECT g.gdo_number FROM public.gdos g
         WHERE g.client_id = c.id AND g.status = 'ACTIVE'
         ORDER BY g.id LIMIT 1)
    ) AS permit_number,
    veh.name AS truck,
    veh.grease_tank_capacity_gallons,
    string_agg(e.full_name, ', ' ORDER BY e.full_name) AS crew,
    v.duration_minutes
FROM public.visits v
JOIN public.clients c ON c.id = v.client_id
LEFT JOIN public.properties vp ON vp.id = v.property_id
LEFT JOIN public.properties pp ON pp.client_id = c.id AND pp.is_primary = true
LEFT JOIN public.client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'
LEFT JOIN public.service_configs sc ON sc.client_id = c.id AND sc.service_type = v.service_type
LEFT JOIN public.vehicles veh ON veh.id = v.vehicle_id
LEFT JOIN public.visit_assignments va ON va.visit_id = v.id
LEFT JOIN public.employees e ON e.id = va.employee_id
WHERE v.visit_date = CURRENT_DATE
  AND v.visit_status IN ('UPCOMING','LATE','completed')
GROUP BY
    v.id, v.visit_date, v.start_at, v.end_at, v.visit_status, v.service_type,
    v.is_gps_confirmed, c.id, c.client_code, c.name,
    vp.zone, vp.address, vp.city, vp.county, vp.latitude, vp.longitude,
    vp.access_hours_start, vp.access_hours_end,
    pp.zone, pp.address, pp.city, pp.county, pp.latitude, pp.longitude,
    pp.access_hours_start, pp.access_hours_end,
    cc.name, cc.phone, sc.equipment_size_gallons, v.property_id,
    veh.name, veh.grease_tank_capacity_gallons, v.duration_minutes
ORDER BY v.start_at, COALESCE(vp.zone, pp.zone), c.name;

-- ============================================================
-- 6. ops.v_service_due
-- ============================================================
-- Same granularity (1 row per (client, GT|CL service_config)). permit_number
-- is display only; subquery picks one ACTIVE permit per client.
CREATE OR REPLACE VIEW ops.v_service_due AS
WITH actual_last_visit AS (
    SELECT client_id, MAX(visit_date) AS last_visit_actual
    FROM public.visits
    WHERE visit_status = 'completed'
    GROUP BY client_id
)
SELECT
    c.id,
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
    -- Phase 4a: source from gdos
    (SELECT g.gdo_number FROM public.gdos g
     WHERE g.client_id = c.id AND g.status = 'ACTIVE'
     ORDER BY g.id LIMIT 1) AS permit_number,
    sc.price_per_visit,
    COALESCE(sc.last_visit, alv.last_visit_actual) AS last_service_date,
    ((COALESCE(sc.last_visit, alv.last_visit_actual) + ((sc.frequency_days || ' days')::interval))::date) AS scheduled_next_visit,
    (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) AS days_since_service,
    CASE
        WHEN COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL THEN 'never_serviced'
        WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90 THEN 'derm_violation'
        WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days THEN 'overdue'
        WHEN ((COALESCE(sc.last_visit, alv.last_visit_actual) + sc.frequency_days) - CURRENT_DATE) <= 14 THEN 'due_soon'
        ELSE 'on_schedule'
    END AS service_status
FROM public.clients c
JOIN public.service_configs sc ON sc.client_id = c.id AND sc.service_type IN ('GT','CL')
LEFT JOIN public.client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'
LEFT JOIN public.properties p ON p.client_id = c.id AND p.is_primary = true
LEFT JOIN actual_last_visit alv ON alv.client_id = c.id
WHERE c.status IN ('ACTIVE','RECURRING')
  AND (
    COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL
    OR (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= (COALESCE(sc.frequency_days, 90) - 14)
  )
ORDER BY
    CASE WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90 THEN 1 ELSE 2 END,
    p.zone,
    CASE
        WHEN COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL THEN 1
        WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days THEN 2
        ELSE 3
    END,
    (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) DESC NULLS LAST;

COMMIT;

-- ============================================================
-- VERIFICATION (run after apply)
-- ============================================================
-- 1. No view still depends on service_configs.permit_* columns:
--    SELECT DISTINCT v.schemaname || '.' || v.viewname AS view_name,
--           (v.definition ILIKE '%sc.permit_%' OR v.definition ILIKE '%sc_gt.permit_%')::int AS legacy_ref
--    FROM pg_views v
--    WHERE v.definition ILIKE '%service_configs%' AND v.definition ILIKE '%permit%'
--    ORDER BY view_name;
--    Expected: all legacy_ref = 0
--
-- 2. ops.v_gdo_expiry returns 3 rows for Casa Neos
--    SELECT permit_number, permit_expiration, permit_status
--    FROM ops.v_gdo_expiry WHERE client_code = '009-CN' ORDER BY permit_number;
--    Expected: 3 rows (GDO-10877, GDO-15062, GDO-16389), all valid
--
-- 3. ops.v_route_today still returns rows for today (smoke test):
--    SELECT COUNT(*) FROM ops.v_route_today;
--
-- 4. ops.v_derm_compliance still returns rows for ACTIVE/RECURRING GT clients
--    SELECT COUNT(*) FROM ops.v_derm_compliance;
--
-- 5. customer.clients sample
--    SELECT name, gdo_permit_url FROM customer.clients WHERE name ILIKE '%Casa Neos%';
