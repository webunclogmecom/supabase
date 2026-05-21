-- 2026-05-15b_derm_manifest_documents.sql
--
-- Add canonical columns for the two DERM-side attachments tracked in AT's
-- DERM table. These power the Field Portal's "DERM FOG eManifest" and
-- "WWTP Disposal Receipt" sections.
--
-- AT field mapping (per Fred 2026-05-15):
--   AT "DERM Address" attachment  → derm_manifests.derm_address_url
--                                   (displayed as "DERM FOG eManifest" PDF in UI)
--   AT "DERM Manifest" attachment → derm_manifests.derm_manifest_url
--                                   (displayed as "WWTP Disposal Receipt" PDF in UI)
--
-- STOP-GAP NOTE: these store the raw AT-served URLs which expire in hours.
-- Follow-up task: migrate to Supabase Storage and switch column type/semantics
-- to storage_path. Same pattern as the planned Jobber photo migration.

BEGIN;

ALTER TABLE public.derm_manifests
  ADD COLUMN IF NOT EXISTS derm_manifest_url text,
  ADD COLUMN IF NOT EXISTS derm_address_url  text;

COMMENT ON COLUMN public.derm_manifests.derm_manifest_url IS
  'URL of the DERM-issued manifest PDF (sourced from AT "DERM Manifest" attachment). Surfaced to customers as the "WWTP Disposal Receipt" document in the Field Portal. STOP-GAP: stores AT-signed URL (expires in hours). Migrate to Supabase Storage path in a follow-up.';

COMMENT ON COLUMN public.derm_manifests.derm_address_url IS
  'URL of the DERM address-proof PDF (sourced from AT "DERM Address" attachment). Surfaced to customers as the "DERM FOG eManifest" document in the Field Portal. STOP-GAP: stores AT-signed URL (expires in hours). Migrate to Supabase Storage path in a follow-up.';

COMMIT;
