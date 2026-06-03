-- 2026-06-03b — derm.manifest_recipients: enumerate recipients per LINKED-VISIT client.
-- Applied via Mgmt API from the Building Apps session (Fred-authorized, per his decision).
-- Supersedes the recipient shape in 2026-06-03_derm_manifest_recipients_view.sql.
--
-- WHY: a single WWTP receipt (one derm_manifests row) can legitimately have visits from
-- MULTIPLE clients linked to it (a shared dump run; e.g. #825906 = manifest 1171, owned by
-- 214-MYK, but with both 214-MYK's visit 5157 AND 034-LG's visit 5158 linked). The /manifests
-- list already shows "N clients" by reading the linked visits, but the old recipients view
-- emitted ONE row per manifest keyed on the manifest's own client_id — so the "Send DERM to
-- clients" email modal only listed the owner client (1) and the other clients on the same
-- receipt never got the email. Fred chose: email EVERY client on the manifest.
--
-- 6 manifests were in this multi-client state at apply time (441, 575, 712, 946, 987, 1171).
--
-- NEW shape: one row per (manifest, DISTINCT client) where the client is either the manifest's
-- own client OR any client with a (non-deleted) visit linked to that manifest. Same column set
-- + order as before (so the DERM Tracker modal query is unaffected) — only the row multiplicity
-- and the per-row client_id/client_name/has_email/visit_date now follow the linked visits.
-- visit_date is that recipient-client's latest linked visit on this manifest (NULL if the client
-- is only the manifest's own with no linked visit). client_name keeps the "CODE Name" format.
--
-- The send-derm-email Edge Function was updated in lockstep to accept
--   { recipients: [{ manifest_id, client_id }], test_recipient? }
-- (it still accepts the legacy { manifest_ids: [...] } → client_id = the manifest's own client),
-- and the DERM Tracker modal sends the selected (manifest_id, client_id) pairs.
--
-- Owner-run (NOT security_invoker) so the EXISTS over public.client_contacts (PII) + the
-- visit join run under the view owner; the frontend only ever sees has_email/has_pdf booleans.

CREATE OR REPLACE VIEW derm.manifest_recipients AS
SELECT m.id AS manifest_id,
       m.display_number,
       m.display_label,
       m.jurisdiction,
       r.client_id,
       CASE WHEN cl.client_code IS NOT NULL AND cl.client_code <> ''
            THEN cl.client_code || ' ' || cl.name
            ELSE cl.name END AS client_name,
       (m.manifest_photo_url IS NOT NULL) AS has_pdf,   -- manifest_photo_url = derm_manifest_url (the WWTP receipt we attach)
       EXISTS (
         SELECT 1 FROM public.client_contacts cc
         WHERE cc.client_id = r.client_id AND cc.email IS NOT NULL AND cc.email <> ''
       ) AS has_email,
       (SELECT max(v.visit_date)
          FROM public.manifest_visits mv
          JOIN public.visits v ON v.id = mv.visit_id
         WHERE mv.manifest_id = m.id AND v.client_id = r.client_id AND v.deleted_at IS NULL) AS visit_date
FROM derm.manifests m
JOIN LATERAL (
  -- distinct recipient clients: the manifest's own client + every client with a linked visit
  SELECT DISTINCT cid AS client_id FROM (
    SELECT m.client_id AS cid
    UNION
    SELECT v.client_id
      FROM public.manifest_visits mv
      JOIN public.visits v ON v.id = mv.visit_id
     WHERE mv.manifest_id = m.id AND v.deleted_at IS NULL
  ) u WHERE cid IS NOT NULL
) r ON true
JOIN public.clients cl ON cl.id = r.client_id;

GRANT SELECT ON derm.manifest_recipients TO anon, authenticated;
