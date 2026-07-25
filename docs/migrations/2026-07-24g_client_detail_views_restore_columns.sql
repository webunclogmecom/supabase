-- ============================================================================
-- 2026-07-24g — client.derm_manifests + client.photos: restore columns the
--               Client App queries (undo over-aggressive phase-1 shaping)
-- ============================================================================
-- WHY: rule-#12 live verification of the detail page (clients.unclogme.app
-- /clients/:id) surfaced "column derm_manifests.deleted_at does not exist". The
-- app was built against the Mirror's FULL column shape (SELECT *) and applies its
-- OWN soft-delete filter (`deleted_at=is.null`), so the column must EXIST even
-- though our view already filters it. In 2026-07-24e I dropped deleted_at from
-- client.derm_manifests and dropped EXIF geo/device + uploader from client.photos
-- as a least-exposure call — but that broke the contract the app was built
-- against. This app is STAFF-facing (authenticated @ayache/@unclogme, not
-- customer-facing), so exposing photo capture metadata to staff is acceptable and
-- the shaping wasn't worth breaking the app. Restore the full shape; a later
-- hardening pass can curate columns + update the app's queries together.
--
-- FIX (CREATE OR REPLACE, append-only — owner/grants preserved):
--   * client.derm_manifests: append deleted_at (still filtered to NULL rows, so
--     it is always NULL — the app just needs the column to exist for its filter).
--   * client.photos: append exif_latitude, exif_longitude, exif_device,
--     uploaded_by_employee_id (the 4 dropped in 24e).
--
-- AUDIT (ADR 010): views only. Reads-only.
-- ============================================================================

begin;

create or replace view client.derm_manifests as
  select id, client_id, service_date, dump_ticket_date,
         white_manifest_number, yellow_ticket_number,
         sent_to_client, sent_to_city, created_at, updated_at,
         wwtp_receipt_number, wwtp_receipt_document_path, wwtp_ticket_number,
         disposal_facility_id, derm_manifest_url, derm_address_url, gdo_id,
         derm_manifest_extra_urls, derm_address_extra_urls,
         notes, derm_address_no, fog_manifest_url, deleted_at
    from public.derm_manifests
   where deleted_at is null;

create or replace view client.photos as
  select id, storage_path, thumbnail_path, file_name, content_type,
         size_bytes, width_px, height_px, exif_taken_at, uploaded_at, source, created_at,
         exif_latitude, exif_longitude, exif_device, uploaded_by_employee_id
    from public.photos;

commit;
