-- =====================================================================
-- 2026-08-03_1545  PHASE C2 (CONTRACT, part 2) — drop service_line_items.service_kind
-- =====================================================================
-- WHY
--   Fred: "is this to remove service_kind and make it service_type correct?"
--   then "let's do phase C then". Phase B set service_line_items.service_type =
--   service_kind on all 28 rows, so the two columns have been byte-identical
--   since. This removes the duplicate. The real hazard it retires is
--   DIVERGENCE: two columns holding the same fact can be updated independently
--   and then silently disagree, and nothing in the schema would notice.
--
-- 🛑 THE NAME COLLISION THAT MAKES A MECHANICAL REWRITE DANGEROUS
--   A catalogue sweep says 10 objects "reference service_kind". THREE are FALSE
--   POSITIVES: derm.v_stamp_unlinked_visits, derm.v_stamp_row_candidate_visits
--   and ops.v_calendar_visit_detail each build their OWN service_kind via a CASE
--   returning 'SA'/'SC'. They never touch the catalogue column.
--   ops.v_calendar_visit does BOTH — it reads sli.service_kind eight times AND
--   emits its own SA/SC column of the same name. A blind find-and-replace would
--   have destroyed the SA/SC classifier in four views, and the Visit Calendar
--   equality-filters on it.
--   ⇒ Only `sli.`-QUALIFIED references were rewritten, plus three explicitly
--     inspected unqualified ones. Every count asserted at generation time, with
--     a negative control that no sli.service_kind survives.
--
-- OBJECTS REWRITTEN (7 — not the 10 a name sweep reports):
--   client.service_line_items, ops.service_line_items  — passthrough catalogue views
--   ops.service_options                                — level2 came from the kind
--   customer.work_orders            (2 refs)  — CUSTOMER-FACING
--   ops.client_service_options      (3 refs)  — Client App job editor payload
--   ops.v_calendar_visit            (8 refs)  — Calendar cadence / chips / label
--   public.fn_generate_sa_visits    (3 refs)  — the SA generator
--
-- ⚠ OUTPUT COLUMN NAMES ARE DELIBERATELY UNCHANGED. The two passthrough views
--   still emit a column called `service_kind`, now sourced from service_type,
--   and ops.client_service_options still ships a `service_kind` JSON key. That
--   keeps every app working with no republish. It does mean the APP-FACING
--   surface does NOT get simpler today — only the base table does. Retiring the
--   app-facing name is a separate, app-coordinated change.
--
-- PROOF: this is a pure source swap between two columns already holding
--   identical values, so EVERY dependent view must be byte-identical before and
--   after. The rehearsal asserts exactly that, key-by-key via to_jsonb. The only
--   intended observable is the dropped column itself.
--
-- AUDIT OPT-IN (rule #8): no new table. public.service_line_items is a 28-row
--   reference catalogue with no audit trigger; unchanged by this migration.
--
-- 🛑 NOT REVERSIBLE BY RE-RUNNING AN EARLIER FILE. Restoring requires re-adding
--   the column and repopulating it:
--     alter table public.service_line_items add column service_kind text;
--     update public.service_line_items set service_kind = service_type;
--   plus reverting the 7 objects to their pre-C2 definitions (in git, set by
--   2026-08-03_1745_service_type_phaseB_migrate.sql).
-- =====================================================================

begin;

set local search_path = public;

-- GUARD: refuse unless the two columns are still identical. If they have
-- diverged, dropping one silently discards whichever fact was right.
do $$
declare n int;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='service_line_items'
                    and column_name='service_kind') then
    raise exception 'service_kind is already gone — Phase C2 appears to have run. Refusing.';
  end if;
  select count(*) into n from public.service_line_items
   where service_type is distinct from service_kind;
  if n > 0 then
    raise exception 'REFUSING: % catalogue row(s) have service_type <> service_kind. They have diverged; reconcile before dropping.', n;
  end if;
end $$;

create or replace view client.service_line_items as
SELECT id,
    code,
    title,
    requires_derm,
    reason,
    service_type AS service_kind,
    location_target,
    method,
    service_type,
    schedulable,
    active,
    created_at,
    updated_at,
    unit_price,
    default_vehicle_id
   FROM service_line_items;

create or replace view ops.service_line_items as
SELECT id,
    code,
    title,
    requires_derm,
    reason,
    service_type AS service_kind,
    location_target,
    method,
    service_type,
    schedulable,
    active,
    created_at,
    updated_at,
    unit_price
   FROM service_line_items;

create or replace view ops.service_options as
SELECT id,
    code,
    title,
    requires_derm,
    service_type,
        CASE
            WHEN (reason = ANY (ARRAY['Service Agreement'::text, 'Service Call'::text])) THEN reason
            ELSE regexp_replace(title, '^[0-9]+ - '::text, ''::text)
        END AS level1,
        CASE
            WHEN (reason = ANY (ARRAY['Service Agreement'::text, 'Service Call'::text])) THEN service_type
            ELSE NULL::text
        END AS level2,
        CASE
            WHEN (location_target IS NOT NULL) THEN (location_target || COALESCE((' - '::text || method), ''::text))
            ELSE NULL::text
        END AS level3
   FROM service_line_items
  WHERE (active = true);

create or replace view customer.work_orders as
SELECT v.public_id AS id,
    customer.uuid_from_bigint(v.client_id) AS client_id,
    v.visit_date,
        CASE
            WHEN (v.start_at IS NOT NULL) THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text)
            ELSE NULL::text
        END AS visit_time,
    COALESCE(( SELECT string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS string_agg
           FROM (visit_assignments va
             JOIN employees e ON ((e.id = va.employee_id)))
          WHERE (va.visit_id = v.id)), ( SELECT string_agg(e2.full_name, ', '::text ORDER BY e2.full_name) AS string_agg
           FROM (visit_team vt
             JOIN employees e2 ON ((e2.id = vt.employee_id)))
          WHERE (vt.visit_id = v.id))) AS driver,
    veh.name AS truck,
    ( SELECT vd.decal_number
           FROM (((manifest_visits mv
             JOIN derm_manifests dm_1 ON (((dm_1.id = mv.manifest_id) AND (dm_1.deleted_at IS NULL))))
             JOIN disposal_facilities df ON ((df.id = dm_1.disposal_facility_id)))
             JOIN vehicle_decals vd ON (((vd.vehicle_id = veh.id) AND (vd.jurisdiction = df.county) AND (vd.status = 'ACTIVE'::text))))
          WHERE (mv.visit_id = v.id)
         LIMIT 1) AS decal,
    COALESCE(v.manhole_count, NULLIF(prop.grease_trap_manhole_count, 0), NULLIF(( SELECT prim.grease_trap_manhole_count
           FROM properties prim
          WHERE ((prim.client_id = v.client_id) AND (prim.is_primary = true))
         LIMIT 1), 0)) AS manholes,
    v.manhole_breakdown,
    v.ticket_number,
    v.trap_condition_notes AS trap_condition,
    (row_number() OVER (PARTITION BY v.client_id, (EXTRACT(year FROM v.visit_date)) ORDER BY v.visit_date))::integer AS visit_num,
    ( SELECT
                CASE
                    WHEN ((sc.frequency_days IS NULL) OR (sc.frequency_days <= 0)) THEN NULL::integer
                    ELSE (GREATEST((1)::numeric, round((365.0 / (sc.frequency_days)::numeric))))::integer
                END AS "greatest"
           FROM service_configs sc
          WHERE ((sc.client_id = v.client_id) AND (sc.service_type = v.service_type))
         LIMIT 1) AS visit_total,
    NULL::text AS notes,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS derm_manifest_number,
    rd.url AS derm_manifest_url,
    COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number, dm.yellow_ticket_number) AS wwtp_receipt_number,
        CASE
            WHEN (rc.class = 'receipt'::text) THEN dm.derm_manifest_url
            ELSE NULL::text
        END AS wwtp_receipt_url,
    dm.wwtp_ticket_number,
    v.created_at,
    COALESCE(v.completed_at, v.created_at) AS updated_at,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS manifest_number,
        CASE
            WHEN (dm.yellow_ticket_number IS NOT NULL) THEN 'broward'::text
            WHEN ((dm.white_manifest_number IS NOT NULL) AND (length(dm.white_manifest_number) >= 5)) THEN 'dade'::text
            ELSE NULL::text
        END AS manifest_jurisdiction,
    dm.id AS manifest_id,
    COALESCE(NULLIF(prop.sample_port_count, 0), NULLIF(( SELECT prim.sample_port_count
           FROM properties prim
          WHERE ((prim.client_id = v.client_id) AND (prim.is_primary = true))
         LIMIT 1), 0)) AS sample_ports,
    ( SELECT df.name
           FROM disposal_facilities df
          WHERE (df.id = dm.disposal_facility_id)) AS disposal_facility,
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE ((li.visit_id = v.id) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))), ( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL) AND (li.quote_id IS NULL) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))), ARRAY[]::text[]) AS services,
    ( SELECT df2.county
           FROM disposal_facilities df2
          WHERE (df2.id = dm.disposal_facility_id)) AS disposal_county,
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE ((li.visit_id = v.id) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))), ( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL) AND (li.quote_id IS NULL) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))), ARRAY[]::text[]) AS service_items,
    COALESCE(( SELECT array_agg(DISTINCT lbl.label) AS array_agg
           FROM ( SELECT COALESCE(sli.service_type,
                        CASE
                            WHEN (x.nm ~* 'unclog'::text) THEN 'Unclogging'::text
                            WHEN (x.nm ~* 'pump'::text) THEN 'Pumping'::text
                            WHEN (x.nm ~* 'hydrojet'::text) THEN 'Cleaning'::text
                            WHEN (x.nm ~* '^camera inspection'::text) THEN 'Camera Inspection'::text
                            WHEN (x.nm ~* 'dye test'::text) THEN 'Dye Test'::text
                            WHEN (x.nm ~* 'assessment'::text) THEN 'Assessment'::text
                            ELSE NULL::text
                        END) AS label
                   FROM (( SELECT TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) AS nm,
                            lpad("substring"(TRIM(BOTH FROM li.name), '^([0-9]+)'::text), 2, '0'::text) AS code
                           FROM line_items li
                          WHERE ((li.visit_id = v.id) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))) x
                     LEFT JOIN service_line_items sli ON ((sli.code = x.code)))) lbl
          WHERE (lbl.label IS NOT NULL)), ( SELECT array_agg(DISTINCT lbl.label) AS array_agg
           FROM ( SELECT COALESCE(sli.service_type,
                        CASE
                            WHEN (x.nm ~* 'unclog'::text) THEN 'Unclogging'::text
                            WHEN (x.nm ~* 'pump'::text) THEN 'Pumping'::text
                            WHEN (x.nm ~* 'hydrojet'::text) THEN 'Cleaning'::text
                            WHEN (x.nm ~* '^camera inspection'::text) THEN 'Camera Inspection'::text
                            WHEN (x.nm ~* 'dye test'::text) THEN 'Dye Test'::text
                            WHEN (x.nm ~* 'assessment'::text) THEN 'Assessment'::text
                            ELSE NULL::text
                        END) AS label
                   FROM (( SELECT TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) AS nm,
                            lpad("substring"(TRIM(BOTH FROM li.name), '^([0-9]+)'::text), 2, '0'::text) AS code
                           FROM line_items li
                          WHERE ((li.job_id = v.job_id) AND (li.visit_id IS NULL) AND (li.invoice_id IS NULL) AND (li.quote_id IS NULL) AND (li.name IS NOT NULL) AND (TRIM(BOTH FROM li.name) <> ''::text) AND (li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text))) x
                     LEFT JOIN service_line_items sli ON ((sli.code = x.code)))) lbl
          WHERE (lbl.label IS NOT NULL)), ARRAY[]::text[]) AS service_type
   FROM (((((visits v
     LEFT JOIN vehicles veh ON ((veh.id = v.vehicle_id)))
     LEFT JOIN properties prop ON ((prop.id = v.property_id)))
     LEFT JOIN LATERAL ( SELECT dm_inner.id,
            dm_inner.client_id,
            dm_inner.service_date,
            dm_inner.dump_ticket_date,
            dm_inner.white_manifest_number,
            dm_inner.yellow_ticket_number,
            dm_inner.sent_to_client,
            dm_inner.sent_to_city,
            dm_inner.created_at,
            dm_inner.updated_at,
            dm_inner.wwtp_receipt_number,
            dm_inner.wwtp_receipt_document_path,
            dm_inner.wwtp_ticket_number,
            dm_inner.disposal_facility_id,
            dm_inner.derm_manifest_url,
            dm_inner.derm_address_url,
            dm_inner.fog_manifest_url,
            dm_inner.gdo_id
           FROM (derm_manifests dm_inner
             JOIN manifest_visits mv ON ((mv.manifest_id = dm_inner.id)))
          WHERE ((mv.visit_id = v.id) AND (dm_inner.deleted_at IS NULL))
          ORDER BY dm_inner.service_date DESC NULLS LAST
         LIMIT 1) dm ON (true))
     LEFT JOIN derm.redacted_manifest_docs rd ON (((rd.manifest_id = dm.id) AND (rd.client_id = v.client_id))))
     LEFT JOIN derm.receipt_doc_class rc ON ((rc.url = dm.derm_manifest_url)))
  WHERE ((v.visit_status = 'completed'::text) AND (v.client_id IS NOT NULL) AND (COALESCE(v.derm_required, true) = true) AND (v.deleted_at IS NULL));

create or replace view ops.client_service_options as
SELECT c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    j.id AS job_id,
    j.job_number,
        CASE
            WHEN (j.title ~~* 'Service Agreement%'::text) THEN 'SA'::text
            ELSE 'SC'::text
        END AS job_kind,
    j.title AS job_title,
    j.frequency_days,
    j.property_id,
    COALESCE(svc.services, '[]'::json) AS services,
    svc.primary_group AS job_service_group
   FROM ((jobs j
     JOIN clients c ON ((c.id = j.client_id)))
     LEFT JOIN LATERAL ( SELECT json_agg(json_build_object('service_line_item_id', sli.id, 'code', sli.code, 'title', sli.title, 'requires_derm', sli.requires_derm, 'service_type', sli.service_type, 'service_kind', sli.service_type, 'service_group', ops.fn_service_group(sli.reason, sli.service_type, sli.location_target), 'unit_price', li.unit_price) ORDER BY sli.code) AS services,
            (array_agg(ops.fn_service_group(sli.reason, sli.service_type, sli.location_target) ORDER BY sli.code))[1] AS primary_group
           FROM (line_items li
             JOIN service_line_items sli ON ((sli.code = lpad("substring"(btrim(li.name), '^([0-9]+)'::text), 2, '0'::text))))
          WHERE ((li.job_id = j.id) AND (sli.schedulable = true))) svc ON (true))
  WHERE ((j.job_status <> 'archived'::text) AND ((j.title IS NULL) OR (j.title !~~* '%[OLD]%'::text)));

create or replace view ops.v_calendar_visit as
WITH last_completed AS (
         SELECT v_1.id AS visit_id,
            ( SELECT max(prev.visit_date) AS max
                   FROM visits prev
                  WHERE ((prev.client_id = v_1.client_id) AND (prev.service_type = v_1.service_type) AND (prev.visit_status = 'completed'::text) AND (prev.visit_date < v_1.visit_date))) AS last_completed_date
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
                  WHERE ((visits.visit_status = 'completed'::text) AND (visits.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text])))) gaps
          WHERE ((gaps.days_since_prev >= 5) AND (gaps.days_since_prev <= 200))
          GROUP BY gaps.client_id, gaps.service_type
        ), observed_price AS (
         SELECT v_1.client_id,
            v_1.service_type,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((li.total_price)::double precision)))::numeric(12,2) AS median_line_price
           FROM (visits v_1
             JOIN line_items li ON ((li.invoice_id = v_1.invoice_id)))
          WHERE ((v_1.invoice_id IS NOT NULL) AND (v_1.visit_status = 'completed'::text) AND (v_1.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text])) AND (li.total_price > (0)::numeric))
          GROUP BY v_1.client_id, v_1.service_type
        ), observed_job_cadence AS (
         SELECT gaps.job_id,
            (percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((gaps.days_since_prev)::double precision)))::integer AS median_gap_days
           FROM ( SELECT visits.job_id,
                    (visits.visit_date - lag(visits.visit_date) OVER (PARTITION BY visits.job_id ORDER BY visits.visit_date)) AS days_since_prev
                   FROM visits
                  WHERE ((visits.visit_status = 'completed'::text) AND (visits.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text, 'Warranty of Drainage'::text])))) gaps
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
    COALESCE(prop.access_hours_start, primary_prop.access_hours_start) AS access_hours_start,
    COALESCE(prop.access_hours_end, primary_prop.access_hours_end) AS access_hours_end,
    COALESCE(prop.access_days, primary_prop.access_days) AS access_days,
    COALESCE(prop.latitude, primary_prop.latitude) AS latitude,
    COALESCE(prop.longitude, primary_prop.longitude) AS longitude,
    COALESCE(prop.grease_trap_manhole_count, primary_prop.grease_trap_manhole_count) AS manholes,
        CASE
            WHEN (c.client_code ~~ '000-%'::text) THEN NULLIF(jb.frequency_days, 0)
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
        END AS vehicle_source
   FROM ((((((((((((((((((((visits v
     JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties prop ON ((prop.id = v.property_id)))
     LEFT JOIN properties primary_prop ON (((primary_prop.client_id = v.client_id) AND (primary_prop.is_primary = true))))
     LEFT JOIN zones pz ON ((pz.id = prop.zone_id)))
     LEFT JOIN zones ppz ON ((ppz.id = primary_prop.zone_id)))
     LEFT JOIN service_configs sc ON (((sc.client_id = v.client_id) AND (sc.service_type = v.service_type))))
     LEFT JOIN LATERAL ( SELECT fn_resolve_gdo_id(v.client_id, v.property_id, v.id) AS gdo_id) r ON (true))
     LEFT JOIN gdos g ON ((g.id = r.gdo_id)))
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

CREATE OR REPLACE FUNCTION public.fn_generate_sa_visits(p_client_id bigint DEFAULT NULL::bigint, p_horizon_months integer DEFAULT 6, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c_today       date := (now() at time zone 'America/New_York')::date;
  c_horizon_end date := (date_trunc('month', (now() at time zone 'America/New_York')::date)
                         + make_interval(months => p_horizon_months + 1) - interval '1 day')::date;
  c_tolerance   int  := 7;
  c_max_per_job int  := 24;
  c_max_cleanup int  := 40;
  v_planned     jsonb := '[]'::jsonb;
  v_skipped     jsonb := '[]'::jsonb;
  v_inserted    int := 0;
  v_stale_ids   bigint[];
  v_cleaned     int := 0;
  v_cleanup_note text := null;
  v_scope_note  text := null;
  v_run_started timestamptz := clock_timestamp();
  v_n_jobs      int := 0;
begin
  drop table if exists _sa_jobs;
  drop table if exists _sa_candidates;

  create temp table _sa_jobs on commit drop as
  with jobs_in_scope as (
    select j.id           as job_id,
           j.job_number,
           j.title,
           j.frequency_days,
           j.start_at,
           c.id           as client_id,
           c.client_code,
           c.name         as client_name,
           bool_or(public.fn_line_item_requires_derm(li.name)) as derm_required,
           -- The CANONICAL taxonomy. As of 2026-08-03 service_kind and
           -- service_type hold the same values, so there is nothing to convert.
           (select sli.service_type
              from public.line_items l2
              join public.service_line_items sli
                on sli.code = lpad(substring(btrim(l2.name) from '^([0-9]+)'), 2, '0')
             where l2.job_id = j.id and l2.invoice_id is null and sli.service_type is not null
             order by case sli.service_type
                        when 'Pumping' then 1 when 'Cleaning' then 2
                        when 'Warranty of Drainage' then 3 else 4 end
             limit 1) as service_kind
      from public.jobs j
      join public.clients c on c.id = j.client_id
      left join public.line_items li on li.job_id = j.id and li.invoice_id is null
     where j.frequency_days > 0
       and j.title ilike 'Service Agreement%'
       and j.title not ilike '%[OLD]%'
       and coalesce(j.job_status,'') <> 'archived'
       and c.status = 'RECURRING'
       and c.client_code is not null
       and c.client_code not in ('112-YA','777-YA','000-DH','000-HS')
       and exists (
         select 1 from public.line_items lp
          join public.service_line_items slip
            on slip.code = lpad(substring(btrim(lp.name) from '^([0-9]+)'), 2, '0')
          where lp.job_id = j.id and lp.invoice_id is null
            and slip.reason in ('Service Agreement','Service Call') and slip.code <> '08')
       and (p_client_id is null or c.id = p_client_id)
     group by j.id, j.job_number, j.title, j.frequency_days, j.start_at,
              c.id, c.client_code, c.name
  ),
  typed as (
    -- 2026-08-03: the legacy down-conversion (Pumping to GT etc., with an
    -- else-GT fallback that could mislabel) is GONE. The kind IS the type.
    select s.*, s.service_kind as service_type
      from jobs_in_scope s
  )
  select t.*,
         st.max_future,
         st.n_visits,
         lc.last_completed,
         case
           when st.max_future    is not null then st.max_future    + t.frequency_days
           when lc.last_completed is not null then lc.last_completed + t.frequency_days
           when t.start_at       is not null then (t.start_at at time zone 'America/New_York')::date
           else c_today + t.frequency_days
         end as anchor,
         case
           when st.max_future     is not null then 'job_scheduled+freq'
           when lc.last_completed is not null then 'client_completed+freq'
           when t.start_at        is not null then 'job_start_at'
           else 'today+freq'
         end as anchor_src
    from typed t
    left join lateral (
      select max(v.visit_date) filter (
               where v.visit_status = 'scheduled' and v.visit_date >= c_today) as max_future,
             count(*) as n_visits
        from public.visits v
       where v.job_id = t.job_id and v.deleted_at is null
    ) st on true
    left join lateral (
      -- same-service anchor (the 178-LG rule): a completed visit of ANOTHER
      -- service must not set this agreement's cadence. Both sides now speak
      -- the new vocabulary.
      select max(v.visit_date) as last_completed
        from public.visits v
       where v.client_id = t.client_id
         and v.visit_status = 'completed'
         and v.service_type = t.service_type
         and v.deleted_at is null
    ) lc on true;

  select count(*) into v_n_jobs from _sa_jobs;

  if p_client_id is not null and v_n_jobs = 0 then
    select case
             when c.id is null then 'That client does not exist.'
             when c.client_code in ('112-YA','777-YA','000-DH','000-HS')
               then 'This is a test/non-serviceable account and is permanently excluded from automatic visit generation.'
             when c.client_code is null
               then 'This client has no client code, so it is excluded from automatic visit generation.'
             when c.status <> 'RECURRING'
               then format('Visits are only generated for RECURRING clients — this one is %s. Set it to Recurring to schedule visits.', c.status)
             when not exists (
                    select 1 from public.jobs j
                     where j.client_id = c.id and j.job_status <> 'archived'
                       and j.title ilike 'Service Agreement%' and j.title not ilike '%[OLD]%')
               then 'This client has no open Service Agreement job, so there is nothing to generate from.'
             when not exists (
                    select 1 from public.jobs j
                     where j.client_id = c.id and j.job_status <> 'archived'
                       and j.title ilike 'Service Agreement%' and coalesce(j.frequency_days,0) > 0)
               then 'This client''s Service Agreement has no frequency set, so no cadence can be generated.'
             else 'This client''s only Service Agreement is billing-only (Warranty of Drainage), which never generates recurring visits.'
           end
      into v_scope_note
      from public.clients c where c.id = p_client_id;
    if v_scope_note is null then v_scope_note := 'That client does not exist.'; end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'job_id', job_id, 'job_number', job_number, 'title', title,
           'client_code', client_code,
           'reason', 'no start date and no visits yet — set a start date to begin scheduling')), '[]'::jsonb)
    into v_skipped
    from _sa_jobs
   where start_at is null and n_visits = 0;

  delete from _sa_jobs where start_at is null and n_visits = 0;

  create temp table _sa_candidates on commit drop as
  select j.*, d::date as visit_date
    from _sa_jobs j
    cross join lateral (
      select d, row_number() over (order by d) as rn
        from generate_series(j.anchor::timestamp,
                             c_horizon_end::timestamp,
                             make_interval(days => j.frequency_days)) as g(d)
       where d::date >= c_today
    ) s
   where s.rn <= c_max_per_job
     and not exists (
       select 1 from public.visits v
        where v.job_id = j.job_id
          and v.deleted_at is null
          and abs(v.visit_date - s.d::date) <= c_tolerance
     );

  select coalesce(jsonb_agg(jsonb_build_object(
           'job_id', job_id, 'job_number', job_number, 'client_code', client_code,
           'anchor', anchor, 'anchor_src', anchor_src, 'visit_date', visit_date,
           'service_kind', service_kind)
           order by client_code, job_number, visit_date), '[]'::jsonb)
    into v_planned
    from _sa_candidates;

  if not p_dry_run then
    insert into public.visits
      (client_id, job_id, visit_date, visit_status, source, title, service_type, derm_required)
    select client_id, job_id, visit_date, 'scheduled', 'supabase_cron',
           client_code || ' ' || client_name || ' - ' || title,
           service_type, derm_required
      from _sa_candidates;
    get diagnostics v_inserted = row_count;
  end if;

  -- CLEANUP — full sweep only, and deliberately still keyed on ACTIVE *or*
  -- RECURRING: it removes visits whose JOB stopped qualifying, never visits
  -- that merely belong to a client who left RECURRING. That transition is the
  -- trigger's job.
  if p_client_id is null then
    select array_agg(v.id) into v_stale_ids
      from public.visits v
     where v.source = 'supabase_cron'
       and v.deleted_at is null
       and v.visit_date >= c_today
       and not exists (
         select 1 from public.jobs j join public.clients c on c.id = j.client_id
          where j.id = v.job_id
            and j.frequency_days > 0
            and j.title ilike 'Service Agreement%'
            and j.title not ilike '%[OLD]%'
            and coalesce(j.job_status,'') <> 'archived'
            and c.status in ('ACTIVE','RECURRING')
            and c.client_code is not null
            and c.client_code not in ('112-YA','777-YA','000-DH','000-HS')
            and exists (
              select 1 from public.line_items lp
               join public.service_line_items slip
                 on slip.code = lpad(substring(btrim(lp.name) from '^([0-9]+)'), 2, '0')
               where lp.job_id = j.id and lp.invoice_id is null
                 and slip.reason in ('Service Agreement','Service Call') and slip.code <> '08'));

    v_cleaned := coalesce(array_length(v_stale_ids, 1), 0);
    if v_cleaned > c_max_cleanup then
      v_cleanup_note := format('ABORTED: %s stale > max %s — likely a bulk data issue, investigate',
                               v_cleaned, c_max_cleanup);
      v_cleaned := 0;
    elsif v_cleaned > 0 and not p_dry_run then
      update public.visits set deleted_at = now() where id = any(v_stale_ids);
    end if;
  end if;

  if not p_dry_run then
    insert into public.sync_log
      (sync_source, started_at, finished_at, rows_inserted, rows_updated,
       rows_errored, duration_seconds, status, details)
    values ('sa-visit-generation',
            v_run_started, clock_timestamp(),
            v_inserted, v_cleaned,
            case when v_cleanup_note is null then 0 else 1 end,
            round(extract(epoch from (clock_timestamp() - v_run_started))::numeric, 3),
            case when v_cleanup_note is null then 'success' else 'warning' end,
            jsonb_build_object(
              'scope',        coalesce(p_client_id::text, 'all'),
              'jobs',         v_n_jobs,
              'generated',    v_inserted,
              'skipped',      jsonb_array_length(v_skipped),
              'cleaned',      v_cleaned,
              'cleanup_note', v_cleanup_note,
              'scope_note',   v_scope_note,
              'horizon_end',  c_horizon_end));
  end if;

  return jsonb_build_object(
    'dry_run',      p_dry_run,
    'scope',        coalesce(p_client_id::text, 'all'),
    'today',        c_today,
    'horizon_end',  c_horizon_end,
    'jobs_considered', v_n_jobs,
    'generated',    case when p_dry_run then jsonb_array_length(v_planned) else v_inserted end,
    'planned',      v_planned,
    'skipped',      v_skipped,
    'scope_note',   v_scope_note,
    'cleaned',      v_cleaned,
    'cleanup_note', v_cleanup_note,
    'ms',           round(extract(epoch from (clock_timestamp() - v_run_started)) * 1000));
end;
$function$;

-- ---------------------------------------------------------------------
-- Drop the duplicate. Every reader above now sources from service_type.
-- ---------------------------------------------------------------------
alter table public.service_line_items drop column service_kind;

-- ---------------------------------------------------------------------
-- ASSERTIONS
-- ---------------------------------------------------------------------
do $$
declare n int; v_grp text;
begin
  -- the column is gone
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='service_line_items'
                and column_name='service_kind') then
    raise exception 'service_kind still exists on the base table';
  end if;

  -- nothing anywhere may still reference the catalogue column.
  -- POSIX class, not a backslash escape: escape-free patterns are immune to
  -- whatever mangles the body in transit (root CLAUDE.md 5.5).
  select count(*) into n from (
    select pg_get_functiondef(p.oid) d from pg_proc p join pg_namespace nn on nn.oid=p.pronamespace
     where nn.nspname not in ('pg_catalog','information_schema') and p.prokind in ('f','p')
    union all
    select definition from pg_views where schemaname not in ('pg_catalog','information_schema')) x
   where d like '%sli.service_kind%';
  if n > 0 then
    raise exception '% object(s) still read sli.service_kind after the drop', n;
  end if;

  -- 🛑 THE NAME-COLLISION CHECK. ops.v_calendar_visit emits its OWN service_kind
  -- (SA/SC) and separately read sli.service_kind eight times. If the rewrite had
  -- confused the two, this column would be empty and the Calendar would filter
  -- on nothing.
  select count(*) into n from ops.v_calendar_visit where service_kind in ('SA','SC');
  if n = 0 then
    raise exception 'ops.v_calendar_visit.service_kind (SA/SC) is empty — the collision destroyed it';
  end if;

  -- the chip discriminator must still work
  select ops.fn_service_group('Service Agreement','Pumping','Grease Trap & Tank Cleaning') into v_grp;
  if v_grp is distinct from 'PUMPING_GT' then
    raise exception 'fn_service_group no longer returns PUMPING_GT (got %)', v_grp;
  end if;
  select count(*) into n from ops.v_calendar_visit where sa_group = 'PUMPING_GT';
  if n = 0 then raise exception 'PUMPING_GT chips are gone'; end if;

  -- the passthrough views must still expose a populated service_kind column
  select count(*) into n from ops.service_line_items where service_kind is not null;
  if n = 0 then raise exception 'ops.service_line_items.service_kind is blank'; end if;
  select count(*) into n from client.service_line_items where service_kind is not null;
  if n = 0 then raise exception 'client.service_line_items.service_kind is blank'; end if;

  -- customer-facing and Client App payloads must still be populated
  select count(*) into n from customer.work_orders where array_length(service_type,1) > 0;
  if n = 0 then raise exception 'customer.work_orders.service_type is blank'; end if;
  select count(*) into n from ops.client_service_options where json_array_length(services) > 0;
  if n = 0 then raise exception 'ops.client_service_options.services is blank'; end if;
  select count(*) into n from ops.service_options where level2 is not null;
  if n = 0 then raise exception 'ops.service_options.level2 is blank'; end if;

  raise notice 'PHASE C2 OK - service_kind dropped, SA/SC intact, chips intact, all payloads populated';
end $$;

commit;
