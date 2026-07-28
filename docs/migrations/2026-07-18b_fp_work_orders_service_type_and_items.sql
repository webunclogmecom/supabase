-- 2026-07-18b — FP work orders: keep BOTH the service TYPE and the itemised line items (Fred)
--
-- WHY: 2026-07-18 replaced the raw Jobber line-item text in `services` with the clean taxonomy. Fred
-- preferred the itemised detail on the customer receipt ("I liked it more how it was before … show the Line
-- Items instead") and asked for both, structured:  "Service Type: Pumping"  +  "Service Items: - <items>".
-- That is strictly better than either alone — the type classifies the visit, the items say what was actually
-- done (Grease Trap vs Lift Station, tank cleaning, warranty), which a bare "Pumping" loses.
--
-- SHAPE (both arrays, so the app renders a label + a list):
--   `services`      = the clean TAXONOMY, de-duplicated  -> FP labels it "Service Type"   (unchanged from
--                     2026-07-18: code-prefix -> service_line_items.service_kind, conservative keyword
--                     fallback, else the item's own text)
--   `service_items` = NEW. The itemised line items exactly as the receipt showed them BEFORE 2026-07-18 —
--                     the Jobber name with the leading "NN - " code stripped, ORDER BY li.id, NOT de-duped
--                     (each billed line is its own item). Same fee/credit-card exclusions, same
--                     visit-scoped-then-job-template fallback.
--
-- NB `service_items` is appended as the LAST column on purpose: CREATE OR REPLACE VIEW can only add columns
-- at the end. `customer.get_visit_by_slug_and_token` RETURNS SETOF this view, so it picks the new column up
-- automatically (no function change); its def is backed up in case the rowtype dependency blocks the replace.
--
-- SCOPE: only `service_items` is added; `services` and every other column (incl. the decal expression and the
-- FP-blackout `rd.url` / receipt_doc_class joins from other sessions) are reproduced verbatim. Diff to confirm.
-- Frontend: the FP must be updated to render "Service Type" (services) + "Service Items" (service_items).
--
-- AUDIT (ADR-010): view only, no audited table changes.
-- ROLLBACK: restore backups/2026-07-18b_customer_work_orders_before_service_items.sql
--           (function backup: backups/2026-07-18b_get_visit_by_slug_and_token_before.sql).

CREATE OR REPLACE VIEW customer.work_orders AS
 SELECT v.public_id AS id,
    customer.uuid_from_bigint(v.client_id) AS client_id,
    v.visit_date,
        CASE
            WHEN v.start_at IS NOT NULL THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text)
            ELSE NULL::text
        END AS visit_time,
    COALESCE(( SELECT string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS string_agg
           FROM visit_assignments va
             JOIN employees e ON e.id = va.employee_id
          WHERE va.visit_id = v.id), ( SELECT string_agg(e2.full_name, ', '::text ORDER BY e2.full_name) AS string_agg
           FROM visit_team vt
             JOIN employees e2 ON e2.id = vt.employee_id
          WHERE vt.visit_id = v.id)) AS driver,
    veh.name AS truck,
    ( SELECT vd.decal_number
           FROM manifest_visits mv
             JOIN derm_manifests dm_1 ON dm_1.id = mv.manifest_id AND dm_1.deleted_at IS NULL
             JOIN disposal_facilities df ON df.id = dm_1.disposal_facility_id
             JOIN vehicle_decals vd ON vd.vehicle_id = veh.id AND vd.jurisdiction = df.county AND vd.status = 'ACTIVE'::text
          WHERE mv.visit_id = v.id
         LIMIT 1) AS decal,
    COALESCE(v.manhole_count, NULLIF(prop.grease_trap_manhole_count, 0), NULLIF(( SELECT prim.grease_trap_manhole_count
           FROM properties prim
          WHERE prim.client_id = v.client_id AND prim.is_primary = true
         LIMIT 1), 0)) AS manholes,
    v.manhole_breakdown,
    v.ticket_number,
    v.trap_condition_notes AS trap_condition,
    row_number() OVER (PARTITION BY v.client_id, (EXTRACT(year FROM v.visit_date)) ORDER BY v.visit_date)::integer AS visit_num,
    ( SELECT
                CASE
                    WHEN sc.frequency_days IS NULL OR sc.frequency_days <= 0 THEN NULL::integer
                    ELSE GREATEST(1::numeric, round(365.0 / sc.frequency_days::numeric))::integer
                END AS "greatest"
           FROM service_configs sc
          WHERE sc.client_id = v.client_id AND sc.service_type = v.service_type
         LIMIT 1) AS visit_total,
    v.title AS notes,
    dm.white_manifest_number AS derm_manifest_number,
    rd.url AS derm_manifest_url,
    COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number, dm.yellow_ticket_number) AS wwtp_receipt_number,
        CASE
            WHEN rc.class = 'receipt'::text THEN dm.derm_manifest_url
            ELSE NULL::text
        END AS wwtp_receipt_url,
    dm.wwtp_ticket_number,
    v.created_at,
    COALESCE(v.completed_at, v.created_at) AS updated_at,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS manifest_number,
        CASE
            WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'::text
            WHEN dm.white_manifest_number IS NOT NULL AND length(dm.white_manifest_number) >= 5 THEN 'dade'::text
            ELSE NULL::text
        END AS manifest_jurisdiction,
    dm.id AS manifest_id,
    COALESCE(NULLIF(prop.sample_port_count, 0), NULLIF(( SELECT prim.sample_port_count
           FROM properties prim
          WHERE prim.client_id = v.client_id AND prim.is_primary = true
         LIMIT 1), 0)) AS sample_ports,
    ( SELECT df.name
           FROM disposal_facilities df
          WHERE df.id = dm.disposal_facility_id) AS disposal_facility,
    COALESCE(( SELECT array_agg(DISTINCT lbl.label) AS array_agg
           FROM ( SELECT COALESCE(sli.service_kind,
                        CASE
                            WHEN x.nm ~* 'unclog'::text THEN 'Unclogging'::text
                            WHEN x.nm ~* 'pump'::text THEN 'Pumping'::text
                            WHEN x.nm ~* 'hydrojet'::text THEN 'Cleaning'::text
                            WHEN x.nm ~* '^camera inspection'::text THEN 'Camera Inspection'::text
                            WHEN x.nm ~* 'dye test'::text THEN 'Dye Test'::text
                            WHEN x.nm ~* 'assessment'::text THEN 'Assessment'::text
                            ELSE NULL::text
                        END, x.nm) AS label
                   FROM ( SELECT TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) AS nm,
                            lpad("substring"(TRIM(BOTH FROM li.name), '^([0-9]+)'::text), 2, '0'::text) AS code
                           FROM line_items li
                          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text) x
                     LEFT JOIN service_line_items sli ON sli.code = x.code) lbl), ( SELECT array_agg(DISTINCT lbl.label) AS array_agg
           FROM ( SELECT COALESCE(sli.service_kind,
                        CASE
                            WHEN x.nm ~* 'unclog'::text THEN 'Unclogging'::text
                            WHEN x.nm ~* 'pump'::text THEN 'Pumping'::text
                            WHEN x.nm ~* 'hydrojet'::text THEN 'Cleaning'::text
                            WHEN x.nm ~* '^camera inspection'::text THEN 'Camera Inspection'::text
                            WHEN x.nm ~* 'dye test'::text THEN 'Dye Test'::text
                            WHEN x.nm ~* 'assessment'::text THEN 'Assessment'::text
                            ELSE NULL::text
                        END, x.nm) AS label
                   FROM ( SELECT TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) AS nm,
                            lpad("substring"(TRIM(BOTH FROM li.name), '^([0-9]+)'::text), 2, '0'::text) AS code
                           FROM line_items li
                          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text) x
                     LEFT JOIN service_line_items sli ON sli.code = x.code) lbl), ARRAY[]::text[]) AS services,
    ( SELECT df2.county
           FROM disposal_facilities df2
          WHERE df2.id = dm.disposal_facility_id) AS disposal_county,
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ARRAY[]::text[]) AS service_items
   FROM visits v
     LEFT JOIN vehicles veh ON veh.id = v.vehicle_id
     LEFT JOIN properties prop ON prop.id = v.property_id
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
           FROM derm_manifests dm_inner
             JOIN manifest_visits mv ON mv.manifest_id = dm_inner.id
          WHERE mv.visit_id = v.id AND dm_inner.deleted_at IS NULL
          ORDER BY dm_inner.service_date DESC NULLS LAST
         LIMIT 1) dm ON true
     LEFT JOIN derm.redacted_manifest_docs rd ON rd.manifest_id = dm.id AND rd.client_id = v.client_id
     LEFT JOIN derm.receipt_doc_class rc ON rc.url = dm.derm_manifest_url
  WHERE v.visit_status = 'completed'::text AND v.client_id IS NOT NULL AND COALESCE(v.derm_required, true) = true AND v.deleted_at IS NULL;