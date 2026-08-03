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
-- ops.v_service_due — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_service_due AS
WITH actual_last_visit AS (
         SELECT visits.client_id,
            max(visits.visit_date) AS last_visit_actual
           FROM visits
          WHERE visits.visit_status = 'completed'::text
          GROUP BY visits.client_id
        )
 SELECT c.id,
    c.client_code,
    c.name AS client_name,
    c.status AS client_status,
    p.zone,
    p.address,
    p.city,
    p.county,
    p.access_hours_start,
    p.access_hours_end,
    cc.name AS contact_name,
    cc.email,
    cc.phone,
    sc.service_type,
    sc.frequency_days,
    sc.equipment_size_gallons,
    ( SELECT g.gdo_number
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id
         LIMIT 1) AS permit_number,
    sc.price_per_visit,
    COALESCE(sc.last_visit, alv.last_visit_actual) AS last_service_date,
    (COALESCE(sc.last_visit, alv.last_visit_actual) + ((sc.frequency_days || ' days'::text)::interval))::date AS scheduled_next_visit,
    CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual) AS days_since_service,
        CASE
            WHEN COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL THEN 'never_serviced'::text
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90 THEN 'derm_violation'::text
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days THEN 'overdue'::text
            WHEN (COALESCE(sc.last_visit, alv.last_visit_actual) + sc.frequency_days - CURRENT_DATE) <= 14 THEN 'due_soon'::text
            ELSE 'on_schedule'::text
        END AS service_status
   FROM clients c
     JOIN service_configs sc ON sc.client_id = c.id AND (sc.service_type = ANY (ARRAY['GT'::text, 'CL'::text]))
     LEFT JOIN client_contacts cc ON cc.client_id = c.id AND cc.contact_role = 'primary'::text
     LEFT JOIN properties p ON p.client_id = c.id AND p.is_primary = true
     LEFT JOIN actual_last_visit alv ON alv.client_id = c.id
  WHERE (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])) AND (COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL OR (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= (COALESCE(sc.frequency_days, 90) - 14))
  ORDER BY (
        CASE
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) > 90 THEN 1
            ELSE 2
        END), p.zone, (
        CASE
            WHEN COALESCE(sc.last_visit, alv.last_visit_actual) IS NULL THEN 1
            WHEN (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) >= sc.frequency_days THEN 2
            ELSE 3
        END), (CURRENT_DATE - COALESCE(sc.last_visit, alv.last_visit_actual)) DESC NULLS LAST;
