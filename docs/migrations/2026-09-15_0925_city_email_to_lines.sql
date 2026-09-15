-- 2026-09-15_0925_city_email_to_lines.sql
--
-- WHY: THE MANUAL CITY DIALOGS MUST SHOW WHO RECEIVES THE EMAIL, NOW THAT SENDS ARE REAL.
-- ---------------------------------------------------------------------------
-- Fred, 2026-09-15: "verify what that means, like prefilling the emails to the City Email the
-- property have when sending it manually and so". Sends became real in 2026-09-15_0907. Both
-- dialogs used to show an editable test address; from this file they show the property's real
-- inbox(es), read-only, from two view columns that mirror EXACTLY what the mailers resolve:
--
--   public.v_visit_city_email.city_emails        (Admin Review "Send email to City?" dialog)
--     the visit's property: every city_emails element containing '@', trimmed, lower-cased, stored
--     order. Same filter send-visit-photos-email applies server-side from the same hour.
--     APPENDED as the 5th column; the four existing columns are row-identical (asserted).
--
--   derm.v_manifest_recipient_city_emails         (DERM Tracker "Send DERM to city" dialog)
--     one row per (manifest_id, client_id) of derm.manifest_recipients: the DISTINCT inboxes of
--     the properties of that client's non-deleted visits on that manifest, plus the municipality
--     string, mirroring send-derm-email's city branch (visits.property_id -> properties.city_emails,
--     '@' filter, trim, lower) and manifest_recipients.has_city_email (asserted: has_city_email is
--     true exactly where this view has at least one address).
--
-- RULE 8: views only. No table changes. Grants: the new derm view gets the same ACL as
-- derm.manifest_recipients (authenticated SELECT, nothing for anon).

BEGIN;

DO $do$
DECLARE v_def text; v_n integer;
BEGIN
  SELECT pg_get_viewdef('public.v_visit_city_email'::regclass, true) INTO v_def;
  IF v_def NOT LIKE '%city_email_on_file%' THEN RAISE EXCEPTION 'PRE 1: v_visit_city_email is not the 2026-08-21_2130 body'; END IF;
  IF v_def LIKE '%AS city_emails%' THEN RAISE EXCEPTION 'PRE 2: v_visit_city_email already exposes city_emails; this file has run'; END IF;
  SELECT count(*) INTO v_n FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'v_visit_city_email';
  IF v_n <> 4 THEN RAISE EXCEPTION 'PRE 3: v_visit_city_email has % columns (expected 4)', v_n; END IF;
  IF to_regclass('derm.v_manifest_recipient_city_emails') IS NOT NULL THEN RAISE EXCEPTION 'PRE 4: derm.v_manifest_recipient_city_emails already exists'; END IF;
END $do$;

CREATE TEMP TABLE _vce_before AS SELECT * FROM public.v_visit_city_email;
CREATE TEMP TABLE _vce_opts AS SELECT relacl::text AS acl, reloptions FROM pg_class WHERE oid = 'public.v_visit_city_email'::regclass;

CREATE OR REPLACE VIEW public.v_visit_city_email AS
 SELECT v.id AS visit_id,
    p.city AS property_city,
    CASE WHEN EXISTS ( SELECT 1
             FROM unnest(COALESCE(p.city_emails, '{}'::text[])) e(e)
            WHERE e.e IS NOT NULL AND POSITION(('@'::text) IN (e.e)) > 0)
         THEN p.city ELSE NULL::text END AS regulator_municipality,
    (EXISTS ( SELECT 1
           FROM unnest(COALESCE(p.city_emails, '{}'::text[])) e(e)
          WHERE e.e IS NOT NULL AND POSITION(('@'::text) IN (e.e)) > 0)) AS city_email_on_file,
    ( SELECT COALESCE(array_agg(lower(btrim(e.e)) ORDER BY e.ord), '{}'::text[])
        FROM unnest(COALESCE(p.city_emails, '{}'::text[])) WITH ORDINALITY e(e, ord)
       WHERE e.e IS NOT NULL AND POSITION(('@'::text) IN (e.e)) > 0) AS city_emails
   FROM v_visits_live v
     LEFT JOIN properties p ON p.id = v.property_id;

CREATE VIEW derm.v_manifest_recipient_city_emails AS
 SELECT mr.manifest_id,
        mr.client_id,
        COALESCE(x.city_emails, '{}'::text[]) AS city_emails,
        x.municipality
   FROM derm.manifest_recipients mr
   LEFT JOIN LATERAL (
        SELECT array_agg(DISTINCT e.addr ORDER BY e.addr) AS city_emails,
               string_agg(DISTINCT e.city, ', ') AS municipality
          FROM manifest_visits mv
          JOIN visits v ON v.id = mv.visit_id AND v.deleted_at IS NULL AND v.client_id = mr.client_id
          JOIN properties p ON p.id = v.property_id AND p.deleted_at IS NULL
          CROSS JOIN LATERAL (
                SELECT lower(btrim(ce.e)) AS addr, NULLIF(btrim(p.city), '') AS city
                  FROM unnest(COALESCE(p.city_emails, '{}'::text[])) ce(e)
                 WHERE ce.e IS NOT NULL AND POSITION('@' IN ce.e) > 0) e
         WHERE mv.manifest_id = mr.manifest_id) x ON true;

GRANT SELECT ON derm.v_manifest_recipient_city_emails TO authenticated;
REVOKE ALL ON derm.v_manifest_recipient_city_emails FROM anon;

DO $do$
DECLARE v_n integer; v_acl text; v_opts text[];
BEGIN
  SELECT count(*) INTO v_n FROM (
    (SELECT visit_id, property_city, regulator_municipality, city_email_on_file FROM public.v_visit_city_email
     EXCEPT ALL SELECT visit_id, property_city, regulator_municipality, city_email_on_file FROM _vce_before)
    UNION ALL
    (SELECT visit_id, property_city, regulator_municipality, city_email_on_file FROM _vce_before
     EXCEPT ALL SELECT visit_id, property_city, regulator_municipality, city_email_on_file FROM public.v_visit_city_email)) d;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: % row(s) differ on the four pre-existing columns', v_n; END IF;
  SELECT count(*) INTO v_n FROM public.v_visit_city_email WHERE city_email_on_file <> (cardinality(city_emails) > 0);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % row(s) where city_emails disagrees with city_email_on_file', v_n; END IF;
  SELECT count(*) INTO v_n FROM public.v_visit_city_email WHERE visit_id = 6217 AND cardinality(city_emails) >= 1;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: positive control visit 6217 (082-TFC, property 126) does not resolve an inbox'; END IF;
  SELECT relacl::text, reloptions INTO v_acl, v_opts FROM pg_class WHERE oid = 'public.v_visit_city_email'::regclass;
  IF v_acl IS DISTINCT FROM (SELECT acl FROM _vce_opts) OR v_opts IS DISTINCT FROM (SELECT reloptions FROM _vce_opts) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: grants or reloptions changed on v_visit_city_email';
  END IF;

  -- derm view: one row per manifest_recipients row, and the inbox test agrees with has_city_email on every row
  SELECT count(*) INTO v_n FROM (
    (SELECT manifest_id, client_id FROM derm.manifest_recipients EXCEPT ALL SELECT manifest_id, client_id FROM derm.v_manifest_recipient_city_emails)
    UNION ALL
    (SELECT manifest_id, client_id FROM derm.v_manifest_recipient_city_emails EXCEPT ALL SELECT manifest_id, client_id FROM derm.manifest_recipients)) d;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 5 FAILED: % (manifest, client) key(s) differ between manifest_recipients and the new view', v_n; END IF;
  SELECT count(*) INTO v_n
    FROM derm.manifest_recipients mr
    JOIN derm.v_manifest_recipient_city_emails x ON x.manifest_id = mr.manifest_id AND x.client_id = mr.client_id
   WHERE mr.has_city_email <> (cardinality(x.city_emails) > 0);
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 6 FAILED: % row(s) where the new view disagrees with manifest_recipients.has_city_email', v_n; END IF;
  SELECT count(*) INTO v_n FROM derm.v_manifest_recipient_city_emails WHERE manifest_id = 1929 AND client_id = 31 AND cardinality(city_emails) >= 1 AND municipality = 'Surfside';
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 7 FAILED: positive control manifest 1929 / client 31 (082-TFC) does not resolve its Surfside inbox'; END IF;
  IF NOT has_table_privilege('authenticated', 'derm.v_manifest_recipient_city_emails', 'SELECT') THEN RAISE EXCEPTION 'VERIFY 8 FAILED: authenticated cannot read the new view'; END IF;
  IF has_table_privilege('anon', 'derm.v_manifest_recipient_city_emails', 'SELECT') THEN RAISE EXCEPTION 'VERIFY 9 FAILED: anon can read the new view'; END IF;
  RAISE NOTICE 'VERIFY ok: v_visit_city_email exposes city_emails (4 old columns identical); derm.v_manifest_recipient_city_emails agrees with has_city_email on every row';
END $do$;

DROP TABLE _vce_before; DROP TABLE _vce_opts;
NOTIFY pgrst, 'reload schema';
COMMIT;
