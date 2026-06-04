-- Migration: public.derm_email_sends + DERM email-status read surfaces
-- Date:   2026-06-04
-- Author: Claude, directed by Fred (DERM Tracker — "Send DERM to client" send log)
--
-- WHAT: durable, append-only log of "Send DERM to client" email attempts (one row
--   per (manifest, client) send attempt), written by the send-derm-email Edge
--   Function. Plus 3 derm.* read-views surfacing "emailed" status to the DERM
--   Tracker UI. "Emailed" = the LATEST row for that (manifest, client) with
--   status='sent' AND is_test=false (test sends NEVER count).
--
-- 3NF (rule 2): every column depends on the send-attempt PK and nothing else.
--   manifest_id, client_id  - the (manifest, recipient) the attempt targeted (FKs).
--   recipient_email         - the address actually used (test address or the
--                             contact at send time); a fact OF the attempt, not
--                             re-derivable from the client later.
--   resend_email_id         - Resend's id for THIS send (attempt-scoped).
--   status/reason/is_test/sent_at - facts of this attempt. No transitive deps.
--   (No client name / current email / manifest number copied - referenced out.)
--
-- AUDIT (rule 8 standing check): OPT-IN, full trigger (INSERT/UPDATE/DELETE).
--   DERM-compliance-adjacent (records the compliance communication of a manifest
--   to a client); rule 8 names "DERM compliance" a hard-rule must-audit, and the
--   DERM Tracker precedent (derm_manifests, manifest_visits) is opt-in. It is an
--   append-only, function-written log, so the INSERT capture is somewhat redundant
--   (the row IS the record) - retained for strict rule-8 conformance; the
--   UPDATE/DELETE capture is tamper-evidence on a table that should never mutate.
--   Volume is low (manual sends). Flip to UPDATE/DELETE-only if the noise matters.
--
-- RLS / grants: base table is LOCKED. service_role (BYPASSRLS) inserts from the
--   Edge Function; the derm.* read-views (owned by postgres, NOT security_invoker)
--   expose only aggregates to anon/authenticated. NO anon/authenticated grant on
--   the base table - matches the spec + keeps raw recipient emails un-exposed.

SET search_path TO public, derm;

-- == 1. base table ==========================================================
CREATE TABLE IF NOT EXISTS public.derm_email_sends (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  manifest_id     bigint NOT NULL REFERENCES public.derm_manifests(id),
  client_id       bigint NOT NULL REFERENCES public.clients(id),
  recipient_email text,
  resend_email_id text,
  status          text NOT NULL CHECK (status IN ('sent','skipped','error')),
  reason          text,
  is_test         boolean NOT NULL DEFAULT false,
  sent_at         timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.derm_email_sends IS
  'Append-only log of "Send DERM to client" email attempts (one row per (manifest,client) attempt), written by the send-derm-email Edge Function. "Emailed" = latest row with status=sent AND is_test=false.';

-- FK indexes (Postgres does not auto-index FKs) + read-path partial index
CREATE INDEX IF NOT EXISTS derm_email_sends_manifest_id_idx ON public.derm_email_sends (manifest_id);
CREATE INDEX IF NOT EXISTS derm_email_sends_client_id_idx   ON public.derm_email_sends (client_id);
CREATE INDEX IF NOT EXISTS derm_email_sends_real_sent_idx   ON public.derm_email_sends (manifest_id, client_id, sent_at DESC)
  WHERE status = 'sent' AND is_test = false;

-- RLS: locked base table; service_role inserts, no anon/auth grants
ALTER TABLE public.derm_email_sends ENABLE ROW LEVEL SECURITY;
-- Supabase default privileges auto-grant ALL to anon/authenticated on new public
-- tables; REVOKE so the base table stays LOCKED (raw recipient emails un-exposed).
-- The only anon/auth access path is the derm.* read-views (aggregates only).
REVOKE ALL ON public.derm_email_sends FROM anon, authenticated;
GRANT SELECT, INSERT ON public.derm_email_sends TO service_role;

-- Audit: opt-in (see header)
DROP TRIGGER IF EXISTS audit_derm_email_sends ON public.derm_email_sends;
CREATE TRIGGER audit_derm_email_sends
  AFTER INSERT OR UPDATE OR DELETE ON public.derm_email_sends
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- == 2. read surfaces (derm.*) ==============================================
-- Each wraps the existing view + appends columns (idempotent: only when absent),
-- reading the LIVE def so the complex visit/manifest SQL is never re-transcribed.

-- Surface (a): derm.manifests + emailed_client_count + total_client_count
DO $mig$
DECLARE body text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='derm' AND table_name='manifests' AND column_name='emailed_client_count') THEN
    SELECT rtrim(pg_get_viewdef('derm.manifests'::regclass, true), E' \n\r\t;') INTO body;
    EXECUTE 'CREATE OR REPLACE VIEW derm.manifests AS SELECT sub.*,'
      || ' (SELECT count(DISTINCT es.client_id) FROM public.derm_email_sends es'
      || '   WHERE es.manifest_id = sub.id AND es.status = ''sent'' AND es.is_test = false) AS emailed_client_count,'
      || ' (SELECT count(DISTINCT u.cid) FROM ('
      || '     SELECT sub.client_id AS cid'
      || '     UNION'
      || '     SELECT v.client_id FROM public.manifest_visits mv JOIN public.visits v ON v.id = mv.visit_id'
      || '       WHERE mv.manifest_id = sub.id AND v.deleted_at IS NULL'
      || '   ) u WHERE u.cid IS NOT NULL) AS total_client_count'
      || ' FROM ( ' || body || ' ) sub';
  END IF;
END
$mig$;

-- Surface (b): derm.manifest_recipients + last_emailed_at  (per manifest+client)
DO $mig$
DECLARE body text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='derm' AND table_name='manifest_recipients' AND column_name='last_emailed_at') THEN
    SELECT rtrim(pg_get_viewdef('derm.manifest_recipients'::regclass, true), E' \n\r\t;') INTO body;
    EXECUTE 'CREATE OR REPLACE VIEW derm.manifest_recipients AS SELECT sub.*,'
      || ' (SELECT max(es.sent_at) FROM public.derm_email_sends es'
      || '   WHERE es.manifest_id = sub.manifest_id AND es.client_id = sub.client_id'
      || '     AND es.status = ''sent'' AND es.is_test = false) AS last_emailed_at'
      || ' FROM ( ' || body || ' ) sub';
  END IF;
END
$mig$;

-- Surface (c): derm.visits + last_emailed_at  (this visit's manifest -> visit's own client)
DO $mig$
DECLARE body text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema='derm' AND table_name='visits' AND column_name='last_emailed_at') THEN
    SELECT rtrim(pg_get_viewdef('derm.visits'::regclass, true), E' \n\r\t;') INTO body;
    EXECUTE 'CREATE OR REPLACE VIEW derm.visits AS SELECT sub.*,'
      || ' (SELECT max(es.sent_at) FROM public.manifest_visits mv'
      || '   JOIN public.derm_email_sends es ON es.manifest_id = mv.manifest_id'
      || '   WHERE mv.visit_id = sub.id AND es.client_id = sub.client_id'
      || '     AND es.status = ''sent'' AND es.is_test = false) AS last_emailed_at'
      || ' FROM ( ' || body || ' ) sub';
  END IF;
END
$mig$;

NOTIFY pgrst, 'reload schema';
