-- 2026-10-29_1700  ops.v_calendar_visit: a visit with no truck shows the USUAL truck at that address (Trello alpHmTtL)
--
-- WHY. Fred (Slack DM to Viktor, 2026-10-28): "making the default truck for visits without an assigned truck to be by
-- what should the truck be, like taking into consideration the previous truck going to that kind of visits, or by a
-- logic of which truck should go if we have no record", then "the usual truck that goes there, or the average one,
-- because it can be that 2 trucks went there for different reasons". His picks (2026-10-29): the most frequent truck
-- of the last 6 completed visits at the address for that service; a tie goes to "The most recent truck"; no history =
-- today's service default with the reason shown; "Show it, don't write it". He saw the backtest (since Aug 20: 82.4%
-- against 80.1% for today's rule; since April 72.6% against 78.4%) and chose it knowingly.
-- Spec: Building Apps/Visit Calendar/docs/specs/2026-10-29-smart-default-truck.md.
--
-- WHAT. Built from the LIVE pg_get_viewdef (md5 bcaae9068124d69ff92aac0fe97bfdd0), never retyped; three anchored edits, each asserted
-- to match exactly once:
--   1. new LATERAL ut, before effv: only for a visit with no stored truck, status scheduled, dated today (ET) or later.
--      It reads the last 6 completed, not deleted visits at the same property_id and service_type whose stored truck is
--      ACTIVE, and keeps the truck with the most of them; a tie goes to the truck that went last. It also returns the
--      count, the total and the truck it tied with, for the sentence.
--   2. effv.vehicle_id = COALESCE(stored, ut, visit line-item default, job line-item default). vehicle_source is not
--      touched: a usual truck still reads 'default' (it is not assigned), so every reader that tests it is unchanged.
--   3. two APPENDED columns (CREATE OR REPLACE stays legal; public.client_services_flat, the only dependent, is untouched):
--      default_truck_basis  'usual' | 'service', NULL when the truck is assigned or there is none;
--      default_truck_reason the sentence the drawer prints after "Not assigned.".
-- Past, completed, skipped and cancelled visits keep the service default, so no stored Grease pumped day moves: the
-- freezer (ops.fn_freeze_grease_estimates) stores days before today only and re-stores a day whose truck crosses Moises.
-- REACH, measured 2026-10-29 16:40 ET on a rolled-back TEMP view of this exact body: 731 upcoming unassigned visits,
-- every one with a usual truck (an independent recount agrees on all 731); 120 change truck (89 Moises -> David, 31
-- Moises -> Cloggy), 45 by a tie; 0 rows change anywhere else; vehicle_source identical on all 2,361 rows.
-- A 42-day read: 132 -> 152 ms and 124 -> 148 ms (median of 3).
-- The view stays owner-rights (reloptions NULL); the lateral reads visits and vehicles only, so no grant changes.
-- Only cheap checks run here: DDL on this view blocks the Calendar's reads until COMMIT. The full comparison ran before
-- (TEMP view) and runs after commit, read-only: scripts/checks/usual_truck.sql.
-- Rule 8 (audit): a view, nothing to audit. ROLLBACK: 2026-10-29_rollback_calendar_usual_truck.sql

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(pg_get_viewdef('ops.v_calendar_visit'::regclass, false)) <> 'bcaae9068124d69ff92aac0fe97bfdd0' then
    raise exception 'ops.v_calendar_visit changed since this migration was generated; rebuild it from the live definition';
  end if;
end
$pin$;

create or replace view ops.v_calendar_visit as
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
            WHEN ut.vehicle_id IS NOT NULL AND ut.tot = 1 THEN format('Usual truck here: %s (the last %s visit).'::text, veh.name, lower(v.service_type))
            WHEN ut.vehicle_id IS NOT NULL THEN format('Usual truck here: %s, %s of the last %s %s visits.'::text, veh.name, ut.n, ut.tot, lower(v.service_type))
            WHEN v.visit_status = 'scheduled'::text AND v.visit_date >= (now() AT TIME ZONE 'America/New_York'::text)::date AND v.property_id IS NOT NULL AND v.service_type IS NOT NULL
              THEN format('Defaults to %s from the service line items (no earlier %s visit here to go by).'::text, veh.name, lower(v.service_type))
            ELSE format('Defaults to %s from the service line items.'::text, veh.name)
        END AS default_truck_reason
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
     LEFT JOIN LATERAL ( SELECT c.vehicle_id, c.n, c.tot, c.next_n = c.n AS tied, c.next_vehicle_id AS tied_with
           FROM ( SELECT g.vehicle_id, g.n, sum(g.n) OVER () AS tot,
                    lead(g.n) OVER (ORDER BY g.n DESC, g.last_rk) AS next_n,
                    lead(g.vehicle_id) OVER (ORDER BY g.n DESC, g.last_rk) AS next_vehicle_id,
                    row_number() OVER (ORDER BY g.n DESC, g.last_rk) AS pos
                   FROM ( SELECT h.vehicle_id, count(*) AS n, min(h.rk) AS last_rk
                           FROM ( SELECT hv.vehicle_id, row_number() OVER (ORDER BY hv.visit_date DESC, hv.id DESC) AS rk
                                   FROM visits hv
                                     JOIN vehicles htr ON htr.id = hv.vehicle_id AND htr.status = 'ACTIVE'::text
                                  WHERE v.vehicle_id IS NULL AND v.visit_status = 'scheduled'::text AND v.visit_date >= (now() AT TIME ZONE 'America/New_York'::text)::date
                                    AND hv.property_id = v.property_id AND hv.service_type = v.service_type
                                    AND hv.deleted_at IS NULL AND hv.visit_status = 'completed'::text
                                  ORDER BY hv.visit_date DESC, hv.id DESC
                                 LIMIT 6) h
                          GROUP BY h.vehicle_id) g) c
          WHERE c.pos = 1) ut ON true
     LEFT JOIN LATERAL ( SELECT COALESCE(v.vehicle_id, ut.vehicle_id, ( SELECT min(sli.default_vehicle_id) AS min
                   FROM line_items li2
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li2.visit_id = v.id), ( SELECT min(sli.default_vehicle_id) AS min
                   FROM line_items li2
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li2.job_id = v.job_id AND li2.visit_id IS NULL AND li2.invoice_id IS NULL)) AS vehicle_id) effv ON true
     LEFT JOIN vehicles veh ON veh.id = effv.vehicle_id
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

comment on column ops.v_calendar_visit.default_truck_basis is
  'Why vehicle_id shows a truck nobody assigned: usual (most frequent of the last 6 completed visits at the address for that service, upcoming visits only) or service (the line-item default). NULL when assigned or none. 2026-10-29, Trello alpHmTtL.';
comment on column ops.v_calendar_visit.default_truck_reason is
  'The sentence the Calendar drawer shows after "Not assigned." for default_truck_basis. 2026-10-29, Trello alpHmTtL.';

do $verify$
declare v_n int; v_names text; v_acl text;
begin
  select count(*) into v_n from pg_attribute where attrelid = 'ops.v_calendar_visit'::regclass and attnum > 0 and not attisdropped;
  select string_agg(attname, ',' order by attnum) into v_names from pg_attribute
   where attrelid = 'ops.v_calendar_visit'::regclass and attnum in (74, 75, 76);
  if v_n <> 76 or v_names <> 'gdo_permits,default_truck_basis,default_truck_reason' then
    raise exception 'VERIFY 1: % columns, last three %', v_n, v_names;
  end if;
  if (select reloptions from pg_class where oid = 'ops.v_calendar_visit'::regclass) is not null then
    raise exception 'VERIFY 2: reloptions set';
  end if;
  select relacl::text into v_acl from pg_class where oid = 'ops.v_calendar_visit'::regclass;
  if v_acl not like '%authenticated=r/postgres%' or v_acl not like '%service_role=r/postgres%' or v_acl like '%anon%' then
    raise exception 'VERIFY 3: acl %', v_acl;
  end if;
  -- the gate: an assigned visit never gets a basis, and no row reads 'usual' outside the gate
  -- (a 4-week window keeps this cheap: the whole view is compared after commit, scripts/checks/usual_truck.sql)
  select count(*) into v_n from ops.v_calendar_visit
   where visit_date between (now() at time zone 'America/New_York')::date - 7 and (now() at time zone 'America/New_York')::date + 21
     and default_truck_basis = 'usual' and (assigned_vehicle_id is not null or visit_status <> 'scheduled'
         or visit_date < (now() at time zone 'America/New_York')::date);
  if v_n <> 0 then raise exception 'VERIFY 4: % usual rows outside the gate', v_n; end if;
  select count(*) into v_n from ops.v_calendar_visit
   where visit_date between (now() at time zone 'America/New_York')::date and (now() at time zone 'America/New_York')::date + 21
     and default_truck_basis = 'usual';
  if v_n = 0 then raise exception 'VERIFY 5: no usual row at all (positive control)'; end if;
end
$verify$;

COMMIT;
