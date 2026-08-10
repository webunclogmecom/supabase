-- 2026-08-07_0330 — CORRECTION: a CITY send was counting as a CLIENT send on /manifests
--
-- 🛑 THIS IS A CORRECTION, NOT A REGRESSION. LABEL IT THAT WAY WHEN IT IS REPORTED.
-- After this, 12 rows flip from "Emailed" to "Not emailed yet" and 13 manifests show a LOWER
-- `Emailed N/M` count. Nothing broke. Those numbers were wrong before and are right now.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THE DEFECT
-- ─────────────────────────────────────────────────────────────────────────────
-- `public.derm_email_sends` carries `recipient_type` ('client' | 'city'). In BOTH views below, the
-- CITY arm filters on it and the CLIENT arm does not:
--
--     derm.manifest_recipients.last_emailed_at     city: AND recipient_type='city'   client: (none)
--     derm.manifests.emailed_client_count          city: AND recipient_type='city'   client: (none)
--
-- So emailing the MUNICIPAL REGULATOR set the value that means "we emailed the customer". Measured
-- independently by two sessions, same numbers:
--
--     manifest_recipients.last_emailed_at   36 shown · 24 genuine · 12 MISLABELLED
--     manifests.emailed_client_count        13 manifests OVERCOUNTED · 0 undercounted
--     control: 51 real sends, 34 client / 17 city (the split is sane, city columns are not inflated)
--
-- Found while building the DERM Tracker visit-page send buttons: the same bug was in
-- `derm.visits.last_emailed_at`, where it would have told the office a customer had already been
-- emailed and offered a resend on that basis. That one was handled in `2026-08-07_0210` by adding a
-- correctly-predicated `client_last_emailed_at` rather than editing the old column, because
-- /manifests still read it. This migration closes the /manifests side, so the whole system now agrees.
--
-- ⚠ WHY IT SURVIVED: it fails in the flattering direction. It only ever OVER-reports success, so no
-- one is ever told an email did not go out when it did. A defect that only ever says "yes" is exactly
-- the kind nobody reports. Generalisable: **a surface that claims "already done" must read a value
-- scoped to the SAME action its button performs**, and two sibling columns where only one carries the
-- discriminator is the shape to look for.
--
-- ⚠ `derm.visits.last_emailed_at` IS DELIBERATELY LEFT ALONE. It has the same defect. New app code
-- reads `client_last_emailed_at` instead. Fixing it here would be a third simultaneous behaviour
-- change on a screen nobody asked about; it can go in its own pass once the visit-page UI ships.
--
-- 3NF: no schema change, no stored value, one predicate added to two derived columns.
-- Audit: views are not audited; `public.derm_email_sends` is unchanged and remains audit opt-in.
-- Method: both bodies were read from `pg_get_viewdef` and patched by an EXACT string replacement
-- asserted to match exactly once. Nothing was retyped (see `2026-08-06_1316` for why that matters).

begin;

create or replace view derm.manifest_recipients as
SELECT manifest_id,
    display_number,
    display_label,
    jurisdiction,
    client_id,
    client_name,
    has_pdf,
    has_email,
    visit_date,
    last_emailed_at,
    (EXISTS ( SELECT 1
           FROM properties p
             JOIN municipality_regulators mr ON lower(btrim(mr.municipality)) = lower(btrim(p.city)) AND mr.status = 'ACTIVE'::text
          WHERE p.client_id = w.client_id)) AS has_city_email,
    ( SELECT string_agg(DISTINCT mr.municipality, ', '::text) AS string_agg
           FROM properties p
             JOIN municipality_regulators mr ON lower(btrim(mr.municipality)) = lower(btrim(p.city)) AND mr.status = 'ACTIVE'::text
          WHERE p.client_id = w.client_id) AS municipality,
    ( SELECT max(es.sent_at) AS max
           FROM derm_email_sends es
          WHERE es.manifest_id = w.manifest_id AND es.client_id = w.client_id AND es.recipient_type = 'city'::text AND es.status = 'sent'::text AND es.is_test = false) AS city_last_emailed_at
   FROM ( SELECT sub.manifest_id,
            sub.display_number,
            sub.display_label,
            sub.jurisdiction,
            sub.client_id,
            sub.client_name,
            sub.has_pdf,
            sub.has_email,
            sub.visit_date,
            ( SELECT max(es.sent_at) AS max
                   FROM derm_email_sends es
                  WHERE es.manifest_id = sub.manifest_id AND es.client_id = sub.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false) AS last_emailed_at
           FROM ( SELECT m.id AS manifest_id,
                    m.display_number,
                    m.display_label,
                    m.jurisdiction,
                    r.client_id,
                        CASE
                            WHEN cl.client_code IS NOT NULL AND cl.client_code <> ''::text THEN (cl.client_code || ' '::text) || cl.name
                            ELSE cl.name
                        END AS client_name,
                    m.manifest_photo_url IS NOT NULL AS has_pdf,
                    (EXISTS ( SELECT 1
                           FROM client_contacts cc
                          WHERE cc.client_id = r.client_id AND cc.email IS NOT NULL AND cc.email <> ''::text)) AS has_email,
                    ( SELECT max(v.visit_date) AS max
                           FROM manifest_visits mv
                             JOIN visits v ON v.id = mv.visit_id
                          WHERE mv.manifest_id = m.id AND v.client_id = r.client_id AND v.deleted_at IS NULL) AS visit_date
                   FROM derm.manifests m
                     JOIN LATERAL ( SELECT DISTINCT v.client_id
                           FROM manifest_visits mv
                             JOIN visits v ON v.id = mv.visit_id
                          WHERE mv.manifest_id = m.id AND v.deleted_at IS NULL AND v.client_id IS NOT NULL) r ON true
                     JOIN clients cl ON cl.id = r.client_id) sub) w;

create or replace view derm.manifests as
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
                  WHERE es.manifest_id = sub.id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false) AS emailed_client_count,
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
                             JOIN derm_manifests m2 ON m2.id = l.manifest_id AND m2.deleted_at IS NULL
                          WHERE COALESCE(m2.white_manifest_number, m2.yellow_ticket_number) = COALESCE(dm.white_manifest_number, dm.yellow_ticket_number)
                          ORDER BY s.sheet_no
                         LIMIT 1)) AS derm_address_no,
                    array_remove(COALESCE(gs.addr_urls, ARRAY[]::text[]), dm.derm_address_url) AS address_photo_extra_urls,
                    array_remove(COALESCE(gs.man_urls, ARRAY[]::text[]), dm.derm_manifest_url) AS manifest_photo_extra_urls
                   FROM derm_manifests dm
                     LEFT JOIN clients c ON c.id = dm.client_id
                     LEFT JOIN disposal_facilities df ON df.id = dm.disposal_facility_id
                     LEFT JOIN grp gs ON gs.gk = COALESCE(dm.white_manifest_number, dm.yellow_ticket_number, 'id:'::text || dm.id::text)
                  WHERE dm.deleted_at IS NULL) sub) w;

commit;

-- VERIFY:
--   * both views now contain recipient_type='client' exactly once, alongside the existing 'city'
--   * manifest_recipients: rows with last_emailed_at drops 36 -> 24
--   * manifests: emailed_client_count exactly matches the real client-send count on every manifest
--   * city columns UNCHANGED (city_last_emailed_at, city_emailed_count)
--   * column lists and grants unchanged on both views
