-- ============================================================================
-- ops.v_derm_human_override_conflict — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_derm_human_override_conflict AS
SELECT v.id AS visit_id,
    c.client_code,
    c.name AS client_name,
    v.visit_date,
    v.visit_status,
    (now() AT TIME ZONE 'America/New_York'::text)::date - v.visit_date AS age_days,
    (EXISTS ( SELECT 1
           FROM manifest_visits mv
             JOIN derm_manifests dm ON dm.id = mv.manifest_id
          WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL)) AS has_manifest,
    v.derm_required,
    v.derm_required_locked
   FROM visits v
     LEFT JOIN clients c ON c.id = v.client_id
  WHERE v.deleted_at IS NULL AND v.visit_status = 'completed'::text AND v.derm_required_locked = true AND v.derm_required = false AND fn_visit_requires_derm(v.id) = true
  ORDER BY ((now() AT TIME ZONE 'America/New_York'::text)::date - v.visit_date) DESC;
