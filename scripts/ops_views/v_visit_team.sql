-- ============================================================================
-- ops.v_visit_team — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_visit_team AS
SELECT vt.visit_id,
    vt.employee_id,
    e.full_name
   FROM visit_team vt
     JOIN employees e ON e.id = vt.employee_id;
