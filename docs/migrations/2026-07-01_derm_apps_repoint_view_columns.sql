-- 2026-07-01_derm_apps_repoint_view_columns.sql
-- Unblocks the get-derm-doc app repoint (Building Apps handoff): the frontends each hold ONLY
-- one of the fn s two required inputs. customer.work_orders (Field Portal) had the client_code slug
-- but no numeric manifest_id -> add dm.id AS manifest_id (the manifest lateral already exposes id;
-- client-scoped view, harmless without the matching client_code the fn also requires). derm.manifests
-- (DERM Tracker) had id + client_id but no client_code -> add it via a correlated lookup on client_id.
-- Both additive (appended last); no other column/row/behavior change.

CREATE OR REPLACE VIEW customer.work_orders AS
 SELECT v.public_id AS id,
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
    dm.fog_manifest_url AS derm_manifest_url,
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
        END AS manifest_jurisdiction,
    dm.id AS manifest_id
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
  WHERE v.visit_status = 'completed'::text AND v.client_id IS NOT NULL AND COALESCE(v.derm_required, true) = true AND v.deleted_at IS NULL;

CREATE OR REPLACE VIEW derm.manifests AS
 WITH grp AS (
         SELECT s.gk,
            array_agg(DISTINCT s.url) FILTER (WHERE s.kind = 'a'::text AND s.url IS NOT NULL) AS addr_urls,
            array_agg(DISTINCT s.url) FILTER (WHERE s.kind = 'm'::text AND s.url IS NOT NULL) AS man_urls
           FROM ( SELECT COALESCE(d2.white_manifest_number, d2.yellow_ticket_number, 'id:'::text || d2.id::text) AS gk,
                    'a'::text AS kind,
                    unnest(array_prepend(d2.derm_address_url, COALESCE(d2.derm_address_extra_urls, ARRAY[]::text[]))) AS url
                   FROM derm_manifests d2
                  WHERE d2.deleted_at IS NULL
                UNION ALL
                 SELECT COALESCE(d2.white_manifest_number, d2.yellow_ticket_number, 'id:'::text || d2.id::text) AS "coalesce",
                    'm'::text AS text,
                    unnest(array_prepend(d2.derm_manifest_url, COALESCE(d2.derm_manifest_extra_urls, ARRAY[]::text[]))) AS unnest
                   FROM derm_manifests d2
                  WHERE d2.deleted_at IS NULL) s
          GROUP BY s.gk
        )
 SELECT id,
    manifest_number,
    manifest_type,
    manifest_photo_url,
    address_photo_url,
    dump_date,
    dump_location,
    driver_name,
    gallons,
    created_at,
    client_id,
    client_name,
    service_date,
    yellow_ticket_number,
    wwtp_receipt_number,
    wwtp_receipt_document_path,
    wwtp_ticket_number,
    disposal_facility_id,
    sent_to_client,
    sent_to_city,
    updated_at,
    jurisdiction,
    display_number,
    display_label,
    notes,
    derm_address_no,
    emailed_client_count,
    total_client_count,
    ( SELECT count(DISTINCT es.client_id) AS count
           FROM derm_email_sends es
          WHERE es.manifest_id = w.id AND es.recipient_type = 'city'::text AND es.status = 'sent'::text AND es.is_test = false) AS city_emailed_count,
    ( SELECT count(DISTINCT vv.client_id) AS count
           FROM manifest_visits mv
             JOIN visits vv ON vv.id = mv.visit_id AND vv.deleted_at IS NULL
          WHERE mv.manifest_id = w.id AND (EXISTS ( SELECT 1
                   FROM properties p
                     JOIN municipality_regulators mr ON lower(btrim(mr.municipality)) = lower(btrim(p.city)) AND mr.status = 'ACTIVE'::text
                  WHERE p.client_id = vv.client_id))) AS city_total_count,
    address_photo_extra_urls,
    manifest_photo_extra_urls,
    ( SELECT c2.client_code FROM clients c2 WHERE c2.id = w.client_id) AS client_code
   FROM ( SELECT sub.id,
            sub.manifest_number,
            sub.manifest_type,
            sub.manifest_photo_url,
            sub.address_photo_url,
            sub.dump_date,
            sub.dump_location,
            sub.driver_name,
            sub.gallons,
            sub.created_at,
            sub.client_id,
            sub.client_name,
            sub.service_date,
            sub.yellow_ticket_number,
            sub.wwtp_receipt_number,
            sub.wwtp_receipt_document_path,
            sub.wwtp_ticket_number,
            sub.disposal_facility_id,
            sub.sent_to_client,
            sub.sent_to_city,
            sub.updated_at,
            sub.jurisdiction,
            sub.display_number,
            sub.display_label,
            sub.notes,
            sub.derm_address_no,
            sub.address_photo_extra_urls,
            sub.manifest_photo_extra_urls,
            ( SELECT count(DISTINCT es.client_id) AS count
                   FROM derm_email_sends es
                  WHERE es.manifest_id = sub.id AND es.status = 'sent'::text AND es.is_test = false) AS emailed_client_count,
            ( SELECT count(DISTINCT v.client_id) AS count
                   FROM manifest_visits mv
                     JOIN visits v ON v.id = mv.visit_id
                  WHERE mv.manifest_id = sub.id AND v.deleted_at IS NULL AND v.client_id IS NOT NULL) AS total_client_count
           FROM ( SELECT dm.id,
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
                    dm.derm_address_no,
                    array_remove(COALESCE(gs.addr_urls, ARRAY[]::text[]), dm.derm_address_url) AS address_photo_extra_urls,
                    array_remove(COALESCE(gs.man_urls, ARRAY[]::text[]), dm.derm_manifest_url) AS manifest_photo_extra_urls
                   FROM derm_manifests dm
                     LEFT JOIN clients c ON c.id = dm.client_id
                     LEFT JOIN disposal_facilities df ON df.id = dm.disposal_facility_id
                     LEFT JOIN grp gs ON gs.gk = COALESCE(dm.white_manifest_number, dm.yellow_ticket_number, 'id:'::text || dm.id::text)
                  WHERE dm.deleted_at IS NULL) sub) w;
