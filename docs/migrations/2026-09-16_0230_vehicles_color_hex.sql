-- 2026-09-16_0230_vehicles_color_hex.sql
-- A truck's identity colour, canonical in the DB, the same way a person's is (employees.color_hex).
--
-- WHY (Fred, 2026-09-16): "make Cloggy also have a color, and like the others it should be consistent
-- across all apps." His 2026-08-28 words already asked for "set colors for the Team members and the
-- trucks across all the apps"; the people half shipped that day (2026-08-28_1027 / _1210) and the
-- trucks were deliberately left colourless (Building Apps/CLAUDE.md 4b, Visit Calendar CLAUDE.md 3).
-- This is the truck half, done the same way: one column, exposed through the Calendar views, read by
-- every app; never hardcoded app-side, never hashed from the name.
--
-- COLOURS: chosen by CIE Lab distance against the nine employee colours, the lateness rails
-- (#EF4444, #FACC15), the brand orange (#F14714) and the old slate badge (#334155), maximising the
-- minimum separation (37.3 dE; the two closest PEOPLE are 26.3 apart):
--   1 Moises -> #1E40AF (navy)   2 Cloggy -> #881337 (wine)   3 David -> #92400E (rust)
--   4 Goliath (INACTIVE) stays NULL.
-- The Calendar's truck badge keeps encoding PROVENANCE by fill vs stroke (solid = assigned, dashed =
-- service default); the hue is added on top. Circle = person, square = truck, unchanged.
--
-- VIEWS: ops.v_calendar_truck gains color_hex (last column); ops.v_calendar_visit gains truck_color
-- (last column, veh.color_hex through the existing vehicles join). Both CREATE OR REPLACE with the
-- column appended, grants untouched. The visit view body below is the live definition (md5
-- 5fd95820c913ee1a124564734d7712b5 before) with ONE line added; VERIFY compares the old 72 columns row
-- by row in both directions (CREATE OR REPLACE VIEW checks types, not expressions).
--
-- AUDIT (ADR 010): the UPDATE on vehicles is real business data, the audit trigger fires (intended).
-- REVERSIBLE: re-run the previous definitions (backups/2026-09-16_v_calendar_visit_before_truck_color.sql
-- is written by the session before applying), ALTER TABLE public.vehicles DROP COLUMN color_hex.
-- Supabase session note: v_calendar_visit was last replaced by 2026-09-15_1100 (destroyed jobs); this
-- file starts from THAT definition as read from pg_get_viewdef on 2026-09-16 02:30 ET.

-- REPEATABLE READ so the VERIFY snapshot and the post-replace read see the same data: at READ COMMITTED the
-- first attempt (02:31 ET) reported before-only 1 / after-only 4 with an unchanged row count, which is the
-- Jobber polls writing visits between the two statements, not a definition change. It also pins now().
BEGIN ISOLATION LEVEL REPEATABLE READ;

-- PRE 1: the view bodies are the ones this file was spliced from.
DO $$ BEGIN
  IF md5(pg_get_viewdef('ops.v_calendar_visit'::regclass, true)) <> '5fd95820c913ee1a124564734d7712b5' THEN
    RAISE EXCEPTION 'ops.v_calendar_visit changed since this migration was written; re-splice from the live definition';
  END IF;
  IF (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'v_calendar_visit') <> 72 THEN
    RAISE EXCEPTION 'ops.v_calendar_visit does not have 72 columns';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vehicles' AND column_name = 'color_hex') THEN
    RAISE EXCEPTION 'public.vehicles.color_hex already exists';
  END IF;
END $$;

-- PRE 2: the three trucks are the ones expected.
DO $$ BEGIN
  IF (SELECT string_agg(id || ':' || name, ',' ORDER BY id) FROM public.vehicles WHERE status = 'ACTIVE') <> '1:Moises,2:Cloggy,3:David' THEN
    RAISE EXCEPTION 'active vehicles are not 1 Moises, 2 Cloggy, 3 David';
  END IF;
END $$;

-- snapshot for VERIFY
CREATE TEMP TABLE vcv_before ON COMMIT DROP AS SELECT id, public_id, client_id, property_id, vehicle_id, job_id, visit_date, visit_status, service_type, start_at, end_at, completed_at, duration_minutes, title, derm_required, is_gps_confirmed, manhole_count, ticket_number, visit_created_at, visit_updated_at, amount, client_code, client_name, client_status, client_group_id, zone, address, city, state, zip, county, access_hours_start, access_hours_end, access_days, latitude, longitude, manholes, frequency_days, equipment_size_gallons, sc_first_visit, sc_last_visit, sc_stop_date, material_type, gdo_number, gdo_expiration, gdo_max_frequency_days, gdo_document_path, gdo_status, truck_name, vehicle_status, grease_tank_capacity_gallons, fuel_tank_capacity_gallons, driver_id, driver_name, driver_role, late_status, last_completed_date, assigned_driver_id, assigned_driver_name, amount_estimated, is_all_day, service_kind, notes, sync_state, skip_reason, sa_group, expected_date, driver_color, service_label, assigned_vehicle_id, vehicle_source, zone_color FROM ops.v_calendar_visit;

-- 1. the column, same shape as employees.color_hex
ALTER TABLE public.vehicles ADD COLUMN color_hex text;
ALTER TABLE public.vehicles ADD CONSTRAINT vehicles_color_hex_chk CHECK (color_hex IS NULL OR color_hex ~ '^#[0-9A-Fa-f]{6}$');
COMMENT ON COLUMN public.vehicles.color_hex IS 'Canonical per-truck identity colour (hex). Shared cross-app so a truck is the same colour everywhere (Building Apps/CLAUDE.md 4b). NULL = no colour, apps fall back to neutral slate. Set 2026-09-16 by Lab-distance separation from employees.color_hex.';

-- 2. the values
UPDATE public.vehicles SET color_hex = v.hex
FROM (VALUES (1, '#1E40AF'), (2, '#881337'), (3, '#92400E')) AS v(id, hex)
WHERE public.vehicles.id = v.id;

-- 3. ops.v_calendar_truck: color_hex appended
CREATE OR REPLACE VIEW ops.v_calendar_truck AS
 SELECT id, name, status, make, model, year, grease_tank_capacity_gallons, fuel_tank_capacity_gallons,
        license_plate, decal_number, notes, created_at, updated_at, color_hex
   FROM vehicles
  ORDER BY (CASE status WHEN 'ACTIVE'::text THEN 0 ELSE 1 END), name;

-- 4. ops.v_calendar_visit: truck_color appended (live definition + one line)
CREATE OR REPLACE VIEW ops.v_calendar_visit AS WITH last_completed AS (
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
    COALESCE(prop.grease_trap_size_gallons::numeric, primary_prop.grease_trap_size_gallons::numeric, sc.equipment_size_gallons) AS equipment_size_gallons,
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
    COALESCE(pz.color_hex, ppz.color_hex) AS zone_color,
    veh.color_hex AS truck_color
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

-- VERIFY 1: the old 72 columns are row-for-row identical in both directions.
DO $$
DECLARE n_a bigint; n_b bigint; n_before bigint; n_after bigint;
BEGIN
  SELECT count(*) INTO n_a FROM (SELECT id, public_id, client_id, property_id, vehicle_id, job_id, visit_date, visit_status, service_type, start_at, end_at, completed_at, duration_minutes, title, derm_required, is_gps_confirmed, manhole_count, ticket_number, visit_created_at, visit_updated_at, amount, client_code, client_name, client_status, client_group_id, zone, address, city, state, zip, county, access_hours_start, access_hours_end, access_days, latitude, longitude, manholes, frequency_days, equipment_size_gallons, sc_first_visit, sc_last_visit, sc_stop_date, material_type, gdo_number, gdo_expiration, gdo_max_frequency_days, gdo_document_path, gdo_status, truck_name, vehicle_status, grease_tank_capacity_gallons, fuel_tank_capacity_gallons, driver_id, driver_name, driver_role, late_status, last_completed_date, assigned_driver_id, assigned_driver_name, amount_estimated, is_all_day, service_kind, notes, sync_state, skip_reason, sa_group, expected_date, driver_color, service_label, assigned_vehicle_id, vehicle_source, zone_color FROM vcv_before EXCEPT ALL SELECT id, public_id, client_id, property_id, vehicle_id, job_id, visit_date, visit_status, service_type, start_at, end_at, completed_at, duration_minutes, title, derm_required, is_gps_confirmed, manhole_count, ticket_number, visit_created_at, visit_updated_at, amount, client_code, client_name, client_status, client_group_id, zone, address, city, state, zip, county, access_hours_start, access_hours_end, access_days, latitude, longitude, manholes, frequency_days, equipment_size_gallons, sc_first_visit, sc_last_visit, sc_stop_date, material_type, gdo_number, gdo_expiration, gdo_max_frequency_days, gdo_document_path, gdo_status, truck_name, vehicle_status, grease_tank_capacity_gallons, fuel_tank_capacity_gallons, driver_id, driver_name, driver_role, late_status, last_completed_date, assigned_driver_id, assigned_driver_name, amount_estimated, is_all_day, service_kind, notes, sync_state, skip_reason, sa_group, expected_date, driver_color, service_label, assigned_vehicle_id, vehicle_source, zone_color FROM ops.v_calendar_visit) d;
  SELECT count(*) INTO n_b FROM (SELECT id, public_id, client_id, property_id, vehicle_id, job_id, visit_date, visit_status, service_type, start_at, end_at, completed_at, duration_minutes, title, derm_required, is_gps_confirmed, manhole_count, ticket_number, visit_created_at, visit_updated_at, amount, client_code, client_name, client_status, client_group_id, zone, address, city, state, zip, county, access_hours_start, access_hours_end, access_days, latitude, longitude, manholes, frequency_days, equipment_size_gallons, sc_first_visit, sc_last_visit, sc_stop_date, material_type, gdo_number, gdo_expiration, gdo_max_frequency_days, gdo_document_path, gdo_status, truck_name, vehicle_status, grease_tank_capacity_gallons, fuel_tank_capacity_gallons, driver_id, driver_name, driver_role, late_status, last_completed_date, assigned_driver_id, assigned_driver_name, amount_estimated, is_all_day, service_kind, notes, sync_state, skip_reason, sa_group, expected_date, driver_color, service_label, assigned_vehicle_id, vehicle_source, zone_color FROM ops.v_calendar_visit EXCEPT ALL SELECT id, public_id, client_id, property_id, vehicle_id, job_id, visit_date, visit_status, service_type, start_at, end_at, completed_at, duration_minutes, title, derm_required, is_gps_confirmed, manhole_count, ticket_number, visit_created_at, visit_updated_at, amount, client_code, client_name, client_status, client_group_id, zone, address, city, state, zip, county, access_hours_start, access_hours_end, access_days, latitude, longitude, manholes, frequency_days, equipment_size_gallons, sc_first_visit, sc_last_visit, sc_stop_date, material_type, gdo_number, gdo_expiration, gdo_max_frequency_days, gdo_document_path, gdo_status, truck_name, vehicle_status, grease_tank_capacity_gallons, fuel_tank_capacity_gallons, driver_id, driver_name, driver_role, late_status, last_completed_date, assigned_driver_id, assigned_driver_name, amount_estimated, is_all_day, service_kind, notes, sync_state, skip_reason, sa_group, expected_date, driver_color, service_label, assigned_vehicle_id, vehicle_source, zone_color FROM vcv_before) d;
  SELECT count(*) INTO n_before FROM vcv_before;
  SELECT count(*) INTO n_after FROM ops.v_calendar_visit;
  IF n_a <> 0 OR n_b <> 0 OR n_before <> n_after THEN
    RAISE EXCEPTION 'v_calendar_visit old columns changed: before-only %, after-only %, rows % -> %', n_a, n_b, n_before, n_after;
  END IF;
END $$;

-- VERIFY 2: the new column carries the colours through the existing join, exactly as truck_name does.
DO $$
DECLARE bad bigint; coloured bigint; cnt_truck bigint;
BEGIN
  SELECT count(*) INTO bad FROM ops.v_calendar_visit x
   WHERE (x.truck_name = 'Moises' AND x.truck_color IS DISTINCT FROM '#1E40AF')
      OR (x.truck_name = 'Cloggy' AND x.truck_color IS DISTINCT FROM '#881337')
      OR (x.truck_name = 'David'  AND x.truck_color IS DISTINCT FROM '#92400E')
      OR (x.truck_name IS NULL AND x.truck_color IS NOT NULL);
  SELECT count(*) INTO coloured FROM ops.v_calendar_visit WHERE truck_color IS NOT NULL;
  SELECT count(*) INTO cnt_truck FROM ops.v_calendar_truck WHERE color_hex IS NOT NULL;
  IF bad <> 0 OR coloured = 0 OR cnt_truck <> 3 THEN
    RAISE EXCEPTION 'truck_color mismatch: bad %, coloured visits %, coloured trucks %', bad, coloured, cnt_truck;
  END IF;
  IF (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'v_calendar_visit') <> 73
     OR (SELECT column_name FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'v_calendar_visit' AND ordinal_position = 73) <> 'truck_color'
     OR (SELECT column_name FROM information_schema.columns WHERE table_schema = 'ops' AND table_name = 'v_calendar_truck' AND ordinal_position = 14) <> 'color_hex' THEN
    RAISE EXCEPTION 'appended columns are not where expected';
  END IF;
END $$;

-- VERIFY 3: grants survived CREATE OR REPLACE (authenticated + service_role + yannick_readonly SELECT on both).
DO $$ BEGIN
  IF (SELECT count(*) FROM information_schema.role_table_grants WHERE table_schema = 'ops' AND table_name = 'v_calendar_visit' AND privilege_type = 'SELECT' AND grantee IN ('authenticated','service_role','yannick_readonly')) <> 3
     OR (SELECT count(*) FROM information_schema.role_table_grants WHERE table_schema = 'ops' AND table_name = 'v_calendar_truck' AND privilege_type = 'SELECT' AND grantee IN ('authenticated','service_role','yannick_readonly')) <> 3 THEN
    RAISE EXCEPTION 'grants changed on the views';
  END IF;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
