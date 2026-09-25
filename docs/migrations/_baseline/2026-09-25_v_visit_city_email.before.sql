-- Baseline (pre-change) definition of public.v_visit_city_email, before 2026-09-25_0045 (md5 f2c63cd8df1e4cd70ce73e4ea7f03d8a).
-- CREATE OR REPLACE cannot drop the appended column: to restore exactly, DROP VIEW public.v_visit_city_email, run this,
-- then re-apply its grants (authenticated=arwdDxtm, service_role=arwdDxtm, yannick_readonly=r at the time).

CREATE VIEW public.v_visit_city_email AS
 SELECT v.id AS visit_id,
    p.city AS property_city,
        CASE
            WHEN (EXISTS ( SELECT 1
               FROM unnest(COALESCE(p.city_emails, '{}'::text[])) e(e)
              WHERE ((e.e IS NOT NULL) AND (POSITION(('@'::text) IN (e.e)) > 0)))) THEN p.city
            ELSE NULL::text
        END AS regulator_municipality,
    (EXISTS ( SELECT 1
           FROM unnest(COALESCE(p.city_emails, '{}'::text[])) e(e)
          WHERE ((e.e IS NOT NULL) AND (POSITION(('@'::text) IN (e.e)) > 0)))) AS city_email_on_file,
    ( SELECT COALESCE(array_agg(lower(btrim(e.e)) ORDER BY e.ord), '{}'::text[]) AS "coalesce"
           FROM unnest(COALESCE(p.city_emails, '{}'::text[])) WITH ORDINALITY e(e, ord)
          WHERE ((e.e IS NOT NULL) AND (POSITION(('@'::text) IN (e.e)) > 0))) AS city_emails
   FROM (v_visits_live v
     LEFT JOIN properties p ON ((p.id = v.property_id)));
