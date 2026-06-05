-- Migration: derm city-status view extensions (Send DERM to City)
-- Date:   2026-06-05
-- Author: Claude, directed by Fred (DERM Tracker — "Send DERM to City")
-- Design: Building Apps/DERM Tracker/docs/send-derm-to-city-design.md
--
-- Mirrors the client email-status surfaces with city columns. NEVER exposes the
-- regulator .gov address (booleans/labels only): the views read municipality_regulators
-- as the postgres view-owner (definer) — anon reads the views, never the locked base table.
--
-- City availability for a (manifest, client) = the client has a property whose city
-- matches an ACTIVE municipality_regulators.municipality (case-insensitive). Resolved via
-- the CLIENT'S properties (not the sparse visits.property_id — only 206/647 populated — so
-- this realizes the design's "all Surfside/Hallandale clients" intent; 73 covered pairs vs 14).
--
-- Applied as an idempotent wrap on the LIVE def (skips if the city column already exists),
-- preserving last_emailed_at / emailed_client_count and every other column.

SET search_path TO public;

-- (a) derm.manifest_recipients += has_city_email, municipality, city_last_emailed_at
DO $mig$
DECLARE body text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='derm' AND table_name='manifest_recipients' AND column_name='has_city_email') THEN
    body := rtrim(pg_get_viewdef('derm.manifest_recipients'::regclass, true), E' \n\r\t;');
    EXECUTE 'CREATE OR REPLACE VIEW derm.manifest_recipients AS SELECT w.*, '
      || '(EXISTS (SELECT 1 FROM public.properties p JOIN public.municipality_regulators mr ON lower(btrim(mr.municipality)) = lower(btrim(p.city)) AND mr.status = ''ACTIVE'' WHERE p.client_id = w.client_id)) AS has_city_email, '
      || '(SELECT string_agg(DISTINCT mr.municipality, '', '') FROM public.properties p JOIN public.municipality_regulators mr ON lower(btrim(mr.municipality)) = lower(btrim(p.city)) AND mr.status = ''ACTIVE'' WHERE p.client_id = w.client_id) AS municipality, '
      || '(SELECT max(es.sent_at) FROM public.derm_email_sends es WHERE es.manifest_id = w.manifest_id AND es.client_id = w.client_id AND es.recipient_type = ''city'' AND es.status = ''sent'' AND es.is_test = false) AS city_last_emailed_at '
      || 'FROM ( ' || body || ' ) w';
  END IF;
END
$mig$;

-- (b) derm.manifests += city_emailed_count, city_total_count
DO $mig$
DECLARE body text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='derm' AND table_name='manifests' AND column_name='city_emailed_count') THEN
    body := rtrim(pg_get_viewdef('derm.manifests'::regclass, true), E' \n\r\t;');
    EXECUTE 'CREATE OR REPLACE VIEW derm.manifests AS SELECT w.*, '
      || '(SELECT count(DISTINCT es.client_id) FROM public.derm_email_sends es WHERE es.manifest_id = w.id AND es.recipient_type = ''city'' AND es.status = ''sent'' AND es.is_test = false) AS city_emailed_count, '
      || '(SELECT count(DISTINCT vv.client_id) FROM public.manifest_visits mv JOIN public.visits vv ON vv.id = mv.visit_id AND vv.deleted_at IS NULL WHERE mv.manifest_id = w.id AND EXISTS (SELECT 1 FROM public.properties p JOIN public.municipality_regulators mr ON lower(btrim(mr.municipality)) = lower(btrim(p.city)) AND mr.status = ''ACTIVE'' WHERE p.client_id = vv.client_id)) AS city_total_count '
      || 'FROM ( ' || body || ' ) w';
  END IF;
END
$mig$;

-- (c) derm.visits += city_last_emailed_at
DO $mig$
DECLARE body text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='derm' AND table_name='visits' AND column_name='city_last_emailed_at') THEN
    body := rtrim(pg_get_viewdef('derm.visits'::regclass, true), E' \n\r\t;');
    EXECUTE 'CREATE OR REPLACE VIEW derm.visits AS SELECT w.*, '
      || '(SELECT max(es.sent_at) FROM public.manifest_visits mv JOIN public.derm_email_sends es ON es.manifest_id = mv.manifest_id WHERE mv.visit_id = w.id AND es.client_id = w.client_id AND es.recipient_type = ''city'' AND es.status = ''sent'' AND es.is_test = false) AS city_last_emailed_at '
      || 'FROM ( ' || body || ' ) w';
  END IF;
END
$mig$;

NOTIFY pgrst, 'reload schema';
