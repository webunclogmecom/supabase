-- 2026-05-19a_derm_views_client_code_prefix.sql
--
-- Smart client_name rendering in derm.* views: prepend client_code when the
-- name doesn't already include it.
--
-- Background: 144 of 382 clients (38%) have a client_code value but the
-- code isn't baked into the name string (e.g., name = "Baoli Miami",
-- code = "004-BAO"). Another 52 clients DO have the code in their name
-- ("125-EI Esther Isaacov"). The DERM Tracker app reads client_name raw,
-- so the inconsistent shape leaks into the UI.
--
-- Fix: views compute `client_name` as:
--   CASE WHEN code IS NOT NULL AND name NOT LIKE (code || '%')
--        THEN code || ' ' || name
--        ELSE name
--   END
--
-- This is idempotent — names that already include the prefix stay unchanged.
-- The underlying public.clients rows are untouched (no risk of Jobber sync
-- conflict on next upsert).
--
-- Views updated: derm.visits, derm.manifest_visits, derm.manifests.

BEGIN;

CREATE OR REPLACE VIEW derm.visits AS
SELECT
  v.id,
  CASE
    WHEN c.client_code IS NOT NULL AND c.name NOT LIKE (c.client_code || '%')
      THEN c.client_code || ' ' || c.name
    ELSE c.name
  END                                       AS client_name,
  COALESCE(p.address, '')                   AS address,
  COALESCE(p.county,  '')                   AS county,
  v.visit_date::text                        AS visit_date,
  NULL::text                                AS technician,
  NULL::text                                AS notes,
  v.created_at::text                        AS created_at,
  v.client_id,
  v.service_type,
  EXISTS (SELECT 1 FROM public.manifest_visits mv WHERE mv.visit_id = v.id) AS has_manifest
FROM public.visits v
JOIN public.clients c ON c.id = v.client_id
LEFT JOIN LATERAL (
  SELECT p2.address, p2.county
  FROM public.properties p2
  WHERE p2.client_id = c.id AND p2.is_billing = false
  ORDER BY p2.id LIMIT 1
) p ON true
WHERE v.visit_status = 'completed';

CREATE OR REPLACE VIEW derm.manifest_visits AS
SELECT
  mv.manifest_id,
  mv.visit_id,
  v.visit_date::text                        AS visit_date,
  v.client_id,
  CASE
    WHEN c.client_code IS NOT NULL AND c.name NOT LIKE (c.client_code || '%')
      THEN c.client_code || ' ' || c.name
    ELSE c.name
  END                                       AS client_name,
  COALESCE(p.address, '')                   AS address,
  COALESCE(p.county,  '')                   AS county
FROM public.manifest_visits mv
JOIN public.visits v  ON v.id = mv.visit_id
JOIN public.clients c ON c.id = v.client_id
LEFT JOIN LATERAL (
  SELECT p2.address, p2.county
  FROM public.properties p2
  WHERE p2.client_id = c.id AND p2.is_billing = false
  ORDER BY p2.id LIMIT 1
) p ON true;

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
  CASE
    WHEN c.client_code IS NOT NULL AND c.name NOT LIKE (c.client_code || '%')
      THEN c.client_code || ' ' || c.name
    ELSE c.name
  END                               AS client_name,
  dm.service_date::text             AS service_date,
  dm.yellow_ticket_number,
  dm.wwtp_receipt_number,
  dm.wwtp_receipt_document_path,
  dm.wwtp_ticket_number,
  dm.disposal_facility_id,
  dm.sent_to_client,
  dm.sent_to_city,
  dm.updated_at::text               AS updated_at,
  CASE WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'
       WHEN dm.white_manifest_number IS NOT NULL AND LENGTH(dm.white_manifest_number) >= 5 THEN 'dade'
       ELSE 'unknown' END           AS jurisdiction,
  COALESCE(
    CASE WHEN dm.yellow_ticket_number IS NOT NULL THEN dm.yellow_ticket_number END,
    CASE WHEN dm.white_manifest_number IS NOT NULL AND LENGTH(dm.white_manifest_number) >= 5
         THEN dm.white_manifest_number END
  )                                 AS display_number,
  CASE WHEN dm.yellow_ticket_number IS NOT NULL
         THEN 'Broward #' || dm.yellow_ticket_number
       WHEN dm.white_manifest_number IS NOT NULL AND LENGTH(dm.white_manifest_number) >= 5
         THEN 'Miami-Dade #' || dm.white_manifest_number
       ELSE 'Pending paperwork' END AS display_label
FROM public.derm_manifests dm
LEFT JOIN public.clients c ON c.id = dm.client_id
LEFT JOIN public.disposal_facilities df ON df.id = dm.disposal_facility_id;

COMMIT;
