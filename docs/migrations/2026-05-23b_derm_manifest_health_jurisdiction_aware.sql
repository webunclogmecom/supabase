-- 2026-05-23b_derm_manifest_health_jurisdiction_aware.sql
--
-- DOCUMENT-DEPLOYED-STATE migration for `derm.manifest_health`.
--
-- Background:
--   The original migration `2026-05-18c_derm_manifest_health.sql` shipped a
--   view that only checked `dm.white_manifest_number` for "has a number?"
--   logic. That meant any Broward manifest (which uses `yellow_ticket_number`
--   and legitimately has no `white_manifest_number`) was misclassified as
--   `has_pdfs_no_number` / P1 even when complete.
--
--   At some point between 2026-05-18 and 2026-05-23 the deployed view was
--   updated ad-hoc to be jurisdiction-aware. No matching migration file
--   exists in the repo — this is a drift between code and Prod schema.
--
--   This migration captures the deployed state verbatim via CREATE OR
--   REPLACE so a future reader sees the actual logic in one canonical file.
--   It is a no-op against the live view (same definition that's already
--   running), but it brings the repo back in sync with reality.
--
-- Verified state (2026-05-23, see Fred Zerpa autonomous bug-fix pass):
--   - 120 Broward manifests in DB → 118 classified `fully_complete`, 2
--     legitimately P1 (no/partial PDFs).
--   - 874 fully_complete + 26 unhealthy (2.9% unhealthy) overall — matches
--     what the DERM Tracker Health page shows.
--
-- Audit (Rule 8): VIEW only, no triggers needed. Underlying
-- public.derm_manifests already has audit_derm_manifests trigger
-- (2026-05-17).
--
-- 3NF (Rule 2): no new storage. View is a computed read of canonical.
--
-- Source-of-truth (Rule 4): reads canonical derm_manifests + clients +
-- disposal_facilities. No source-prefixed columns.
--
-- Idempotent (Rule 5): CREATE OR REPLACE. Re-runnable.

BEGIN;

CREATE OR REPLACE VIEW derm.manifest_health AS
SELECT
  dm.id,
  dm.client_id,
  c.name                                  AS client_name,
  dm.white_manifest_number,
  dm.yellow_ticket_number,
  dm.service_date::text                   AS service_date,
  dm.dump_ticket_date::text               AS dump_ticket_date,
  dm.disposal_facility_id,
  df.name                                 AS dump_location,
  dm.derm_manifest_url                    AS manifest_photo_url,
  dm.derm_address_url                     AS address_photo_url,
  dm.created_at::text                     AS created_at,
  dm.updated_at::text                     AS updated_at,

  -- Jurisdiction (mirrors derm.manifests view logic)
  CASE
    WHEN dm.yellow_ticket_number IS NOT NULL                                      THEN 'broward'
    WHEN dm.white_manifest_number IS NOT NULL AND length(dm.white_manifest_number) >= 5 THEN 'dade'
    ELSE 'unknown'
  END                                     AS jurisdiction,

  -- Jurisdiction-specific number flags (granular, so the UI can show
  -- jurisdiction-correct affordances without re-deriving on the client)
  (dm.white_manifest_number IS NOT NULL)                        AS has_dade_white_number,
  (dm.yellow_ticket_number  IS NOT NULL)                        AS has_broward_ticket_number,
  (dm.derm_manifest_url     IS NOT NULL)                        AS has_manifest_pdf,
  (dm.derm_address_url      IS NOT NULL)                        AS has_address_pdf,
  (dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL) AS has_any_pdf,
  (dm.dump_ticket_date      IS NOT NULL)                        AS has_dump_date,
  (dm.disposal_facility_id  IS NOT NULL)                        AS has_dump_site,
  (dm.client_id             IS NOT NULL)                        AS has_client,
  (dm.sent_to_client        IS TRUE)                            AS sent_to_client,
  (dm.sent_to_city          IS TRUE)                            AS sent_to_city,

  -- The one-of-four mutually-exclusive health state, jurisdiction-aware.
  -- A Broward manifest is `fully_complete` when yellow_ticket_number +
  -- both PDFs + dump_ticket_date are set. A Dade manifest is
  -- `fully_complete` when white_manifest_number (>= 5 chars, to filter
  -- partial/typo'd numbers) + both PDFs + dump_ticket_date are set.
  CASE
    WHEN dm.white_manifest_number IS NULL
         AND dm.yellow_ticket_number IS NULL
         AND dm.derm_manifest_url IS NULL
         AND dm.derm_address_url  IS NULL
         AND dm.dump_ticket_date  IS NULL
      THEN 'empty_placeholder'
    WHEN dm.yellow_ticket_number IS NOT NULL
         AND dm.derm_manifest_url IS NOT NULL
         AND dm.derm_address_url  IS NOT NULL
         AND dm.dump_ticket_date  IS NOT NULL
      THEN 'fully_complete'
    WHEN dm.white_manifest_number IS NOT NULL
         AND length(dm.white_manifest_number) >= 5
         AND dm.derm_manifest_url IS NOT NULL
         AND dm.derm_address_url  IS NOT NULL
         AND dm.dump_ticket_date  IS NOT NULL
      THEN 'fully_complete'
    WHEN (dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL)
         AND dm.yellow_ticket_number IS NULL
         AND dm.white_manifest_number IS NULL
      THEN 'has_pdfs_no_number'
    WHEN (dm.yellow_ticket_number IS NOT NULL OR dm.white_manifest_number IS NOT NULL)
         AND dm.derm_manifest_url IS NULL
         AND dm.derm_address_url  IS NULL
      THEN 'has_number_no_pdfs'
    ELSE 'partial_other'
  END                                     AS health_state,

  -- P0 = no paperwork at all (no number AND no PDFs) — compliance blocker
  -- P1 = has paperwork but a critical field missing
  -- P2 = compliance fields present, but missing send-to-client/city flags
  -- OK = everything filled
  CASE
    WHEN dm.white_manifest_number IS NULL
         AND dm.yellow_ticket_number IS NULL
         AND dm.derm_manifest_url IS NULL
         AND dm.derm_address_url  IS NULL
      THEN 'P0'
    WHEN (dm.yellow_ticket_number IS NULL AND dm.white_manifest_number IS NULL)
         OR dm.derm_manifest_url IS NULL
         OR dm.derm_address_url  IS NULL
         OR dm.dump_ticket_date  IS NULL
      THEN 'P1'
    WHEN NOT dm.sent_to_client OR NOT dm.sent_to_city
      THEN 'P2'
    ELSE 'OK'
  END                                     AS severity

FROM public.derm_manifests dm
LEFT JOIN public.clients              c  ON c.id  = dm.client_id
LEFT JOIN public.disposal_facilities  df ON df.id = dm.disposal_facility_id;

-- Grants — anon read for the DERM Tracker app (matches the other derm.* views)
GRANT SELECT ON derm.manifest_health TO anon, authenticated;
GRANT ALL    ON derm.manifest_health TO service_role;

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION (run as service_role)
-- ============================================================
-- 1. Broward classification:
--    SELECT health_state, severity, COUNT(*) FROM derm.manifest_health
--    WHERE jurisdiction = 'broward' GROUP BY 1, 2 ORDER BY 1, 2;
--    Expected: most fully_complete (OK or P2), a few legitimate P1s only.
--
-- 2. Dade classification unchanged:
--    SELECT health_state, severity, COUNT(*) FROM derm.manifest_health
--    WHERE jurisdiction = 'dade' GROUP BY 1, 2 ORDER BY 1, 2;
--
-- 3. Empty placeholders still surfaced:
--    SELECT COUNT(*) FROM derm.manifest_health WHERE health_state = 'empty_placeholder';
