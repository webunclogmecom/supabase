-- 2026-08-03_0052  customer.work_orders: fall back to the YELLOW ticket for derm_manifest_number
--
-- Fred, on the FP visit page for 041-MB / Jul 28: the DERM FOG eManifest card showed no number.
--
-- -- THE BUG -------------------------------------------------------------------
-- Two sibling columns in THIS SAME VIEW disagreed about how to name a manifest:
--     derm_manifest_number = dm.white_manifest_number                                    -- no fallback
--     wwtp_receipt_number  = COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number,
--                                     dm.yellow_ticket_number)                           -- falls back
-- So on a manifest carrying only a YELLOW ticket, the WWTP card showed 310429 while the FOG card
-- showed nothing. Manifest 1648 (041-MB, ticket 310429) is exactly that shape: white NULL,
-- yellow '310429'. This is independent of the missing-image bug fixed in 2026-08-03_0046 —
-- fixing the image alone would still have left the number blank.
--
-- -- THE CHANGE ----------------------------------------------------------------
-- One expression, bringing FOG into line with the WWTP sibling. No new column, no reordering.
-- Built by asserting a UNIQUE anchor against the live pg_get_viewdef and verifying the full
-- 'AS <column>' sequence is byte-identical before and after (CREATE OR REPLACE VIEW rejects any
-- column list change with 42P16, but an unnoticed REORDER would be silently wrong, hence the check).
--
-- ⚠ WHITE vs YELLOW ARE NOT INTERCHANGEABLE IN GENERAL. White is the DERM manifest number, yellow
-- is the disposal-facility ticket. They coincide often enough that the WWTP column already treats
-- yellow as an acceptable last resort, and showing the yellow ticket is strictly better than
-- showing nothing on a card whose companion already displays it. If DERM ever requires the label
-- to mean specifically "white", this is the line to revisit.
--
-- ADR 010 rule 8: view only, no table/column change -> no audit-trigger decision.
-- customer.* views are owner-rights by design (the FP reads them via SECURITY DEFINER RPCs as
-- anon); do NOT add security_invoker.

BEGIN;

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
    NULL::text AS notes,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS derm_manifest_number,
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
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ARRAY[]::text[]) AS services,
    ( SELECT df2.county
           FROM disposal_facilities df2
          WHERE df2.id = dm.disposal_facility_id) AS disposal_county,
    COALESCE(( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ( SELECT array_agg(TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) ORDER BY li.id) AS array_agg
           FROM line_items li
          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text), ARRAY[]::text[]) AS service_items,
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
                        END) AS label
                   FROM ( SELECT TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) AS nm,
                            lpad("substring"(TRIM(BOTH FROM li.name), '^([0-9]+)'::text), 2, '0'::text) AS code
                           FROM line_items li
                          WHERE li.visit_id = v.id AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text) x
                     LEFT JOIN service_line_items sli ON sli.code = x.code) lbl
          WHERE lbl.label IS NOT NULL), ( SELECT array_agg(DISTINCT lbl.label) AS array_agg
           FROM ( SELECT COALESCE(sli.service_kind,
                        CASE
                            WHEN x.nm ~* 'unclog'::text THEN 'Unclogging'::text
                            WHEN x.nm ~* 'pump'::text THEN 'Pumping'::text
                            WHEN x.nm ~* 'hydrojet'::text THEN 'Cleaning'::text
                            WHEN x.nm ~* '^camera inspection'::text THEN 'Camera Inspection'::text
                            WHEN x.nm ~* 'dye test'::text THEN 'Dye Test'::text
                            WHEN x.nm ~* 'assessment'::text THEN 'Assessment'::text
                            ELSE NULL::text
                        END) AS label
                   FROM ( SELECT TRIM(BOTH FROM regexp_replace(li.name, '^\s*\d+\s*-\s*'::text, ''::text)) AS nm,
                            lpad("substring"(TRIM(BOTH FROM li.name), '^([0-9]+)'::text), 2, '0'::text) AS code
                           FROM line_items li
                          WHERE li.job_id = v.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL AND li.name IS NOT NULL AND TRIM(BOTH FROM li.name) <> ''::text AND li.name !~* '(credit[ ]?card|fee|discount|surcharge|convenience|gratuity)'::text) x
                     LEFT JOIN service_line_items sli ON sli.code = x.code) lbl
          WHERE lbl.label IS NOT NULL), ARRAY[]::text[]) AS service_type
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

COMMIT;
