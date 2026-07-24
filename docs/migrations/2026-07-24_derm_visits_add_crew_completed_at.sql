-- ============================================================================
-- 2026-07-24 - derm.visits: add crew + completed_at (DERM Tracker Visit Details section)
-- ============================================================================
-- Fred: on the DERM Tracker visit view (/visits/:id) add a "Details" section below
-- "Linked manifests" showing the key details of the visit. derm.visits already carries
-- client/address/county/service/derm_required/gdo/job/line_items_json/notes/dates; the two
-- missing "key details" are the CREW (technician column is hardcoded NULL) and the completion
-- timestamp. Added WITHOUT touching the deeply-nested existing definition, by wrapping it and
-- appending two columns (backward-compatible: existing 19 columns keep name+order+position).
-- AUDIT (ADR 010): opt-out - view only, no base table, no write path.
-- ============================================================================

CREATE OR REPLACE VIEW derm.visits AS
SELECT dv.*,
  ( SELECT string_agg(DISTINCT e.full_name, ', ')
      FROM public.visit_team vt JOIN public.employees e ON e.id = vt.employee_id
     WHERE vt.visit_id = dv.id ) AS crew,
  ( SELECT v.completed_at FROM public.visits v WHERE v.id = dv.id ) AS completed_at
FROM (
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
    city_last_emailed_at
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
                   FROM manifest_visits mv
                     JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
                  WHERE mv.visit_id = w.id AND es.client_id = w.client_id AND es.recipient_type = 'city'::text AND es.status = 'sent'::text AND es.is_test = false) AS city_last_emailed_at
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
                           FROM manifest_visits mv
                             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
                          WHERE mv.visit_id = sub.id AND es.client_id = sub.client_id AND es.status = 'sent'::text AND es.is_test = false) AS last_emailed_at
                   FROM ( SELECT v.id,
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
                          WHERE v.visit_status = 'completed'::text) sub) w) _dv
  WHERE NOT (client_id IN ( SELECT clients.id
           FROM clients
          WHERE clients.client_code = ANY (ARRAY['000-DH'::text, '000-DP'::text])))
) dv;
