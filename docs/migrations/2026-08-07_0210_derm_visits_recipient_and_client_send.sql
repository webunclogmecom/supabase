-- 2026-08-07_0210 — name the recipient before the click, and stop a CITY send counting as a CLIENT send
--
-- Follows 2026-08-07_0130. Both are for the DERM Tracker visit page send buttons Fred asked for.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- 🛑 A CORRECTNESS BUG IN EXISTING DATA, FOUND WHILE BUILDING THE FEATURE
-- ─────────────────────────────────────────────────────────────────────────────
-- `derm.visits.last_emailed_at` carries NO `recipient_type` predicate, while `city_last_emailed_at`
-- sitting directly beside it carries `AND es.recipient_type = 'city'`. So a send to the MUNICIPAL
-- REGULATOR sets the column the UI reads as "we emailed the client".
--
-- Measured on Prod today:
--     36  visits display as client-emailed
--     24  genuinely have a client send
--     12  are city-only sends showing as client sends
--
-- That is not cosmetic on this screen. The whole point of the new card is to answer "did this reach
-- the customer" before offering a resend, and on 12 visits it would have answered yes when no
-- customer was ever emailed. `client_last_emailed_at` is added with the correct predicate and the
-- card reads THAT. `last_emailed_at` is left in place untouched: `/manifests` still reads it, and
-- silently changing a column another screen depends on is how you turn a fix into an incident.
--
-- ⚠ THE SAME ASYMMETRY VERY LIKELY AFFECTS `/manifests`. `derm.manifest_recipients.last_emailed_at`
-- and `derm.manifests.emailed_client_count` are built the same way. Not fixed here because that
-- changes a screen Fred did not ask about, and the change flips rows from "Emailed" to "Not emailed
-- yet", which reads as a regression unless it is announced. Raised to Fred separately. Do not fix it
-- silently; fix it with a changelog line that calls it a correction.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- NAMING THE RECIPIENT BEFORE THE CLICK
-- ─────────────────────────────────────────────────────────────────────────────
-- A client send emails a real customer a regulator-facing compliance document, and there is no undo.
-- The confirm step must say WHERE it is going, which means the view has to expose the address the
-- backend will actually use.
--
-- 🛑 `client_email` REPRODUCES THE EDGE FUNCTION'S SELECTION EXACTLY, AND IS COUPLED TO IT.
-- `send-derm-email` picks the client recipient with:
--     ORDER BY property_id ASC NULLS FIRST, contact_role DESC, id ASC LIMIT 1
-- `contact_role DESC` is load-bearing: the vocabulary is accounting | city | primary (measured: 398
-- primary, 156 accounting, 22 city), so DESCENDING puts `primary` first. ASCENDING would name the
-- bookkeeper, and the UI would promise one address while the backend used another.
-- **If that ordering ever changes in the edge function, this column must change in the same commit.**
-- Verified today: resolves for 608 of 608 visits where `has_client_email` is true, zero misses.
--
-- `client_last_email_to` is the address the last REAL client send actually went to, so a resend
-- warning can say where the first copy landed rather than implying it went where we would send now.
--
-- ⚠ PII SCOPE. This puts a customer contact address on a view. `anon` has NO SELECT on `derm.visits`
-- (measured: only `authenticated` and `service_role`), so it is a staff-only exposure on an
-- auth-gated app, and `public.derm_email_sends` has RLS on with ZERO policies, so this view is the
-- only client-side route to any of it. The REGULATOR addresses remain unreachable: the city side
-- still exposes only `has_city_email` and `municipality`, never an address. Do not add one.
--
-- 3NF: all derived on read, nothing stored. Audit: views are not audited; the write path
-- (`public.derm_email_sends`) is already audit opt-in and RLS-locked and is untouched.

begin;

create or replace view derm.visits as
select w3.*,
       ( select max(es.sent_at)
           from public.manifest_visits mv
           join public.derm_email_sends es on es.manifest_id = mv.manifest_id
          where mv.visit_id = w3.id
            and es.client_id = w3.client_id
            and es.recipient_type = 'client'
            and es.status = 'sent'
            and es.is_test = false
       ) as client_last_emailed_at,
       ( select es.recipient_email
           from public.manifest_visits mv
           join public.derm_email_sends es on es.manifest_id = mv.manifest_id
          where mv.visit_id = w3.id
            and es.client_id = w3.client_id
            and es.recipient_type = 'client'
            and es.status = 'sent'
            and es.is_test = false
          order by es.sent_at desc
          limit 1
       ) as client_last_email_to,
       -- MUST mirror send-derm-email's ordering exactly. See the header before touching it.
       ( select cc.email
           from public.client_contacts cc
          where cc.client_id = w3.client_id
            and cc.email is not null
            and cc.email <> ''
          order by cc.property_id asc nulls first, cc.contact_role desc, cc.id asc
          limit 1
       ) as client_email
  from (
SELECT w2.id,
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
         LIMIT 1) em ON true
  ) w3;

commit;

-- VERIFY:
--   * 26 pre-existing columns keep name, type and order; exactly 3 appended
--   * row count unchanged at 974
--   * client_last_emailed_at is non-null on 24 visits, NOT 36 (the 12 city-only rows drop out)
--   * client_email is non-null wherever has_client_email is true (608 of 608)
--   * no regulator address is reachable: still only has_city_email + municipality on the city side
