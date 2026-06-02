-- 2026-06-02 — add deleted_at IS NULL filter so read views/Field Portal honor soft-delete.
-- Applied from Building Apps session via Management API (Fred-approved). Pre-state backup: docs/backups/derm_softdelete_views_constraints_backup_2026-06-02.json

BEGIN;

CREATE OR REPLACE VIEW derm.manifests AS  SELECT dm.id,
    dm.white_manifest_number AS manifest_number,
    'WHITE'::text AS manifest_type,
    dm.derm_manifest_url AS manifest_photo_url,
    dm.derm_address_url AS address_photo_url,
    dm.dump_ticket_date::text AS dump_date,
    df.name AS dump_location,
    NULL::text AS driver_name,
    NULL::numeric AS gallons,
    dm.created_at::text AS created_at,
    dm.client_id,
        CASE
            WHEN c.client_code IS NOT NULL AND c.name !~~ (c.client_code || '%'::text) THEN (c.client_code || ' '::text) || c.name
            ELSE c.name
        END AS client_name,
    dm.service_date::text AS service_date,
    dm.yellow_ticket_number,
    dm.wwtp_receipt_number,
    dm.wwtp_receipt_document_path,
    dm.wwtp_ticket_number,
    dm.disposal_facility_id,
    dm.sent_to_client,
    dm.sent_to_city,
    dm.updated_at::text AS updated_at,
        CASE
            WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'::text
            WHEN dm.white_manifest_number IS NOT NULL AND length(dm.white_manifest_number) >= 5 THEN 'dade'::text
            ELSE 'unknown'::text
        END AS jurisdiction,
    COALESCE(
        CASE
            WHEN dm.yellow_ticket_number IS NOT NULL THEN dm.yellow_ticket_number
            ELSE NULL::text
        END,
        CASE
            WHEN dm.white_manifest_number IS NOT NULL AND length(dm.white_manifest_number) >= 5 THEN dm.white_manifest_number
            ELSE NULL::text
        END) AS display_number,
        CASE
            WHEN dm.yellow_ticket_number IS NOT NULL THEN 'Broward #'::text || dm.yellow_ticket_number
            WHEN dm.white_manifest_number IS NOT NULL AND length(dm.white_manifest_number) >= 5 THEN 'Miami-Dade #'::text || dm.white_manifest_number
            ELSE 'Pending paperwork'::text
        END AS display_label,
    dm.notes,
    dm.derm_address_no
   FROM derm_manifests dm
     LEFT JOIN clients c ON c.id = dm.client_id
     LEFT JOIN disposal_facilities df ON df.id = dm.disposal_facility_id WHERE dm.deleted_at IS NULL;

CREATE OR REPLACE VIEW derm.manifest_health AS  SELECT dm.id,
    dm.client_id,
    c.name AS client_name,
    dm.white_manifest_number,
    dm.yellow_ticket_number,
    dm.service_date::text AS service_date,
    dm.dump_ticket_date::text AS dump_ticket_date,
    dm.disposal_facility_id,
    df.name AS dump_location,
    dm.derm_manifest_url AS manifest_photo_url,
    dm.derm_address_url AS address_photo_url,
    dm.created_at::text AS created_at,
    dm.updated_at::text AS updated_at,
        CASE
            WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'::text
            WHEN dm.white_manifest_number IS NOT NULL AND length(dm.white_manifest_number) >= 5 THEN 'dade'::text
            ELSE 'unknown'::text
        END AS jurisdiction,
    dm.white_manifest_number IS NOT NULL AS has_dade_white_number,
    dm.yellow_ticket_number IS NOT NULL AS has_broward_ticket_number,
    dm.derm_manifest_url IS NOT NULL AS has_manifest_pdf,
    dm.derm_address_url IS NOT NULL AS has_address_pdf,
    dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL AS has_any_pdf,
    dm.dump_ticket_date IS NOT NULL AS has_dump_date,
    dm.disposal_facility_id IS NOT NULL AS has_dump_site,
    dm.client_id IS NOT NULL AS has_client,
    dm.sent_to_client IS TRUE AS sent_to_client,
    dm.sent_to_city IS TRUE AS sent_to_city,
        CASE
            WHEN dm.white_manifest_number IS NULL AND dm.yellow_ticket_number IS NULL AND dm.derm_manifest_url IS NULL AND dm.derm_address_url IS NULL AND dm.dump_ticket_date IS NULL THEN 'empty_placeholder'::text
            WHEN dm.yellow_ticket_number IS NOT NULL AND dm.derm_manifest_url IS NOT NULL AND dm.derm_address_url IS NOT NULL AND dm.dump_ticket_date IS NOT NULL THEN 'fully_complete'::text
            WHEN dm.white_manifest_number IS NOT NULL AND length(dm.white_manifest_number) >= 5 AND dm.derm_manifest_url IS NOT NULL AND dm.derm_address_url IS NOT NULL AND dm.dump_ticket_date IS NOT NULL THEN 'fully_complete'::text
            WHEN (dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL) AND dm.yellow_ticket_number IS NULL AND dm.white_manifest_number IS NULL THEN 'has_pdfs_no_number'::text
            WHEN (dm.yellow_ticket_number IS NOT NULL OR dm.white_manifest_number IS NOT NULL) AND dm.derm_manifest_url IS NULL AND dm.derm_address_url IS NULL THEN 'has_number_no_pdfs'::text
            ELSE 'partial_other'::text
        END AS health_state,
        CASE
            WHEN dm.white_manifest_number IS NULL AND dm.yellow_ticket_number IS NULL AND dm.derm_manifest_url IS NULL AND dm.derm_address_url IS NULL THEN 'P0'::text
            WHEN dm.yellow_ticket_number IS NULL AND dm.white_manifest_number IS NULL OR dm.derm_manifest_url IS NULL OR dm.derm_address_url IS NULL OR dm.dump_ticket_date IS NULL THEN 'P1'::text
            WHEN NOT dm.sent_to_client OR NOT dm.sent_to_city THEN 'P2'::text
            ELSE 'OK'::text
        END AS severity,
    dm.notes,
    dm.derm_address_no
   FROM derm_manifests dm
     LEFT JOIN clients c ON c.id = dm.client_id
     LEFT JOIN disposal_facilities df ON df.id = dm.disposal_facility_id WHERE dm.deleted_at IS NULL;

CREATE OR REPLACE VIEW derm.manifest_visits AS  SELECT mv.manifest_id,
    mv.visit_id,
    v.visit_date::text AS visit_date,
    v.client_id,
        CASE
            WHEN c.client_code IS NOT NULL AND c.name !~~ (c.client_code || '%'::text) THEN (c.client_code || ' '::text) || c.name
            ELSE c.name
        END AS client_name,
    COALESCE(p.address, ''::text) AS address,
    COALESCE(p.county, ''::text) AS county
   FROM manifest_visits mv
     JOIN visits v ON v.id = mv.visit_id
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN LATERAL ( SELECT p2.address,
            p2.county
           FROM properties p2
          WHERE p2.client_id = c.id AND p2.is_billing = false
          ORDER BY p2.id
         LIMIT 1) p ON true WHERE EXISTS (SELECT 1 FROM public.derm_manifests dm WHERE dm.id = mv.manifest_id AND dm.deleted_at IS NULL);

CREATE OR REPLACE VIEW customer.work_orders AS  SELECT v.public_id AS id,
    customer.uuid_from_bigint(v.client_id) AS client_id,
    v.visit_date,
        CASE
            WHEN v.start_at IS NOT NULL THEN to_char((v.start_at AT TIME ZONE 'America/New_York'::text), 'FMHH12:MI AM'::text)
            ELSE NULL::text
        END AS visit_time,
    ( SELECT string_agg(e.full_name, ', '::text ORDER BY e.full_name) AS string_agg
           FROM visit_assignments va
             JOIN employees e ON e.id = va.employee_id
          WHERE va.visit_id = v.id) AS driver,
    veh.name AS truck,
    veh.decal_number AS decal,
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
    NULL::text AS derm_manifest_url,
    COALESCE(dm.wwtp_receipt_number, dm.white_manifest_number, dm.yellow_ticket_number) AS wwtp_receipt_number,
    dm.derm_manifest_url AS wwtp_receipt_url,
    dm.wwtp_ticket_number,
    v.created_at,
    COALESCE(v.completed_at, v.created_at) AS updated_at,
    COALESCE(dm.white_manifest_number, dm.yellow_ticket_number) AS manifest_number,
        CASE
            WHEN dm.white_manifest_number IS NOT NULL THEN 'dade'::text
            WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'::text
            ELSE NULL::text
        END AS manifest_jurisdiction
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
            dm_inner.gdo_id
           FROM derm_manifests dm_inner
             JOIN manifest_visits mv ON mv.manifest_id = dm_inner.id
          WHERE mv.visit_id = v.id AND dm_inner.deleted_at IS NULL
          ORDER BY dm_inner.service_date DESC NULLS LAST
         LIMIT 1) dm ON true
  WHERE v.visit_status = 'completed'::text AND v.client_id IS NOT NULL AND COALESCE(v.derm_required, true) = true;

CREATE OR REPLACE VIEW derm.visits AS  SELECT v.id,
        CASE
            WHEN c.client_code IS NOT NULL AND c.name !~~ (c.client_code || '%'::text) THEN (c.client_code || ' '::text) || c.name
            ELSE c.name
        END AS client_name,
    COALESCE(p.address, ''::text) AS address,
    COALESCE(p.county, ''::text) AS county,
    v.visit_date::text AS visit_date,
    NULL::text AS technician,
    NULL::text AS notes,
    v.created_at::text AS created_at,
    v.client_id,
    v.service_type,
    (EXISTS ( SELECT 1
           FROM manifest_visits mv
             JOIN derm_manifests dm ON dm.id = mv.manifest_id
          WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL AND (dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL))) AS has_manifest,
    v.derm_required,
    COALESCE(v.derm_required, true) AS needs_manifest,
    COALESCE(( SELECT (NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || (( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
                   FROM line_items li
                  WHERE li.invoice_id = v.invoice_id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))
           FROM jobs j
          WHERE j.id = v.job_id AND j.title IS NOT NULL AND TRIM(BOTH FROM j.title) <> ''::text AND (EXISTS ( SELECT 1
                   FROM line_items li
                  WHERE li.invoice_id = v.invoice_id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
           FROM line_items li
          WHERE li.invoice_id = v.invoice_id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text), ( SELECT (NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || (( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
                   FROM line_items li
                  WHERE li.job_id = v.job_id AND li.invoice_id IS NULL AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))
           FROM jobs j
          WHERE j.id = v.job_id AND j.title IS NOT NULL AND TRIM(BOTH FROM j.title) <> ''::text AND (EXISTS ( SELECT 1
                   FROM line_items li
                  WHERE li.job_id = v.job_id AND li.invoice_id IS NULL AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
           FROM line_items li
          WHERE li.job_id = v.job_id AND li.invoice_id IS NULL AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text), NULLIF(TRIM(BOTH FROM split_part(v.title, ' - '::text, 2)), ''::text), ( SELECT NULLIF(TRIM(BOTH FROM j.title), ''::text) AS "nullif"
           FROM jobs j
          WHERE j.id = v.job_id)) AS line_items,
    COALESCE(( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
           FROM line_items li
          WHERE li.invoice_id = v.invoice_id), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
           FROM line_items li
          WHERE li.job_id = v.job_id AND li.invoice_id IS NULL), '[]'::jsonb) AS line_items_json,
    ( SELECT g.gdo_number
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS gdo_number,
    ( SELECT j.job_number
           FROM jobs j
          WHERE j.id = v.job_id) AS job_number
   FROM visits v
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN LATERAL ( SELECT p2.address,
            p2.county
           FROM properties p2
          WHERE p2.client_id = c.id
          ORDER BY p2.is_primary DESC NULLS LAST, (p2.is_billing IS NOT TRUE) DESC, p2.id
         LIMIT 1) p ON true
  WHERE v.visit_status = 'completed'::text;

COMMIT;
