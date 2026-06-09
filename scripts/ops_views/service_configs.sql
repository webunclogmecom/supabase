-- ============================================================================
-- ops.service_configs — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.service_configs AS
SELECT id,
    client_id,
    service_type,
    frequency_days,
    first_visit,
    last_visit,
    stop_date,
    price_per_visit,
    schedule_notes,
    created_at,
    updated_at,
    equipment_size_gallons,
    ( SELECT g.gdo_number
           FROM gdos g
          WHERE g.client_id = sc.client_id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_number,
    ( SELECT g.permit_expiration
           FROM gdos g
          WHERE g.client_id = sc.client_id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_expiration,
    material_type,
    ( SELECT g.permit_document_path
           FROM gdos g
          WHERE g.client_id = sc.client_id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_document_path,
    property_id
   FROM service_configs sc;
