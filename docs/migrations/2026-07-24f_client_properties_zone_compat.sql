-- ============================================================================
-- 2026-07-24f — client.properties: re-expose `zone` (derived) for the Client App
-- ============================================================================
-- WHY: rule-#12 live verification of the Client App (clients.unclogme.app,
-- published 2026-07-24) caught a 400 on
--   GET /rest/v1/properties?select=client_id,city,zone,is_primary,is_billing
-- The app (built against the Mirror, where properties still had the old `zone`
-- text column) selects `zone`, but this week's zone-collapse (2026-07-21 21n/21o)
-- dropped public.properties.zone in favour of zone_id -> zones.code. The newer
-- client.properties (created 2026-07-24) exposes zone_id, not zone -> PostgREST
-- 42703 "column zone does not exist". Non-fatal for the list (zone there comes
-- from client_services_flat.zone) but the properties enrichment call fails and it
-- likely contributes to the /clients/:id SSR 500.
--
-- FIX: append a derived `zone` column (the zone CODE via zone_id -> public.zones),
-- exactly the read-layer derivation the zone-collapse intended and the same shape
-- client_services_flat.zone already exposes. Backward-compat, additive
-- (CREATE OR REPLACE append-only), no frontend republish needed, keeps zone_id.
-- Owner + grants are preserved by CREATE OR REPLACE.
--
-- AUDIT (ADR 010): view only, no trigger. Reads-only.
-- ============================================================================

begin;

create or replace view client.properties as
  select p.id, p.client_id, p.name, p.address, p.city, p.state, p.zip, p.country,
         p.is_billing, p.created_at, p.updated_at, p.latitude, p.longitude,
         p.geofence_radius_meters, p.geofence_type, p.access_hours_start,
         p.access_hours_end, p.access_days, p.is_primary, p.notes, p.county,
         p.grease_trap_manhole_count, p.access_notes, p.default_disposal_facility_id,
         p.zone_id, p.sample_port_count,
         (select z.code from public.zones z where z.id = p.zone_id) as zone
    from public.properties p;

commit;
