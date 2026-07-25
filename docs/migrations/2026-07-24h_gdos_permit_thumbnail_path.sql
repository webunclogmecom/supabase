-- ============================================================================
-- 2026-07-24h — gdos.permit_thumbnail_path + expose in client.gdos
-- ============================================================================
-- WHY: Client App permit card wants a VISUAL thumbnail of the permit PDF
-- (pdf.js/iframe render badly in Lovable). Server-side thumbnail path (Fred-
-- approved, BA relayed). This migration is the UNBLOCK step only: add the column
-- + expose it so the app can select it WITHOUT a missing-column 400 (the zone /
-- deleted_at class). The thumbnails themselves (render first PDF page -> ~400px
-- PNG for the ~174 permit docs, store in gdo-permits/gdo/thumbs/, backfill +
-- on-upload) are a SEPARATE follow-on (pdf-service endpoint); column stays NULL
-- until then and the app shows its placeholder.
--
-- Relative-path convention matches permit_document_path (e.g. gdo/GDO-x.pdf ->
-- gdo/thumbs/GDO-x.png), in the PUBLIC gdo-permits bucket (public by decision).
--
-- AUDIT (ADR 010): gdos is already audited (audit_gdos) — column-add auto-captured.
-- Additive + NULL-safe; client.gdos owner/grants preserved by CREATE OR REPLACE.
-- ============================================================================

begin;

alter table public.gdos add column if not exists permit_thumbnail_path text;

create or replace view client.gdos as
  select id, client_id, gdo_number, location_label, property_id, permit_expiration,
         permit_document_path, status, notes, created_at, updated_at,
         max_frequency_days, client_location_id, permit_thumbnail_path
    from public.gdos;

commit;
