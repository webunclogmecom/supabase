-- 2026-11-13_1115  ops.v_calendar_visit: "Supposed to be" (and the Late chip) anchor on the visit's OWN JOB (Trello #190 3O7jidnM)
--
-- WHY. Fred (Slack #new-app-issues, 2026-11-13, on 034-LG's Nov 19 visit, tooltip "Supposed to be: Dec 3, 2026"):
-- "It says 'Supposed to be' on Dec, but the last visit of that Job we have for that client was done on Oct, and it has a
-- frequency of 30 days, meaning the next visit should be on Nov not Dec."
--
-- ROOT CAUSE, measured. expected_date and late_status both read prev_live: the client's previous completed-or-scheduled,
-- not deleted visit of the same SERVICE TYPE, from ANY job (2026-07-03h). 034-LG's Agreement job #99900615 (30 days) last
-- ran Oct 22; a Service Call job #99900614 pumped Nov 3, so the Agreement's Nov 19 visit anchored on the Service Call:
-- Nov 3 + 30 = Dec 3. By the Agreement's own visits it is Oct 22 + 30 = Nov 21. Per-job anchoring was never weighed in
-- July: the client + service anchor came from the fix for a different problem (a whole forward chain reading late).
--
-- WHAT. Built from the LIVE pg_get_viewdef (md5 2b53615627a7b0ed54bb5dd9ec407259, the 2026-10-29_1700 body as applied), never retyped; ONE
-- anchored edit, asserted to match exactly once: the prev_live subquery becomes
--   COALESCE(<same job AND same service type>, <the old client + same service type subquery, unchanged>)
-- so a visit follows its own job's previous visit, and only a job's FIRST visit (or a visit with no job) falls back to the
-- client's previous visit of that service. Same statuses (completed, scheduled), same deleted_at filter, same "before
-- this visit_date". The frequency, the 000-* rule and both CASE expressions are untouched, so the tooltip and the Late
-- chip still move together (0 rows disagree, before and after). Column list, grants and reloptions unchanged.
-- The fallback keeps what Fred's rule says nothing about: 9 upcoming first visits of a new Agreement keep their date
-- (288-PER: its Service Call Nov 3 + 60 = Jan 2, the visit's own date), and 202-CAP stays Late (last pumped Apr 15).
--
-- REACH, measured 2026-11-13 ~11:10 ET on a TEMP view of this exact body against the live view (scratchpad rehearsal):
--   2,565 rows before = after; every other column identical on every row.
--   expected_date changes on 68 rows, 27 of them upcoming scheduled visits; 0 upcoming lose or gain a date.
--     Kinds: a Service Call of the same service in between (034-LG, 043-MIL, 047-PAM, 055-PV, 061-TCE, 083-SHUL, 089-COW,
--     168-AVA, 221-YAS, 222-SPE, 306-16, 346-VES); two 30-day Agreement jobs at one address that each anchored on the
--     other (031-KRU, 14 visits); an annual job that anchored on another job's cleaning (021-GRA).
--   late_status changes on 4 rows, all upcoming, each now read by the Agreement's own schedule:
--     6609 031-KRU Nov 15  on_time -> will_be_late (its job last ran Oct 14, due Nov 13)
--     6097 061-TCE Nov 18  on_time -> late         (21 days from Oct 21 = Nov 11; a Service Call Oct 29 had hidden it)
--     8789 346-VES Nov 19  on_time -> late         (7 days from Nov 5 = Nov 12; a Service Call Nov 12 had hidden it)
--     7488 021-GRA Feb 26  on_time -> will_be_late (annual from Jan 9 2026 = Jan 8 2027)
--   A rescheduled visit (rolled back: 6010 moved to Dec 1): it keeps Nov 21 and reads will_be_late; the next visit
--   re-anchors on Dec 1 (Dec 31). Month ends add up (Jan 31 + 30 = Mar 2, Feb 28 2028 + 1 = Feb 29).
--   A six-week read (Nov 1 to Dec 12, 238 rows): 19 ms before, 19 ms after (median of 3); visits(job_id) is indexed.
-- Both apps read this column (calendar.unclogme.app and ops.unclogme.app/calendar): no app change, no publish.
-- Not changed: last_completed_date (the "Last completed" line stays the client's last visit of that service, any job),
-- observed_cadence, fn_generate_sa_visits (already per job).
-- Only cheap checks run inside: DDL on this view blocks the Calendar's reads until COMMIT. The whole-view recount runs
-- after commit, read-only: scripts/checks/calendar_expected_date_same_job.sql (it fails on the old body: 68 rows).
-- Rule 8 (audit): a view, nothing to audit. ROLLBACK: 2026-11-13_rollback_calendar_expected_date_same_job.sql

BEGIN;
SET LOCAL lock_timeout = '3s';

do $pin$
begin
  if md5(pg_get_viewdef('ops.v_calendar_visit'::regclass, false)) <> '2b53615627a7b0ed54bb5dd9ec407259' then
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
            COALESCE(( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE ((prev.job_id = v_1.job_id) AND (prev.service_type = v_1.service_type) AND (prev.visit_status = ANY (ARRAY['completed'::text, 'scheduled'::text])) AND (prev.deleted_at IS NULL) AND (prev.visit_date < v_1.visit_date))), ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE ((prev.client_id = v_1.client_id) AND (prev.service_type = v_1.service_type) AND (prev.visit_status = ANY (ARRAY['completed'::text, 'scheduled'::text])) AND (prev.deleted_at IS NULL) AND (prev.visit_date < v_1.visit_date)))) AS prev_live_date
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
    gp.permits AS gdo_permits,
        CASE
            WHEN ((v.vehicle_id IS NOT NULL) OR (effv.vehicle_id IS NULL)) THEN NULL::text
            WHEN (ut.vehicle_id IS NOT NULL) THEN 'usual'::text
            ELSE 'service'::text
        END AS default_truck_basis,
        CASE
            WHEN ((v.vehicle_id IS NOT NULL) OR (effv.vehicle_id IS NULL)) THEN NULL::text
            WHEN ((ut.vehicle_id IS NOT NULL) AND ut.tied) THEN format('Usual truck here: %s (tied %s to %s with %s, %s went last).'::text, veh.name, ut.n, ut.n, tw.name, veh.name)
            WHEN ((ut.vehicle_id IS NOT NULL) AND (ut.tot = (1)::numeric)) THEN format('Usual truck here: %s (the last %s visit).'::text, veh.name, lower(v.service_type))
            WHEN (ut.vehicle_id IS NOT NULL) THEN format('Usual truck here: %s, %s of the last %s %s visits.'::text, veh.name, ut.n, ut.tot, lower(v.service_type))
            WHEN ((v.visit_status = 'scheduled'::text) AND (v.visit_date >= ((now() AT TIME ZONE 'America/New_York'::text))::date) AND (v.property_id IS NOT NULL) AND (v.service_type IS NOT NULL)) THEN format('Defaults to %s from the service line items (no earlier %s visit here to go by).'::text, veh.name, lower(v.service_type))
            ELSE format('Defaults to %s from the service line items.'::text, veh.name)
        END AS default_truck_reason
   FROM (((((((((((((((((((((visits v
     JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties prop ON ((prop.id = v.property_id)))
     LEFT JOIN properties primary_prop ON (((primary_prop.client_id = v.client_id) AND (primary_prop.is_primary = true))))
     LEFT JOIN zones pz ON ((pz.id = prop.zone_id)))
     LEFT JOIN zones ppz ON ((ppz.id = primary_prop.zone_id)))
     LEFT JOIN v_client_agreement_services sc ON (((sc.client_id = v.client_id) AND (sc.service_type = v.service_type))))
     LEFT JOIN LATERAL ( SELECT COALESCE(jsonb_agg(jsonb_build_object('gdo_id', g.id, 'gdo_number', g.gdo_number, 'expiration', g.permit_expiration, 'max_frequency_days', g.max_frequency_days, 'document_path', g.permit_document_path, 'location', cl.name) ORDER BY (g.gdo_number COLLATE "C")), '[]'::jsonb) AS permits
           FROM (gdos g
             LEFT JOIN client_locations cl ON ((cl.id = g.client_location_id)))
          WHERE ((g.client_id = v.client_id) AND (g.status = 'ACTIVE'::text) AND (g.gdo_number ~ '^GDO-[0-9]+$'::text))) gp ON (true))
     LEFT JOIN LATERAL ( SELECT c_1.vehicle_id,
            c_1.n,
            c_1.tot,
            (c_1.next_n = c_1.n) AS tied,
            c_1.next_vehicle_id AS tied_with
           FROM ( SELECT g.vehicle_id,
                    g.n,
                    sum(g.n) OVER () AS tot,
                    lead(g.n) OVER (ORDER BY g.n DESC, g.last_rk) AS next_n,
                    lead(g.vehicle_id) OVER (ORDER BY g.n DESC, g.last_rk) AS next_vehicle_id,
                    row_number() OVER (ORDER BY g.n DESC, g.last_rk) AS pos
                   FROM ( SELECT h.vehicle_id,
                            count(*) AS n,
                            min(h.rk) AS last_rk
                           FROM ( SELECT hv.vehicle_id,
                                    row_number() OVER (ORDER BY hv.visit_date DESC, hv.id DESC) AS rk
                                   FROM (visits hv
                                     JOIN vehicles htr ON (((htr.id = hv.vehicle_id) AND (htr.status = 'ACTIVE'::text))))
                                  WHERE ((v.vehicle_id IS NULL) AND (v.visit_status = 'scheduled'::text) AND (v.visit_date >= ((now() AT TIME ZONE 'America/New_York'::text))::date) AND (hv.property_id = v.property_id) AND (hv.service_type = v.service_type) AND (hv.deleted_at IS NULL) AND (hv.visit_status = 'completed'::text))
                                  ORDER BY hv.visit_date DESC, hv.id DESC
                                 LIMIT 6) h
                          GROUP BY h.vehicle_id) g) c_1
          WHERE (c_1.pos = 1)) ut ON (true))
     LEFT JOIN LATERAL ( SELECT COALESCE(v.vehicle_id, ut.vehicle_id, ( SELECT min(sli.default_vehicle_id) AS min
                   FROM (line_items li2
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE (li2.visit_id = v.id)), ( SELECT min(sli.default_vehicle_id) AS min
                   FROM (line_items li2
                     JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li2.name), '^([0-9]+)'::text), 2, '0'::text))))
                  WHERE ((li2.job_id = v.job_id) AND (li2.visit_id IS NULL) AND (li2.invoice_id IS NULL)))) AS vehicle_id) effv ON (true))
     LEFT JOIN vehicles veh ON ((veh.id = effv.vehicle_id)))
     LEFT JOIN vehicles tw ON ((tw.id = ut.tied_with)))
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

do $verify$
declare v_n int; v_acl text; v_e date; v_l text;
begin
  -- shape and rights unchanged
  select count(*) into v_n from pg_attribute where attrelid = 'ops.v_calendar_visit'::regclass and attnum > 0 and not attisdropped;
  if v_n <> 76 then raise exception 'VERIFY 1: % columns, expected 76', v_n; end if;
  if (select reloptions from pg_class where oid = 'ops.v_calendar_visit'::regclass) is not null then
    raise exception 'VERIFY 2: reloptions set';
  end if;
  select relacl::text into v_acl from pg_class where oid = 'ops.v_calendar_visit'::regclass;
  if v_acl not like '%authenticated=r/postgres%' or v_acl not like '%service_role=r/postgres%' or v_acl like '%anon%' then
    raise exception 'VERIFY 3: acl %', v_acl;
  end if;
  -- the reported case: 034-LG Nov 19 Agreement visit anchors on its own job's Oct 22 visit, not the Nov 3 Service Call
  select expected_date, late_status into v_e, v_l from ops.v_calendar_visit where id = 6010;
  if v_e is distinct from date '2026-11-21' then raise exception 'VERIFY 4: 6010 expected_date %, expected 2026-11-21', v_e; end if;
  -- the chain after it is unchanged (Dec 19 anchors on Nov 19)
  select expected_date into v_e from ops.v_calendar_visit where id = 6011;
  if v_e is distinct from date '2026-12-19' then raise exception 'VERIFY 5: 6011 expected_date %, expected 2026-12-19', v_e; end if;
  -- two Agreement jobs at one address (031-KRU): each follows its own job
  select expected_date into v_e from ops.v_calendar_visit where id = 6845;
  if v_e is distinct from date '2026-11-27' then raise exception 'VERIFY 6: 6845 expected_date %, expected 2026-11-27', v_e; end if;
  -- a job's first visit keeps the client fallback (288-PER: Service Call Nov 3 + 60)
  select expected_date into v_e from ops.v_calendar_visit where id = 9092;
  if v_e is distinct from date '2027-01-02' then raise exception 'VERIFY 7: 9092 expected_date %, expected 2027-01-02', v_e; end if;
  -- the tooltip and the Late chip still agree (cheap window; the whole view is compared after commit)
  select count(*) into v_n from ops.v_calendar_visit
   where visit_date between date '2026-11-01' and date '2027-01-31'
     and expected_date is not null and late_status is not null
     and late_status <> case when expected_date < current_date then 'late' when expected_date < visit_date then 'will_be_late' else 'on_time' end;
  if v_n <> 0 then raise exception 'VERIFY 8: % rows where late_status and expected_date disagree', v_n; end if;
end
$verify$;

COMMIT;
