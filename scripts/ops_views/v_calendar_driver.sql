-- ============================================================================
-- ops.v_calendar_driver — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

CREATE OR REPLACE VIEW ops.v_calendar_driver AS
SELECT id,
    full_name,
    role,
    status,
    shift,
    phone,
    email
   FROM employees
  WHERE status = 'ACTIVE'::text
  ORDER BY full_name;
