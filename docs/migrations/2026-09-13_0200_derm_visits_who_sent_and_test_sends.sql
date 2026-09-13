-- 2026-09-13_0200  derm.visits says who sent the DERM email, where, and labels test sends
--
-- Fred, 2026-09-13 (the DERM app visit view): the client and city rows must say "on <time> by <name>",
-- and a test send must be visible as a test instead of leaving the page on "Not sent to the city yet."
-- (which is what it says today after every send while city_email_live_sends = false).
--
-- Nine columns APPENDED to derm.visits, each read from the SAME row as its *_at partner (newest
-- status = 'sent' row for this visit's manifest and client, real = is_test false, test = is_test true):
--   client_last_sent_by, city_last_sent_by, city_last_email_to            (real sends; the *_at exist)
--   client_last_test_at, client_last_test_by, client_last_test_to           (last test send, client)
--   city_last_test_at,   city_last_test_by,   city_last_test_to             (last test send, city)
-- The sender label: employees.full_name by sent_by_email; 'Office account' for contact@unclogme.com;
-- 'Automatic' when sent_by_email is NULL on a row written after 2026-07-22 (the column exists since
-- 2026-07-21h, so a later NULL is a machine send: the sweep, or a service-role script); NULL when the
-- row predates the column (17 real city rows from July, 34 client rows), the app then prints no "by".
-- Column list and types of the existing columns unchanged (asserted), so grants are kept.

begin;

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
         LIMIT 1) AS client_email,
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
    ty.recipient_email AS city_last_test_to
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
                  WHERE (v3.id = w2.id)) vp ON (true))) w3
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'client'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))
          ORDER BY es.sent_at DESC
         LIMIT 1) lc ON (true)
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'city'::text) AND (es.status = 'sent'::text) AND (es.is_test = false))
          ORDER BY es.sent_at DESC
         LIMIT 1) ly ON (true)
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'client'::text) AND (es.status = 'sent'::text) AND (es.is_test = true))
          ORDER BY es.sent_at DESC
         LIMIT 1) tc ON (true)
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM (manifest_visits mv
             JOIN derm_email_sends es ON ((es.manifest_id = mv.manifest_id)))
          WHERE ((mv.visit_id = w3.id) AND (es.client_id = w3.client_id) AND (es.recipient_type = 'city'::text) AND (es.status = 'sent'::text) AND (es.is_test = true))
          ORDER BY es.sent_at DESC
         LIMIT 1) ty ON (true);

commit;
