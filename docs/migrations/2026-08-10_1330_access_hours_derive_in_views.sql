-- ============================================================================
-- 2026-08-10_1330: derive the legacy access trio from access_schedule in the views
-- ============================================================================
-- Step 3 of finishing the access-hours migration. Fred, 2026-08-10:
--   "do the migration for the old way of the access hours to the current one, and
--    once that is complete to do view checks on the apps, and do smoke tests to
--    also check the DB, and once that is complete we can drop the old way."
--
-- WHAT THIS DOES, AND WHY IT IS THE CHEAP ROUTE.
-- The five views that expose access_hours_start / access_hours_end / access_days
-- stop reading those base columns and DERIVE them from access_schedule instead.
-- The column NAMES, types and positions in every view are unchanged, so:
--   - the Visit Calendar keeps reading the same three fields (it names them
--     explicitly in two PostgREST calls and FILTERS on one of them), and
--   - the Client App keeps receiving the same keys from client.properties,
-- and NOTHING on any screen changes. That is what turns Fred's "view checks on
-- the apps" into a check rather than a six-app port.
--
-- After this, public.properties.access_hours_start/_end/access_days are read by
-- nothing except client.update_property_operational, and become droppable.
--
-- WHY THIS IS A PROVABLE NO-OP RATHER THAN A HOPEFUL ONE.
-- The derivation only substitutes cleanly if it reproduces what is stored, on
-- every row. Two migrations were shipped first to make that true:
--   2026-08-10_1212  padded 20 unpadded hours  -> start 198/198, end 198/198 match
--   2026-08-10_1305  normalised 7 properties   -> days 198/198 match
-- PART 3 below re-asserts all of it against the live views after the swap.
--
-- THE HELPERS ARE NAMED fn_sched_*, NOT fn_access_*, ON PURPOSE.
-- "fn_access_days" CONTAINS the string "access_days". A later find-and-replace on
-- the column name would silently maul the function body and every call site -- the
-- same collision that makes service_kind dangerous (see CLAUDE.md). The generator
-- that produced PART 2 asserts that after substitution the string "access_days"
-- survives ONLY as an output alias, and that check FAILED under the fn_access_days
-- name. The rename is what makes the guard meaningful.
--
-- GRANTS: THE VIEW/FUNCTION ASYMMETRY THAT HAS NOW BITTEN FOUR TIMES.
-- These views are owner-rights (reloptions NULL, owned by postgres), so they launder
-- the TABLE grant on public.properties. They do NOT launder FUNCTION EXECUTE: a
-- SECURITY INVOKER function called from inside an owner-rights view runs as the
-- CALLER and raises 42501 if that caller lacks EXECUTE. Without the grants below,
-- every staff user gets 42501 on the Calendar grid -- the exact fn_resolve_gdo_id
-- failure of 2026-07-28h. PART 1 asserts the grant with has_function_privilege,
-- which does not depend on a role switch behaving.
--
-- The helpers touch NO table, so they are pure and need no SECURITY DEFINER; the
-- search_path is pinned anyway. anon holds nothing (it reads none of these views).
--
-- REVERSIBILITY: base columns are untouched and still populated. Reverting is
-- re-running the previous CREATE OR REPLACE VIEW bodies, which are in git.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table added, renamed or dropped; no
-- trigger changed. Views and pure functions only.
-- ============================================================================

-- ---------------------------------------------------------------- PART 1: helpers
-- The modal-open / modal-close rule reproduced EXACTLY as
-- client.update_property_operational writes it today:
--     (select v_sched->d->>'open' from jsonb_object_keys(v_sched) d
--       group by v_sched->d->>'open' order by count(*) desc, 1 limit 1)
-- i.e. most common value, ties broken lexically ascending.
-- STRICT: a NULL schedule yields NULL, matching a property with no hours recorded.
-- An empty '{}' schedule also yields NULL (no rows to aggregate), matching the RPC.

create or replace function public.fn_sched_open(p_sched jsonb)
returns text language sql immutable strict
set search_path = pg_catalog, public
as $fn$
  select s.k from (
    select e.value->>'open' as k, count(*) as n
      from jsonb_each(p_sched) e
     group by 1 order by n desc, 1 limit 1) s;
$fn$;

create or replace function public.fn_sched_close(p_sched jsonb)
returns text language sql immutable strict
set search_path = pg_catalog, public
as $fn$
  select s.k from (
    select e.value->>'close' as k, count(*) as n
      from jsonb_each(p_sched) e
     group by 1 order by n desc, 1 limit 1) s;
$fn$;

-- Days in the canonical mon..sun order the column already uses.
create or replace function public.fn_sched_days(p_sched jsonb)
returns text[] language sql immutable strict
set search_path = pg_catalog, public
as $fn$
  select array_agg(k order by array_position(
           array['mon','tue','wed','thu','fri','sat','sun']::text[], k))
    from jsonb_object_keys(p_sched) k;
$fn$;

revoke all on function public.fn_sched_open(jsonb)  from public, anon;
revoke all on function public.fn_sched_close(jsonb) from public, anon;
revoke all on function public.fn_sched_days(jsonb)  from public, anon;
grant execute on function public.fn_sched_open(jsonb)  to authenticated, service_role;
grant execute on function public.fn_sched_close(jsonb) to authenticated, service_role;
grant execute on function public.fn_sched_days(jsonb)  to authenticated, service_role;

do $do$
declare v_fn text; v_ok boolean;
begin
  foreach v_fn in array array['fn_sched_open(jsonb)','fn_sched_close(jsonb)','fn_sched_days(jsonb)'] loop
    -- authenticated MUST hold EXECUTE or the Calendar grid raises 42501 for every user
    if not has_function_privilege('authenticated', 'public.'||v_fn, 'EXECUTE') then
      raise exception 'authenticated lacks EXECUTE on public.% -- the Calendar would 42501', v_fn;
    end if;
    if not has_function_privilege('service_role', 'public.'||v_fn, 'EXECUTE') then
      raise exception 'service_role lacks EXECUTE on public.%', v_fn;
    end if;
    -- and the default-privileges auto-grant must not have left anon holding it
    if has_function_privilege('anon', 'public.'||v_fn, 'EXECUTE') then
      raise exception 'anon still holds EXECUTE on public.% -- default privileges leaked', v_fn;
    end if;
  end loop;

  -- POSITIVE CONTROL on the instrument itself: has_function_privilege must be capable
  -- of returning a value, or the three checks above prove nothing.
  select has_function_privilege('authenticated','public.fn_sched_open(jsonb)','EXECUTE') into v_ok;
  if v_ok is null then raise exception 'has_function_privilege returned NULL -- instrument broken'; end if;
end
$do$;

-- ------------------------------------------------------- PART 2: the five views
-- Generated by copying pg_get_viewdef output and substituting ONLY the access
-- references. Every anchor was asserted to match exactly once, and the generator
-- refuses to emit a body where any legacy column name survives outside an output
-- alias. No other byte of any view body was touched.
-- client.properties: 1 anchor(s), each matched exactly once
create or replace view client.properties as
SELECT id,
    client_id,
    name,
    address,
    city,
    state,
    zip,
    country,
    is_billing,
    created_at,
    updated_at,
    latitude,
    longitude,
    geofence_radius_meters,
    geofence_type,
    public.fn_sched_open(p.access_schedule) AS access_hours_start,
    public.fn_sched_close(p.access_schedule) AS access_hours_end,
    public.fn_sched_days(p.access_schedule) AS access_days,
    is_primary,
    notes,
    county,
    grease_trap_manhole_count,
    access_notes,
    default_disposal_facility_id,
    zone_id,
    sample_port_count,
    ( SELECT z.code
           FROM zones z
          WHERE z.id = p.zone_id) AS zone,
    (( SELECT count(*) AS count
           FROM jobs j
          WHERE j.property_id = p.id))::integer AS job_count,
    (EXISTS ( SELECT 1
           FROM entity_source_links l
          WHERE l.entity_type = 'property'::text AND l.source_system = 'jobber'::text AND l.entity_id = p.id)) AS jobber_linked,
    ( SELECT sc.equipment_size_gallons
           FROM service_configs sc
          WHERE sc.property_id = p.id AND sc.service_type = 'Pumping'::text
          ORDER BY sc.id
         LIMIT 1) AS grease_capacity_gallons,
    access_schedule
   FROM properties p;

-- ops.properties: 1 anchor(s), each matched exactly once
create or replace view ops.properties as
SELECT p.id,
    p.client_id,
    p.name,
    p.address,
    p.city,
    p.state,
    p.zip,
    p.country,
    p.is_billing,
    p.created_at,
    p.updated_at,
    z.code AS zone,
    p.latitude,
    p.longitude,
    p.geofence_radius_meters,
    p.geofence_type,
    public.fn_sched_open(p.access_schedule) AS access_hours_start,
    public.fn_sched_close(p.access_schedule) AS access_hours_end,
    public.fn_sched_days(p.access_schedule) AS access_days,
    p.is_primary,
    p.notes,
    p.county,
    p.grease_trap_manhole_count,
    p.access_notes,
    p.default_disposal_facility_id
   FROM properties p
     LEFT JOIN zones z ON z.id = p.zone_id;

-- ops.v_service_due: 1 anchor(s), each matched exactly once
create or replace view ops.v_service_due as
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
    public.fn_sched_open(p.access_schedule) AS access_hours_start,
    public.fn_sched_close(p.access_schedule) AS access_hours_end,
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
        END), (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) DESC NULLS LAST;

-- ops.v_calendar_visit: 3 anchor(s), each matched exactly once
create or replace view ops.v_calendar_visit as
WITH last_completed AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE prev.client_id = v_1.client_id AND prev.service_type = v_1.service_type AND prev.visit_status = 'completed'::text AND prev.visit_date < v_1.visit_date) AS last_completed_date
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
                  WHERE visits.visit_status = 'completed'::text AND (visits.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text]))) gaps
          WHERE gaps.days_since_prev >= 5 AND gaps.days_since_prev <= 200
          GROUP BY gaps.client_id, gaps.service_type
        ), observed_price AS (
         SELECT v_1.client_id,
            v_1.service_type,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (li.total_price::double precision))::numeric(12,2) AS median_line_price
           FROM visits v_1
             JOIN line_items li ON li.invoice_id = v_1.invoice_id
          WHERE v_1.invoice_id IS NOT NULL AND v_1.visit_status = 'completed'::text AND (v_1.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text])) AND li.total_price > 0::numeric
          GROUP BY v_1.client_id, v_1.service_type
        ), observed_job_cadence AS (
         SELECT gaps.job_id,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (gaps.days_since_prev::double precision))::integer AS median_gap_days
           FROM ( SELECT visits.job_id,
                    visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.job_id ORDER BY visits.visit_date) AS days_since_prev
                   FROM visits
                  WHERE visits.visit_status = 'completed'::text AND (visits.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text]))) gaps
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
    COALESCE(public.fn_sched_open(prop.access_schedule), public.fn_sched_open(primary_prop.access_schedule)) AS access_hours_start,
    COALESCE(public.fn_sched_close(prop.access_schedule), public.fn_sched_close(primary_prop.access_schedule)) AS access_hours_end,
    COALESCE(public.fn_sched_days(prop.access_schedule), public.fn_sched_days(primary_prop.access_schedule)) AS access_days,
    COALESCE(prop.latitude, primary_prop.latitude) AS latitude,
    COALESCE(prop.longitude, primary_prop.longitude) AS longitude,
    COALESCE(prop.grease_trap_manhole_count, primary_prop.grease_trap_manhole_count) AS manholes,
        CASE
            WHEN c.client_code ~~ '000-%'::text THEN NULLIF(jb.frequency_days, 0)
            ELSE COALESCE(NULLIF(jb.frequency_days, 0), sc.frequency_days, oc.median_gap_days)
        END AS frequency_days,
    sc.equipment_size_gallons,
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
  WHERE v.deleted_at IS NULL;

-- ops.v_route_today: 4 anchor(s), each matched exactly once
create or replace view ops.v_route_today as
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
    COALESCE(public.fn_sched_open(vp.access_schedule), public.fn_sched_open(pp.access_schedule)) AS access_hours_start,
    COALESCE(public.fn_sched_close(vp.access_schedule), public.fn_sched_close(pp.access_schedule)) AS access_hours_end,
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
     LEFT JOIN zones vp_z ON vp_z.id = vp.zone_id
     LEFT JOIN zones pp_z ON pp_z.id = pp.zone_id
  WHERE v.visit_date = CURRENT_DATE AND (v.visit_status = ANY (ARRAY['UPCOMING'::text, 'LATE'::text, 'completed'::text]))
  GROUP BY v.id, v.visit_date, v.start_at, v.end_at, v.visit_status, v.service_type, v.is_gps_confirmed, c.id, c.client_code, c.name, vp_z.code, vp.address, vp.city, vp.county, vp.latitude, vp.longitude, vp.access_schedule, pp_z.code, pp.address, pp.city, pp.county, pp.latitude, pp.longitude, pp.access_schedule, cc.name, cc.phone, sc.equipment_size_gallons, v.property_id, veh.name, veh.grease_tank_capacity_gallons, v.duration_minutes
  ORDER BY v.start_at, (COALESCE(vp_z.code, pp_z.code)), c.name;

-- --------------------------------------------------------- PART 3: verification
do $do$
declare
  v_bad int; v_def text; v_n int; v_probe text; v_days text[];
begin
  -- (a) REVERT DISCRIMINATION. Every check in (b) passes identically against the OLD
  -- view bodies, because stored already equals derived -- that is the whole point of
  -- the two preceding migrations. So (b) alone cannot tell whether this migration did
  -- anything. Assert the swap actually happened.
  foreach v_def in array array['client.properties','ops.properties','ops.v_calendar_visit',
                               'ops.v_route_today','ops.v_service_due'] loop
    if pg_get_viewdef(v_def::regclass, true) !~ 'fn_sched_' then
      raise exception 'view % was NOT repointed -- it still reads the base columns', v_def;
    end if;
    -- and no qualified reference to a base access column may survive
    if pg_get_viewdef(v_def::regclass, true) ~ '[a-z_]+\.access_(hours_start|hours_end|days)' then
      raise exception 'view % still references a base access column directly', v_def;
    end if;
  end loop;

  -- (b) THE NO-OP PROOF: what each view now serves must equal what the base table
  -- still stores, row for row.
  select count(*) into v_bad from client.properties v join public.properties b on b.id = v.id
   where v.access_hours_start is distinct from b.access_hours_start
      or v.access_hours_end   is distinct from b.access_hours_end
      or (select array_agg(x order by x) from unnest(v.access_days) x)
         is distinct from (select array_agg(x order by x) from unnest(b.access_days) x);
  if v_bad <> 0 then raise exception 'client.properties diverges from stored on % rows', v_bad; end if;

  select count(*) into v_bad from ops.properties v join public.properties b on b.id = v.id
   where v.access_hours_start is distinct from b.access_hours_start
      or v.access_hours_end   is distinct from b.access_hours_end
      or (select array_agg(x order by x) from unnest(v.access_days) x)
         is distinct from (select array_agg(x order by x) from unnest(b.access_days) x);
  if v_bad <> 0 then raise exception 'ops.properties diverges from stored on % rows', v_bad; end if;

  -- v_calendar_visit COALESCEs the visit property over the client primary property,
  -- so it is compared against the SAME coalesce over the base columns, not one property.
  -- PRECONDITION: the view's primary_prop join is a plain LEFT JOIN on is_primary, so a
  -- client with two primaries would multiply rows here and manufacture false mismatches.
  -- Measured 0 such clients (439 have exactly one). Asserted, not assumed.
  select count(*) into v_bad from (
    select client_id from public.properties where is_primary group by client_id having count(*) > 1) t;
  if v_bad <> 0 then
    raise exception '% clients hold multiple primary properties -- the check below would be invalid', v_bad;
  end if;

  select count(*) into v_bad
    from ops.v_calendar_visit v
    left join public.properties vp on vp.id = v.property_id
    left join public.properties pp on pp.client_id = v.client_id and pp.is_primary = true
   where v.access_hours_start is distinct from coalesce(vp.access_hours_start, pp.access_hours_start)
      or v.access_hours_end   is distinct from coalesce(vp.access_hours_end,   pp.access_hours_end)
      or (select array_agg(x order by x) from unnest(v.access_days) x) is distinct from
         (select array_agg(x order by x) from unnest(coalesce(vp.access_days, pp.access_days)) x);
  if v_bad <> 0 then raise exception 'ops.v_calendar_visit diverges on % rows', v_bad; end if;

  -- (c) NON-EMPTY CONTROL. Every comparison above is satisfied by a view returning
  -- all NULLs, since NULL is not distinct from NULL. Prove real values are flowing.
  select count(*) into v_n from client.properties where access_hours_start is not null;
  if v_n <> 198 then raise exception 'client.properties serves % non-null hours, expected 198', v_n; end if;
  select count(*) into v_n from client.properties where access_days is not null;
  if v_n <> 198 then raise exception 'client.properties serves % non-null day arrays, expected 198', v_n; end if;
  select count(*) into v_n from ops.v_calendar_visit where access_hours_start is not null;
  if v_n = 0 then raise exception 'ops.v_calendar_visit serves zero access hours -- the switch blanked it'; end if;

  -- (d) the helpers themselves, on a known-overnight window and on the edge cases
  select public.fn_sched_open('{"mon":{"open":"22:00","close":"06:00"}}'::jsonb) into v_probe;
  if v_probe <> '22:00' then raise exception 'fn_sched_open returned % for a single window', v_probe; end if;
  select public.fn_sched_open('{}'::jsonb) into v_probe;
  if v_probe is not null then raise exception 'fn_sched_open on empty object returned %, expected NULL', v_probe; end if;
  select public.fn_sched_open(null) into v_probe;
  if v_probe is not null then raise exception 'fn_sched_open(null) returned %, expected NULL', v_probe; end if;
  select public.fn_sched_days('{"fri":{"open":"09:00","close":"17:00"},"mon":{"open":"09:00","close":"17:00"}}'::jsonb) into v_days;
  if v_days <> array['mon','fri']::text[] then
    raise exception 'fn_sched_days returned % -- canonical mon..sun order broken', v_days;
  end if;
  -- ties break lexically ascending, matching the RPC
  select public.fn_sched_open('{"mon":{"open":"08:00","close":"17:00"},"tue":{"open":"06:00","close":"17:00"}}'::jsonb) into v_probe;
  if v_probe <> '06:00' then raise exception 'fn_sched_open tie-break gave %, expected 06:00', v_probe; end if;

  raise notice 'all five views repointed; 198 hours and 198 day arrays served, matching stored exactly';
end
$do$;
