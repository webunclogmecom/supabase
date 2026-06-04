-- Migration: fix derm.manifest_recipients + derm.manifests.total_client_count
-- Date:   2026-06-04
-- Author: Claude, directed by Fred (DERM Tracker recipient bug)
--
-- BUG: the recipient set was {manifest.client_id OWNER} UNION {distinct clients
-- of linked visits}, so a manifest with NO manifest_visits links still listed its
-- OWNER as a recipient — the "Send DERM to clients" modal showed clients NOT
-- attached to the manifest (17 owner-only (manifest,client) rows; e.g. #488184,
-- #294999's 5 Broward rows which have PDFs but 0 linked visits).
--
-- FIX: recipients = ONLY the distinct clients of the manifest's NON-DELETED linked
-- visits (drop the owner UNION branch). A 0-linked-visit manifest now yields 0
-- recipient rows. The SAME definition is applied to derm.manifests.total_client_count
-- so the list "N clients", the accordion, the modal, and the "Emailed N/M" chip all
-- agree. emailed_client_count (real sends only) is unaffected — only the M total.
-- Multi-client manifests are preserved (e.g. #825906 -> {214-MYK, 034-LG}).
--
-- Applied as a targeted regexp_replace on the LIVE view def (idempotent: the old
-- owner-UNION pattern is gone after the first run, so a re-run is a no-op),
-- preserving every other column incl. the last_emailed_at / emailed_client_count
-- wrappers, client_name, has_pdf, has_email, visit_date.

SET search_path TO public, derm;

-- (a) derm.manifest_recipients — recipient LATERAL becomes linked-visit clients only
DO $mig$
DECLARE body text;
BEGIN
  body := pg_get_viewdef('derm.manifest_recipients'::regclass, true);
  body := regexp_replace(body,
    'LATERAL \( SELECT DISTINCT u\.cid AS client_id[^;]*?WHERE u\.cid IS NOT NULL\) r ON true',
    'LATERAL ( SELECT DISTINCT v.client_id FROM manifest_visits mv JOIN visits v ON v.id = mv.visit_id WHERE mv.manifest_id = m.id AND v.deleted_at IS NULL AND v.client_id IS NOT NULL) r ON true');
  EXECUTE 'CREATE OR REPLACE VIEW derm.manifest_recipients AS ' || rtrim(body, E' \n\r\t;');
END
$mig$;

-- (b) derm.manifests.total_client_count — same linked-visit-clients definition
DO $mig$
DECLARE body text;
BEGIN
  body := pg_get_viewdef('derm.manifests'::regclass, true);
  body := regexp_replace(body,
    'count\(DISTINCT u\.cid\)[^;]*?u\.cid IS NOT NULL\) AS total_client_count',
    'count(DISTINCT v.client_id) AS count FROM manifest_visits mv JOIN visits v ON v.id = mv.visit_id WHERE mv.manifest_id = sub.id AND v.deleted_at IS NULL AND v.client_id IS NOT NULL) AS total_client_count');
  EXECUTE 'CREATE OR REPLACE VIEW derm.manifests AS ' || rtrim(body, E' \n\r\t;');
END
$mig$;

NOTIFY pgrst, 'reload schema';
