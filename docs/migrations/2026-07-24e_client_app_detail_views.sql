-- ============================================================================
-- 2026-07-24e — Client App: 5 list/detail views in the `client` schema
-- ============================================================================
-- WHY: the Client App (Lovable dbf2133c) frontend was repointed off the Mirror
-- onto Prod's `client` schema (2026-07-24_client_app_schema.sql). The BA session's
-- adversarial audit found the app reads 14 relations; 9 already exist in `client`
-- and exactly these 5 were missing, so the clients LIST renders "0 of 0" and the
-- DETAIL page can't load DERM/photos. Adds them, matching the existing `client.*`
-- convention (explicit projections, postgres-owned, no security_invoker so the
-- owner-run view bypasses the base tables' RLS, GRANT SELECT to authenticated +
-- service_role). All 4 base tables have RLS enabled — the owner-run pattern is
-- load-bearing or authenticated gets empty/403.
--
-- SCHEMA-OWNER DECISIONS (BA deferred these to me):
--   * PII shaping on `photos`: DROP exif_latitude, exif_longitude, exif_device,
--     uploaded_by_employee_id. These are photo-capture / employee-side metadata
--     (precise GPS, device fingerprint, uploader attribution), NOT client-photo
--     display data, and this schema already strips employee PII (email/phone).
--     Least-exposure; trivially reversible if the detail UI proves it needs one.
--   * `derm_manifests`: soft-delete filtered; drop the always-null deleted_at from
--     the projection. Doc URL / storage-path strings ARE exposed — this app is
--     STAFF-facing (authenticated @ayache/@unclogme), so the FP customer FOG-
--     blackout (a customer-facing redaction) does NOT apply and is NOT regressed
--     (untouched). ⚠ Frontend contract: the app MUST resolve these paths via
--     SIGNED URLs (get-derm-doc / createSignedUrl), not as public URLs — DERM +
--     GT-Visits-Images storage is going private+signed (project_pending_derm_
--     storage_private); raw paths will 403 once it does.
--   * Grants: authenticated + service_role, matching client.clients/client.gdos.
--   * Explicit projections (not SELECT *) so a future PII column added upstream
--     can't auto-leak into a client-data app.
--
-- AUDIT (ADR 010): views only — no audit trigger. Underlying tables already
-- audited (derm_manifests, manifest_visits) or are photo metadata; no new
-- business table. Reads-only; no write path (phase-1 reads-first).
-- ============================================================================

begin;

-- 1) client_services_flat — the clients LIST (public VIEW, no deleted_at).
create or replace view client.client_services_flat as
  select id, name, client_code, address, city, zone, status,
         gt_size_gallons, gt_frequency_days, gt_price_per_visit, gt_last_visit, gt_next_visit, gt_status,
         cl_frequency_days, cl_price_per_visit, cl_last_visit, cl_next_visit, cl_status,
         wd_frequency_days, wd_price_per_visit, wd_last_visit, wd_next_visit, wd_status
    from public.client_services_flat;
alter view client.client_services_flat owner to postgres;
grant select on client.client_services_flat to authenticated;
grant select on client.client_services_flat to service_role;

-- 2) derm_manifests — DETAIL (public TABLE; soft-delete filtered; deleted_at dropped).
create or replace view client.derm_manifests as
  select id, client_id, service_date, dump_ticket_date,
         white_manifest_number, yellow_ticket_number,
         sent_to_client, sent_to_city, created_at, updated_at,
         wwtp_receipt_number, wwtp_receipt_document_path, wwtp_ticket_number,
         disposal_facility_id, derm_manifest_url, derm_address_url, gdo_id,
         derm_manifest_extra_urls, derm_address_extra_urls,
         notes, derm_address_no, fog_manifest_url
    from public.derm_manifests
   where deleted_at is null;
alter view client.derm_manifests owner to postgres;
grant select on client.derm_manifests to authenticated;
grant select on client.derm_manifests to service_role;

-- 3) manifest_visits — DETAIL junction (no deleted_at).
create or replace view client.manifest_visits as
  select manifest_id, visit_id
    from public.manifest_visits;
alter view client.manifest_visits owner to postgres;
grant select on client.manifest_visits to authenticated;
grant select on client.manifest_visits to service_role;

-- 4) photo_links — DETAIL (polymorphic photo->entity link + staff caption).
create or replace view client.photo_links as
  select id, photo_id, entity_type, entity_id, role, caption, created_at
    from public.photo_links;
alter view client.photo_links owner to postgres;
grant select on client.photo_links to authenticated;
grant select on client.photo_links to service_role;

-- 5) photos — DETAIL (EXIF geo/device + uploader dropped; see header).
create or replace view client.photos as
  select id, storage_path, thumbnail_path, file_name, content_type,
         size_bytes, width_px, height_px, exif_taken_at, uploaded_at, source, created_at
    from public.photos;
alter view client.photos owner to postgres;
grant select on client.photos to authenticated;
grant select on client.photos to service_role;

commit;
