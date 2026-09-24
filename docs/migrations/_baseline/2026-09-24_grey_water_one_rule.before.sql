-- Baseline (pre-change) definitions of the objects changed by 2026-09-24_1920_grey_water_one_rule_and_free_text.sql.
-- Rollback: run this whole file. It restores the three views and the classifier (CREATE OR REPLACE keeps their
-- ACLs), puts back the 1615 column comment, then drops the two new objects, in that order.
-- Unqualified names resolve on the default search_path, as when these were captured.

-- public.fn_line_item_requires_derm (md5 8c272167ef33ef1751a237bd71a09341)
CREATE OR REPLACE FUNCTION public.fn_line_item_requires_derm(p_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE
    WHEN p_name IS NULL OR btrim(p_name) = '' THEN NULL
    -- (a) taxonomy-formatted "NN - ..." -> authoritative flag by code.
    --     ⚠ A fee/admin line answers NULL, not FALSE: it does not say whether the work
    --     needed a manifest, and FALSE would be read as "definitively not required".
    WHEN substring(btrim(p_name) from '^([0-9]{1,2})\s*-\s') IS NOT NULL THEN
      (SELECT CASE WHEN s.reason IN ('fee', 'other') THEN NULL ELSE s.requires_derm END
         FROM public.service_line_items s
        WHERE s.code = lpad(substring(btrim(p_name) from '^([0-9]{1,2})\s*-\s'), 2, '0'))
    -- (b) free-text PUMPING: a regulated vessel (grease trap/interceptor, grey water, lift station)
    --     near a pump word (either order), or an explicit pump-out (any word-form).
    WHEN btrim(p_name) ~* '(grease\s*tr?ap|grease\s*interceptor|interceptor|grey\s*water|greywater|(lift|lyft)\s*station)[^,]*pump'
      OR btrim(p_name) ~* 'pump[a-z]*[^,]*(grease\s*tr?ap|grease\s*interceptor|interceptor|grey\s*water|greywater|(lift|lyft)\s*station)'
      OR btrim(p_name) ~* 'pump(ed|ing|s)?\s*[- ]?out'
      THEN true
    -- (c) free-text recognized NON-pumping services / parts / fees
    --     ⚠ Left answering FALSE on purpose: this same branch covers clean/hydrojet/camera/
    --     labour, where FALSE is real evidence. Narrowing it is a separate change.
    WHEN btrim(p_name) ~* '(clean|hydrojet|unclog|camera|dye|assess|inspect|labou?r|\mpart|warrant|fee|tax|gdo|manifest|report|faucet|toilet|pipe|drain|install|repair|replace|locator|leak|smell|pictur|material|supply|\mdig|concret|cover|barrier|discount|credit|tip|commissary|ceiling|sump|plumb|cancel|removal|sample|mop|connection|brass|tapcon|union|p-?trap|reconnect|reinstal|drill|valve|emergency\s*visit|manhole|driver)'
      THEN false
    ELSE NULL
  END
$function$;

-- customer.work_orders (md5 8691c35a57b742d45deff6d2d50e892a)
CREATE OR REPLACE VIEW customer.work_orders AS
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
  WHERE ((v.visit_status = 'completed'::text) AND (v.client_id IS NOT NULL) AND ((COALESCE(v.derm_required, true) = true) OR (EXISTS ( WITH lc AS (
                 SELECT lpad("substring"(btrim(li.name), '^([0-9]{1,2})[[:space:]]*-[[:space:]]'::text), 2, '0'::text) AS code,
                        CASE
                            WHEN (li.visit_id = v.id) THEN 1
                            WHEN ((v.job_id IS NOT NULL) AND (li.job_id = v.job_id)) THEN 2
                            ELSE 3
                        END AS tier
                   FROM line_items li
                  WHERE ((li.name IS NOT NULL) AND ((li.visit_id = v.id) OR ((v.job_id IS NOT NULL) AND (li.job_id = v.job_id)) OR ((v.invoice_id IS NOT NULL) AND (li.invoice_id = v.invoice_id))))
                ), svc AS (
                 SELECT lc.code,
                    lc.tier
                   FROM (lc
                     JOIN service_line_items s ON ((s.code = lc.code)))
                  WHERE (s.reason <> ALL (ARRAY['fee'::text, 'other'::text]))
                )
         SELECT 1
           FROM svc
          WHERE ((svc.tier = ( SELECT min(svc_1.tier) AS min
                   FROM svc svc_1)) AND (svc.code IN ( SELECT service_line_items.code
                   FROM service_line_items
                  WHERE ((service_line_items.service_type = 'Pumping'::text) AND (service_line_items.location_target = 'Grey Water'::text)))))))) AND (v.deleted_at IS NULL));

-- derm.visits (md5 70ff5ed14c907d1f64010d6acfbaaaa0)
CREATE OR REPLACE VIEW derm.visits AS
 SELECT w3.id,
    w3.client_name,
    w3.address,
    w3.county,
    w3.visit_date,
    w3.technician,
    w3.notes,
    w3.created_at,
    w3.client_id,
    w3.service_type,
    w3.has_manifest,
    w3.derm_required,
    w3.needs_manifest,
    w3.line_items,
    w3.line_items_json,
    w3.gdo_number,
    w3.job_number,
    w3.last_emailed_at,
    w3.city_last_emailed_at,
    w3.crew,
    w3.completed_at,
    w3.manifest_id,
    w3.has_pdf,
    w3.has_client_email,
    w3.has_city_email,
    w3.municipality,
    ( SELECT max(es.sent_at) AS max
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'client'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))) AS client_last_emailed_at,
    ( SELECT string_agg(DISTINCT es.recipient_email, ', '::text) AS string_agg
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'client'::text) AND (es.status = 'sent'::text) AND (es.is_test = false) AND (COALESCE(es.resend_email_id, ('row:'::text || (es.id)::text)) = ( SELECT COALESCE(es2.resend_email_id, ('row:'::text || (es2.id)::text)) AS "coalesce"
                   FROM (manifest_visits mv2
                     JOIN derm_email_sends es2 ON ((es2.manifest_id = mv2.manifest_id)))
                  WHERE ((mv2.visit_id = w3.id) AND (es2.client_id = w3.client_id) AND (es2.recipient_type = 'client'::text) AND (es2.status = 'sent'::text) AND (es2.is_test = false))
                  ORDER BY es2.sent_at DESC
                 LIMIT 1)))) AS client_last_email_to,
    (client.fn_derm_recipient(w3.client_id) ->> 'email'::text) AS client_email,
        CASE
            WHEN (lc.sent_at IS NULL) THEN NULL::text
            WHEN (lc.sent_by_email IS NULL) THEN
            CASE
                WHEN (lc.sent_at >= '2026-07-22 00:00:00+00'::timestamp with time zone) THEN 'Automatic'::text
                ELSE NULL::text
            END
            WHEN (lower(btrim(lc.sent_by_email)) = 'contact@unclogme.com'::text) THEN 'Office account'::text
            ELSE COALESCE(( SELECT emp.full_name
               FROM employees emp
              WHERE (lower(btrim(emp.email)) = lower(btrim(lc.sent_by_email)))
              ORDER BY emp.id
             LIMIT 1), lc.sent_by_email)
        END AS client_last_sent_by,
        CASE
            WHEN (ly.sent_at IS NULL) THEN NULL::text
            WHEN (ly.sent_by_email IS NULL) THEN
            CASE
                WHEN (ly.sent_at >= '2026-07-22 00:00:00+00'::timestamp with time zone) THEN 'Automatic'::text
                ELSE NULL::text
            END
            WHEN (lower(btrim(ly.sent_by_email)) = 'contact@unclogme.com'::text) THEN 'Office account'::text
            ELSE COALESCE(( SELECT emp.full_name
               FROM employees emp
              WHERE (lower(btrim(emp.email)) = lower(btrim(ly.sent_by_email)))
              ORDER BY emp.id
             LIMIT 1), ly.sent_by_email)
        END AS city_last_sent_by,
    ly.recipient_email AS city_last_email_to,
    tc.sent_at AS client_last_test_at,
        CASE
            WHEN (tc.sent_at IS NULL) THEN NULL::text
            WHEN (tc.sent_by_email IS NULL) THEN
            CASE
                WHEN (tc.sent_at >= '2026-07-22 00:00:00+00'::timestamp with time zone) THEN 'Automatic'::text
                ELSE NULL::text
            END
            WHEN (lower(btrim(tc.sent_by_email)) = 'contact@unclogme.com'::text) THEN 'Office account'::text
            ELSE COALESCE(( SELECT emp.full_name
               FROM employees emp
              WHERE (lower(btrim(emp.email)) = lower(btrim(tc.sent_by_email)))
              ORDER BY emp.id
             LIMIT 1), tc.sent_by_email)
        END AS client_last_test_by,
    tc.recipient_email AS client_last_test_to,
    ty.sent_at AS city_last_test_at,
        CASE
            WHEN (ty.sent_at IS NULL) THEN NULL::text
            WHEN (ty.sent_by_email IS NULL) THEN
            CASE
                WHEN (ty.sent_at >= '2026-07-22 00:00:00+00'::timestamp with time zone) THEN 'Automatic'::text
                ELSE NULL::text
            END
            WHEN (lower(btrim(ty.sent_by_email)) = 'contact@unclogme.com'::text) THEN 'Office account'::text
            ELSE COALESCE(( SELECT emp.full_name
               FROM employees emp
              WHERE (lower(btrim(emp.email)) = lower(btrim(ty.sent_by_email)))
              ORDER BY emp.id
             LIMIT 1), ty.sent_by_email)
        END AS city_last_test_by,
    ty.recipient_email AS city_last_test_to,
    ARRAY( SELECT (r.value ->> 'email'::text)
           FROM jsonb_array_elements(client.fn_derm_recipients(w3.client_id)) r(value)) AS client_emails,
    (EXISTS ( SELECT 1
           FROM visits gv
          WHERE ((gv.id = w3.id) AND (EXISTS ( WITH gw_lc AS (
                         SELECT lpad("substring"(btrim(li.name), '^([0-9]{1,2})[[:space:]]*-[[:space:]]'::text), 2, '0'::text) AS code,
                                CASE
                                    WHEN (li.visit_id = gv.id) THEN 1
                                    WHEN ((gv.job_id IS NOT NULL) AND (li.job_id = gv.job_id)) THEN 2
                                    ELSE 3
                                END AS tier
                           FROM line_items li
                          WHERE ((li.name IS NOT NULL) AND ((li.visit_id = gv.id) OR ((gv.job_id IS NOT NULL) AND (li.job_id = gv.job_id)) OR ((gv.invoice_id IS NOT NULL) AND (li.invoice_id = gv.invoice_id))))
                        ), gw_svc AS (
                         SELECT gw_lc.code,
                            gw_lc.tier
                           FROM (gw_lc
                             JOIN service_line_items s ON ((s.code = gw_lc.code)))
                          WHERE (s.reason <> ALL (ARRAY['fee'::text, 'other'::text]))
                        )
                 SELECT 1
                   FROM gw_svc
                  WHERE ((gw_svc.tier = ( SELECT min(gw_svc_1.tier) AS min
                           FROM gw_svc gw_svc_1)) AND (gw_svc.code IN ( SELECT service_line_items.code
                           FROM service_line_items
                          WHERE ((service_line_items.service_type = 'Pumping'::text) AND (service_line_items.location_target = 'Grey Water'::text)))))))))) AS grey_water_pumping
   FROM ((((( SELECT w2.id,
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
                  WHERE (v3.id = w2.id)) vp ON (true))) w3
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'client'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))
          ORDER BY es.sent_at DESC
         LIMIT 1) lc ON (true))
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'city'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))
          ORDER BY es.sent_at DESC
         LIMIT 1) ly ON (true))
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'client'::text) AND (es.status = 'sent'::text) AND (es.is_test = true))
          ORDER BY es.sent_at DESC
         LIMIT 1) tc ON (true))
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'city'::text) AND (es.status = 'sent'::text) AND (es.is_test = true))
          ORDER BY es.sent_at DESC
         LIMIT 1) ty ON (true));

-- derm.v_lwt_grey_water_unlinked (md5 da1355a9d4f764210fa6a812a1f51509)
CREATE OR REPLACE VIEW derm.v_lwt_grey_water_unlinked AS
 SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    p.county,
    v.derm_required
   FROM ((visits v
     LEFT JOIN clients c ON ((c.id = v.client_id)))
     LEFT JOIN properties p ON ((p.id = v.property_id)))
  WHERE ((v.deleted_at IS NULL) AND (v.visit_status = 'completed'::text) AND (v.visit_date >= '2026-09-24'::date) AND (EXISTS ( SELECT 1
           FROM line_items li
          WHERE ((li.name IS NOT NULL) AND ((li.visit_id = v.id) OR ((v.invoice_id IS NOT NULL) AND (li.invoice_id = v.invoice_id)) OR ((v.job_id IS NOT NULL) AND (li.job_id = v.job_id))) AND (lpad("substring"(btrim(li.name), '^([0-9]{1,2})[[:space:]]*-[[:space:]]'::text), 2, '0'::text) IN ( SELECT service_line_items.code
                   FROM service_line_items
                  WHERE ((service_line_items.service_type = 'Pumping'::text) AND (service_line_items.location_target = 'Grey Water'::text))))))) AND (NOT (EXISTS ( SELECT 1
           FROM (manifest_visits mv
             JOIN derm_manifests m ON ((m.id = mv.manifest_id)))
          WHERE ((mv.visit_id = v.id) AND (m.deleted_at IS NULL))))));

-- derm.visits.grey_water_pumping: the column comment 2026-09-24_1615 set (the 1920 file rewrote it).
COMMENT ON COLUMN derm.visits.grey_water_pumping IS 'TRUE when the visit is grey water pumping by the same rule as the customer.work_orders grey water arm (catalogue Pumping + Grey Water; own coded lines first, then job, then invoice; fee/other codes abstain). Such a visit stays in the client''s Field Portal when DERM not required, so the DERM Tracker bulk dialog does not count it as hidden (2026-09-24). Never NULL.';

-- Last, the two new objects. Only after everything above: the restored views and classifier no longer
-- reference them, and the view must go before the function it calls.
DROP VIEW public.v_visit_grey_water_pumping;
DROP FUNCTION public.fn_line_item_is_free_text_grey_water(text);

NOTIFY pgrst, 'reload schema';
