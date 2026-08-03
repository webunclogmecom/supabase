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
-- ops.v_derm_compliance — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_derm_compliance AS
WITH last_manifest AS (
         SELECT derm_manifests.client_id,
            max(derm_manifests.service_date) AS last_manifest_date,
            count(*) AS total_manifests
           FROM derm_manifests
          GROUP BY derm_manifests.client_id
        ), unmatched_visits AS (
         SELECT v.client_id,
            count(*) AS missing_manifests
           FROM visits v
          WHERE v.service_type = 'GT'::text AND v.visit_status = 'completed'::text AND v.visit_date >= (CURRENT_DATE - '120 days'::interval) AND NOT (EXISTS ( SELECT 1
                   FROM derm_manifests dm
                  WHERE dm.client_id = v.client_id AND dm.service_date = v.visit_date))
          GROUP BY v.client_id
        )
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
    ( SELECT g.gdo_number
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_number,
    ( SELECT g.permit_expiration
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_expiration,
    sc.equipment_size_gallons,
    sc.frequency_days,
    lm.last_manifest_date,
    lm.total_manifests,
    COALESCE(uv.missing_manifests, 0::bigint) AS missing_manifest_count,
        CASE
            WHEN COALESCE(uv.missing_manifests, 0::bigint) > 0 THEN true
            ELSE false
        END AS has_missing_manifests,
    CURRENT_DATE - lm.last_manifest_date AS days_since_last_manifest,
        CASE
            WHEN lm.last_manifest_date IS NULL THEN 'no_service_record'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 'derm_violation'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 'overdue'::text
            WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 'due_soon'::text
            ELSE 'compliant'::text
        END AS compliance_status
   FROM clients c
     JOIN service_configs sc ON sc.client_id = c.id AND sc.service_type = 'GT'::text
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN last_manifest lm ON lm.client_id = c.id
     LEFT JOIN unmatched_visits uv ON uv.client_id = c.id
  WHERE c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])
  ORDER BY (
        CASE
            WHEN (CURRENT_DATE - lm.last_manifest_date) > 90 THEN 1
            WHEN lm.last_manifest_date IS NULL THEN 2
            WHEN (CURRENT_DATE - lm.last_manifest_date) > COALESCE(sc.frequency_days, 90) THEN 3
            WHEN (CURRENT_DATE - lm.last_manifest_date) > (COALESCE(sc.frequency_days, 90) - 14) THEN 4
            ELSE 5
        END), (COALESCE(uv.missing_manifests, 0::bigint)) DESC, (CURRENT_DATE - lm.last_manifest_date) DESC NULLS LAST;
