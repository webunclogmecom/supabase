-- 2026-07-01_derm_manifests_union_sheets_across_rows.sql
-- UNION the DERM sheet images across all client rows that share a manifest number, so a sheet
-- attached to ANY client's row shows for ALL of them. Closes known-issue #14 (sheets split across
-- rows): before this, each row's *_extra_urls held only that row's own sheets, so a visit whose
-- client row was missing a sheet showed an incomplete set (e.g. 242-WYN saw only 1004-1 while other
-- #306859 rows carried 1003-1/1003-2) until someone re-uploaded every sheet onto every row.
-- Grouping key = white_manifest_number, else yellow_ticket_number, else 'id:'||id (number-less rows
-- stay isolated — pending-paperwork rows don't pool). ONLY the *_extra_urls arrays change; the
-- primary address_photo_url / manifest_photo_url are UNTOUCHED, so Health/completeness (which key
-- off the primaries) and Field Portal (customer.work_orders reads the raw columns, not this view)
-- are unaffected. The app already renders primary + extras (2026-07-01), so no app change needed.
CREATE OR REPLACE VIEW derm.manifests AS
WITH grp AS (
         SELECT s.gk,
            array_agg(DISTINCT s.url) FILTER (WHERE s.kind = 'a'::text AND s.url IS NOT NULL) AS addr_urls,
            array_agg(DISTINCT s.url) FILTER (WHERE s.kind = 'm'::text AND s.url IS NOT NULL) AS man_urls
           FROM ( SELECT COALESCE(d2.white_manifest_number, d2.yellow_ticket_number, ('id:'::text || d2.id::text)) AS gk,
                    'a'::text AS kind,
                    unnest(array_prepend(d2.derm_address_url, COALESCE(d2.derm_address_extra_urls, ARRAY[]::text[]))) AS url
                   FROM derm_manifests d2
                  WHERE d2.deleted_at IS NULL
                UNION ALL
                 SELECT COALESCE(d2.white_manifest_number, d2.yellow_ticket_number, ('id:'::text || d2.id::text)),
                    'm'::text,
                    unnest(array_prepend(d2.derm_manifest_url, COALESCE(d2.derm_manifest_extra_urls, ARRAY[]::text[])))
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
    manifest_photo_extra_urls
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
                     LEFT JOIN grp gs ON gs.gk = COALESCE(dm.white_manifest_number, dm.yellow_ticket_number, ('id:'::text || dm.id::text))
                  WHERE dm.deleted_at IS NULL) sub) w;
