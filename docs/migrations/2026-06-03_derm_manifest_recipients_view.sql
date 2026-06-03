-- 2026-06-03 — derm.manifest_recipients view (for the DERM Tracker /manifests "Send DERM to clients" email feature).
-- Applied via Mgmt API from the Building Apps session (Fred-authorized).
--
-- Feeds the /manifests email modal: per manifest row (client entry), exposes whether it has a PDF to send
-- and whether the client has a contact email — WITHOUT exposing the actual email to the anon frontend
-- (the send-derm-email Edge Function resolves the real email server-side via the service role).
--
-- Owner-run (NOT security_invoker) so the EXISTS subquery can read public.client_contacts (PII) under the
-- view owner, while the frontend only ever sees the has_email boolean. Granted to anon/authenticated to match
-- the DERM Tracker MVP anon-auth model (consistent with the other derm.* views).
--
-- Part of the email-to-client feature (replaces Airtable "Send DERM to client"):
--   * Edge Function public functions/send-derm-email (Resend) — deployed 2026-06-03, --no-verify-jwt.
--       Input { manifest_ids: bigint[], test_recipient?: string }; attaches derm_manifest_url (WWTP receipt).
--   * Secrets (Functions): RESEND_API_KEY (Fred), RESEND_FROM='Unclogme <contact@unclogme.com>'.
--   * unclogme.com verified in Resend (DKIM + SPF, GoDaddy). Backend verified live: test email sent
--     (test_recipient override) with the WWTP PDF attached, Resend id returned.

CREATE OR REPLACE VIEW derm.manifest_recipients AS
SELECT m.id AS manifest_id,
       m.display_number,
       m.display_label,
       m.jurisdiction,
       m.client_id,
       m.client_name,
       (m.manifest_photo_url IS NOT NULL) AS has_pdf,   -- manifest_photo_url = derm_manifest_url (the WWTP receipt we attach)
       EXISTS (
         SELECT 1 FROM public.client_contacts cc
         WHERE cc.client_id = m.client_id AND cc.email IS NOT NULL AND cc.email <> ''
       ) AS has_email
FROM derm.manifests m;

GRANT SELECT ON derm.manifest_recipients TO anon, authenticated;
