-- ============================================================================
-- Sandbox-only view override during transition — 2026-05-07
-- ============================================================================
-- Apply ONLY to Sandbox (ubtlwpcyntelgbykdatn). Do NOT run on Prod.
--
-- Problem: during Lovable's transition window, READS will swap to
-- visits_with_review BEFORE writes swap to app_visit_reviews. New writes
-- in that window land on visits.review_status etc. The Prod-compatible view
-- (which only reads from app_visit_reviews) wouldn't reflect them, so
-- Yannick would see stale 'pending' values until the write swap ships.
--
-- This Sandbox override replaces the view with a 3-way COALESCE:
--   app_visit_reviews.review_status   (post-write-swap data — winning)
--   visits.review_status              (legacy column, still updated until write-swap ships)
--   'pending'                         (default)
--
-- Apply AFTER yannick_app_tables_2026_05_05.sql.
--
-- Once Lovable confirms write swap is shipped AND the canonical columns
-- are dropped (yannick_sandbox_cleanup_2026_05_05.sql), this override
-- becomes equivalent to the Prod view and can be re-aligned by re-running
-- the main migration's CREATE OR REPLACE VIEW.
-- ============================================================================

CREATE OR REPLACE VIEW visits_with_review WITH (security_invoker = true) AS
SELECT
  v.id, v.client_id, v.property_id, v.job_id, v.vehicle_id,
  v.visit_date, v.start_at, v.end_at, v.completed_at, v.duration_minutes,
  v.title, v.service_type, v.visit_status,
  v.actual_arrival_at, v.actual_departure_at, v.is_gps_confirmed,
  v.created_at, v.updated_at, v.invoice_id, v.completed_by,
  COALESCE(avr.review_status,    v.review_status,    'pending') AS review_status,
  COALESCE(avr.reviewed_at,      v.reviewed_at)               AS reviewed_at,
  COALESCE(avr.reviewed_by,      v.reviewed_by)               AS reviewed_by,
  COALESCE(avr.bonus_status,     v.bonus_status,     'pending') AS bonus_status,
  COALESCE(avr.bonus_decided_at, v.bonus_decided_at)          AS bonus_decided_at,
  COALESCE(avr.bonus_decided_by, v.bonus_decided_by)          AS bonus_decided_by,
  COALESCE(avr.bonus_denial_note, v.bonus_denial_note)        AS bonus_denial_note,
  COALESCE(avr.quality_flag_note, v.quality_flag_note)        AS quality_flag_note
FROM visits v
LEFT JOIN app_visit_reviews avr ON avr.external_visit_id = v.id;

GRANT SELECT ON visits_with_review TO authenticated, anon, service_role;
