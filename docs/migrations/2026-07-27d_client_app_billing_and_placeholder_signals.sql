-- ============================================================================
-- 2026-07-27d — Client App: expose the two signals behind Fred's "duplicates"
--               and the 009-CN merged-GDO report
-- ============================================================================
-- Fred, 2026-07-27, on the Client App:
--   (1) "clients with multiple properties where some have 0 jobs … most likely
--        they're duplicated like 286-ASI"
--   (2) "009-CN first GDO is wrong, like it merged all 3 other GDOs"
--
-- INVESTIGATION RESULT — NEITHER IS A DUPLICATE/CORRUPTION TO CLEAN UP. Both are
-- REAL rows being DISPLAYED as something they are not. So the fix is display-side
-- (filter/label), and this migration exposes the signal the app needs instead of
-- making the frontend guess.
--
-- (1) THE "DUPLICATE" PROPERTIES ARE JOBBER BILLING ADDRESSES. Of the 372
--     zero-job properties on multi-property clients: **372/372 have
--     is_billing = true** (0 with neither flag). 341 of them repeat the SAME
--     address as a sibling property that does have jobs (the 286-ASI shape: one
--     service row + one billing row at 2906 NE 207th St); the other 31 are a
--     genuinely different billing address (accountant/HQ). So there are ZERO
--     accidental duplicates — the app is rendering billing addresses as if they
--     were service sites. Known class: memory project_property_service_billing_dup.
--     → expose `job_count` so the app can label/hide a billing-only address.
--
-- (2) 009-CN's FIRST CARD IS LEGACY PLACEHOLDER DIRT, and its 3 real permits are
--     all present and correct: id 63 GDO-10877 (KITCHENS, ACTIVE, 60d), id 64
--     GDO-15062 (BARS, ACTIVE, 90d), id 65 GDO-16389 (LOUNGE, ACTIVE, 30d).
--     The bad card is id 164: gdo_number = 'GDO-10877, GDO-15062, GDO-16389' —
--     three permit numbers crammed into one text field — INACTIVE, expired
--     2025-12-04, no location_label, no client_location_id, no frequency.
--     It is one of a 28-row Airtable-era placeholder class ('Not available' ×20,
--     'Needs review' ×4, '043-MIL: GDO-14117 / GDO-11024', this one) — ALL INACTIVE.
--     ⚠ Fred's standing instruction is "do NOT fix AT's ~28 wrong #s"
--     (memory feedback_gdo_name_match_required), so this migration does NOT touch
--     the data. → expose `is_placeholder` so the app can stop rendering them as
--     permits, which fixes the whole class at once and stays reversible.
--
-- Both columns are additive; owner/grants preserved by CREATE OR REPLACE.
-- AUDIT (ADR 010): views only, reads-only.
-- ============================================================================

begin;

-- job_count → a billing-only address is is_billing = true AND job_count = 0.
create or replace view client.properties as
  select p.id, p.client_id, p.name, p.address, p.city, p.state, p.zip, p.country,
         p.is_billing, p.created_at, p.updated_at, p.latitude, p.longitude,
         p.geofence_radius_meters, p.geofence_type, p.access_hours_start,
         p.access_hours_end, p.access_days, p.is_primary, p.notes, p.county,
         p.grease_trap_manhole_count, p.access_notes, p.default_disposal_facility_id,
         p.zone_id, p.sample_port_count,
         (select z.code from public.zones z where z.id = p.zone_id) as zone,
         (select count(*) from public.jobs j where j.property_id = p.id)::int as job_count
    from public.properties p;

-- is_placeholder → gdo_number is not a real permit number ('^GDO-<digits>$').
-- Catches the comma/slash-merged rows plus 'Not available' / 'Needs review'.
create or replace view client.gdos as
  select id, client_id, gdo_number, location_label, property_id, permit_expiration,
         permit_document_path, status, notes, created_at, updated_at,
         max_frequency_days, client_location_id, permit_thumbnail_path,
         (gdo_number !~ '^GDO-[0-9]+$') as is_placeholder
    from public.gdos;

commit;
