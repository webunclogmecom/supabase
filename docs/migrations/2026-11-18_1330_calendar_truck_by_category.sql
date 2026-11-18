-- 2026-11-18_1330_calendar_truck_by_category.sql
-- Trello #170 (iElTShdF): truck by category, step B of two. The Calendar reads the categories of step A
-- (2026-11-18_1300_truck_categories.sql). Fred's picks, 2026-11-18 (Supabase docs/decisions-to-build.md):
--   * the suggested truck stays the usual truck of the last 6 visits at the address for the service, but only a truck of
--     a category the visit needs can be it ("Usual truck, only within the category"): one wrong truck cannot teach it;
--     with none of the right category there, the line items' default (the category's first truck) with its reason;
--   * the visit needs the categories of its own line items, else its job's, else those of its service type;
--   * "Are you sure?" on Save when the truck does not fit: ops.fn_truck_check gives the answer and the sentence;
--   * the letter on the visit: P for pumping, C for cleaning, nothing on the others.
-- ops.v_calendar_visit: from the LIVE body (md5 6b60a9a8 of pg_get_viewdef(.., true)) by four anchored edits, made by
-- scratchpad/c170/make_b.py: (1) a lateral `need` before `ut`; `ut` counts the last 6 visits with every ACTIVE truck but
-- picks only a truck that fits (fits first in the ordering, `vehicle_id` NULL when none fits, `tied` only between two
-- that fit); (2) truck_categories joined for the effective truck; (3) two reason sentences for "none of the right
-- category here"; (4) six columns at the END: needed_truck_categories, needed_truck_category_names, truck_category,
-- truck_category_name, truck_category_mismatch (assigned visits only), service_letter. Nothing else in the body moved.
-- ops.v_calendar_truck: truck_category and truck_category_name at the end.
-- Measured in a rolled-back rehearsal against the live view (2,585 rows): every old column equal except on 22
-- upcoming visits with no truck: 9 change their suggested truck (pumping visits where Cloggy usually went, now Moises:
-- 6196, 6368, 6731, 7043, 7532, 7962, 8658, 8668, 9004), 13 keep it with a new sentence. Assigned, completed and past
-- visits: unchanged. 1 upcoming assigned visit does not fit (167-FEN 2026-11-20, pumping on Cloggy); 35 completed since
-- 2026-08-20 would have asked. public.client_services_flat reads this view: its truck follows the 9.
-- The standing check scripts/checks/usual_truck.sql recomputes the new rule (it passes on the new body; the old check
-- fails on exactly the 9). A month read 148-160 ms before, 161-167 ms after; one fn_truck_check 2 ms.
-- Access: views keep their grants. ops.fn_truck_check is SECURITY DEFINER, search_path pinned, Calendar View required
-- (hr.fn_require_app), EXECUTE to authenticated and service_role only.
-- Audit: no table changes here.
-- Rollback: 2026-11-18_1330_calendar_truck_by_category_rollback.sql (keeps the six columns, empty: a view cannot drop
-- columns in place while public.client_services_flat depends on it).

BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL search_path TO public;

DO $guard$
BEGIN
  IF md5(pg_get_viewdef('ops.v_calendar_visit'::regclass, true)) <> '6b60a9a8a82ee5d384bbf6a3b2e0fbdf' THEN
    RAISE EXCEPTION 'ops.v_calendar_visit changed since 2026-11-18 13:10 ET: rebuild this migration from the live body';
  END IF;
  IF md5(pg_get_viewdef('ops.v_calendar_truck'::regclass, true)) <> 'c5379a86dea7eb86356fbc16660fc1e9' THEN
    RAISE EXCEPTION 'ops.v_calendar_truck changed: rebuild this migration from the live body';
  END IF;
  IF to_regclass('public.truck_categories') IS NULL THEN
    RAISE EXCEPTION 'step A (2026-11-18_1300_truck_categories) has not run';
  END IF;
END
$guard$;

CREATE OR REPLACE VIEW ops.v_calendar_visit AS
WITH last_completed AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE prev.client_id = v_1.client_id AND prev.service_type = v_1.service_type AND prev.visit_status = 'completed'::text AND prev.deleted_at IS NULL AND prev.visit_date < v_1.visit_date) AS last_completed_date
           FROM visits v_1
        ), prev_live AS (
         SELECT v_1.id AS visit_id,
            COALESCE(( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE prev.job_id = v_1.job_id AND prev.service_type = v_1.service_type AND (prev.visit_status = ANY (ARRAY['completed'::text, 'scheduled'::text])) AND prev.deleted_at IS NULL AND prev.visit_date < v_1.visit_date), ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE prev.client_id = v_1.client_id AND prev.service_type = v_1.service_type AND (prev.visit_status = ANY (ARRAY['completed'::text, 'scheduled'::text])) AND prev.deleted_at IS NULL AND prev.visit_date < v_1.visit_date)) AS prev_live_date
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
    (gp.permits -> 0) ->> 'gdo_number'::text AS gdo_number,
    ((gp.permits -> 0) ->> 'expiration'::text)::date AS gdo_expiration,
    ((gp.permits -> 0) ->> 'max_frequency_days'::text)::integer AS gdo_max_frequency_days,
    (gp.permits -> 0) ->> 'document_path'::text AS gdo_document_path,
        CASE
            WHEN jsonb_array_length(gp.permits) > 0 THEN 'ACTIVE'::text
            ELSE NULL::text
        END AS gdo_status,
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
    veh.color_hex AS truck_color,
    gp.permits AS gdo_permits,
        CASE
            WHEN v.vehicle_id IS NOT NULL OR effv.vehicle_id IS NULL THEN NULL::text
            WHEN ut.vehicle_id IS NOT NULL THEN 'usual'::text
            ELSE 'service'::text
        END AS default_truck_basis,
        CASE
            WHEN v.vehicle_id IS NOT NULL OR effv.vehicle_id IS NULL THEN NULL::text
            WHEN ut.vehicle_id IS NOT NULL AND ut.tied THEN format('Usual truck here: %s (tied %s to %s with %s, %s went last).'::text, veh.name, ut.n, ut.n, tw.name, veh.name)
            WHEN ut.vehicle_id IS NOT NULL AND ut.tot = 1::numeric THEN format('Usual truck here: %s (the last %s visit).'::text, veh.name, lower(v.service_type))
            WHEN ut.vehicle_id IS NOT NULL THEN format('Usual truck here: %s, %s of the last %s %s visits.'::text, veh.name, ut.n, ut.tot, lower(v.service_type))
            WHEN ut.tot = 1::numeric THEN format('Defaults to %s from the service line items (no %s truck on the last %s visit here).'::text, veh.name, lower(( SELECT string_agg(tc.name, ' or '::text ORDER BY tc.sort) AS string_agg
           FROM truck_categories tc
          WHERE tc.code = ANY (need.cats))), lower(v.service_type))
            WHEN ut.tot IS NOT NULL THEN format('Defaults to %s from the service line items (no %s truck on the last %s %s visits here).'::text, veh.name, lower(( SELECT string_agg(tc.name, ' or '::text ORDER BY tc.sort) AS string_agg
           FROM truck_categories tc
          WHERE tc.code = ANY (need.cats))), ut.tot, lower(v.service_type))
            WHEN v.visit_status = 'scheduled'::text AND v.visit_date >= (now() AT TIME ZONE 'America/New_York'::text)::date AND v.property_id IS NOT NULL AND v.service_type IS NOT NULL THEN format('Defaults to %s from the service line items (no earlier %s visit here to go by).'::text, veh.name, lower(v.service_type))
            ELSE format('Defaults to %s from the service line items.'::text, veh.name)
        END AS default_truck_reason,
    need.cats AS needed_truck_categories,
    ( SELECT string_agg(tc.name, ' or '::text ORDER BY tc.sort) AS string_agg
           FROM truck_categories tc
          WHERE tc.code = ANY (need.cats)) AS needed_truck_category_names,
    veh.truck_category,
    vtc.name AS truck_category_name,
        CASE
            WHEN v.vehicle_id IS NULL OR need.cats IS NULL OR veh.truck_category IS NULL THEN NULL::boolean
            ELSE NOT veh.truck_category = ANY (need.cats)
        END AS truck_category_mismatch,
        CASE v.service_type
            WHEN 'Pumping'::text THEN 'P'::text
            WHEN 'Cleaning'::text THEN 'C'::text
            ELSE NULL::text
        END AS service_letter
   FROM visits v
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN properties prop ON prop.id = v.property_id
     LEFT JOIN properties primary_prop ON primary_prop.client_id = v.client_id AND primary_prop.is_primary = true
     LEFT JOIN zones pz ON pz.id = prop.zone_id
     LEFT JOIN zones ppz ON ppz.id = primary_prop.zone_id
     LEFT JOIN v_client_agreement_services sc ON sc.client_id = v.client_id AND sc.service_type = v.service_type
     LEFT JOIN LATERAL ( SELECT COALESCE(jsonb_agg(jsonb_build_object('gdo_id', g.id, 'gdo_number', g.gdo_number, 'expiration', g.permit_expiration, 'max_frequency_days', g.max_frequency_days, 'document_path', g.permit_document_path, 'location', cl.name) ORDER BY (g.gdo_number COLLATE "C")), '[]'::jsonb) AS permits
           FROM gdos g
             LEFT JOIN client_locations cl ON cl.id = g.client_location_id
          WHERE g.client_id = v.client_id AND g.status = 'ACTIVE'::text AND g.gdo_number ~ '^GDO-[0-9]+$'::text) gp ON true
     LEFT JOIN LATERAL ( SELECT COALESCE(( SELECT array_agg(DISTINCT sli.truck_category ORDER BY sli.truck_category) AS array_agg
                   FROM line_items li2
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li2.visit_id = v.id AND sli.truck_category IS NOT NULL), ( SELECT array_agg(DISTINCT sli.truck_category ORDER BY sli.truck_category) AS array_agg
                   FROM line_items li2
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li2.job_id = v.job_id AND li2.visit_id IS NULL AND li2.invoice_id IS NULL AND sli.truck_category IS NOT NULL), ( SELECT array_agg(DISTINCT sli.truck_category ORDER BY sli.truck_category) AS array_agg
                   FROM service_line_items sli
                  WHERE sli.service_type = v.service_type AND sli.truck_category IS NOT NULL)) AS cats) need ON true
     LEFT JOIN LATERAL ( SELECT
                CASE
                    WHEN c_1.fits THEN c_1.vehicle_id
                    ELSE NULL::bigint
                END AS vehicle_id,
            c_1.n,
            c_1.tot,
            c_1.next_fits AND c_1.next_n = c_1.n AS tied,
            c_1.next_vehicle_id AS tied_with
           FROM ( SELECT g.vehicle_id,
                    g.n,
                    g.fits,
                    sum(g.n) OVER () AS tot,
                    lead(g.n) OVER (ORDER BY g.fits DESC, g.n DESC, g.last_rk) AS next_n,
                    lead(g.fits) OVER (ORDER BY g.fits DESC, g.n DESC, g.last_rk) AS next_fits,
                    lead(g.vehicle_id) OVER (ORDER BY g.fits DESC, g.n DESC, g.last_rk) AS next_vehicle_id,
                    row_number() OVER (ORDER BY g.fits DESC, g.n DESC, g.last_rk) AS pos
                   FROM ( SELECT h.vehicle_id,
                            count(*) AS n,
                            min(h.rk) AS last_rk,
                            bool_or(h.fits) AS fits
                           FROM ( SELECT hv.vehicle_id,
                                    row_number() OVER (ORDER BY hv.visit_date DESC, hv.id DESC) AS rk,
                                    COALESCE(need.cats IS NULL OR htr.truck_category = ANY (need.cats), false) AS fits
                                   FROM visits hv
                                     JOIN vehicles htr ON htr.id = hv.vehicle_id AND htr.status = 'ACTIVE'::text
                                  WHERE v.vehicle_id IS NULL AND v.visit_status = 'scheduled'::text AND v.visit_date >= (now() AT TIME ZONE 'America/New_York'::text)::date AND hv.property_id = v.property_id AND hv.service_type = v.service_type AND hv.deleted_at IS NULL AND hv.visit_status = 'completed'::text
                                  ORDER BY hv.visit_date DESC, hv.id DESC
                                 LIMIT 6) h
                          GROUP BY h.vehicle_id) g) c_1
          WHERE c_1.pos = 1) ut ON true
     LEFT JOIN LATERAL ( SELECT COALESCE(v.vehicle_id, ut.vehicle_id, ( SELECT min(sli.default_vehicle_id) AS min
                   FROM line_items li2
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li2.visit_id = v.id), ( SELECT min(sli.default_vehicle_id) AS min
                   FROM line_items li2
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li2.job_id = v.job_id AND li2.visit_id IS NULL AND li2.invoice_id IS NULL)) AS vehicle_id) effv ON true
     LEFT JOIN vehicles veh ON veh.id = effv.vehicle_id
     LEFT JOIN truck_categories vtc ON vtc.code = veh.truck_category
     LEFT JOIN vehicles tw ON tw.id = ut.tied_with
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
  WHERE v.deleted_at IS NULL;

CREATE OR REPLACE VIEW ops.v_calendar_truck AS
SELECT id,
    name,
    status,
    make,
    model,
    year,
    grease_tank_capacity_gallons,
    fuel_tank_capacity_gallons,
    license_plate,
    decal_number,
    notes,
    created_at,
    updated_at,
    color_hex,
    truck_category,
    ( SELECT tc.name
           FROM truck_categories tc
          WHERE tc.code = vehicles.truck_category) AS truck_category_name
   FROM vehicles
  ORDER BY (
        CASE status
            WHEN 'ACTIVE'::text THEN 0
            ELSE 1
        END), name;

CREATE OR REPLACE FUNCTION ops.fn_truck_check(p_vehicle_id bigint, p_visit_id bigint DEFAULT NULL::bigint, p_line_item_codes text[] DEFAULT NULL::text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
-- Trello #170 (2026-11-18): does this truck fit the visit's work? The Calendar asks on Save ("Are you sure?") when it
-- does not. The visit's needed categories come from ops.v_calendar_visit (one rule: its line items, else its job's,
-- else its service type); a New Visit not saved yet passes its line item codes. Never blocks anything by itself.
-- Returns {fits, needed, needed_names, truck, truck_category, sentence}: fits true = no question; false = ask, with the
-- sentence; null = cannot tell (the truck has no category yet), with a sentence saying so.
DECLARE
  v_role text := coalesce(current_setting('role', true), 'none');
  v_need text[];
  v_service text;
  v_names text;
  v_truck record;
BEGIN
  PERFORM hr.fn_require_app('visit_calendar', 'view');
  IF v_role NOT IN ('authenticated', 'service_role', 'none') THEN
    RAISE EXCEPTION 'fn_truck_check: not allowed for role %', v_role USING ERRCODE = '42501';
  END IF;
  IF p_vehicle_id IS NULL THEN
    RAISE EXCEPTION 'Pick a truck first.' USING ERRCODE = '22023';
  END IF;
  SELECT t.id, t.name, t.truck_category, tc.name AS category_name INTO v_truck
    FROM public.vehicles t LEFT JOIN public.truck_categories tc ON tc.code = t.truck_category
   WHERE t.id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'That truck is not on file.' USING ERRCODE = '22023';
  END IF;

  IF p_line_item_codes IS NOT NULL THEN
    SELECT array_agg(DISTINCT sli.truck_category ORDER BY sli.truck_category),
           (array_agg(sli.service_type ORDER BY sli.code))[1]
      INTO v_need, v_service
      FROM public.service_line_items sli
     WHERE sli.code IN (SELECT lpad(btrim(c), 2, '0') FROM unnest(p_line_item_codes) c)
       AND sli.truck_category IS NOT NULL;
  ELSIF p_visit_id IS NOT NULL THEN
    SELECT cv.needed_truck_categories, cv.service_type INTO v_need, v_service
      FROM ops.v_calendar_visit cv WHERE cv.id = p_visit_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'That visit is not on file.' USING ERRCODE = '22023';
    END IF;
  ELSE
    RAISE EXCEPTION 'fn_truck_check needs a visit or its line item codes.' USING ERRCODE = '22023';
  END IF;

  SELECT string_agg(lower(tc.name), ' or ' ORDER BY tc.sort) INTO v_names
    FROM public.truck_categories tc WHERE tc.code = ANY (v_need);

  IF v_need IS NULL THEN          -- fees, GDO reporting, dump: no truck question
    RETURN jsonb_build_object('fits', true, 'needed', NULL, 'needed_names', NULL, 'truck', v_truck.name,
                              'truck_category', v_truck.truck_category, 'sentence', NULL);
  END IF;
  IF v_truck.truck_category IS NULL THEN
    RETURN jsonb_build_object('fits', NULL, 'needed', to_jsonb(v_need), 'needed_names', v_names, 'truck', v_truck.name,
                              'truck_category', NULL,
                              'sentence', format('%s has no truck category yet, so the Calendar cannot check it. Ask Fred to set it.', v_truck.name));
  END IF;
  IF v_truck.truck_category = ANY (v_need) THEN
    RETURN jsonb_build_object('fits', true, 'needed', to_jsonb(v_need), 'needed_names', v_names, 'truck', v_truck.name,
                              'truck_category', v_truck.truck_category, 'sentence', NULL);
  END IF;
  RETURN jsonb_build_object('fits', false, 'needed', to_jsonb(v_need), 'needed_names', v_names, 'truck', v_truck.name,
    'truck_category', v_truck.truck_category,
    'sentence', format('This %s visit needs %s %s truck, and %s is %s %s truck. Use %s anyway?',
                       coalesce(lower(v_service), 'kind of'),
                       CASE WHEN left(v_names, 1) IN ('a','e','i','o','u') THEN 'an' ELSE 'a' END, v_names,
                       v_truck.name,
                       CASE WHEN left(lower(v_truck.category_name), 1) IN ('a','e','i','o','u') THEN 'an' ELSE 'a' END,
                       lower(v_truck.category_name), v_truck.name));
END
$function$;
REVOKE ALL ON FUNCTION ops.fn_truck_check(bigint, bigint, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION ops.fn_truck_check(bigint, bigint, text[]) TO authenticated, service_role;
COMMENT ON FUNCTION ops.fn_truck_check(bigint, bigint, text[]) IS
  'Trello #170: does this truck fit the visit (p_visit_id) or a New Visit''s line items (p_line_item_codes)? '
  '{fits, needed, needed_names, truck, truck_category, sentence}: false = ask "Are you sure?" with the sentence. Never blocks.';
COMMENT ON COLUMN ops.v_calendar_visit.needed_truck_categories IS
  'Trello #170: the truck categories the visit''s work needs (its line items, else its job''s, else its service type); NULL = none.';
COMMENT ON COLUMN ops.v_calendar_visit.truck_category_mismatch IS
  'Trello #170: true when the ASSIGNED truck is of no needed category; NULL when nothing is assigned or either side is not set.';
COMMENT ON COLUMN ops.v_calendar_visit.service_letter IS 'Trello #170: P for a pumping visit, C for a cleaning visit, NULL otherwise.';

-- VERIFY (cheap only: the full comparison ran in the rehearsal; the standing check runs after the commit)
DO $verify$
DECLARE r jsonb;
BEGIN
  IF (SELECT array_agg(attname ORDER BY attnum) FROM pg_attribute WHERE attrelid = 'ops.v_calendar_visit'::regclass AND attnum > 76 AND NOT attisdropped)
     <> ARRAY['needed_truck_categories', 'needed_truck_category_names', 'truck_category', 'truck_category_name', 'truck_category_mismatch', 'service_letter']::name[] THEN
    RAISE EXCEPTION 'the six new columns are not at the end, in order';
  END IF;
  IF has_function_privilege('anon', 'ops.fn_truck_check(bigint, bigint, text[])', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'ops.fn_truck_check(bigint, bigint, text[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'fn_truck_check grants are wrong';
  END IF;
  r := ops.fn_truck_check(2, NULL, ARRAY['01']);
  IF (r->>'fits') IS DISTINCT FROM 'false' OR r->>'sentence' IS NULL THEN
    RAISE EXCEPTION 'Cloggy on a pumping line item should ask: %', r;
  END IF;
  r := ops.fn_truck_check(1, NULL, ARRAY['01']);
  IF (r->>'fits') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'Moises on a pumping line item should fit: %', r;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM ops.v_calendar_visit WHERE visit_date BETWEEN (now() AT TIME ZONE 'America/New_York')::date
                   AND (now() AT TIME ZONE 'America/New_York')::date + 7 AND needed_truck_categories IS NOT NULL AND service_letter = 'P') THEN
    RAISE EXCEPTION 'no visit of the coming week needs a category or reads P';
  END IF;
END
$verify$;

COMMIT;
