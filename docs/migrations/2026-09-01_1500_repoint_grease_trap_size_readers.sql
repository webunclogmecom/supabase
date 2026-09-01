-- 2026-09-01_1500_repoint_grease_trap_size_readers.sql
--
-- WHAT: repoint the 7 property-facing readers of grease-trap capacity from the legacy
--   public.service_configs.equipment_size_gallons onto the authoritative
--   public.properties.grease_trap_size_gallons (COALESCE, legacy as fallback).
-- WHY: 2026-08-13_0030 moved the store to properties.grease_trap_size_gallons and repointed only
--   client.*; it deliberately left these readers on the legacy column, which drift the first time a
--   capacity is edited in the Client App. Reported live on Wynd 27 (241-WYN): edit -> Calendar shows '-'.
-- HOW: string-surgery on the live pg_get_viewdef output (copy, don't retype). Per-visit/GDO views use
--   the row's own property; per-client views prefer the primary property then any property carrying a
--   value (handles the billing/service property twin, e.g. Wynd 27's service prop 975 = 1500 vs billing
--   prop 890 = null). The three service_configs MIRROR views (ops/client/public.service_configs) are
--   intentionally NOT touched -- they faithfully expose the table column.
-- CREATE OR REPLACE preserves grants (DROP would discard them). No column names/types/order change.

BEGIN;

CREATE OR REPLACE VIEW ops.v_calendar_visit AS
WITH last_completed AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE prev.client_id = v_1.client_id AND prev.service_type = v_1.service_type AND prev.visit_status = 'completed'::text AND prev.deleted_at IS NULL AND prev.visit_date < v_1.visit_date) AS last_completed_date
           FROM visits v_1
        ), prev_live AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE prev.client_id = v_1.client_id AND prev.service_type = v_1.service_type AND (prev.visit_status = ANY (ARRAY['completed'::text, 'scheduled'::text])) AND prev.deleted_at IS NULL AND prev.visit_date < v_1.visit_date) AS prev_live_date
           FROM visits v_1
        ), observed_cadence AS (
         SELECT gaps.client_id,
            gaps.service_type,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (gaps.days_since_prev::double precision))::integer AS median_gap_days
           FROM ( SELECT visits.client_id,
                    visits.service_type,
                    visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.client_id, visits.service_type ORDER BY visits.visit_date) AS days_since_prev
                   FROM visits
                  WHERE visits.deleted_at IS NULL AND visits.visit_status = 'completed'::text AND (visits.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text]))) gaps
          WHERE gaps.days_since_prev >= 5 AND gaps.days_since_prev <= 200
          GROUP BY gaps.client_id, gaps.service_type
        ), observed_price AS (
         SELECT v_1.client_id,
            v_1.service_type,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (li.total_price::double precision))::numeric(12,2) AS median_line_price
           FROM visits v_1
             JOIN line_items li ON li.invoice_id = v_1.invoice_id
          WHERE v_1.deleted_at IS NULL AND v_1.invoice_id IS NOT NULL AND v_1.visit_status = 'completed'::text AND (v_1.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text])) AND li.total_price > 0::numeric
          GROUP BY v_1.client_id, v_1.service_type
        ), observed_job_cadence AS (
         SELECT gaps.job_id,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (gaps.days_since_prev::double precision))::integer AS median_gap_days
           FROM ( SELECT visits.job_id,
                    visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.job_id ORDER BY visits.visit_date) AS days_since_prev
                   FROM visits
                  WHERE visits.deleted_at IS NULL AND visits.visit_status = 'completed'::text AND (visits.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text]))) gaps
          WHERE gaps.days_since_prev >= 5 AND gaps.days_since_prev <= 200
          GROUP BY gaps.job_id
        )
 SELECT v.id,
    v.public_id,
    v.client_id,
    v.property_id,
    effv.vehicle_id,
    v.job_id,
    v.visit_date,
    v.visit_status,
    v.service_type,
    v.start_at,
    v.end_at,
    v.completed_at,
    COALESCE(v.duration_minutes, (EXTRACT(epoch FROM v.end_at - v.start_at) / 60::numeric)::integer) AS duration_minutes,
    v.title,
    v.derm_required,
    v.is_gps_confirmed,
    v.manhole_count,
    v.ticket_number,
    v.created_at AS visit_created_at,
    v.updated_at AS visit_updated_at,
    COALESCE(NULLIF(( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE li.visit_id = v.id), 0::numeric),
        CASE
            WHEN v.invoice_id IS NOT NULL AND (( SELECT count(*) AS count
               FROM visits v2
              WHERE v2.invoice_id = v.invoice_id AND v2.deleted_at IS NULL)) = 1 THEN ( SELECT sum(li.total_price) AS sum
               FROM line_items li
              WHERE li.invoice_id = v.invoice_id)
            ELSE NULL::numeric
        END, ( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL), ( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE li.visit_id = v.id))::numeric(12,2) AS amount,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    c.group_id AS client_group_id,
    COALESCE(pz.code, ppz.code) AS zone,
    COALESCE(prop.address, primary_prop.address) AS address,
    COALESCE(prop.city, primary_prop.city) AS city,
    COALESCE(prop.state, primary_prop.state) AS state,
    COALESCE(prop.zip, primary_prop.zip) AS zip,
    COALESCE(prop.county, primary_prop.county) AS county,
    COALESCE(fn_sched_open(prop.access_schedule), fn_sched_open(primary_prop.access_schedule)) AS access_hours_start,
    COALESCE(fn_sched_close(prop.access_schedule), fn_sched_close(primary_prop.access_schedule)) AS access_hours_end,
    COALESCE(fn_sched_days(prop.access_schedule), fn_sched_days(primary_prop.access_schedule)) AS access_days,
    COALESCE(prop.latitude, primary_prop.latitude) AS latitude,
    COALESCE(prop.longitude, primary_prop.longitude) AS longitude,
    COALESCE(prop.grease_trap_manhole_count, primary_prop.grease_trap_manhole_count) AS manholes,
        CASE
            WHEN c.client_code ~~ '000-%'::text THEN NULLIF(jb.frequency_days, 0)
            ELSE COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days)
        END AS frequency_days,
    COALESCE(prop.grease_trap_size_gallons, primary_prop.grease_trap_size_gallons, sc.equipment_size_gallons) AS equipment_size_gallons,
    sc.first_visit AS sc_first_visit,
    sc.last_visit AS sc_last_visit,
    sc.stop_date AS sc_stop_date,
    sc.material_type,
    g.gdo_number,
    g.permit_expiration AS gdo_expiration,
    g.max_frequency_days AS gdo_max_frequency_days,
    g.permit_document_path AS gdo_document_path,
    g.status AS gdo_status,
    veh.name AS truck_name,
    veh.status AS vehicle_status,
    veh.grease_tank_capacity_gallons,
    veh.fuel_tank_capacity_gallons,
    COALESCE(emp.id, asg.id) AS driver_id,
    COALESCE(emp.full_name, asg.full_name) AS driver_name,
    COALESCE(emp.role, asg.role) AS driver_role,
        CASE
            WHEN v.visit_status = 'skipped'::text THEN NULL::text
            WHEN v.visit_status = 'completed'::text THEN NULL::text
            WHEN pl.prev_live_date IS NULL THEN NULL::text
            WHEN COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days) IS NULL THEN NULL::text
            WHEN (pl.prev_live_date + COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days)::double precision * '1 day'::interval)::date < CURRENT_DATE THEN 'late'::text
            WHEN (pl.prev_live_date + COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days)::double precision * '1 day'::interval)::date < v.visit_date THEN 'will_be_late'::text
            ELSE 'on_time'::text
        END AS late_status,
    lc.last_completed_date,
    v.assigned_driver_id,
    asg.full_name AS assigned_driver_name,
    COALESCE(sc.price_per_visit, op.median_line_price) AS amount_estimated,
    v.start_at IS NULL OR (v.start_at AT TIME ZONE 'America/New_York'::text)::time without time zone = '00:00:00'::time without time zone AND v.end_at IS NOT NULL AND (v.end_at - v.start_at) >= '23:00:00'::interval AS is_all_day,
        CASE
            WHEN c.client_code ~~ '000-%'::text THEN 'SC'::text
            WHEN NULLIF(jb.frequency_days, 0) > 0 THEN 'SA'::text
            WHEN lower(jb.title) ~~ '%service call%'::text OR lower(jb.title) ~~ '%emergency%'::text THEN 'SC'::text
            WHEN ojc.median_gap_days > 0 OR lower(jb.title) ~~ '%grease%'::text OR lower(jb.title) ~~ '%grey water%'::text OR lower(jb.title) ~~ '%service agreement%'::text THEN 'SA'::text
            ELSE 'SC'::text
        END AS service_kind,
    v.notes,
    v.sync_state,
    v.skip_reason,
    sagrp.sa_group,
        CASE
            WHEN c.client_code ~~ '000-%'::text THEN NULL::date
            WHEN pl.prev_live_date IS NULL THEN NULL::date
            WHEN COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days) IS NULL THEN NULL::date
            ELSE (pl.prev_live_date + COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days)::double precision * '1 day'::interval)::date
        END AS expected_date,
        CASE
            WHEN emp.id IS NOT NULL THEN emp.color_hex
            ELSE asg.color_hex
        END AS driver_color,
    COALESCE(( SELECT (array_agg(sli.service_type ORDER BY (NOT sli.schedulable), sli.code) FILTER (WHERE sli.service_type IS NOT NULL))[1] AS array_agg
           FROM line_items li
             JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text)
          WHERE li.visit_id = v.id), ( SELECT (array_agg(sli.service_type ORDER BY (NOT sli.schedulable), sli.code) FILTER (WHERE sli.service_type IS NOT NULL))[1] AS array_agg
           FROM line_items li
             JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text)
          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL),
        CASE
            WHEN v.derm_required IS TRUE THEN 'Pumping'::text
            ELSE NULL::text
        END) AS service_label,
    v.vehicle_id AS assigned_vehicle_id,
        CASE
            WHEN v.vehicle_id IS NOT NULL THEN 'assigned'::text
            WHEN effv.vehicle_id IS NOT NULL THEN 'default'::text
            ELSE 'none'::text
        END AS vehicle_source,
    COALESCE(pz.color_hex, ppz.color_hex) AS zone_color
   FROM visits v
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN properties prop ON prop.id = v.property_id
     LEFT JOIN properties primary_prop ON primary_prop.client_id = v.client_id AND primary_prop.is_primary = true
     LEFT JOIN zones pz ON pz.id = prop.zone_id
     LEFT JOIN zones ppz ON ppz.id = primary_prop.zone_id
     LEFT JOIN service_configs sc ON sc.client_id = v.client_id AND sc.service_type = v.service_type
     LEFT JOIN LATERAL ( SELECT fn_resolve_gdo_id(v.client_id, v.property_id, v.id) AS gdo_id) r ON true
     LEFT JOIN gdos g ON g.id = r.gdo_id
     LEFT JOIN LATERAL ( SELECT COALESCE(v.vehicle_id, ( SELECT min(sli.default_vehicle_id) AS min
                   FROM line_items li2
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li2.visit_id = v.id), ( SELECT min(sli.default_vehicle_id) AS min
                   FROM line_items li2
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li2.job_id = v.job_id AND li2.visit_id IS NULL AND li2.invoice_id IS NULL)) AS vehicle_id) effv ON true
     LEFT JOIN vehicles veh ON veh.id = effv.vehicle_id
     LEFT JOIN LATERAL ( SELECT COALESCE(( SELECT min(e.id) AS min
                   FROM visit_assignments va
                     JOIN employees e ON e.id = va.employee_id
                  WHERE va.visit_id = v.id AND e.status = 'ACTIVE'::text), ( SELECT min(va.employee_id) AS min
                   FROM visit_assignments va
                  WHERE va.visit_id = v.id), ( SELECT e.id
                   FROM inspections i
                     JOIN employees e ON e.id = i.employee_id
                  WHERE i.vehicle_id = v.vehicle_id AND i.shift_date >= (v.visit_date - 1) AND i.shift_date <= (v.visit_date + 1)
                  ORDER BY (i.shift_date = v.visit_date) DESC, (e.status = 'ACTIVE'::text) DESC, (abs(i.shift_date - v.visit_date)), e.id
                 LIMIT 1)) AS employee_id) fa ON true
     LEFT JOIN employees emp ON emp.id = fa.employee_id
     LEFT JOIN employees asg ON asg.id = v.assigned_driver_id
     LEFT JOIN last_completed lc ON lc.visit_id = v.id
     LEFT JOIN prev_live pl ON pl.visit_id = v.id
     LEFT JOIN observed_cadence oc ON oc.client_id = v.client_id AND oc.service_type = v.service_type
     LEFT JOIN observed_price op ON op.client_id = v.client_id AND op.service_type = v.service_type
     LEFT JOIN jobs jb ON jb.id = v.job_id
     LEFT JOIN observed_job_cadence ojc ON ojc.job_id = v.job_id
     LEFT JOIN LATERAL ( SELECT COALESCE(( SELECT (array_agg(ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) ORDER BY sli.code) FILTER (WHERE ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) IS NOT NULL))[1] AS grp
                   FROM line_items li3
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li3.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li3.visit_id = v.id AND sli.schedulable = true), ( SELECT (array_agg(ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) ORDER BY sli.code) FILTER (WHERE ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) IS NOT NULL))[1] AS grp
                   FROM line_items li3
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li3.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li3.job_id = v.job_id AND li3.visit_id IS NULL AND li3.invoice_id IS NULL AND sli.schedulable = true)) AS sa_group) sagrp ON true
  WHERE v.deleted_at IS NULL;;

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
    COALESCE(vp_z.code, pp_z.code) AS zone,
    COALESCE(vp.address, pp.address) AS address,
    COALESCE(vp.city, pp.city) AS city,
    COALESCE(vp.county, pp.county) AS county,
    COALESCE(vp.latitude, pp.latitude) AS latitude,
    COALESCE(vp.longitude, pp.longitude) AS longitude,
    COALESCE(fn_sched_open(vp.access_schedule), fn_sched_open(pp.access_schedule)) AS access_hours_start,
    COALESCE(fn_sched_close(vp.access_schedule), fn_sched_close(pp.access_schedule)) AS access_hours_end,
    cc.name AS contact_name,
    cc.phone AS contact_phone,
    COALESCE(vp.grease_trap_size_gallons, pp.grease_trap_size_gallons, sc.equipment_size_gallons) AS equipment_size_gallons,
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
     LEFT JOIN zones vp_z ON vp_z.id = vp.zone_id
     LEFT JOIN zones pp_z ON pp_z.id = pp.zone_id
  WHERE v.visit_date = CURRENT_DATE AND (v.visit_status = ANY (ARRAY['UPCOMING'::text, 'LATE'::text, 'completed'::text]))
  GROUP BY v.id, v.visit_date, v.start_at, v.end_at, v.visit_status, v.service_type, v.is_gps_confirmed, c.id, c.client_code, c.name, vp_z.code, vp.address, vp.city, vp.county, vp.latitude, vp.longitude, vp.access_schedule, pp_z.code, pp.address, pp.city, pp.county, pp.latitude, pp.longitude, pp.access_schedule, cc.name, cc.phone, vp.grease_trap_size_gallons, pp.grease_trap_size_gallons, sc.equipment_size_gallons, v.property_id, veh.name, veh.grease_tank_capacity_gallons, v.duration_minutes
  ORDER BY v.start_at, (COALESCE(vp_z.code, pp_z.code)), c.name;;

CREATE OR REPLACE VIEW ops.v_gdo_expiry AS
SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p_z.code AS zone,
    p.address,
    p.city,
    p.county,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    'Pumping'::text AS service_type,
    g.gdo_number AS permit_number,
    g.permit_expiration,
    COALESCE(p.grease_trap_size_gallons, ( SELECT ps.grease_trap_size_gallons FROM properties ps WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL ORDER BY ps.is_primary DESC, ps.id LIMIT 1), sc.equipment_size_gallons) AS equipment_size_gallons,
    sc.frequency_days,
    g.permit_expiration - CURRENT_DATE AS days_until_expiry,
        CASE
            WHEN g.permit_expiration IS NULL THEN 'no_permit'::text
            WHEN g.permit_expiration < CURRENT_DATE THEN 'expired'::text
            WHEN (g.permit_expiration - CURRENT_DATE) <= 30 THEN 'expiring_30d'::text
            WHEN (g.permit_expiration - CURRENT_DATE) <= 60 THEN 'expiring_60d'::text
            WHEN (g.permit_expiration - CURRENT_DATE) <= 90 THEN 'expiring_90d'::text
            ELSE 'valid'::text
        END AS permit_status
   FROM gdos g
     JOIN clients c ON c.id = g.client_id
     LEFT JOIN properties p ON p.id = g.property_id
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = 'Pumping'::text
     LEFT JOIN zones p_z ON p_z.id = p.zone_id
  WHERE g.status = 'ACTIVE'::text AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]))
  ORDER BY (
        CASE
            WHEN g.permit_expiration IS NULL THEN 2
            WHEN g.permit_expiration < CURRENT_DATE THEN 1
            WHEN (g.permit_expiration - CURRENT_DATE) <= 30 THEN 3
            WHEN (g.permit_expiration - CURRENT_DATE) <= 60 THEN 4
            WHEN (g.permit_expiration - CURRENT_DATE) <= 90 THEN 5
            ELSE 6
        END), (g.permit_expiration - CURRENT_DATE);;

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
    p_z.code AS zone,
    p.address,
    p.city,
    p.county,
    fn_sched_open(p.access_schedule) AS access_hours_start,
    fn_sched_close(p.access_schedule) AS access_hours_end,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    sc.service_type,
    sc.frequency_days,
    COALESCE(p.grease_trap_size_gallons, ( SELECT ps.grease_trap_size_gallons FROM properties ps WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL ORDER BY ps.is_primary DESC, ps.id LIMIT 1), sc.equipment_size_gallons) AS equipment_size_gallons,
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
     JOIN service_configs sc ON sc.client_id = c.id AND (sc.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text]))
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN actual_last_visit alv ON alv.client_id = c.id
     LEFT JOIN zones p_z ON p_z.id = p.zone_id
  WHERE (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AND (COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL OR (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= (COALESCE(sc.frequency_days, 90) - 14))
  ORDER BY (
        CASE
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90 THEN 1
            ELSE 2
        END), p_z.code, (
        CASE
            WHEN COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL THEN 1
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days THEN 2
            ELSE 3
        END), (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) DESC NULLS LAST;;

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
          WHERE (v.derm_required IS NULL OR v.derm_required = true) AND v.visit_status = 'completed'::text AND v.deleted_at IS NULL AND v.visit_date >= (CURRENT_DATE - '120 days'::interval) AND NOT (EXISTS ( SELECT 1
                   FROM derm_manifests dm
                  WHERE dm.client_id = v.client_id AND dm.service_date = v.visit_date))
          GROUP BY v.client_id
        )
 SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p_z.code AS zone,
    p.address,
    p.city,
    p.county,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    ( SELECT g.gdo_number
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_number,
    ( SELECT g.permit_expiration
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_expiration,
    COALESCE(p.grease_trap_size_gallons, ( SELECT ps.grease_trap_size_gallons FROM properties ps WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL ORDER BY ps.is_primary DESC, ps.id LIMIT 1), sc.equipment_size_gallons) AS equipment_size_gallons,
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
     JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = 'Pumping'::text
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN last_manifest lm ON lm.client_id = c.id
     LEFT JOIN unmatched_visits uv ON uv.client_id = c.id
     LEFT JOIN zones p_z ON p_z.id = p.zone_id
  WHERE c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])
  ORDER BY (
        CASE
            WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 1
            WHEN lm.last_manifest_date IS NULL THEN 2
            WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 3
            WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 4
            ELSE 5
        END), (COALESCE(uv.missing_manifests, 0::bigint)) DESC, (CURRENT_DATE - lm.last_manifest_date) DESC NULLS LAST;;

CREATE OR REPLACE VIEW customer.clients AS
SELECT customer.uuid_from_bigint(c.id) AS id,
    lower(c.client_code) AS slug,
    c.name,
    c.client_code,
    cg.name AS group_name,
    p.address AS address1,
    NULLIF(TRIM(BOTH ' ,'::text FROM concat_ws(', '::text, NULLIF(p.city, ''::text), NULLIF(concat_ws(' '::text, NULLIF(p.state, ''::text), NULLIF(p.zip, ''::text)), ''::text))), ''::text) AS address2,
        CASE
            WHEN COALESCE(p.grease_trap_size_gallons, ( SELECT ps.grease_trap_size_gallons FROM properties ps WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL ORDER BY ps.is_primary DESC, ps.id LIMIT 1), sc_gt.equipment_size_gallons) IS NOT NULL THEN COALESCE(p.grease_trap_size_gallons, ( SELECT ps.grease_trap_size_gallons FROM properties ps WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL ORDER BY ps.is_primary DESC, ps.id LIMIT 1), sc_gt.equipment_size_gallons)::text || ' gal grease trap'::text
            ELSE NULL::text
        END AS container_type,
        CASE
            WHEN COALESCE(p.grease_trap_size_gallons, ( SELECT ps.grease_trap_size_gallons FROM properties ps WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL ORDER BY ps.is_primary DESC, ps.id LIMIT 1), sc_gt.equipment_size_gallons) IS NOT NULL THEN COALESCE(p.grease_trap_size_gallons, ( SELECT ps.grease_trap_size_gallons FROM properties ps WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL ORDER BY ps.is_primary DESC, ps.id LIMIT 1), sc_gt.equipment_size_gallons)::text || ' gal'::text
            ELSE NULL::text
        END AS trap_capacity,
    sc_gt.material_type AS material,
    df.name AS disposal_facility,
    ( SELECT g.permit_document_path
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS gdo_permit_url,
    p.access_notes,
    c.created_at,
    c.status,
    c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]) AS is_active,
    ( SELECT max(j.frequency_days) AS max
           FROM jobs j
          WHERE j.client_id = c.id AND j.title ~~* '%Service Agreement%'::text AND j.job_status <> 'archived'::text AND j.frequency_days > 0) AS service_frequency_days
   FROM clients c
     LEFT JOIN client_groups cg ON cg.id = c.group_id
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true AND p.deleted_at IS NULL
     LEFT JOIN service_configs sc_gt ON sc_gt.client_id = c.id AND sc_gt.service_type = 'Pumping'::text
     LEFT JOIN disposal_facilities df ON df.id = p.default_disposal_facility_id;;

CREATE OR REPLACE VIEW public.client_services_flat AS
SELECT c.id,
    c.name,
    c.client_code,
    p.address,
    p.city,
    p_z.code AS zone,
    c.status,
    max(
        CASE
            WHEN s.service_type = 'Pumping'::text THEN COALESCE(p.grease_trap_size_gallons, ( SELECT ps.grease_trap_size_gallons FROM properties ps WHERE ps.client_id = c.id AND ps.grease_trap_size_gallons IS NOT NULL ORDER BY ps.is_primary DESC, ps.id LIMIT 1), s.equipment_size_gallons)
            ELSE NULL::numeric
        END) AS gt_size_gallons,
    max(
        CASE
            WHEN s.service_type = 'Pumping'::text THEN s.frequency_days
            ELSE NULL::integer
        END) AS gt_frequency_days,
    max(
        CASE
            WHEN s.service_type = 'Pumping'::text THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS gt_price_per_visit,
    max(
        CASE
            WHEN s.service_type = 'Pumping'::text THEN s.last_visit
            ELSE NULL::date
        END) AS gt_last_visit,
    max(
        CASE
            WHEN s.service_type = 'Pumping'::text THEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date
            ELSE NULL::date
        END) AS gt_next_visit,
    max(
        CASE
            WHEN s.service_type = 'Pumping'::text THEN
            CASE
                WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date < CURRENT_DATE THEN 'OVERDUE'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date <= (CURRENT_DATE + 14) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS gt_status,
    max(
        CASE
            WHEN s.service_type = 'Cleaning'::text THEN s.frequency_days
            ELSE NULL::integer
        END) AS cl_frequency_days,
    max(
        CASE
            WHEN s.service_type = 'Cleaning'::text THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS cl_price_per_visit,
    max(
        CASE
            WHEN s.service_type = 'Cleaning'::text THEN s.last_visit
            ELSE NULL::date
        END) AS cl_last_visit,
    max(
        CASE
            WHEN s.service_type = 'Cleaning'::text THEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date
            ELSE NULL::date
        END) AS cl_next_visit,
    max(
        CASE
            WHEN s.service_type = 'Cleaning'::text THEN
            CASE
                WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date < CURRENT_DATE THEN 'OVERDUE'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date <= (CURRENT_DATE + 14) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS cl_status,
    max(
        CASE
            WHEN s.service_type = 'Warranty of Drainage'::text THEN s.frequency_days
            ELSE NULL::integer
        END) AS wd_frequency_days,
    max(
        CASE
            WHEN s.service_type = 'Warranty of Drainage'::text THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS wd_price_per_visit,
    max(
        CASE
            WHEN s.service_type = 'Warranty of Drainage'::text THEN s.last_visit
            ELSE NULL::date
        END) AS wd_last_visit,
    max(
        CASE
            WHEN s.service_type = 'Warranty of Drainage'::text THEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date
            ELSE NULL::date
        END) AS wd_next_visit,
    max(
        CASE
            WHEN s.service_type = 'Warranty of Drainage'::text THEN
            CASE
                WHEN s.last_visit IS NULL OR s.frequency_days IS NULL THEN 'UNKNOWN'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date < CURRENT_DATE THEN 'OVERDUE'::text
                WHEN (s.last_visit + ((s.frequency_days || ' days'::text)::interval))::date <= (CURRENT_DATE + 14) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS wd_status,
    max(nve.nve) AS next_visit_expected
   FROM clients c
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN service_configs s ON s.client_id = c.id
     LEFT JOIN zones p_z ON p_z.id = p.zone_id
     LEFT JOIN ( SELECT v_calendar_visit.client_id,
            min(v_calendar_visit.expected_date) AS nve
           FROM ops.v_calendar_visit
          WHERE v_calendar_visit.visit_status = 'scheduled'::text AND v_calendar_visit.visit_date >= CURRENT_DATE AND v_calendar_visit.expected_date IS NOT NULL
          GROUP BY v_calendar_visit.client_id) nve ON nve.client_id = c.id
  GROUP BY c.id, p.address, p.city, p_z.code;;

NOTIFY pgrst, 'reload schema';

-- assertion: Wynd 27 (client 477, service property 975 = 1500) now reads 1500 on the Calendar,
-- and the legacy fallback still resolves for a legacy-only property.
DO $$
DECLARE v int;
BEGIN
  SELECT equipment_size_gallons INTO v FROM ops.v_calendar_visit WHERE client_id = 477 AND equipment_size_gallons IS NOT NULL LIMIT 1;
  IF v IS DISTINCT FROM 1500 THEN RAISE EXCEPTION 'Wynd 27 calendar capacity is % (expected 1500)', v; END IF;
  RAISE NOTICE 'OK: Wynd 27 calendar reads 1500';
END $$;

COMMIT;
