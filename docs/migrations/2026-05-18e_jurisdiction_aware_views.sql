-- 2026-05-18e_jurisdiction_aware_views.sql
--
-- Make the derm.* read views jurisdiction-aware after discovering that
-- DERM manifests fall into two distinct numbering systems based on dump-site
-- county:
--   Miami-Dade dumps → identifier is `white_manifest_number` (6-digit, from
--     the Miami-Dade disposal facility receipt)
--   Broward dumps   → identifier is `yellow_ticket_number` (6-digit, from
--     the Broward Septage Receiving Receipt)
--
-- Pre-2026-05-18 the manifests view exposed `manifest_number` aliased only
-- to white_manifest_number. That left every Broward record looking like
-- "missing manifest number" in the UI (visit 3941 was the original symptom).
--
-- Changes:
--   1. derm.manifest_health — DROP + CREATE (column shape changed): adds
--      jurisdiction, has_dade_white_number, has_broward_ticket_number,
--      yellow_ticket_number; updates health_state + severity to use the
--      right identifier per jurisdiction.
--   2. derm.manifests — CREATE OR REPLACE (append-only): adds jurisdiction,
--      display_number, display_label at the end. Existing manifest_number
--      column unchanged for backward compat with the Lovable app until it
--      switches to display_label.
--
-- Companion narrative + Building Apps handoff:
--   - Building Apps/DERM Tracker/docs/handoff-jurisdiction-aware-display-2026-05-18.md
--   - feedback_only_migrate_from_upstream.md (the Broward facility decision)
--
-- Audit opt-in per Rule 8: these are VIEWS only, not tables — no triggers
-- needed. Underlying public.derm_manifests + public.disposal_facilities
-- remain audited as before.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. derm.manifest_health — jurisdiction-aware
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS derm.manifest_health;

CREATE VIEW derm.manifest_health AS
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

  -- Jurisdiction derived from which identifier is set
  CASE
    WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'
    WHEN dm.white_manifest_number IS NOT NULL AND LENGTH(dm.white_manifest_number) >= 5 THEN 'dade'
    ELSE 'unknown'
  END                                     AS jurisdiction,

  -- Boolean flags
  (dm.white_manifest_number IS NOT NULL)                                AS has_dade_white_number,
  (dm.yellow_ticket_number  IS NOT NULL)                                AS has_broward_ticket_number,
  (dm.derm_manifest_url IS NOT NULL)                                    AS has_manifest_pdf,
  (dm.derm_address_url IS NOT NULL)                                     AS has_address_pdf,
  (dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL) AS has_any_pdf,
  (dm.dump_ticket_date IS NOT NULL)                                     AS has_dump_date,
  (dm.disposal_facility_id IS NOT NULL)                                 AS has_dump_site,
  (dm.client_id IS NOT NULL)                                            AS has_client,
  (dm.sent_to_client IS TRUE)                                           AS sent_to_client,
  (dm.sent_to_city   IS TRUE)                                           AS sent_to_city,

  -- Jurisdiction-aware health state
  CASE
    WHEN dm.white_manifest_number IS NULL AND dm.yellow_ticket_number IS NULL
         AND dm.derm_manifest_url IS NULL AND dm.derm_address_url IS NULL
         AND dm.dump_ticket_date IS NULL                                    THEN 'empty_placeholder'
    WHEN dm.yellow_ticket_number IS NOT NULL
         AND dm.derm_manifest_url IS NOT NULL AND dm.derm_address_url IS NOT NULL
         AND dm.dump_ticket_date IS NOT NULL                                THEN 'fully_complete'
    WHEN dm.white_manifest_number IS NOT NULL AND LENGTH(dm.white_manifest_number) >= 5
         AND dm.derm_manifest_url IS NOT NULL AND dm.derm_address_url IS NOT NULL
         AND dm.dump_ticket_date IS NOT NULL                                THEN 'fully_complete'
    WHEN (dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL)
         AND dm.yellow_ticket_number IS NULL AND dm.white_manifest_number IS NULL THEN 'has_pdfs_no_number'
    WHEN (dm.yellow_ticket_number IS NOT NULL OR dm.white_manifest_number IS NOT NULL)
         AND dm.derm_manifest_url IS NULL AND dm.derm_address_url IS NULL   THEN 'has_number_no_pdfs'
    ELSE 'partial_other'
  END                                     AS health_state,

  -- Severity (disposal_facility_id intentionally excluded — universal known gap)
  CASE
    WHEN dm.white_manifest_number IS NULL AND dm.yellow_ticket_number IS NULL
         AND dm.derm_manifest_url IS NULL AND dm.derm_address_url IS NULL   THEN 'P0'
    WHEN (dm.yellow_ticket_number IS NULL AND dm.white_manifest_number IS NULL)
         OR dm.derm_manifest_url IS NULL OR dm.derm_address_url IS NULL
         OR dm.dump_ticket_date IS NULL                                     THEN 'P1'
    WHEN NOT dm.sent_to_client OR NOT dm.sent_to_city                       THEN 'P2'
    ELSE 'OK'
  END                                     AS severity

FROM public.derm_manifests dm
LEFT JOIN public.clients              c  ON c.id  = dm.client_id
LEFT JOIN public.disposal_facilities df ON df.id = dm.disposal_facility_id;

GRANT SELECT ON derm.manifest_health TO anon, authenticated;
GRANT ALL    ON derm.manifest_health TO service_role;

-- ---------------------------------------------------------------------------
-- 2. derm.manifests — append jurisdiction + display_number + display_label
-- (CREATE OR REPLACE because columns 1-21 unchanged; only adding to the end)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.manifests AS
SELECT
  dm.id,
  dm.white_manifest_number          AS manifest_number,
  'WHITE'::text                     AS manifest_type,
  dm.derm_manifest_url              AS manifest_photo_url,
  dm.derm_address_url               AS address_photo_url,
  dm.dump_ticket_date::text         AS dump_date,
  df.name                           AS dump_location,
  NULL::text                        AS driver_name,
  NULL::numeric                     AS gallons,
  dm.created_at::text               AS created_at,
  dm.client_id,
  c.name                            AS client_name,
  dm.service_date::text             AS service_date,
  dm.yellow_ticket_number,
  dm.wwtp_receipt_number,
  dm.wwtp_receipt_document_path,
  dm.wwtp_ticket_number,
  dm.disposal_facility_id,
  dm.sent_to_client,
  dm.sent_to_city,
  dm.updated_at::text               AS updated_at,

  -- NEW: jurisdiction-aware fields (appended; preserves backward compat)
  CASE
    WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'
    WHEN dm.white_manifest_number IS NOT NULL AND LENGTH(dm.white_manifest_number) >= 5 THEN 'dade'
    ELSE 'unknown'
  END                               AS jurisdiction,

  COALESCE(
    CASE WHEN dm.yellow_ticket_number IS NOT NULL THEN dm.yellow_ticket_number END,
    CASE WHEN dm.white_manifest_number IS NOT NULL AND LENGTH(dm.white_manifest_number) >= 5
         THEN dm.white_manifest_number END
  )                                 AS display_number,

  CASE
    WHEN dm.yellow_ticket_number IS NOT NULL
      THEN 'Broward #' || dm.yellow_ticket_number
    WHEN dm.white_manifest_number IS NOT NULL AND LENGTH(dm.white_manifest_number) >= 5
      THEN 'Miami-Dade #' || dm.white_manifest_number
    ELSE 'Pending paperwork'
  END                               AS display_label

FROM public.derm_manifests dm
LEFT JOIN public.clients              c  ON c.id  = dm.client_id
LEFT JOIN public.disposal_facilities df ON df.id = dm.disposal_facility_id;

GRANT SELECT ON derm.manifests TO anon, authenticated;
GRANT ALL    ON derm.manifests TO service_role;

COMMIT;
