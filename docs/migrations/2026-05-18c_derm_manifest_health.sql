-- 2026-05-18c_derm_manifest_health.sql
--
-- derm.manifest_health view — classifies every manifest into one of four
-- mutually-exclusive states so DERM Tracker can surface "what needs attention".
-- Plus boolean flags for each missing piece so the UI can show concrete
-- per-row CTAs.
--
-- Discovered 2026-05-18 from the visit 3941 / visit 3939 diagnostic:
--   - 84 empty placeholders (no PDFs, no number, no dump date)
--   - 121 have PDFs but no manifest number (data-entry gap in AT)
--   - 57 have a number but no PDFs (rare backwards case)
--   - 736 fully complete (72%)
--
-- Audit opt-in per Rule 8: this is a VIEW, not a table. The underlying
-- public.derm_manifests is already audited (audit_derm_manifests trigger
-- since 2026-05-17). No additional triggers needed.

BEGIN;

CREATE OR REPLACE VIEW derm.manifest_health AS
SELECT
  dm.id,
  dm.client_id,
  c.name                                  AS client_name,
  dm.white_manifest_number,
  dm.service_date::text                   AS service_date,
  dm.dump_ticket_date::text               AS dump_ticket_date,
  dm.disposal_facility_id,
  df.name                                 AS dump_location,
  dm.derm_manifest_url                    AS manifest_photo_url,
  dm.derm_address_url                     AS address_photo_url,
  dm.created_at::text                     AS created_at,
  dm.updated_at::text                     AS updated_at,

  -- Boolean flags — what's present, what's missing
  (dm.white_manifest_number IS NOT NULL)                        AS has_number,
  (dm.derm_manifest_url     IS NOT NULL)                        AS has_manifest_pdf,
  (dm.derm_address_url      IS NOT NULL)                        AS has_address_pdf,
  (dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL) AS has_any_pdf,
  (dm.dump_ticket_date      IS NOT NULL)                        AS has_dump_date,
  (dm.disposal_facility_id  IS NOT NULL)                        AS has_dump_site,
  (dm.client_id             IS NOT NULL)                        AS has_client,
  (dm.sent_to_client        IS TRUE)                            AS sent_to_client,
  (dm.sent_to_city          IS TRUE)                            AS sent_to_city,

  -- The one-of-four mutually-exclusive health state
  CASE
    WHEN dm.white_manifest_number IS NOT NULL
         AND dm.derm_manifest_url IS NOT NULL
         AND dm.derm_address_url  IS NOT NULL
         AND dm.dump_ticket_date  IS NOT NULL
      THEN 'fully_complete'
    WHEN dm.white_manifest_number IS NULL
         AND dm.derm_manifest_url IS NULL
         AND dm.derm_address_url  IS NULL
         AND dm.dump_ticket_date  IS NULL
      THEN 'empty_placeholder'
    WHEN dm.white_manifest_number IS NULL
         AND (dm.derm_manifest_url IS NOT NULL OR dm.derm_address_url IS NOT NULL)
      THEN 'has_pdfs_no_number'
    WHEN dm.white_manifest_number IS NOT NULL
         AND dm.derm_manifest_url IS NULL
         AND dm.derm_address_url  IS NULL
      THEN 'has_number_no_pdfs'
    ELSE 'partial_other'
  END                                     AS health_state,

  -- P0 = no paperwork at all (compliance blocker)
  -- P1 = has paperwork but a critical field missing (number / PDF / dump date)
  -- P2 = compliance OK, but missing send-to-client / send-to-city flags
  -- OK = everything filled including send flags
  --
  -- NOTE: disposal_facility_id is intentionally excluded from severity
  -- because it's 100% NULL across the entire table today (universal
  -- known-gap pre-DERM-Tracker backfill). Including it would mark every
  -- manifest as P2 and defeat the purpose.
  CASE
    WHEN dm.white_manifest_number IS NULL
         AND dm.derm_manifest_url IS NULL
         AND dm.derm_address_url  IS NULL
      THEN 'P0'
    WHEN dm.white_manifest_number IS NULL OR dm.derm_manifest_url IS NULL OR dm.derm_address_url IS NULL OR dm.dump_ticket_date IS NULL
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
