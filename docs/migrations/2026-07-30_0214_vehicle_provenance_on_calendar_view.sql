-- 2026-07-30_0214_vehicle_provenance_on_calendar_view.sql
--
-- (Committed first as ..._0614_... That stamp was UTC, not ET. `TZ=America/New_York date` in this
--  workspace's Git Bash SILENTLY RETURNS UTC: it is byte-identical to `date -u`, and plain `date`
--  gives machine-local UTC+2. Neither is ET, which the workspace rule requires. Correct ET is
--  UTC-4 in EDT. Get ET from the DB instead: select now() at time zone 'America/New_York'.)
--
-- MAKES THE CALENDAR'S TRUCK DISPLAY HONEST. Purely additive: two trailing columns.
--
-- THE PROBLEM. `ops.v_calendar_visit.vehicle_id` is an EFFECTIVE value:
--     COALESCE(visits.vehicle_id, visit-level line-item default, job-level line-item default)
-- That is the default-trucks-by-line-item feature (2026-06-27, Yannick's request), working as
-- designed. But the column carries TWO meanings and nothing distinguishes them, so the app renders
-- a defaulted truck identically to an assigned one.
--
--     live visits                                    1,652
--     stored vehicle_id NULL                           780
--       ...of which STILL DISPLAY a truck              740   <- 45% of the whole board
--
-- The trucks are named Moises / David / Cloggy / Goliath, human first names, so there is no visual
-- tell. On 2026-07-30 this cost real data integrity: visit 6041 displayed "Moises", its stored
-- vehicle_id was NULL, and it was "restored" to the wrong value on the strength of that display.
--
-- WHAT THIS DOES NOT DO. It does not remove or weaken the default-trucks feature, does not write
-- defaults into public.visits, does not touch service_line_items.default_vehicle_id, and does not
-- change the meaning of `vehicle_id` or `truck_name`. The truck filter still returns the same rows.
-- Every existing consumer keeps working unchanged.
--
-- ⚠ WHY THE COLUMNS GO AT THE END AND NOT NEXT TO truck_name. `CREATE OR REPLACE VIEW` can ONLY
-- append. Verified by a rolled-back probe on throwaway scratch objects: renaming a view column,
-- inserting one mid-list, and retyping one all fail with SQLSTATE 42P16 "cannot change name of view
-- column"; appending succeeds EVEN WITH A DEPENDENT VIEW PRESENT. So the dependent is not the
-- constraint, the CREATE OR REPLACE contract is. Putting these next to `truck_name` at attnum 49 is
-- the intuitive placement and it simply fails.
--
-- 🛑 AND THE ONE THAT WOULD HAVE BEEN SILENT: do NOT "fix" this by redefining `vehicle_id` to mean
-- the stored value. Postgres would ACCEPT that (same name, same type, same position) and 740 visits
-- would lose their truck with no error, while the truck filter quietly dropped 45% of the board.
--
-- ⚠ DO NOT add `WITH (security_invoker = true)`. `reloptions` is NULL today and must stay NULL: the
-- view runs as postgres (which holds rolbypassrls), and 8 RLS policies across `visits` and `clients`
-- (both FORCE ROW LEVEL SECURITY) would suddenly engage. Rows would vanish with no error.
--
-- ⚠ DO NOT use DROP VIEW ... CASCADE. It would drop public.client_services_flat AND
-- client.client_services_flat (the Client App reads the latter) and discard three ACLs.
--
-- PERFORMANCE: FREE, and measured rather than assumed. Both new expressions read values already
-- materialised for existing columns (`v.vehicle_id` is a base-table column; `effv.vehicle_id` is
-- already computed for attnum 5), so no subquery is added and the plan does not change.
-- EXPLAIN (ANALYZE, BUFFERS) over the full vehicle+driver lateral chain, all 1,652 live visits,
-- three runs, minimum taken:
--     today's shape                     31.18 ms   13,185 shared buffer hits
--     with these two columns            31.34 ms   13,185 shared buffer hits
--     (REJECTED) split-lateral variant  88.37 ms   36,599 shared buffer hits
-- 🛑 DO NOT SPLIT THE effv/fa LATERALS to expose visit-level vs job-level separately. Emitting each
-- COALESCE branch as its own output column defeats short-circuiting across five correlated
-- subqueries, including an inspections ORDER BY ... LIMIT 1 that today never runs for the 727 visits
-- resolved by crew. That is 2.8x the time and 2.8x the buffer reads on the hottest read path in the
-- app, bought to populate a distinction no consumer reads.
--
-- NO driver_source COLUMN, DELIBERATELY. Driver provenance is ALREADY computable from existing
-- columns: `assigned_driver_id IS NULL AND driver_id IS NOT NULL` = 728 derived, and
-- `assigned_driver_id IS NOT NULL AND driver_id = assigned_driver_id` = 247 stored, with 0 rows
-- where a derived driver shadows a stored one. A column would add nothing.
-- ⚠ But note the ASYMMETRY, because it is a live trap: the two chains have OPPOSITE precedence.
--     vehicle:  COALESCE(v.vehicle_id, defaults...)   STORED first
--     driver:   COALESCE(emp.id, asg.id)              DERIVED first
-- Do not infer one from the other. Reversing the driver order is a behaviour change and is Fred's
-- call, tracked as Visit Calendar known-issue #0000 (a2).
--
-- Baseline body captured before this change and committed alongside it:
--   docs/migrations/_baseline/2026-07-30_v_calendar_visit.before.sql   (203 lines, 12,780 chars)
-- The body below is that file verbatim, with a comma added to the `service_label` line and six
-- lines appended. Diff the two to confirm nothing else moved.
--
-- Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>

BEGIN;

CREATE OR REPLACE VIEW ops.v_calendar_visit AS
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
                  WHERE visits.visit_status = 'completed'::text AND (visits.service_type = ANY (ARRAY['GT'::text, 'CL'::text, 'WD'::text]))) gaps
          WHERE gaps.days_since_prev >= 5 AND gaps.days_since_prev <= 200
          GROUP BY gaps.client_id, gaps.service_type
        ), observed_price AS (
         SELECT v_1.client_id,
            v_1.service_type,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (li.total_price::double precision))::numeric(12,2) AS median_line_price
           FROM visits v_1
             JOIN line_items li ON li.invoice_id = v_1.invoice_id
          WHERE v_1.invoice_id IS NOT NULL AND v_1.visit_status = 'completed'::text AND (v_1.service_type = ANY (ARRAY['GT'::text, 'CL'::text, 'WD'::text])) AND li.total_price > 0::numeric
          GROUP BY v_1.client_id, v_1.service_type
        ), observed_job_cadence AS (
         SELECT gaps.job_id,
            percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (gaps.days_since_prev::double precision))::integer AS median_gap_days
           FROM ( SELECT visits.job_id,
                    visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.job_id ORDER BY visits.visit_date) AS days_since_prev
                   FROM visits
                  WHERE visits.visit_status = 'completed'::text AND (visits.service_type = ANY (ARRAY['GT'::text, 'CL'::text, 'WD'::text]))) gaps
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
    COALESCE(prop.access_hours_start, primary_prop.access_hours_start) AS access_hours_start,
    COALESCE(prop.access_hours_end, primary_prop.access_hours_end) AS access_hours_end,
    COALESCE(prop.access_days, primary_prop.access_days) AS access_days,
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
    COALESCE(( SELECT (array_agg(sli.service_kind ORDER BY (NOT sli.schedulable), sli.code) FILTER (WHERE sli.service_kind IS NOT NULL))[1] AS array_agg
           FROM line_items li
             JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text)
          WHERE li.visit_id = v.id), ( SELECT (array_agg(sli.service_kind ORDER BY (NOT sli.schedulable), sli.code) FILTER (WHERE sli.service_kind IS NOT NULL))[1] AS array_agg
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
        END AS vehicle_source
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
     LEFT JOIN LATERAL ( SELECT COALESCE(( SELECT (array_agg(ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type) ORDER BY sli.code) FILTER (WHERE ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type) IS NOT NULL))[1] AS grp
                   FROM line_items li3
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li3.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li3.visit_id = v.id AND sli.schedulable = true), ( SELECT (array_agg(ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type) ORDER BY sli.code) FILTER (WHERE ops.fn_service_group(sli.reason, sli.service_kind, sli.service_type) IS NOT NULL))[1] AS grp
                   FROM line_items li3
                     JOIN service_line_items sli ON sli.code = lpad("substring"(btrim(li3.name), '^([0-9]+)'::text), 2, '0'::text)
                  WHERE li3.job_id = v.job_id AND li3.visit_id IS NULL AND li3.invoice_id IS NULL AND sli.schedulable = true)) AS sa_group) sagrp ON true
  WHERE v.deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- Column documentation. This is the only doc a DB reader will actually find.
-- ---------------------------------------------------------------------------

COMMENT ON COLUMN ops.v_calendar_visit.vehicle_id IS
  'EFFECTIVE vehicle: COALESCE(stored visits.vehicle_id, visit-level line-item default, job-level line-item default). Read vehicle_source to learn which branch produced it. For the assignment of record use assigned_vehicle_id. Measured 2026-07-30: 740 of 1652 live rows are a default, not an assignment.';

COMMENT ON COLUMN ops.v_calendar_visit.truck_name IS
  'vehicles.name of the EFFECTIVE vehicle. Never a person, even though the trucks carry human first names (Moises/David/Cloggy/Goliath). Qualify every display of this with vehicle_source.';

COMMENT ON COLUMN ops.v_calendar_visit.assigned_vehicle_id IS
  'public.visits.vehicle_id verbatim. NULL means no truck is assigned to this visit. This is the only column safe to treat as an assignment.';

COMMENT ON COLUMN ops.v_calendar_visit.vehicle_source IS
  'NOT NULL. assigned | default | none. Names which branch produced vehicle_id and truck_name. Only "assigned" is an assignment; "default" is a SERVICE-TYPE default from service_line_items.default_vehicle_id (2026-06-27), which can only ever be Moises(1) or Cloggy(2). Clients MUST treat any unexpected value as "default", i.e. fail toward NOT claiming an assignment.';

-- ---------------------------------------------------------------------------
-- Ship-time assertion. A view cannot carry a CHECK, so the invariant is asserted
-- here instead. Note the POSITIVE CONTROL: a zero bucket means the instrument is
-- untested, not that the board is clean. That distinction is why this raises.
-- ---------------------------------------------------------------------------

DO $$
DECLARE bad int; n_assigned int; n_default int; n_none int;
BEGIN
  SELECT
    count(*) FILTER (WHERE
         vehicle_source IS NULL
      OR vehicle_source NOT IN ('assigned','default','none')
      OR (vehicle_source = 'assigned') <> (assigned_vehicle_id IS NOT NULL)
      OR (vehicle_source = 'none')     <> (vehicle_id IS NULL)
      OR (vehicle_source = 'assigned' AND vehicle_id IS DISTINCT FROM assigned_vehicle_id)
      OR (vehicle_source = 'default'  AND assigned_vehicle_id IS NOT NULL)
      OR (vehicle_source <> 'none'    AND truck_name IS NULL)),
    count(*) FILTER (WHERE vehicle_source = 'assigned'),
    count(*) FILTER (WHERE vehicle_source = 'default'),
    count(*) FILTER (WHERE vehicle_source = 'none')
  INTO bad, n_assigned, n_default, n_none
  FROM ops.v_calendar_visit;

  IF bad > 0 THEN
    RAISE EXCEPTION 'vehicle_source invariant violated on % rows', bad;
  END IF;
  IF n_assigned = 0 OR n_default = 0 THEN
    RAISE EXCEPTION 'POSITIVE CONTROL FAILED (assigned=%, default=%). A zero here means the instrument is untested, not that the board is clean.', n_assigned, n_default;
  END IF;
  RAISE NOTICE 'vehicle_source OK: assigned=% default=% none=% total=%',
    n_assigned, n_default, n_none, n_assigned + n_default + n_none;
END $$;

COMMIT;

-- ⚠ REQUIRED AFTER COMMIT. Without this the new columns are invisible to PostgREST and the app's
-- extended select list returns 400. A first UI test failing for THAT reason looks exactly like
-- "the migration broke the view" and is not.
NOTIFY pgrst, 'reload schema';
