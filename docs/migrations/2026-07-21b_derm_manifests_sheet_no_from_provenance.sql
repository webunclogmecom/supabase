-- ============================================================================
-- 2026-07-21b — derm.manifests: derive derm_address_no from sheet provenance
-- ============================================================================
-- WHY: the 2026-07-20f provenance re-key removed the old per-row
-- derm_address_no writeback (it keyed on the MUTABLE ticket number and created
-- the 819788 ghost sheet). Since then the recorded truth lives in
-- derm.address_sheets + derm.address_sheet_manifests, but the derm.manifests
-- view still surfaced the STALE base column -- so the DERM Tracker's new
-- "Sheet N" chip and "Regenerate address sheet" label (shipped 2026-07-21,
-- Fred: "implement it") would never light up for new-flow sheets (verified
-- live: sheet 1054 generated for ticket 999905, view still returned NULL).
--
-- CHANGE: view-only. derm_address_no = COALESCE(legacy base column,
-- live sheet_no of the ticket group's recorded sheet). Membership is by TICKET
-- KEY, so sibling rows appended after generation surface the number too.
-- Gate 2 of record_generated_address_sheet guarantees a ticket cannot carry
-- two live sheets, so the ORDER BY/LIMIT is deterministic in practice.
--
-- 3NF: stays a derived read-model column (computed on read, not stored --
-- exactly the rule the old writeback violated). AUDIT: n/a (view). Grants
-- preserved by CREATE OR REPLACE.
--
-- VERIFICATION (2026-07-21, appended after deploy):
--   - derm.manifests id=1445 (ticket 999905, sheet 1054): derm_address_no
--     1054 (was NULL before this migration).
--   - Legacy rows keep their base-column values (COALESCE first arm).
--   - anon/authenticated SELECT grants intact after REPLACE.
-- ============================================================================

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
    ( SELECT c2.client_code
           FROM clients c2
          WHERE c2.id = w.client_id) AS client_code
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
                    COALESCE(dm.derm_address_no, ( SELECT s.sheet_no
                       FROM derm.address_sheet_manifests l
                       JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
                       JOIN public.derm_manifests m2 ON m2.id = l.manifest_id AND m2.deleted_at IS NULL
                      WHERE COALESCE(m2.white_manifest_number, m2.yellow_ticket_number)
                            = COALESCE(dm.white_manifest_number, dm.yellow_ticket_number)
                      ORDER BY s.sheet_no
                      LIMIT 1)) AS derm_address_no,
                    array_remove(COALESCE(gs.addr_urls, ARRAY[]::text[]), dm.derm_address_url) AS address_photo_extra_urls,
                    array_remove(COALESCE(gs.man_urls, ARRAY[]::text[]), dm.derm_manifest_url) AS manifest_photo_extra_urls
                   FROM derm_manifests dm
                     LEFT JOIN clients c ON c.id = dm.client_id
                     LEFT JOIN disposal_facilities df ON df.id = dm.disposal_facility_id
                     LEFT JOIN grp gs ON gs.gk = COALESCE(dm.white_manifest_number, dm.yellow_ticket_number, 'id:'::text || dm.id::text)
                  WHERE dm.deleted_at IS NULL) sub) w;
