-- ============================================================================
-- ops.v_dump_sites — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_dump_sites AS
SELECT d.dump_key,
    d.label,
    ((d.label || ' ('::text) || c.client_code) || ')'::text AS marker_value,
    d.client_id,
    d.job_id,
    d.property_id,
    p.address,
    p.city,
    p.latitude,
    p.longitude,
    d.county
   FROM ( VALUES ('DH'::text,'Homestead'::text,365::bigint,1720::bigint,98::bigint,'Miami-Dade'::text), ('DP'::text,'Pompano'::text,76::bigint,1662::bigint,155::bigint,'Broward'::text)) d(dump_key, label, client_id, job_id, property_id, county)
     JOIN properties p ON p.id = d.property_id
     JOIN clients c ON c.id = d.client_id;
