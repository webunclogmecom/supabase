-- Retire service_configs, part 1 of 2: every reader moves to the agreement (Jobber job)
--
-- Fred, 2026-10-02: "yes we actually are working with the agreement (job) these
-- 'service configs' should be removed then", then "go ahead and build".
-- service_configs has had no writer since 2026-07-14 (app_source sql); the Client App edits
-- jobs.frequency_days. Every frequency / price / last-visit it served was a July snapshot
-- (192-FRK: 30 here, agreement 60). customer.permits already moved off it (2026-10-02_1352).
--
-- 1. Six trap sizes that existed ONLY in service_configs are copied onto the client's live
--    service property (144-LTG 25, 150-KOS 750, 172-NU 380, 198-ARY 1500, 225-PV 2000,
--    229-BAK 500). Pinned to grease_trap_size_gallons IS NULL. properties is audited.
-- 2. NEW public.v_client_agreement_services: one row per (client, service_type), the same
--    grain as service_configs' unique key, exposing the SAME column names and types its
--    readers use, from the truth:
--      frequency_days          live 'Service Agreement%' job (not archived/destroyed, > 0)
--      service_type            the job-scope line item's catalogue code (01-08) -> service_line_items
--      price_per_visit         that line's unit_price, 0 read as unknown (priced per visit)
--      last_visit              last COMPLETED visit of that client + service type (was AT's stale field)
--      equipment_size_gallons  the job property's trap size, else the client's first sized property
--      first_visit, stop_date, material_type   NULL (no source; material was NULL on all 263 rows)
--    Pumping prefers the lowest code (01 grease trap over 03 grey water / 04 lift station).
--    Owner-rights view, read only by the owner-rights views below: anon/authenticated get nothing.
-- 3. The 13 readers swap the relation name, nothing else, so every column list is identical
--    (the Client App reads client_services_flat with select *). One edit beyond the swap:
--    client_services_flat.gt_size_gallons no longer requires a Pumping row (it would blank
--    the size of every client without an agreement).
--
-- Dry run (rolled back) row counts, before -> after: all app views identical; internal lists
-- follow the live agreements: ops.v_derm_compliance 178 -> 152, ops.v_service_due 181 -> 70,
-- public.clients_due_service 147 -> 162. Value changes are corrections: Calendar
-- amount_estimated 459/2233 (agreement prices), FP visit_total 112/830, client_services_flat
-- gt_frequency_days 48/480, gt_last_visit 177/480 (real visits), sizes only blank -> value.
-- LWT gallons: 1 row filled (249-LOU ticket 309898, its only property, 402); gallons_source
-- keeps the value 'service_config_size' for the client-level fallback (bot contract).
--
-- Rule 8: views only, no audit trigger applies; the properties write is audited.
-- DDL locks ops.v_calendar_visit briefly: no heavy VERIFY in this transaction (rule in Supabase CLAUDE.md).

begin;

update public.properties p set grease_trap_size_gallons = v.s
  from (values (120,25),(34,750),(200,380),(173,1500),(191,2000),(1015,500)) v(id, s)
 where p.id = v.id and p.grease_trap_size_gallons is null;

create view public.v_client_agreement_services as
select distinct on (j.client_id, sli.service_type)
       j.id                        as id,
       j.client_id,
       sli.service_type,
       j.frequency_days,
       nullif(li.unit_price, 0)    as price_per_visit,
       (select max(v.visit_date) from public.visits v
         where v.client_id = j.client_id and v.service_type = sli.service_type
           and v.visit_status = 'completed' and v.deleted_at is null) as last_visit,
       coalesce((jp.grease_trap_size_gallons)::numeric,
                (select (p.grease_trap_size_gallons)::numeric from public.properties p
                  where p.client_id = j.client_id and p.deleted_at is null and p.grease_trap_size_gallons > 0
                  order by p.is_primary desc, p.id limit 1)) as equipment_size_gallons,
       j.property_id,
       null::date                  as first_visit,
       null::date                  as stop_date,
       null::text                  as material_type
  from public.jobs j
  join public.line_items li
    on li.job_id = j.id and li.visit_id is null and li.invoice_id is null and li.quote_id is null
  join public.service_line_items sli
    on sli.reason = 'Service Agreement'
   and sli.code = substring(li.name from '^[[:space:]]*([0-9]+)')
  left join public.properties jp on jp.id = j.property_id
 where j.title ilike 'Service Agreement%'
   and j.job_status not in ('archived', 'destroyed')
   and j.frequency_days > 0
 order by j.client_id, sli.service_type, sli.code, j.id desc
;

revoke all on public.v_client_agreement_services from public, anon, authenticated;
grant select on public.v_client_agreement_services to service_role;

create or replace view client.properties as SELECT id,
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
    fn_sched_open(access_schedule) AS access_hours_start,
    fn_sched_close(access_schedule) AS access_hours_end,
    fn_sched_days(access_schedule) AS access_days,
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
          WHERE (z.id = p.zone_id)) AS zone,
    (( SELECT count(*) AS count
           FROM jobs j
          WHERE (j.property_id = p.id)))::integer AS job_count,
    (EXISTS ( SELECT 1
           FROM entity_source_links l
          WHERE ((l.entity_type = 'property'::text) AND (l.source_system = 'jobber'::text) AND (l.entity_id = p.id)))) AS jobber_linked,
    COALESCE((grease_trap_size_gallons)::numeric, ( SELECT sc.equipment_size_gallons
           FROM v_client_agreement_services sc
          WHERE ((sc.property_id = p.id) AND (sc.service_type = 'Pumping'::text))
          ORDER BY sc.id
         LIMIT 1)) AS grease_capacity_gallons,
    access_schedule,
    city_emails,
    lock_box_key
   FROM properties p
  WHERE (deleted_at IS NULL);
create or replace view customer.clients as SELECT customer.uuid_from_bigint(c.id) AS id,
    lower(c.client_code) AS slug,
    c.name,
    c.client_code,
    cg.name AS group_name,
    p.address AS address1,
    NULLIF(TRIM(BOTH ' ,'::text FROM concat_ws(', '::text, NULLIF(p.city, ''::text), NULLIF(concat_ws(' '::text, NULLIF(p.state, ''::text), NULLIF(p.zip, ''::text)), ''::text))), ''::text) AS address2,
        CASE
            WHEN (COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons) IS NOT NULL) THEN ((COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons))::text || ' gal grease trap'::text)
            ELSE NULL::text
        END AS container_type,
        CASE
            WHEN (COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons) IS NOT NULL) THEN ((COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, sc_gt.equipment_size_gallons))::text || ' gal'::text)
            ELSE NULL::text
        END AS trap_capacity,
    sc_gt.material_type AS material,
    df.name AS disposal_facility,
    ( SELECT g.permit_document_path
           FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1) AS gdo_permit_url,
    p.access_notes,
    c.created_at,
    c.status,
    (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AS is_active,
    ( SELECT max(j.frequency_days) AS max
           FROM jobs j
          WHERE ((j.client_id = c.id) AND (j.title ~~* '%Service Agreement%'::text) AND (j.job_status <> ALL (ARRAY['archived'::text, 'destroyed'::text])) AND (j.frequency_days > 0))) AS service_frequency_days
   FROM ((((clients c
     LEFT JOIN client_groups cg ON ((cg.id = c.group_id)))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true) AND (p.deleted_at IS NULL))))
     LEFT JOIN v_client_agreement_services sc_gt ON (((sc_gt.client_id = c.id) AND (sc_gt.service_type = 'Pumping'::text))))
     LEFT JOIN disposal_facilities df ON ((df.id = p.default_disposal_facility_id)));
create or replace view customer.work_orders as SELECT v.public_id AS id,
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
           FROM v_client_agreement_services sc
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
          WHERE (lbl.label IS NOT NULL)), ARRAY[]::text[]) AS service_type,
    COALESCE(v.derm_required, true) AS derm_required
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
     LEFT JOIN LATERAL ( SELECT f.url
           FROM derm.fn_fog_documents(dm.id, v.client_id, v.id) f(effective_page, url)
          ORDER BY f.effective_page
         LIMIT 1) rd ON (true))
     LEFT JOIN derm.receipt_doc_class rc ON ((rc.url = dm.derm_manifest_url)))
  WHERE ((v.visit_status = 'completed'::text) AND (v.client_id IS NOT NULL) AND ((COALESCE(v.derm_required, true) = true) OR (EXISTS ( SELECT 1
           FROM v_visit_grey_water_pumping gwp
          WHERE (gwp.visit_id = v.id)))) AND (v.deleted_at IS NULL));
create or replace view customer.work_orders_all as SELECT v.public_id AS id,
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
           FROM v_client_agreement_services sc
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
          WHERE (lbl.label IS NOT NULL)), ARRAY[]::text[]) AS service_type,
    COALESCE(v.derm_required, true) AS derm_required
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
     LEFT JOIN LATERAL ( SELECT f.url
           FROM derm.fn_fog_documents(dm.id, v.client_id, v.id) f(effective_page, url)
          ORDER BY f.effective_page
         LIMIT 1) rd ON (true))
     LEFT JOIN derm.receipt_doc_class rc ON ((rc.url = dm.derm_manifest_url)))
  WHERE ((v.visit_status = 'completed'::text) AND (v.client_id IS NOT NULL) AND (v.deleted_at IS NULL));
create or replace view derm.v_lwt_monthly_rows as SELECT COALESCE(m.white_manifest_number, m.yellow_ticket_number) AS ticket_number,
        CASE
            WHEN (m.white_manifest_number IS NOT NULL) THEN 'white'::text
            ELSE 'yellow'::text
        END AS ticket_kind,
    (m.white_manifest_number IS NOT NULL) AS offload_in_dade,
    m.dump_ticket_date AS offload_date,
    df.name AS disposal_facility,
    v.visit_date AS pickup_date,
    c.client_code,
    replace(replace(replace(replace(replace(replace(replace(c.name, chr(8217), ''''::text), chr(8216), ''''::text), chr(8220), '"'::text), chr(8221), '"'::text), chr(8211), '-'::text), chr(8212), '-'::text), chr(160), ' '::text) AS client_name,
    p.address,
    p.city,
        CASE
            WHEN (p.state IS NULL) THEN NULL::text
            WHEN (upper(translate(derm.fn_normalize_state_input(p.state), (chr(201) || chr(233)), 'Ee'::text)) = ANY (ARRAY['FL'::text, 'FLORIDA'::text])) THEN 'FL'::text
            WHEN (upper(translate(derm.fn_normalize_state_input(p.state), (chr(201) || chr(233)), 'Ee'::text)) = ANY (ARRAY['CA'::text, 'CALIFORNIA'::text])) THEN 'CA'::text
            WHEN (upper(translate(derm.fn_normalize_state_input(p.state), (chr(201) || chr(233)), 'Ee'::text)) = ANY (ARRAY['NY'::text, 'NEW YORK'::text])) THEN 'NY'::text
            WHEN (upper(translate(derm.fn_normalize_state_input(p.state), (chr(201) || chr(233)), 'Ee'::text)) = ANY (ARRAY['QC'::text, 'QUEBEC'::text])) THEN 'QC'::text
            WHEN (derm.fn_normalize_state_input(p.state) ~ '^[A-Za-z]{2}$'::text) THEN upper(derm.fn_normalize_state_input(p.state))
            ELSE derm.fn_normalize_state_input(p.state)
        END AS state,
    p.zip,
    p.county,
    COALESCE((p.county = 'Dade'::text), false) AS pickup_in_dade,
    (COALESCE((p.county = 'Dade'::text), false) OR (m.white_manifest_number IS NOT NULL)) AS in_scope,
    ve.name AS truck,
    ve.grease_tank_capacity_gallons AS truck_capacity_gallons,
        CASE
            WHEN (m.white_manifest_number IS NULL) THEN COALESCE(NULLIF(p.grease_trap_size_gallons, 0), scf.sc_size)
            ELSE NULL::integer
        END AS gallons,
    m.id AS manifest_id,
    v.id AS visit_id,
    vd.decal_number AS truck_decal,
        CASE
            WHEN (m.white_manifest_number IS NOT NULL) THEN NULL::text
            WHEN (NULLIF(p.grease_trap_size_gallons, 0) IS NOT NULL) THEN 'grease_trap_size'::text
            WHEN (scf.sc_size IS NOT NULL) THEN 'service_config_size'::text
            ELSE NULL::text
        END AS gallons_source
   FROM ((((((((derm_manifests m
     JOIN manifest_visits mv ON ((mv.manifest_id = m.id)))
     JOIN visits v ON (((v.id = mv.visit_id) AND (v.deleted_at IS NULL))))
     JOIN clients c ON ((c.id = m.client_id)))
     LEFT JOIN properties p ON ((p.id = v.property_id)))
     LEFT JOIN vehicles ve ON ((ve.id = v.vehicle_id)))
     LEFT JOIN vehicle_decals vd ON (((vd.vehicle_id = ve.id) AND (vd.jurisdiction = 'Miami-Dade'::text) AND (vd.status = 'ACTIVE'::text))))
     LEFT JOIN disposal_facilities df ON ((df.id = m.disposal_facility_id)))
     LEFT JOIN LATERAL ( SELECT (sc.equipment_size_gallons)::integer AS sc_size
           FROM v_client_agreement_services sc
          WHERE ((sc.client_id = m.client_id) AND (sc.service_type = 'Pumping'::text) AND (sc.equipment_size_gallons > (0)::numeric))
          ORDER BY sc.id
         LIMIT 1) scf ON (true))
  WHERE (m.deleted_at IS NULL);
create or replace view ops.v_calendar_visit as WITH last_completed AS (
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
     LEFT JOIN v_client_agreement_services sc ON (((sc.client_id = v.client_id) AND (sc.service_type = v.service_type))))
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
create or replace view ops.v_derm_compliance as WITH last_manifest AS (
         SELECT derm_manifests.client_id,
            max(derm_manifests.service_date) AS last_manifest_date,
            count(*) AS total_manifests
           FROM derm_manifests
          GROUP BY derm_manifests.client_id
        ), unmatched_visits AS (
         SELECT v.client_id,
            count(*) AS missing_manifests
           FROM visits v
          WHERE (((v.derm_required IS NULL) OR (v.derm_required = true)) AND (v.visit_status = 'completed'::text) AND (v.deleted_at IS NULL) AND (v.visit_date >= (CURRENT_DATE - '120 days'::interval)) AND (NOT (EXISTS ( SELECT 1
                   FROM derm_manifests dm
                  WHERE ((dm.client_id = v.client_id) AND (dm.service_date = v.visit_date))))))
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
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1) AS permit_number,
    ( SELECT g.permit_expiration
           FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1) AS permit_expiration,
    COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
           FROM properties ps
          WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
          ORDER BY ps.is_primary DESC, ps.id
         LIMIT 1))::numeric, sc.equipment_size_gallons) AS equipment_size_gallons,
    sc.frequency_days,
    lm.last_manifest_date,
    lm.total_manifests,
    COALESCE(uv.missing_manifests, (0)::bigint) AS missing_manifest_count,
        CASE
            WHEN (COALESCE(uv.missing_manifests, (0)::bigint) > 0) THEN true
            ELSE false
        END AS has_missing_manifests,
    (CURRENT_DATE - lm.last_manifest_date) AS days_since_last_manifest,
        CASE
            WHEN (lm.last_manifest_date IS NULL) THEN 'no_service_record'::text
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > 90) THEN 'derm_violation'::text
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90)) THEN 'overdue'::text
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14)) THEN 'due_soon'::text
            ELSE 'compliant'::text
        END AS compliance_status
   FROM ((((((clients c
     JOIN v_client_agreement_services sc ON (((sc.client_id = c.id) AND (sc.service_type = 'Pumping'::text))))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text) AND (cc.property_id IS NULL))))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN last_manifest lm ON ((lm.client_id = c.id)))
     LEFT JOIN unmatched_visits uv ON ((uv.client_id = c.id)))
     LEFT JOIN zones p_z ON ((p_z.id = p.zone_id)))
  WHERE (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]))
  ORDER BY
        CASE
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > 90) THEN 1
            WHEN (lm.last_manifest_date IS NULL) THEN 2
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90)) THEN 3
            WHEN ((CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14)) THEN 4
            ELSE 5
        END, COALESCE(uv.missing_manifests, (0)::bigint) DESC, (CURRENT_DATE - lm.last_manifest_date) DESC NULLS LAST;
create or replace view ops.v_gdo_expiry as SELECT c.id,
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
    COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
           FROM properties ps
          WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
          ORDER BY ps.is_primary DESC, ps.id
         LIMIT 1))::numeric, sc.equipment_size_gallons) AS equipment_size_gallons,
    sc.frequency_days,
    (g.permit_expiration - CURRENT_DATE) AS days_until_expiry,
        CASE
            WHEN (g.permit_expiration IS NULL) THEN 'no_permit'::text
            WHEN (g.permit_expiration < CURRENT_DATE) THEN 'expired'::text
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 30) THEN 'expiring_30d'::text
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 60) THEN 'expiring_60d'::text
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 90) THEN 'expiring_90d'::text
            ELSE 'valid'::text
        END AS permit_status
   FROM (((((gdos g
     JOIN clients c ON ((c.id = g.client_id)))
     LEFT JOIN properties p ON ((p.id = g.property_id)))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text) AND (cc.property_id IS NULL))))
     LEFT JOIN v_client_agreement_services sc ON (((sc.client_id = c.id) AND (sc.service_type = 'Pumping'::text))))
     LEFT JOIN zones p_z ON ((p_z.id = p.zone_id)))
  WHERE ((g.status = 'ACTIVE'::text) AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])))
  ORDER BY
        CASE
            WHEN (g.permit_expiration IS NULL) THEN 2
            WHEN (g.permit_expiration < CURRENT_DATE) THEN 1
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 30) THEN 3
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 60) THEN 4
            WHEN ((g.permit_expiration - CURRENT_DATE) <= 90) THEN 5
            ELSE 6
        END, (g.permit_expiration - CURRENT_DATE);
create or replace view ops.v_route_today as SELECT v.id AS visit_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.visit_status,
    v.service_type,
    (v.visit_status = 'completed'::text) AS is_complete,
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
    COALESCE((vp.grease_trap_size_gallons)::numeric, (pp.grease_trap_size_gallons)::numeric, sc.equipment_size_gallons) AS equipment_size_gallons,
    COALESCE(( SELECT g.gdo_number
           FROM gdos g
          WHERE ((g.property_id = v.property_id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1), ( SELECT g.gdo_number
           FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1)) AS permit_number,
    veh.name AS truck,
    veh.grease_tank_capacity_gallons,
    string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS crew,
    v.duration_minutes
   FROM ((((((((((v_visits_live v
     JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties vp ON ((vp.id = v.property_id)))
     LEFT JOIN properties pp ON (((pp.client_id = c.id) AND (pp.is_primary = true))))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text) AND (cc.property_id IS NULL))))
     LEFT JOIN v_client_agreement_services sc ON (((sc.client_id = c.id) AND (sc.service_type = v.service_type))))
     LEFT JOIN vehicles veh ON ((veh.id = v.vehicle_id)))
     LEFT JOIN visit_assignments va ON ((va.visit_id = v.id)))
     LEFT JOIN employees e ON ((e.id = va.employee_id)))
     LEFT JOIN zones vp_z ON ((vp_z.id = vp.zone_id)))
     LEFT JOIN zones pp_z ON ((pp_z.id = pp.zone_id)))
  WHERE ((v.visit_date = CURRENT_DATE) AND (v.visit_status = ANY (ARRAY['UPCOMING'::text, 'LATE'::text, 'completed'::text])))
  GROUP BY v.id, v.visit_date, v.start_at, v.end_at, v.visit_status, v.service_type, v.is_gps_confirmed, c.id, c.client_code, c.name, vp_z.code, vp.address, vp.city, vp.county, vp.latitude, vp.longitude, vp.access_schedule, pp_z.code, pp.address, pp.city, pp.county, pp.latitude, pp.longitude, pp.access_schedule, cc.name, cc.phone, vp.grease_trap_size_gallons, pp.grease_trap_size_gallons, sc.equipment_size_gallons, v.property_id, veh.name, veh.grease_tank_capacity_gallons, v.duration_minutes
  ORDER BY v.start_at, COALESCE(vp_z.code, pp_z.code), c.name;
create or replace view ops.v_service_due as WITH actual_last_visit AS (
         SELECT visits.client_id,
            max(visits.visit_date) AS last_visit_actual
           FROM v_visits_live visits
          WHERE (visits.visit_status = 'completed'::text)
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
    COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
           FROM properties ps
          WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
          ORDER BY ps.is_primary DESC, ps.id
         LIMIT 1))::numeric, sc.equipment_size_gallons) AS equipment_size_gallons,
    ( SELECT g.gdo_number
           FROM gdos g
          WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
          ORDER BY g.id
         LIMIT 1) AS permit_number,
    sc.price_per_visit,
    COALESCE(sc.last_visit, alv.last_visit_actual) AS last_service_date,
    ((COALESCE(sc.last_visit, alv.last_visit_actual) + ((sc.frequency_days || ' days'::text))::interval))::date AS scheduled_next_visit,
    (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) AS days_since_service,
        CASE
            WHEN (COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL) THEN 'never_serviced'::text
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90) THEN 'derm_violation'::text
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days) THEN 'overdue'::text
            WHEN (((COALESCE(sc.last_visit, alv.last_visit_actual) + sc.frequency_days) - CURRENT_DATE) <= 14) THEN 'due_soon'::text
            ELSE 'on_schedule'::text
        END AS service_status
   FROM (((((clients c
     JOIN v_client_agreement_services sc ON (((sc.client_id = c.id) AND (sc.service_type = ANY (ARRAY['Pumping'::text, 'Cleaning'::text])))))
     LEFT JOIN client_contacts cc ON (((cc.client_id = c.id) AND (cc.contact_role = 'primary'::text) AND (cc.property_id IS NULL))))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN actual_last_visit alv ON ((alv.client_id = c.id)))
     LEFT JOIN zones p_z ON ((p_z.id = p.zone_id)))
  WHERE ((c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AND ((COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL) OR ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= (COALESCE(sc.frequency_days, 90) - 14))))
  ORDER BY
        CASE
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90) THEN 1
            ELSE 2
        END, p_z.code,
        CASE
            WHEN (COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL) THEN 1
            WHEN ((CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days) THEN 2
            ELSE 3
        END, (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) DESC NULLS LAST;
create or replace view public.client_services_flat as SELECT c.id,
    c.name,
    c.client_code,
    p.address,
    p.city,
    p_z.code AS zone,
    c.status,
    max(
        CASE
            WHEN true THEN COALESCE((p.grease_trap_size_gallons)::numeric, (( SELECT ps.grease_trap_size_gallons
               FROM properties ps
              WHERE ((ps.client_id = c.id) AND (ps.grease_trap_size_gallons IS NOT NULL))
              ORDER BY ps.is_primary DESC, ps.id
             LIMIT 1))::numeric, s.equipment_size_gallons)
            ELSE NULL::numeric
        END) AS gt_size_gallons,
    max(
        CASE
            WHEN (s.service_type = 'Pumping'::text) THEN s.frequency_days
            ELSE NULL::integer
        END) AS gt_frequency_days,
    max(
        CASE
            WHEN (s.service_type = 'Pumping'::text) THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS gt_price_per_visit,
    max(
        CASE
            WHEN (s.service_type = 'Pumping'::text) THEN s.last_visit
            ELSE NULL::date
        END) AS gt_last_visit,
    max(
        CASE
            WHEN (s.service_type = 'Pumping'::text) THEN ((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date
            ELSE NULL::date
        END) AS gt_next_visit,
    max(
        CASE
            WHEN (s.service_type = 'Pumping'::text) THEN
            CASE
                WHEN ((s.last_visit IS NULL) OR (s.frequency_days IS NULL)) THEN 'UNKNOWN'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date < CURRENT_DATE) THEN 'OVERDUE'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS gt_status,
    max(
        CASE
            WHEN (s.service_type = 'Cleaning'::text) THEN s.frequency_days
            ELSE NULL::integer
        END) AS cl_frequency_days,
    max(
        CASE
            WHEN (s.service_type = 'Cleaning'::text) THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS cl_price_per_visit,
    max(
        CASE
            WHEN (s.service_type = 'Cleaning'::text) THEN s.last_visit
            ELSE NULL::date
        END) AS cl_last_visit,
    max(
        CASE
            WHEN (s.service_type = 'Cleaning'::text) THEN ((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date
            ELSE NULL::date
        END) AS cl_next_visit,
    max(
        CASE
            WHEN (s.service_type = 'Cleaning'::text) THEN
            CASE
                WHEN ((s.last_visit IS NULL) OR (s.frequency_days IS NULL)) THEN 'UNKNOWN'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date < CURRENT_DATE) THEN 'OVERDUE'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS cl_status,
    max(
        CASE
            WHEN (s.service_type = 'Warranty of Drainage'::text) THEN s.frequency_days
            ELSE NULL::integer
        END) AS wd_frequency_days,
    max(
        CASE
            WHEN (s.service_type = 'Warranty of Drainage'::text) THEN s.price_per_visit
            ELSE NULL::numeric
        END) AS wd_price_per_visit,
    max(
        CASE
            WHEN (s.service_type = 'Warranty of Drainage'::text) THEN s.last_visit
            ELSE NULL::date
        END) AS wd_last_visit,
    max(
        CASE
            WHEN (s.service_type = 'Warranty of Drainage'::text) THEN ((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date
            ELSE NULL::date
        END) AS wd_next_visit,
    max(
        CASE
            WHEN (s.service_type = 'Warranty of Drainage'::text) THEN
            CASE
                WHEN ((s.last_visit IS NULL) OR (s.frequency_days IS NULL)) THEN 'UNKNOWN'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date < CURRENT_DATE) THEN 'OVERDUE'::text
                WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::text
                ELSE 'OK'::text
            END
            ELSE NULL::text
        END) AS wd_status,
    max(nve.nve) AS next_visit_expected
   FROM ((((clients c
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN v_client_agreement_services s ON ((s.client_id = c.id)))
     LEFT JOIN zones p_z ON ((p_z.id = p.zone_id)))
     LEFT JOIN ( SELECT v_calendar_visit.client_id,
            min(v_calendar_visit.expected_date) AS nve
           FROM ops.v_calendar_visit
          WHERE ((v_calendar_visit.visit_status = 'scheduled'::text) AND (v_calendar_visit.visit_date >= CURRENT_DATE) AND (v_calendar_visit.expected_date IS NOT NULL))
          GROUP BY v_calendar_visit.client_id) nve ON ((nve.client_id = c.id)))
  GROUP BY c.id, p.address, p.city, p_z.code;
create or replace view public.clients_due_service as SELECT c.id,
    c.name,
    c.client_code,
    p.address,
    p.city,
    p_z.code AS zone,
    s.service_type,
    s.last_visit,
    ((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date AS next_visit,
    s.frequency_days,
    (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date - CURRENT_DATE) AS days_until_due,
        CASE
            WHEN ((s.last_visit IS NULL) OR (s.frequency_days IS NULL)) THEN 'UNKNOWN'::text
            WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date < CURRENT_DATE) THEN 'OVERDUE'::text
            WHEN (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::text
            ELSE 'OK'::text
        END AS due_status
   FROM (((clients c
     JOIN v_client_agreement_services s ON ((s.client_id = c.id)))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN zones p_z ON ((p_z.id = p.zone_id)))
  WHERE ((c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AND ((s.stop_date IS NULL) OR (s.stop_date > CURRENT_DATE)) AND (s.last_visit IS NOT NULL) AND (s.frequency_days IS NOT NULL))
  ORDER BY (((s.last_visit + ((s.frequency_days || ' days'::text))::interval))::date);
create or replace view public.visits_with_status as SELECT v.id,
    v.client_id,
    v.property_id,
    v.job_id,
    v.vehicle_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.completed_at,
    v.duration_minutes,
    v.title,
    v.service_type,
    v.visit_status,
    (v.visit_status = 'completed'::text) AS is_complete,
    v.actual_arrival_at,
    v.actual_departure_at,
    v.is_gps_confirmed,
    v.created_at,
    v.updated_at,
    v.invoice_id,
    v.completed_by,
    c.name AS client_name,
    p_z.code AS zone,
    veh.name AS vehicle_name,
    sc.frequency_days,
        CASE
            WHEN (v.visit_status = 'skipped'::text) THEN 'skipped'::text
            WHEN (v.visit_status = 'completed'::text) THEN 'completed'::text
            WHEN ((v.visit_date < CURRENT_DATE) AND (v.visit_status <> 'completed'::text)) THEN 'late'::text
            WHEN (v.visit_date = CURRENT_DATE) THEN 'today'::text
            ELSE 'upcoming'::text
        END AS computed_late_status
   FROM (((((visits v
     LEFT JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties p ON (((p.client_id = c.id) AND (p.is_primary = true))))
     LEFT JOIN vehicles veh ON ((veh.id = v.vehicle_id)))
     LEFT JOIN v_client_agreement_services sc ON (((sc.client_id = v.client_id) AND (sc.service_type = v.service_type))))
     LEFT JOIN zones p_z ON ((p_z.id = p.zone_id)))
  WHERE (v.deleted_at IS NULL);

do $verify$
declare n int;
begin
  select count(*) into n from public.properties where id in (120,34,200,173,191,1015) and grease_trap_size_gallons > 0;
  if n <> 6 then raise exception 'VERIFY sizes: %', n; end if;
  select count(distinct c.oid) into n from pg_depend d join pg_rewrite r on r.oid = d.objid join pg_class c on c.oid = r.ev_class
   where d.refobjid = 'public.service_configs'::regclass and c.relname <> 'service_configs';
  if n <> 0 then raise exception 'VERIFY % views still read service_configs', n; end if;
  if has_table_privilege('authenticated','public.v_client_agreement_services','SELECT')
     or has_table_privilege('anon','public.v_client_agreement_services','SELECT') then
    raise exception 'VERIFY agreement view is exposed'; end if;
end $verify$;

commit;
