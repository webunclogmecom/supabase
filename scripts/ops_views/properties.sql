-- ============================================================================
-- ops.properties — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.properties AS
SELECT p.id,
    p.client_id,
    p.name,
    p.address,
    p.city,
    p.state,
    p.zip,
    p.country,
    p.is_billing,
    p.created_at,
    p.updated_at,
    z.code AS zone,
    p.latitude,
    p.longitude,
    p.geofence_radius_meters,
    p.geofence_type,
    fn_sched_open(p.access_schedule) AS access_hours_start,
    fn_sched_close(p.access_schedule) AS access_hours_end,
    fn_sched_days(p.access_schedule) AS access_days,
    p.is_primary,
    p.notes,
    p.county,
    p.grease_trap_manhole_count,
    p.access_notes,
    p.default_disposal_facility_id
   FROM properties p
     LEFT JOIN zones z ON z.id = p.zone_id;
