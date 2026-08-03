-- ============================================================================
-- ops.v_gdo_expiry — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_gdo_expiry AS
SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p_z.code AS zone,
    p.address,
    p.city,
    p.county,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    'Pumping'::text AS service_type,
    g.gdo_number AS permit_number,
    g.permit_expiration,
    sc.equipment_size_gallons,
    sc.frequency_days,
    g.permit_expiration - CURRENT_DATE AS days_until_expiry,
        CASE
            WHEN g.permit_expiration IS NULL THEN 'no_permit'::text
            WHEN g.permit_expiration < CURRENT_DATE THEN 'expired'::text
            WHEN (g.permit_expiration - CURRENT_DATE) <= 30 THEN 'expiring_30d'::text
            WHEN (g.permit_expiration - CURRENT_DATE) <= 60 THEN 'expiring_60d'::text
            WHEN (g.permit_expiration - CURRENT_DATE) <= 90 THEN 'expiring_90d'::text
            ELSE 'valid'::text
        END AS permit_status
   FROM gdos g
     JOIN clients c ON c.id = g.client_id
     LEFT JOIN properties p ON p.id = g.property_id
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = 'Pumping'::text
     LEFT JOIN zones p_z ON p_z.id = p.zone_id
  WHERE g.status = 'ACTIVE'::text AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text]))
  ORDER BY (
        CASE
            WHEN g.permit_expiration IS NULL THEN 2
            WHEN g.permit_expiration < CURRENT_DATE THEN 1
            WHEN (g.permit_expiration - CURRENT_DATE) <= 30 THEN 3
            WHEN (g.permit_expiration - CURRENT_DATE) <= 60 THEN 4
            WHEN (g.permit_expiration - CURRENT_DATE) <= 90 THEN 5
            ELSE 6
        END), (g.permit_expiration - CURRENT_DATE);
