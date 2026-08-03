-- DO NOT APPLY THIS FILE AS-IS - IT IS A STALE SNAPSHOT (flagged 2026-08-03).
--
-- These checked-in view definitions have drifted from the live database, and
-- re-applying one REVERTS whatever shipped since it was captured. Measured
-- 2026-08-03 against Prod:
--   * 06_v_derm_compliance.sql still filters unmatched_visits on
--     service_type = GT. LIVE uses derm_required (ADR 018, line-item-derived).
--     Applying the file would revert DERM-required to the unreliable proxy.
--   * v_calendar_visit.sql is 6.3 KB against a 13.6 KB live definition, i.e.
--     roughly half the view is missing.
--
-- They also carry the legacy GT/CL/WD/LS vocabulary, retired on 2026-08-03.
-- REGENERATE FROM LIVE (pg_get_viewdef) before trusting or applying any of them.
-- Tracked in docs/plans/2026-08-03_service_type_vocabulary_migration_plan.md.

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
    p.zone,
    p.address,
    p.city,
    p.county,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    'GT'::text AS service_type,
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
     LEFT JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = 'GT'::text
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
