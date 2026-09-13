-- 2026-09-12_2015  The DERM app reads the city inbox from the property THE VISIT WAS SET AT
--
-- Fred, 2026-09-12: "the reading for the email should come from the property data of its own client
-- data. Depending on the property also ... checked which property the visit was set so it selects
-- the correct email."
--
-- The automatic sweep (derm.v_city_email_candidates) and Admin Review (public.v_visit_city_email)
-- already do that. Three DERM-app views did not: they tested ANY property of the CLIENT.
--   derm.manifests.city_total_count        counted a client if any of its properties carried an inbox
--   derm.manifest_recipients.has_city_email / municipality   same test, client-wide
--   derm.visits.has_city_email / municipality   copied from manifest_recipients through the manifest,
--                                              so a visit with no manifest read false whatever its
--                                              property said (visit 6563, 001-VIN, on 2026-09-12)
--
-- Measured before the change (733 manifest/client pairs, 1,200 DERM visits): 0 clients hold two
-- DIFFERENT inboxes today, so the client-wide test agrees with the visit's property everywhere except
-- pairs 1650/499 and 1633/499 (visit on the billing duplicate 930 / visit with no property, while
-- sibling property 973 carries fred@ayache.com) and 52 visits that have an inbox on their own
-- property but no manifest yet. The rule is wrong by construction the first time one client has
-- locations in two municipalities, so it is corrected now rather than when it bites.
--
-- Expected row deltas (asserted by the dry run):
--   manifests:            city_total_count 1 -> 0 on manifests 1650 and 1633; every other column equal
--   manifest_recipients:  (1650,499) and (1633,499) has_city_email true -> false, municipality -> NULL
--   visits:               52 rows false -> true (own property has an inbox, no manifest linked),
--                         2 rows true -> false (7392, 7279); municipality follows; nothing else moves
--
-- Column lists and types unchanged, so CREATE OR REPLACE keeps grants (authenticated SELECT on all
-- three, service_role on manifests/visits). The DERM Tracker visit page ships its manifest_id check
-- FIRST (Building Apps/DERM Tracker/docs/08-changelog.md, same date), because has_city_email now
-- reads true on visits without a manifest and the old page enabled the button on that flag alone.
--
-- Companion: supabase/functions/send-derm-email resolves the property through the manifest's visits
-- when the caller supplies none (the DERM app never does), instead of the client-wide union.

begin;

create or replace view derm.manifests as
WITH grp AS (
         SELECT s.gk,
            array_agg(DISTINCT s.url) FILTER (WHERE ((s.kind = 'a'::text) AND (s.url IS NOT NULL))) AS addr_urls,
            array_agg(DISTINCT s.url) FILTER (WHERE ((s.kind = 'm'::text) AND (s.url IS NOT NULL))) AS man_urls
           FROM ( SELECT COALESCE(d2.white_manifest_number, d2.yellow_ticket_number, ('id:'::text || (d2.id)::text)) AS gk,
                    'a'::text AS kind,
                    unnest(array_prepend(d2.derm_address_url, COALESCE(d2.derm_address_extra_urls, ARRAY[]::text[]))) AS url
                   FROM derm_manifests d2
                  WHERE (d2.deleted_at IS NULL)
                UNION ALL
                 SELECT COALESCE(d2.white_manifest_number, d2.yellow_ticket_number, ('id:'::text || (d2.id)::text)) AS "coalesce",
                    'm'::text AS text,
                    unnest(array_prepend(d2.derm_manifest_url, COALESCE(d2.derm_manifest_extra_urls, ARRAY[]::text[]))) AS unnest
                   FROM derm_manifests d2
                  WHERE (d2.deleted_at IS NULL)) s
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
          WHERE ((es.manifest_id = w.id) AND (es.recipient_type = 'city'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))) AS city_emailed_count,
    ( SELECT count(DISTINCT vv.client_id) AS count
           FROM (manifest_visits mv
             JOIN visits vv ON (((vv.id = mv.visit_id) AND (vv.deleted_at IS NULL))))
          WHERE ((mv.manifest_id = w.id) AND (EXISTS ( SELECT 1
                   FROM properties p
                  WHERE ((p.id = vv.property_id) AND (p.deleted_at IS NULL) AND (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0)))))) AS city_total_count,
    address_photo_extra_urls,
    manifest_photo_extra_urls,
    ( SELECT c2.client_code
           FROM clients c2
          WHERE (c2.id = w.client_id)) AS client_code
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
                  WHERE ((es.manifest_id = sub.id) AND (es.recipient_type = 'client'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))) AS emailed_client_count,
            ( SELECT count(DISTINCT v.client_id) AS count
                   FROM (manifest_visits mv
                     JOIN visits v ON ((v.id = mv.visit_id)))
                  WHERE ((mv.manifest_id = sub.id) AND (v.deleted_at IS NULL) AND (v.client_id IS NOT NULL))) AS total_client_count
           FROM ( SELECT dm.id,
                    dm.white_manifest_number AS manifest_number,
                    'WHITE'::text AS manifest_type,
                    dm.derm_manifest_url AS manifest_photo_url,
                    dm.derm_address_url AS address_photo_url,
                    (dm.dump_ticket_date)::text AS dump_date,
                    df.name AS dump_location,
                    NULL::text AS driver_name,
                    NULL::numeric AS gallons,
                    (dm.created_at)::text AS created_at,
                    dm.client_id,
                        CASE
                            WHEN ((c.client_code IS NOT NULL) AND (c.name !~~ (c.client_code || '%'::text))) THEN ((c.client_code || ' '::text) || c.name)
                            ELSE c.name
                        END AS client_name,
                    (dm.service_date)::text AS service_date,
                    dm.yellow_ticket_number,
                    dm.wwtp_receipt_number,
                    dm.wwtp_receipt_document_path,
                    dm.wwtp_ticket_number,
                    dm.disposal_facility_id,
                    dm.sent_to_client,
                    dm.sent_to_city,
                    (dm.updated_at)::text AS updated_at,
                        CASE
                            WHEN (dm.yellow_ticket_number IS NOT NULL) THEN 'broward'::text
                            WHEN ((dm.white_manifest_number IS NOT NULL) AND (length(dm.white_manifest_number) >= 5)) THEN 'dade'::text
                            ELSE 'unknown'::text
                        END AS jurisdiction,
                    COALESCE(
                        CASE
                            WHEN (dm.yellow_ticket_number IS NOT NULL) THEN dm.yellow_ticket_number
                            ELSE NULL::text
                        END,
                        CASE
                            WHEN ((dm.white_manifest_number IS NOT NULL) AND (length(dm.white_manifest_number) >= 5)) THEN dm.white_manifest_number
                            ELSE NULL::text
                        END) AS display_number,
                        CASE
                            WHEN (dm.yellow_ticket_number IS NOT NULL) THEN ('Broward #'::text || dm.yellow_ticket_number)
                            WHEN ((dm.white_manifest_number IS NOT NULL) AND (length(dm.white_manifest_number) >= 5)) THEN ('Miami-Dade #'::text || dm.white_manifest_number)
                            ELSE 'Pending paperwork'::text
                        END AS display_label,
                    dm.notes,
                    COALESCE(dm.derm_address_no, ( SELECT s.sheet_no
                           FROM ((derm.address_sheet_manifests l
                             JOIN derm.address_sheets s ON (((s.id = l.sheet_id) AND (s.deleted_at IS NULL))))
                             JOIN derm_manifests m2 ON (((m2.id = l.manifest_id) AND (m2.deleted_at IS NULL))))
                          WHERE (COALESCE(m2.white_manifest_number, m2.yellow_ticket_number) = COALESCE(dm.white_manifest_number, dm.yellow_ticket_number))
                          ORDER BY s.sheet_no
                         LIMIT 1)) AS derm_address_no,
                    array_remove(COALESCE(gs.addr_urls, ARRAY[]::text[]), dm.derm_address_url) AS address_photo_extra_urls,
                    array_remove(COALESCE(gs.man_urls, ARRAY[]::text[]), dm.derm_manifest_url) AS manifest_photo_extra_urls
                   FROM (((derm_manifests dm
                     LEFT JOIN clients c ON ((c.id = dm.client_id)))
                     LEFT JOIN disposal_facilities df ON ((df.id = dm.disposal_facility_id)))
                     LEFT JOIN grp gs ON ((gs.gk = COALESCE(dm.white_manifest_number, dm.yellow_ticket_number, ('id:'::text || (dm.id)::text)))))
                  WHERE (dm.deleted_at IS NULL)) sub) w;

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
           FROM ((manifest_visits mv
             JOIN visits v ON (((v.id = mv.visit_id) AND (v.deleted_at IS NULL) AND (v.client_id = w.client_id))))
             JOIN properties p ON (((p.id = v.property_id) AND (p.deleted_at IS NULL))))
          WHERE ((mv.manifest_id = w.manifest_id) AND (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0)))) AS has_city_email,
    ( SELECT string_agg(DISTINCT p.city, ', '::text) AS string_agg
           FROM ((manifest_visits mv
             JOIN visits v ON (((v.id = mv.visit_id) AND (v.deleted_at IS NULL) AND (v.client_id = w.client_id))))
             JOIN properties p ON (((p.id = v.property_id) AND (p.deleted_at IS NULL))))
          WHERE ((mv.manifest_id = w.manifest_id) AND (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0) AND (NULLIF(btrim(p.city), ''::text) IS NOT NULL))) AS municipality,
    ( SELECT max(es.sent_at) AS max
           FROM derm_email_sends es
          WHERE ((es.manifest_id = w.manifest_id) AND (es.client_id = w.client_id) AND (es.recipient_type = 'city'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))) AS city_last_emailed_at
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
                  WHERE ((es.manifest_id = sub.manifest_id) AND (es.client_id = sub.client_id) AND (es.recipient_type = 'client'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))) AS last_emailed_at
           FROM ( SELECT m.id AS manifest_id,
                    m.display_number,
                    m.display_label,
                    m.jurisdiction,
                    r.client_id,
                        CASE
                            WHEN ((cl.client_code IS NOT NULL) AND (cl.client_code <> ''::text)) THEN ((cl.client_code || ' '::text) || cl.name)
                            ELSE cl.name
                        END AS client_name,
                    (m.manifest_photo_url IS NOT NULL) AS has_pdf,
                    (EXISTS ( SELECT 1
                           FROM client_contacts cc
                          WHERE ((cc.client_id = r.client_id) AND (cc.email IS NOT NULL) AND (cc.email <> ''::text)))) AS has_email,
                    ( SELECT max(v.visit_date) AS max
                           FROM (manifest_visits mv
                             JOIN visits v ON ((v.id = mv.visit_id)))
                          WHERE ((mv.manifest_id = m.id) AND (v.client_id = r.client_id) AND (v.deleted_at IS NULL))) AS visit_date
                   FROM ((derm.manifests m
                     JOIN LATERAL ( SELECT DISTINCT v.client_id
                           FROM (manifest_visits mv
                             JOIN visits v ON ((v.id = mv.visit_id)))
                          WHERE ((mv.manifest_id = m.id) AND (v.deleted_at IS NULL) AND (v.client_id IS NOT NULL))) r ON (true))
                     JOIN clients cl ON ((cl.id = r.client_id)))) sub) w;

create or replace view derm.visits as
SELECT id,
    client_name,
    address,
    county,
    visit_date,
    technician,
    notes,
    created_at,
    client_id,
    service_type,
    has_manifest,
    derm_required,
    needs_manifest,
    line_items,
    line_items_json,
    gdo_number,
    job_number,
    last_emailed_at,
    city_last_emailed_at,
    crew,
    completed_at,
    manifest_id,
    has_pdf,
    has_client_email,
    has_city_email,
    municipality,
    ( SELECT max(es.sent_at) AS max
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'client'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))) AS client_last_emailed_at,
    ( SELECT es.recipient_email
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'client'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))
          ORDER BY es.sent_at DESC
         LIMIT 1) AS client_last_email_to,
    ( SELECT cc.email
           FROM client_contacts cc
          WHERE ((cc.client_id = w3.client_id) AND (cc.email IS NOT NULL) AND (cc.email <> ''::text))
          ORDER BY cc.property_id NULLS FIRST, cc.contact_role DESC, cc.id
         LIMIT 1) AS client_email
   FROM ( SELECT w2.id,
            w2.client_name,
            w2.address,
            w2.county,
            w2.visit_date,
            w2.technician,
            w2.notes,
            w2.created_at,
            w2.client_id,
            w2.service_type,
            w2.has_manifest,
            w2.derm_required,
            w2.needs_manifest,
            w2.line_items,
            w2.line_items_json,
            w2.gdo_number,
            w2.job_number,
            w2.last_emailed_at,
            w2.city_last_emailed_at,
            w2.crew,
            w2.completed_at,
            em.manifest_id,
            COALESCE(em.has_pdf, false) AS has_pdf,
            COALESCE(em.has_email, false) AS has_client_email,
            COALESCE(vp.has_city_email, false) AS has_city_email,
            vp.municipality
           FROM ((( SELECT dv.id,
                    dv.client_name,
                    dv.address,
                    dv.county,
                    dv.visit_date,
                    dv.technician,
                    dv.notes,
                    dv.created_at,
                    dv.client_id,
                    dv.service_type,
                    dv.has_manifest,
                    dv.derm_required,
                    dv.needs_manifest,
                    dv.line_items,
                    dv.line_items_json,
                    dv.gdo_number,
                    dv.job_number,
                    dv.last_emailed_at,
                    dv.city_last_emailed_at,
                    ( SELECT string_agg(DISTINCT e.full_name, ', '::text) AS string_agg
                           FROM (visit_team vt
                             JOIN employees e ON ((e.id = vt.employee_id)))
                          WHERE (vt.visit_id = dv.id)) AS crew,
                    ( SELECT v.completed_at
                           FROM visits v
                          WHERE (v.id = dv.id)) AS completed_at
                   FROM ( SELECT _dv.id,
                            _dv.client_name,
                            _dv.address,
                            _dv.county,
                            _dv.visit_date,
                            _dv.technician,
                            _dv.notes,
                            _dv.created_at,
                            _dv.client_id,
                            _dv.service_type,
                            _dv.has_manifest,
                            _dv.derm_required,
                            _dv.needs_manifest,
                            _dv.line_items,
                            _dv.line_items_json,
                            _dv.gdo_number,
                            _dv.job_number,
                            _dv.last_emailed_at,
                            _dv.city_last_emailed_at
                           FROM ( SELECT w.id,
                                    w.client_name,
                                    w.address,
                                    w.county,
                                    w.visit_date,
                                    w.technician,
                                    w.notes,
                                    w.created_at,
                                    w.client_id,
                                    w.service_type,
                                    w.has_manifest,
                                    w.derm_required,
                                    w.needs_manifest,
                                    w.line_items,
                                    w.line_items_json,
                                    w.gdo_number,
                                    w.job_number,
                                    w.last_emailed_at,
                                    ( SELECT max(es.sent_at) AS max
   FROM (manifest_visits mv
     JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
  WHERE ((mv.visit_id = w.id) AND (es.client_id = w.client_id) AND (es.recipient_type = 'city'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))) AS city_last_emailed_at
                                   FROM ( SELECT sub.id,
    sub.client_name,
    sub.address,
    sub.county,
    sub.visit_date,
    sub.technician,
    sub.notes,
    sub.created_at,
    sub.client_id,
    sub.service_type,
    sub.has_manifest,
    sub.derm_required,
    sub.needs_manifest,
    sub.line_items,
    sub.line_items_json,
    sub.gdo_number,
    sub.job_number,
    ( SELECT max(es.sent_at) AS max
     FROM (manifest_visits mv
       JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
    WHERE ((mv.visit_id = sub.id) AND (es.client_id = sub.client_id) AND (es.status = 'sent'::text) AND (es.is_test = false))) AS last_emailed_at
   FROM ( SELECT v.id,
    CASE
     WHEN ((c.client_code IS NOT NULL) AND (c.name !~~ (c.client_code || '%'::text))) THEN ((c.client_code || ' '::text) || c.name)
     ELSE c.name
    END AS client_name,
      COALESCE(p.address, ''::text) AS address,
      COALESCE(p.county, ''::text) AS county,
      (v.visit_date)::text AS visit_date,
      NULL::text AS technician,
      NULL::text AS notes,
      (v.created_at)::text AS created_at,
      v.client_id,
      v.service_type,
      (EXISTS ( SELECT 1
       FROM (manifest_visits mv
         JOIN derm_manifests dm ON ((dm.id = mv.manifest_id)))
      WHERE ((mv.visit_id = v.id) AND (dm.deleted_at IS NULL) AND ((dm.derm_manifest_url IS NOT NULL) OR (dm.derm_address_url IS NOT NULL))))) AS has_manifest,
      v.derm_required,
      COALESCE(v.derm_required, true) AS needs_manifest,
      COALESCE(( SELECT ((NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
         FROM line_items li
        WHERE ((li.visit_id = v.id) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text))))
       FROM jobs j
      WHERE ((j.id = v.job_id) AND (j.title IS NOT NULL) AND (TRIM(BOTH FROM j.title) <> ''::text) AND (( SELECT COALESCE(sum(li2.total_price), (0)::numeric) AS "coalesce"
         FROM line_items li2
        WHERE (li2.visit_id = v.id)) > (0)::numeric) AND (EXISTS ( SELECT 1
         FROM line_items li
        WHERE ((li.visit_id = v.id) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text)))))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
       FROM line_items li
      WHERE ((li.visit_id = v.id) AND (( SELECT COALESCE(sum(li2.total_price), (0)::numeric) AS "coalesce"
         FROM line_items li2
        WHERE (li2.visit_id = v.id)) > (0)::numeric) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text))), ( SELECT ((NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
         FROM line_items li
        WHERE ((li.invoice_id = v.invoice_id) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text))))
       FROM jobs j
      WHERE ((j.id = v.job_id) AND (j.title IS NOT NULL) AND (TRIM(BOTH FROM j.title) <> ''::text) AND (EXISTS ( SELECT 1
         FROM line_items li
        WHERE ((li.invoice_id = v.invoice_id) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text)))))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
       FROM line_items li
      WHERE ((li.invoice_id = v.invoice_id) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text))), ( SELECT ((NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
         FROM line_items li
        WHERE ((li.job_id = v.job_id) AND (li.invoice_id IS NULL) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text))))
       FROM jobs j
      WHERE ((j.id = v.job_id) AND (j.title IS NOT NULL) AND (TRIM(BOTH FROM j.title) <> ''::text) AND (EXISTS ( SELECT 1
         FROM line_items li
        WHERE ((li.job_id = v.job_id) AND (li.invoice_id IS NULL) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text)))))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
       FROM line_items li
      WHERE ((li.job_id = v.job_id) AND (li.invoice_id IS NULL) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text))), ( SELECT ((NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
         FROM line_items li
        WHERE ((li.visit_id = v.id) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text))))
       FROM jobs j
      WHERE ((j.id = v.job_id) AND (j.title IS NOT NULL) AND (TRIM(BOTH FROM j.title) <> ''::text) AND (EXISTS ( SELECT 1
         FROM line_items li
        WHERE ((li.visit_id = v.id) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text)))))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
       FROM line_items li
      WHERE ((li.visit_id = v.id) AND (li.name IS NOT NULL) AND (NOT ((li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text) AND (li.name ~* '(fee|fees|%)'::text))) AND (li.name !~* '^\s*tax\s*$'::text))), NULLIF(TRIM(BOTH FROM split_part(v.title, ' - '::text, 2)), ''::text), ( SELECT NULLIF(TRIM(BOTH FROM j.title), ''::text) AS "nullif"
       FROM jobs j
      WHERE (j.id = v.job_id))) AS line_items,
      COALESCE(( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE ((li.visit_id = v.id) AND (( SELECT COALESCE(sum(li2.total_price), (0)::numeric) AS "coalesce"
         FROM line_items li2
        WHERE (li2.visit_id = v.id)) > (0)::numeric))), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE (li.invoice_id = v.invoice_id)), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE ((li.job_id = v.job_id) AND (li.invoice_id IS NULL))), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE (li.visit_id = v.id)), '[]'::jsonb) AS line_items_json,
      ( SELECT g.gdo_number
       FROM gdos g
      WHERE ((g.client_id = c.id) AND (g.status = 'ACTIVE'::text))
      ORDER BY g.id
     LIMIT 1) AS gdo_number,
      ( SELECT j.job_number
       FROM jobs j
      WHERE (j.id = v.job_id)) AS job_number
     FROM ((visits v
       JOIN clients c ON ((c.id = v.client_id)))
       LEFT JOIN LATERAL ( SELECT p2.address,
        p2.county
       FROM properties p2
      WHERE (p2.client_id = c.id)
      ORDER BY p2.is_primary DESC NULLS LAST, (p2.is_billing IS NOT TRUE) DESC, p2.id
     LIMIT 1) p ON (true))
    WHERE ((v.deleted_at IS NULL) AND (v.visit_status = 'completed'::text))) sub) w) _dv
                          WHERE (NOT (_dv.client_id IN ( SELECT clients.id
                                   FROM clients
                                  WHERE fn_is_non_customer(clients.id, ARRAY['dump_site'::text]))))) dv) w2
             LEFT JOIN LATERAL ( SELECT mr.manifest_id,
                    mr.has_pdf,
                    mr.has_email,
                    mr.has_city_email,
                    mr.municipality
                   FROM (manifest_visits mv
                     JOIN derm.manifest_recipients mr ON (((mr.manifest_id = mv.manifest_id) AND (mr.client_id = w2.client_id))))
                  WHERE (mv.visit_id = w2.id)
                  ORDER BY mr.manifest_id DESC
                 LIMIT 1) em ON (true))
             LEFT JOIN LATERAL ( SELECT (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0) AS has_city_email,
                        CASE
                            WHEN (cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0) THEN NULLIF(btrim(p.city), ''::text)
                            ELSE NULL::text
                        END AS municipality
                   FROM (visits v3
                     LEFT JOIN properties p ON (((p.id = v3.property_id) AND (p.deleted_at IS NULL))))
                  WHERE (v3.id = w2.id)) vp ON (true))) w3;

commit;
