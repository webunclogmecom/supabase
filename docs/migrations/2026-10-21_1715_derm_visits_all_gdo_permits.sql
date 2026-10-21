-- 2026-10-21_1715_derm_visits_all_gdo_permits
-- Trello YAAcQNtJ "DERM Tracker: Casaneos (CS) shows only 1 of 3 GDOs after Oct 20 dump".
-- Diego (#new-app-issues, 2026-10-21): "the DERM tracker only gave me one Casaneos. As I understand we have three
-- different GDOs for CS so where are the other two?" Then: the city filing is fine (3 GDO filing confirmations).
-- Fred (2026-10-21): fix it where a GDO shows today (view only, no app change); leave the PSO permit out.
--
-- WHAT: derm.visits.gdo_number was the client's FIRST ACTIVE permit by id (LIMIT 1), with no format check.
-- It now lists EVERY ACTIVE GDO permit (^GDO-[0-9]+$), sorted by number, joined ", ", NULL when none. That is the
-- same rule as public.dump_visit_gdo_numbers, ops.v_calendar_visit.gdo_permits, the pdf-service _active_gdos and
-- derm.record_generated_sheet_preview: this was a fifth implementation that had drifted. Only the DERM Tracker
-- reads the column (Visits row, visit Details), so no app change.
-- Reach at write time: 64 rows on 4 clients showed one permit of several (009-CN 3, 043-MIL 2, 148-MOR 2,
-- 242-WYN 3; for 043-MIL and 148-MOR not even the first by number), 17 rows of 057-BAY showed PSO-00025 (a
-- private sanitary sewer permit, not a GDO). 754 rows already agreed, 584 have no permit.
-- NOT CHANGED: anything else in the view (one anchored edit to the live body, md5-guarded); the column name and
-- type (text); grants; the per-visit FDEP sheet (one per client on a Broward dump, Fred 2026-09-04); the GDO
-- Online Report (already one block per permit).
-- Rule 8: a view, no table change; nothing to audit.
-- Lock: CREATE OR REPLACE VIEW takes ACCESS EXCLUSIVE; lock_timeout 3s, and only cheap checks run inside (each
-- one ~0.5 s scan). The full nothing-else-moved comparison ran in the rehearsal and runs again after commit.
-- Rollback: 2026-10-21_rollback_derm_visits_all_gdo_permits.sql (rehearsed).

begin;
set local lock_timeout = '3s';
do $g$ begin
  if md5(pg_get_viewdef('derm.visits'::regclass)) <> '5f54c56ed9a8a3e6d20fb30c887b800d' then
    raise exception 'derm.visits changed since this migration was written (md5 %), re-read it', md5(pg_get_viewdef('derm.visits'::regclass));
  end if;
end $g$;
select set_config('yaa.n_before', (select count(*) from derm.visits)::text, true);
select set_config('yaa.cols', (select string_agg(attname || ':' || format_type(atttypid, atttypmod), ',' order by attnum) from pg_attribute
  where attrelid = 'derm.visits'::regclass and attnum > 0 and not attisdropped), true);
create or replace view derm.visits as
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
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false) AS client_last_emailed_at,
    ( SELECT string_agg(DISTINCT es.recipient_email, ', '::text) AS string_agg
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false AND COALESCE(es.resend_email_id, 'row:'::text || es.id::text) = (( SELECT COALESCE(es2.resend_email_id, 'row:'::text || es2.id::text) AS "coalesce"
                   FROM manifest_visits mv2
                     JOIN derm_email_sends es2 ON es2.manifest_id = mv2.manifest_id
                  WHERE mv2.visit_id = w3.id AND es2.client_id = w3.client_id AND es2.recipient_type = 'client'::text AND es2.status = 'sent'::text AND es2.is_test = false
                  ORDER BY es2.sent_at DESC
                 LIMIT 1))) AS client_last_email_to,
    client.fn_derm_recipient(w3.client_id) ->> 'email'::text AS client_email,
        CASE
            WHEN lc.sent_at IS NULL THEN NULL::text
            WHEN lc.sent_by_email IS NULL THEN
            CASE
                WHEN lc.sent_at >= '2026-07-22 00:00:00+00'::timestamp with time zone THEN 'Automatic'::text
                ELSE NULL::text
            END
            WHEN lower(btrim(lc.sent_by_email)) = 'contact@unclogme.com'::text THEN 'Office account'::text
            ELSE COALESCE(( SELECT emp.full_name
               FROM employees emp
              WHERE lower(btrim(emp.email)) = lower(btrim(lc.sent_by_email))
              ORDER BY emp.id
             LIMIT 1), lc.sent_by_email)
        END AS client_last_sent_by,
        CASE
            WHEN ly.sent_at IS NULL THEN NULL::text
            WHEN ly.sent_by_email IS NULL THEN
            CASE
                WHEN ly.sent_at >= '2026-07-22 00:00:00+00'::timestamp with time zone THEN 'Automatic'::text
                ELSE NULL::text
            END
            WHEN lower(btrim(ly.sent_by_email)) = 'contact@unclogme.com'::text THEN 'Office account'::text
            ELSE COALESCE(( SELECT emp.full_name
               FROM employees emp
              WHERE lower(btrim(emp.email)) = lower(btrim(ly.sent_by_email))
              ORDER BY emp.id
             LIMIT 1), ly.sent_by_email)
        END AS city_last_sent_by,
    ly.recipient_email AS city_last_email_to,
    tc.sent_at AS client_last_test_at,
        CASE
            WHEN tc.sent_at IS NULL THEN NULL::text
            WHEN tc.sent_by_email IS NULL THEN
            CASE
                WHEN tc.sent_at >= '2026-07-22 00:00:00+00'::timestamp with time zone THEN 'Automatic'::text
                ELSE NULL::text
            END
            WHEN lower(btrim(tc.sent_by_email)) = 'contact@unclogme.com'::text THEN 'Office account'::text
            ELSE COALESCE(( SELECT emp.full_name
               FROM employees emp
              WHERE lower(btrim(emp.email)) = lower(btrim(tc.sent_by_email))
              ORDER BY emp.id
             LIMIT 1), tc.sent_by_email)
        END AS client_last_test_by,
    tc.recipient_email AS client_last_test_to,
    ty.sent_at AS city_last_test_at,
        CASE
            WHEN ty.sent_at IS NULL THEN NULL::text
            WHEN ty.sent_by_email IS NULL THEN
            CASE
                WHEN ty.sent_at >= '2026-07-22 00:00:00+00'::timestamp with time zone THEN 'Automatic'::text
                ELSE NULL::text
            END
            WHEN lower(btrim(ty.sent_by_email)) = 'contact@unclogme.com'::text THEN 'Office account'::text
            ELSE COALESCE(( SELECT emp.full_name
               FROM employees emp
              WHERE lower(btrim(emp.email)) = lower(btrim(ty.sent_by_email))
              ORDER BY emp.id
             LIMIT 1), ty.sent_by_email)
        END AS city_last_test_by,
    ty.recipient_email AS city_last_test_to,
    ARRAY( SELECT r.value ->> 'email'::text
           FROM jsonb_array_elements(client.fn_derm_recipients(w3.client_id)) r(value)) AS client_emails,
    (EXISTS ( SELECT 1
           FROM v_visit_grey_water_pumping gwp
          WHERE gwp.visit_id = w3.id)) AS grey_water_pumping,
    w3.not_for_city
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
            vp.municipality,
            COALESCE(vp.not_for_city, false) AS not_for_city
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
        WHERE li.visit_id = v.id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))
       FROM jobs j
      WHERE j.id = v.job_id AND j.title IS NOT NULL AND TRIM(BOTH FROM j.title) <> ''::text AND (( SELECT COALESCE(sum(li2.total_price), 0::numeric) AS "coalesce"
         FROM line_items li2
        WHERE li2.visit_id = v.id)) > 0::numeric AND (EXISTS ( SELECT 1
         FROM line_items li
        WHERE li.visit_id = v.id AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text))), ( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
       FROM line_items li
      WHERE li.visit_id = v.id AND (( SELECT COALESCE(sum(li2.total_price), 0::numeric) AS "coalesce"
         FROM line_items li2
        WHERE li2.visit_id = v.id)) > 0::numeric AND li.name IS NOT NULL AND NOT (li.name ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::text AND li.name ~* '(fee|fees|%)'::text) AND li.name !~* '^\s*tax\s*$'::text), ( SELECT (NULLIF(TRIM(BOTH FROM j.title), ''::text) || ' - '::text) || (( SELECT string_agg(li.name, ', '::text ORDER BY li.id) AS string_agg
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
      WHERE li.visit_id = v.id AND (( SELECT COALESCE(sum(li2.total_price), 0::numeric) AS "coalesce"
         FROM line_items li2
        WHERE li2.visit_id = v.id)) > 0::numeric), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE li.invoice_id = v.invoice_id), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE li.job_id = v.job_id AND li.invoice_id IS NULL), ( SELECT NULLIF(jsonb_agg(jsonb_build_object('name', li.name, 'quantity', li.quantity, 'unit_price', li.unit_price, 'total_price', li.total_price) ORDER BY li.id), '[]'::jsonb) AS "nullif"
       FROM line_items li
      WHERE li.visit_id = v.id), '[]'::jsonb) AS line_items_json,
      ( SELECT string_agg(g.gdo_number, ', '::text ORDER BY (g.gdo_number COLLATE "C"))
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text AND g.gdo_number ~ '^GDO-[0-9]+$'::text) AS gdo_number,
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
    WHERE v.deleted_at IS NULL AND v.visit_status = 'completed'::text) sub) w) _dv
                          WHERE NOT (_dv.client_id IN ( SELECT clients.id
                                   FROM clients
                                  WHERE fn_is_non_customer(clients.id, ARRAY['dump_site'::text])))) dv) w2
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
             LEFT JOIN LATERAL ( SELECT x.has_inbox AND NOT x.not_for_city AS has_city_email,
                        CASE
                            WHEN x.has_inbox AND NOT x.not_for_city THEN x.city
                            ELSE NULL::text
                        END AS municipality,
                    x.not_for_city
                   FROM ( SELECT cardinality(COALESCE(p.city_emails, '{}'::text[])) > 0 AS has_inbox,
                            NULLIF(btrim(p.city), ''::text) AS city,
                            (EXISTS ( SELECT 1
                                   FROM v_visit_not_for_city nfc
                                  WHERE nfc.visit_id = v3.id)) AS not_for_city
                           FROM visits v3
                             LEFT JOIN properties p ON p.id = v3.property_id AND p.deleted_at IS NULL
                          WHERE v3.id = w2.id) x) vp ON true) w3
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = false
          ORDER BY es.sent_at DESC
         LIMIT 1) lc ON true
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'city'::text AND es.status = 'sent'::text AND es.is_test = false
          ORDER BY es.sent_at DESC
         LIMIT 1) ly ON true
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'client'::text AND es.status = 'sent'::text AND es.is_test = true
          ORDER BY es.sent_at DESC
         LIMIT 1) tc ON true
     LEFT JOIN LATERAL ( SELECT es.sent_at,
            es.recipient_email,
            es.sent_by_email
           FROM manifest_visits mv
             JOIN derm_email_sends es ON es.manifest_id = mv.manifest_id
          WHERE mv.visit_id = w3.id AND es.client_id = w3.client_id AND es.recipient_type = 'city'::text AND es.status = 'sent'::text AND es.is_test = true
          ORDER BY es.sent_at DESC
         LIMIT 1) ty ON true;
comment on column derm.visits.gdo_number is 'Every ACTIVE GDO permit of the visit''s client, numbers only (^GDO-[0-9]+$), sorted by number, joined by ", "; NULL when the client has none. Same set as public.dump_visit_gdo_numbers, ops.v_calendar_visit.gdo_permits, the pdf-service _active_gdos and derm.record_generated_sheet_preview (one rule, five readers). Was the first permit by id until 2026-10-21_1715 (Trello YAAcQNtJ: Casa Neos showed 1 of 3).';
do $v$
declare n_before bigint := current_setting('yaa.n_before')::bigint; n_after bigint; v text; bad bigint; acl text;
begin
  select count(*) into n_after from derm.visits;
  if n_after <> n_before then raise exception 'VERIFY 1: row count % -> %', n_before, n_after; end if;

  select gdo_number into v from derm.visits where id = 6570;
  if v is distinct from 'GDO-10877, GDO-15062, GDO-16389' then raise exception 'VERIFY 2: visit 6570 reads %', v; end if;

  if exists (select 1 from derm.visits dv join public.clients c on c.id = dv.client_id
             where c.client_code = '057-BAY' and dv.gdo_number is not null) then
    raise exception 'VERIFY 3: 057-BAY still shows a permit';
  end if;

  -- a one-permit client is unchanged (control: such a visit exists)
  select gdo_number into v from derm.visits dv where dv.client_id = (select client_id from public.gdos where gdo_number = 'GDO-11529' and status = 'ACTIVE' limit 1) limit 1;
  if v is distinct from 'GDO-11529' then raise exception 'VERIFY 4: one-permit control reads %', v; end if;

  -- every row equals the canonical rule (public.dump_visit_gdo_numbers)
  select count(*) into bad from derm.visits dv
    left join public.dump_visit_gdo_numbers((select array_agg(id) from derm.visits)) d on d.visit_id = dv.id
   where dv.gdo_number is distinct from nullif(array_to_string(d.gdo_numbers, ', '), '');
  if bad <> 0 then raise exception 'VERIFY 5: % rows differ from dump_visit_gdo_numbers', bad; end if;

  -- column list, types and grants unchanged
  if (select string_agg(attname || ':' || format_type(atttypid, atttypmod), ',' order by attnum) from pg_attribute
       where attrelid = 'derm.visits'::regclass and attnum > 0 and not attisdropped) <> current_setting('yaa.cols') then
    raise exception 'VERIFY 6: column list or types changed';
  end if;
  select relacl::text into acl from pg_class where oid = 'derm.visits'::regclass;
  if acl <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=arwdDxtm/postgres,db_backup_reader=r/postgres}' then
    raise exception 'VERIFY 7: grants changed: %', acl;
  end if;
  if (select reloptions from pg_class where oid = 'derm.visits'::regclass) is not null then raise exception 'VERIFY 8: reloptions set'; end if;
  raise notice 'VERIFY ok: % rows', n_after;
end $v$;
commit;
