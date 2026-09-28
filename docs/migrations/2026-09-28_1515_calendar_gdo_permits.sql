-- 2026-09-28_1515  ops.v_calendar_visit: the Calendar shows EVERY ACTIVE GDO of the client, never a demoted one
--
-- WHY. Fred picked "All permits" (2026-09-28): "Same rule as the Dump App and the Manifest Generator.
-- Hover card lists every number, or No GDO. The drawer shows one block per permit, each with its own PDF
-- link, expiry and max frequency." Until now the view took ONE permit from public.fn_resolve_gdo_id
-- (LIMIT 1, status ignored), so for 19 customer clients the Calendar hover card and drawer showed a permit
-- DEMOTED because its DERM PDF names ANOTHER business (083-SHUL -> GDO-12490 Pizza Fiore), and the drawer's
-- link opened that business's PDF. 137-BB (GDO-11271, Fred: "i need it there if it's the correct one"):
-- the permit is issued to the same company but for the Aventura Mall food hall (19565 Biscayne Blvd FH-7);
-- every 2026 service photo is stamped W Dixie Hwy and the truck GPS stops 7-17 m from 18549 W Dixie Hwy on
-- all 6 completed visits, so it is not this trap's permit and stays hidden like the rest.
--
-- WHAT. Built from the LIVE pg_get_viewdef (md5 677078b1cd342efc792ff4610a274ba2), never retyped; the repo copy
-- scripts/ops_views/v_calendar_visit.sql is stale (no truck_color). Two edits and one appended column:
--   1. the LATERAL fn_resolve_gdo_id + gdos join is replaced by a LATERAL building `permits`: every gdos row of
--      the client with status ACTIVE and strict ^GDO-[0-9]+$, ordered COLLATE "C" = the Manifest Generator
--      (pdf-service _active_gdos), the DUMP app (public.dump_visit_gdo_numbers) and rows_printed
--      (derm.record_generated_sheet_preview). Each element: gdo_id, gdo_number, expiration,
--      max_frequency_days, document_path, location (client_locations.name).
--   2. the five legacy single columns (gdo_number, gdo_expiration, gdo_max_frequency_days, gdo_document_path,
--      gdo_status) keep their names and types and now read the FIRST element of that list (gdo_status is
--      'ACTIVE' or NULL). The currently published Calendar reads them, so it stops showing demoted permits the
--      moment this lands, before the app is republished.
--   3. NEW LAST COLUMN gdo_permits jsonb (array, '[]' when none). Appended, so CREATE OR REPLACE is legal and
--      public.client_services_flat (the only dependent view; reads no gdo column) is untouched.
-- The view stays owner-rights (reloptions NULL) and calls no function for this, so no reader role needs a new
-- grant. fn_resolve_gdo_id is NOT changed; its remaining caller is fn_resolve_gdo_number ->
-- public.dump_outstanding_visits, whose value the DUMP edge fn overwrites.
-- Rule 8 (audit): a view, nothing to audit.

do $pin$
begin
  if md5(pg_get_viewdef('ops.v_calendar_visit'::regclass, false)) <> '677078b1cd342efc792ff4610a274ba2' then
    raise exception 'ops.v_calendar_visit changed since this migration was generated; rebuild it from the live definition';
  end if;
end
$pin$;

create or replace view ops.v_calendar_visit as
WITH last_completed AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE ((prev.client_id = v_1.client_id) AND (prev.service_type = v_1.service_type) AND (prev.visit_status = 'completed'::text) AND (prev.deleted_at IS NULL) AND (prev.visit_date < v_1.visit_date))) AS last_completed_date
           FROM visits v_1
        ), prev_live AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE ((prev.client_id = v_1.client_id) AND (prev.service_type = v_1.service_type) AND (prev.visit_status = ANY (ARRAY['completed'::text, 'scheduled'::text])) AND (prev.deleted_at IS NULL) AND (prev.visit_date < v_1.visit_date))) AS prev_live_date
           FROM visits v_1
        ), observed_cadence AS (
         SELECT gaps.client_id,
            gaps.service_type,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((gaps.days_since_prev)::double precision)))::integer AS median_gap_days
           FROM ( SELECT visits.client_id,
                    visits.service_type,
                    (visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.client_id, visits.service_type ORDER BY visits.visit_date)) AS days_since_prev
                   FROM visits
                  WHERE ((visits.deleted_at IS NULL) AND (visits.visit_status = 'completed'::text) AND (visits.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text])))) gaps
          WHERE ((gaps.days_since_prev >= 5) AND (gaps.days_since_prev <= 200))
          GROUP BY gaps.client_id, gaps.service_type
        ), observed_price AS (
         SELECT v_1.client_id,
            v_1.service_type,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((li.total_price)::double precision)))::numeric(12,2) AS median_line_price
           FROM (visits v_1
             JOIN line_items li ON ((li.invoice_id = v_1.invoice_id)))
          WHERE ((v_1.deleted_at IS NULL) AND (v_1.invoice_id IS NOT NULL) AND (v_1.visit_status = 'completed'::text) AND (v_1.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text])) AND (li.total_price > (0)::numeric))
          GROUP BY v_1.client_id, v_1.service_type
        ), observed_job_cadence AS (
         SELECT gaps.job_id,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((gaps.days_since_prev)::double precision)))::integer AS median_gap_days
           FROM ( SELECT visits.job_id,
                    (visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.job_id ORDER BY visits.visit_date)) AS days_since_prev
                   FROM visits
                  WHERE ((visits.deleted_at IS NULL) AND (visits.visit_status = 'completed'::text) AND (visits.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text])))) gaps
          WHERE ((gaps.days_since_prev >= 5) AND (gaps.days_since_prev <= 200))
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
    COALESCE(v.duration_minutes, ((EXTRACT(epoch FROM (v.end_at - v.start_at)) / (60)::numeric))::integer) AS duration_minutes,
    v.title,
    v.derm_required,
    v.is_gps_confirmed,
    v.manhole_count,
    v.ticket_number,
    v.created_at AS visit_created_at,
    v.updated_at AS visit_updated_at,
    (COALESCE(NULLIF(( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE (li.visit_id = v.id)), (0)::numeric),
        CASE
            WHEN ((v.invoice_id IS NOT NULL) AND (( SELECT count(*) AS count
               FROM visits v2
              WHERE ((v2.invoice_id = v.invoice_id) AND (v2.deleted_at IS NULL))) = 1)) THEN ( SELECT sum(li.total_price) AS sum
               FROM line_items li
              WHERE (li.invoice_id = v.invoice_id))
            ELSE NULL::numeric
        END, ( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL))), ( SELECT sum(li.total_price) AS sum
           FROM line_items li
          WHERE (li.visit_id = v.id))))::numeric(12,2) AS amount,
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
            WHEN (c.client_code ~~ '000-%'::text) THEN NULLIF(jb.frequency_days, 0)
            ELSE COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days)
        END AS frequency_days,
    COALESCE((prop.grease_trap_size_gallons)::numeric, (primary_prop.grease_trap_size_gallons)::numeric, sc.equipment_size_gallons) AS equipment_size_gallons,
    sc.first_visit AS sc_first_visit,
    sc.last_visit AS sc_last_visit,
    sc.stop_date AS sc_stop_date,
    sc.material_type,
    ((gp.permits -> 0) ->> 'gdo_number'::text) AS gdo_number,
    (((gp.permits -> 0) ->> 'expiration'::text))::date AS gdo_expiration,
    (((gp.permits -> 0) ->> 'max_frequency_days'::text))::integer AS gdo_max_frequency_days,
    ((gp.permits -> 0) ->> 'document_path'::text) AS gdo_document_path,
        CASE
            WHEN (jsonb_array_length(gp.permits) > 0) THEN 'ACTIVE'::text
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
            WHEN (v.visit_status = 'skipped'::text) THEN NULL::text
            WHEN (v.visit_status = 'completed'::text) THEN NULL::text
            WHEN (pl.prev_live_date IS NULL) THEN NULL::text
            WHEN (COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days) IS NULL) THEN NULL::text
            WHEN (((pl.prev_live_date + ((COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days))::double precision * '1 day'::interval)))::date < CURRENT_DATE) THEN 'late'::text
            WHEN (((pl.prev_live_date + ((COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days))::double precision * '1 day'::interval)))::date < v.visit_date) THEN 'will_be_late'::text
            ELSE 'on_time'::text
        END AS late_status,
    lc.last_completed_date,
    v.assigned_driver_id,
    asg.full_name AS assigned_driver_name,
    COALESCE(sc.price_per_visit, op.median_line_price) AS amount_estimated,
    ((v.start_at IS NULL) OR ((((v.start_at AT TIME ZONE 'America/New_York'::text))::time without time zone = '00:00:00'::time without time zone) AND (v.end_at IS NOT NULL) AND ((v.end_at - v.start_at) >= '23:00:00'::interval))) AS is_all_day,
        CASE
            WHEN (c.client_code ~~ '000-%'::text) THEN 'SC'::text
            WHEN (NULLIF(jb.frequency_days, 0) > 0) THEN 'SA'::text
            WHEN ((lower(jb.title) ~~ '%service call%'::text) OR (lower(jb.title) ~~ '%emergency%'::text)) THEN 'SC'::text
            WHEN ((ojc.median_gap_days > 0) OR (lower(jb.title) ~~ '%grease%'::text) OR (lower(jb.title) ~~ '%grey water%'::text) OR (lower(jb.title) ~~ '%service agreement%'::text)) THEN 'SA'::text
            ELSE 'SC'::text
        END AS service_kind,
    v.notes,
    v.sync_state,
    v.skip_reason,
    sagrp.sa_group,
        CASE
            WHEN (c.client_code ~~ '000-%'::text) THEN NULL::date
            WHEN (pl.prev_live_date IS NULL) THEN NULL::date
            WHEN (COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days) IS NULL) THEN NULL::date
            ELSE ((pl.prev_live_date + ((COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days))::double precision * '1 day'::interval)))::date
        END AS expected_date,
        CASE
            WHEN (emp.id IS NOT NULL) THEN emp.color_hex
            ELSE asg.color_hex
        END AS driver_color,
    COALESCE(( SELECT (array_agg(sli.service_type ORDER BY (NOT sli.schedulable), sli.code) FILTER (WHERE (sli.service_type IS NOT NULL)))[1] AS array_agg
           FROM (line_items li
             JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text))))
          WHERE (li.visit_id = v.id)), ( SELECT (array_agg(sli.service_type ORDER BY (NOT sli.schedulable), sli.code) FILTER (WHERE (sli.service_type IS NOT NULL)))[1] AS array_agg
           FROM (line_items li
             JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text))))
          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL))),
        CASE
            WHEN (v.derm_required IS TRUE) THEN 'Pumping'::text
            ELSE NULL::text
        END) AS service_label,
    v.vehicle_id AS assigned_vehicle_id,
        CASE
            WHEN (v.vehicle_id IS NOT NULL) THEN 'assigned'::text
            WHEN (effv.vehicle_id IS NOT NULL) THEN 'default'::text
            ELSE 'none'::text
        END AS vehicle_source,
    COALESCE(pz.color_hex, ppz.color_hex) AS zone_color,
    veh.color_hex AS truck_color,
    gp.permits AS gdo_permits
   FROM (((((((((((((((((((visits v
     JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties prop ON ((prop.id = v.property_id)))
     LEFT JOIN properties primary_prop ON (((primary_prop.client_id = v.client_id) AND (primary_prop.is_primary = true))))
     LEFT JOIN zones pz ON ((pz.id = prop.zone_id)))
     LEFT JOIN zones ppz ON ((ppz.id = primary_prop.zone_id)))
     LEFT JOIN service_configs sc ON (((sc.client_id = v.client_id) AND (sc.service_type = v.service_type))))
     LEFT JOIN LATERAL ( SELECT COALESCE(jsonb_agg(jsonb_build_object('gdo_id', g.id, 'gdo_number', g.gdo_number, 'expiration', g.permit_expiration, 'max_frequency_days', g.max_frequency_days, 'document_path', g.permit_document_path, 'location', cl.name) ORDER BY (g.gdo_number COLLATE "C")), '[]'::jsonb) AS permits
           FROM (gdos g
             LEFT JOIN client_locations cl ON ((cl.id = g.client_location_id)))
          WHERE ((g.client_id = v.client_id) AND (g.status = 'ACTIVE'::text) AND (g.gdo_number ~ '^GDO-[0-9]+$'::text))) gp ON (true))
     LEFT JOIN LATERAL ( SELECT COALESCE(v.vehicle_id, ( SELECT min(sli.default_vehicle_id) AS min
                   FROM (line_items li2
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE (li2.visit_id = v.id)), ( SELECT min(sli.default_vehicle_id) AS min
                   FROM (line_items li2
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE ((li2.job_id = v.job_id) AND (li2.visit_id IS NULL) AND (li2.invoice_id IS NULL)))) AS vehicle_id) effv ON (true))
     LEFT JOIN vehicles veh ON ((veh.id = effv.vehicle_id)))
     LEFT JOIN LATERAL ( SELECT COALESCE(( SELECT min(e.id) AS min
                   FROM (visit_assignments va
                     JOIN employees e ON ((e.id = va.employee_id)))
                  WHERE ((va.visit_id = v.id) AND (e.status = 'ACTIVE'::text))), ( SELECT min(va.employee_id) AS min
                   FROM visit_assignments va
                  WHERE (va.visit_id = v.id)), ( SELECT e.id
                   FROM (inspections i
                     JOIN employees e ON ((e.id = i.employee_id)))
                  WHERE ((i.vehicle_id = v.vehicle_id) AND (i.shift_date >= (v.visit_date - 1)) AND (i.shift_date <= (v.visit_date + 1)))
                  ORDER BY (i.shift_date = v.visit_date) DESC, (e.status = 'ACTIVE'::text) DESC, (abs((i.shift_date - v.visit_date))), e.id
                 LIMIT 1)) AS employee_id) fa ON (true))
     LEFT JOIN employees emp ON ((emp.id = fa.employee_id)))
     LEFT JOIN employees asg ON ((asg.id = v.assigned_driver_id)))
     LEFT JOIN last_completed lc ON ((lc.visit_id = v.id)))
     LEFT JOIN prev_live pl ON ((pl.visit_id = v.id)))
     LEFT JOIN observed_cadence oc ON (((oc.client_id = v.client_id) AND (oc.service_type = v.service_type))))
     LEFT JOIN observed_price op ON (((op.client_id = v.client_id) AND (op.service_type = v.service_type))))
     LEFT JOIN jobs jb ON ((jb.id = v.job_id)))
     LEFT JOIN observed_job_cadence ojc ON ((ojc.job_id = v.job_id)))
     LEFT JOIN LATERAL ( SELECT COALESCE(( SELECT (array_agg(ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) ORDER BY sli.code) FILTER (WHERE (ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) IS NOT NULL)))[1] AS grp
                   FROM (line_items li3
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li3.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE ((li3.visit_id = v.id) AND (sli.schedulable = true))), ( SELECT (array_agg(ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) ORDER BY sli.code) FILTER (WHERE (ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) IS NOT NULL)))[1] AS grp
                   FROM (line_items li3
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li3.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE ((li3.job_id = v.job_id) AND (li3.visit_id IS NULL) AND (li3.invoice_id IS NULL) AND (sli.schedulable = true)))) AS sa_group) sagrp ON (true))
  WHERE (v.deleted_at IS NULL);

-- VERIFY (same transaction; any failure rolls the whole file back)
do $verify$
declare v_n int; v_t text; v_casa jsonb; v_acl text;
begin
  -- 1. shape: 74 columns, the new one last and jsonb; options unchanged (owner-rights)
  select count(*) into v_n from pg_attribute where attrelid = 'ops.v_calendar_visit'::regclass and attnum > 0 and not attisdropped;
  select format_type(atttypid, atttypmod) into v_t from pg_attribute where attrelid = 'ops.v_calendar_visit'::regclass and attname = 'gdo_permits' and attnum = 74;
  if v_n <> 74 or v_t is distinct from 'jsonb' then raise exception 'VERIFY 1: % cols, gdo_permits %', v_n, v_t; end if;
  if (select reloptions from pg_class where oid = 'ops.v_calendar_visit'::regclass) is not null then raise exception 'VERIFY 1b: reloptions set'; end if;

  -- 2. the list equals the DUMP app's list for EVERY row (same rule, two implementations: prove they agree)
  select count(*) into v_n
    from ops.v_calendar_visit v
    join public.dump_visit_gdo_numbers(array(select id from ops.v_calendar_visit)) d on d.visit_id = v.id
   where array(select e->>'gdo_number' from jsonb_array_elements(v.gdo_permits) with ordinality x(e, o) order by o) is distinct from d.gdo_numbers;
  if v_n <> 0 then raise exception 'VERIFY 2: % rows disagree with dump_visit_gdo_numbers', v_n; end if;
  select count(*) into v_n from ops.v_calendar_visit where gdo_permits is null;
  if v_n <> 0 then raise exception 'VERIFY 2b: % NULL gdo_permits', v_n; end if;

  -- 3. no row shows a permit that is not ACTIVE, and the legacy value is the first element
  select count(*) into v_n from ops.v_calendar_visit v
   where v.gdo_number is not null and not exists (select 1 from public.gdos g where g.client_id = v.client_id and g.gdo_number = v.gdo_number and g.status = 'ACTIVE');
  if v_n <> 0 then raise exception 'VERIFY 3: % rows show a non-ACTIVE permit', v_n; end if;
  select count(*) into v_n from ops.v_calendar_visit where gdo_number is distinct from (gdo_permits -> 0 ->> 'gdo_number');
  if v_n <> 0 then raise exception 'VERIFY 3b: % legacy mismatches', v_n; end if;

  -- 4. the named cases
  select gdo_permits into v_casa from ops.v_calendar_visit where id = 6569;
  if jsonb_array_length(v_casa) <> 3 or v_casa -> 0 ->> 'gdo_number' <> 'GDO-10877' or v_casa -> 2 ->> 'gdo_number' <> 'GDO-16389'
     or v_casa -> 0 ->> 'document_path' is null then raise exception 'VERIFY 4: Casa Neos 6569 %', v_casa; end if;
  select count(*) into v_n from ops.v_calendar_visit v join public.clients c on c.id = v.client_id
   where c.client_code in ('083-SHUL', '137-BB', '241-WYN', '087-BB') and (v.gdo_number is not null or jsonb_array_length(v.gdo_permits) <> 0);
  if v_n <> 0 then raise exception 'VERIFY 4b: % demoted-permit rows still show a GDO', v_n; end if;

  -- 5. readers: the dependent view still answers, and signed-in staff can read the new column
  perform 1 from public.client_services_flat limit 1;
  set local role authenticated;
  perform gdo_permits from ops.v_calendar_visit limit 1;
  reset role;
  select array_to_string(relacl, ',') into v_acl from pg_class where oid = 'ops.v_calendar_visit'::regclass;
  if v_acl not like '%authenticated=r/postgres%' or v_acl not like '%yannick_readonly=r/postgres%' then raise exception 'VERIFY 5: acl %', v_acl; end if;
end
$verify$;
