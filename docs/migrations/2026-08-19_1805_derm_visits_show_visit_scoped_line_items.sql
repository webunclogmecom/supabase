-- ============================================================================
-- 2026-08-19 18:05 ET  Show a visit's OWN line items on the DERM visit page
-- ============================================================================
-- Fred, on visit 7751 (306-16 16 Handles, 8/12/2026): "at the Details section it's not showing the
-- line items of the visit, does is this also happening to other visits? we need to put the line
-- items too, also how much was it for the visit and quantity etc"
--
-- It happens to others. Measured across completed visits:
--     1,017  render line items today
--        28  render NOTHING while holding real visit-scoped line items   <- the bug
--         6  genuinely have no line items anywhere
--
-- CAUSE. Both `line_items` (the text summary behind the Details "Service" line) and
-- `line_items_json` (the priced table) COALESCE over INVOICE-scoped rows, then JOB-scoped rows, and
-- then give up. Neither ever looks at `li.visit_id = v.id`. A visit whose items are attached to the
-- VISIT and to nothing else therefore falls all the way through to the job-title fallback: 7751
-- displayed "Service call" while holding "09 - Service Call - Pumping - Grease Trap & Tank
-- Cleaning", qty 1, and 5786 displayed "Grease Trap Pumping" while holding two real items
-- including a $1,400 one.
--
-- FIX. A visit-scoped branch is appended as the LAST scope in both COALESCEs, above only the
-- title-only fallbacks. Invoice and job scope still win wherever they matched before, so no visit
-- that renders today changes. Proven, not asserted: all 1,051 rows were snapshotted before and
-- after and diffed by id, and exactly the expected set moved.
--
-- ⚠ THE BODY WAS COPIED FROM pg_get_viewdef AND PATCHED AT TWO VERIFIED ANCHORS, never retyped
-- (repo rule: CREATE OR REPLACE takes the WHOLE body, so anything not reproduced is deleted).
-- Each anchor was asserted to match exactly once and the diff is two hunks, both pure additions.
--
-- 🛑 WHAT THIS DELIBERATELY DOES **NOT** CHANGE, AND IT IS A REAL PROBLEM FOR FRED TO RULE ON:
-- PRECEDENCE. Where a visit has both, invoice scope still wins, and that is often not this visit's
-- work. 113 visits share an invoice with another visit, so the card shows the WHOLE invoice as if
-- it were one visit's. A live example: the invoice reads Hydrojet $399 + Manual Unclogging $225 +
-- ACH $2.25, while the visit itself is only the $399 Hydrojet - the $225 belongs to a different
-- visit on the same invoice. A further 374 visits have a 1:1 invoice whose SERVICE lines still
-- differ from the visit's own. Flipping to visit-scoped-first would change what roughly 900 visit
-- pages display and directly answers "how much was it for the visit", so it is his call, not a
-- silent side effect of a bug fix.
-- (An earlier read of ONE visit showed the two sets identical and nearly became "they are copies".
-- They are not: 683 of 950 differ. One row is not a sample.)
--
-- Audit rule 8: a view, no triggers, no opt-in required.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

CREATE OR REPLACE VIEW derm.visits AS
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
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false) AS client_last_emailed_at,
    ( SELECT es.recipient_email
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false
          ORDER BY es.sent_at DESC
         LIMIT 1) AS client_last_email_to,
    ( SELECT cc.email
           FROM client_contacts cc
          WHERE cc.client_id = w3.client_id AND cc.email IS NOT NULL AND cc.email <> ''::text
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
            COALESCE(em.has_city_email, false) AS has_city_email,
            em.municipality
           FROM ( SELECT dv.id,
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
                           FROM visit_team vt
                             JOIN employees e ON e.id = vt.employee_id
                          WHERE vt.visit_id = dv.id) AS crew,
                    ( SELECT v.completed_at
                           FROM visits v
                          WHERE v.id = dv.id) AS completed_at
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
      WHERE li.job_id = v.job_id AND li.invoice_id IS NULL AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text), ( SELECT (NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || (( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
         FROM line_items li
        WHERE li.visit_id = v.id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))
       FROM jobs j
      WHERE j.id = v.job_id AND j.title IS NOT NULL AND TRIM(BOTH FROM j.title) <> ''::text AND (EXISTS ( SELECT 1
         FROM line_items li
        WHERE li.visit_id = v.id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
       FROM line_items li
      WHERE li.visit_id = v.id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text), NULLIF(TRIM(BOTH FROM split_part(v.title, ' - '::text, 2)), ''::text), ( SELECT NULLIF(TRIM(BOTH FROM j.title), ''::text) AS "nullif"
       FROM jobs j
      WHERE j.id = v.job_id)) AS line_items,
      COALESCE(( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE li.invoice_id = v.invoice_id), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE li.job_id = v.job_id AND li.invoice_id IS NULL), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE li.visit_id = v.id), '[]'::jsonb) AS line_items_json,
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
                          WHERE NOT (_dv.client_id IN ( SELECT clients.id
                                   FROM clients
                                  WHERE clients.client_code = ANY (ARRAY['000-DH'::text, '000-DP'::text])))) dv) w2
             LEFT JOIN LATERAL ( SELECT mr.manifest_id,
                    mr.has_pdf,
                    mr.has_email,
                    mr.has_city_email,
                    mr.municipality
                   FROM manifest_visits mv
                     JOIN derm.manifest_recipients mr ON mr.manifest_id = mv.manifest_id AND mr.client_id = w2.client_id
                  WHERE mv.visit_id = w2.id
                  ORDER BY mr.manifest_id DESC
                 LIMIT 1) em ON true) w3;

COMMIT;
