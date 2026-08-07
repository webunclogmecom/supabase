-- 2026-08-07_0130 — the visit page can tell whether a DERM email can be sent, and to whom
--
-- Fred: "on the derm app when looking at a visit, and if that visit has the availability to send an
-- email to the client, add the button to send an email to the client, same with the city, but
-- remember that the button to send an email to the city is disabled until said otherwise."
--
-- THE GAP THIS CLOSES. The DERM Tracker visit page reads `derm.visits`, which carries
-- `last_emailed_at` and `city_last_emailed_at` (WHEN we last sent) but nothing about whether a send
-- is POSSIBLE. It does not even expose `manifest_id`, which the send call needs. So the page could
-- render "emailed 3 days ago" and had no way to render "can be emailed" or, more importantly, "cannot
-- be emailed, and here is why". Fred asked for the disabled-with-reason state, which is unbuildable
-- without these five columns.
--
-- WHAT IS ADDED (all append-only, all derived, nothing stored):
--   manifest_id       bigint  the manifest this visit's client is a recipient on; NULL = no manifest
--                             linked yet, which is itself a reason to disable the button
--   has_pdf           bool    both DERM PDFs are on the manifest (address sheet + transporter form)
--   has_client_email  bool    this client has a contact email on file
--   has_city_email    bool    this client's municipality is a COVERED regulator (Surfside or
--                             Hallandale Beach today; 112 eligible manifest/client pairs)
--   municipality      text    the label to show; never the .gov address
--
-- 🛑 THE .GOV ADDRESSES ARE NOT EXPOSED AND MUST NOT BE. `public.municipality_regulators` is
-- RLS-LOCKED precisely so the regulator addresses never reach a browser, and
-- `derm.manifest_recipients` already launders that into booleans and a label. This view inherits that
-- discipline: `has_city_email` and `municipality`, never `emails`. Same for the client: a boolean,
-- never `recipient_email`. If a future column here would carry an actual address, it does not belong.
--
-- ⚠ THE BODY IS COPIED, NOT RETYPED. The existing definition is 8.3KB and five levels of nesting
-- deep. It was read from `pg_get_viewdef('derm.visits', true)` and embedded verbatim, then wrapped.
-- Retyping it is how `2026-08-06_1316` silently dropped six guards earlier today. Do the same next
-- time: read the live definition, wrap it, never re-transcribe it.
--
-- ⚠ NO CIRCULAR DEPENDENCY, CHECKED BEFORE WRITING. `derm.manifest_recipients` reads
-- `public.visits`, NOT `derm.visits`, so joining it from here is safe. Verified via pg_depend;
-- nothing at all depends on `derm.visits`, so the replace cannot break a downstream view.
--
-- 3NF: no new stored column, every addition is derived on read from the manifest link and the
-- recipient view. Audit: views are not audited; the underlying write path
-- (`public.derm_email_sends`) is already audit opt-in and RLS-locked, unchanged here.

begin;

create or replace view derm.visits as
select w2.*,
       em.manifest_id,
       coalesce(em.has_pdf, false)        as has_pdf,
       coalesce(em.has_email, false)      as has_client_email,
       coalesce(em.has_city_email, false) as has_city_email,
       em.municipality
  from (
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
                  WHERE clients.client_code = ANY (ARRAY['000-DH'::text, '000-DP'::text])))) dv
  ) w2
  -- One recipient row per (manifest, client). A visit's client is a recipient on the manifest its
  -- visit is linked to. `order by` + `limit 1` because a client can in principle appear on more than
  -- one manifest for the same visit through a re-file; the most recent manifest is the actionable one.
  left join lateral (
    select mr.manifest_id, mr.has_pdf, mr.has_email, mr.has_city_email, mr.municipality
      from public.manifest_visits mv
      join derm.manifest_recipients mr
        on mr.manifest_id = mv.manifest_id
       and mr.client_id   = w2.client_id
     where mv.visit_id = w2.id
     order by mr.manifest_id desc
     limit 1
  ) em on true;

commit;

-- VERIFY:
--   * the 21 pre-existing columns keep their names, types and order (CREATE OR REPLACE enforces it,
--     but confirm, because a silent reorder would break the app's explicit .select() lists)
--   * manifest_id is non-null for visits that have a linked manifest, and NULL for those that do not
--   * has_client_email / has_city_email agree with derm.manifest_recipients for the same pair
--   * no row count change: wrapping with a LEFT JOIN LATERAL ... LIMIT 1 must not multiply rows
--   * no regulator address and no client address is reachable through this view
