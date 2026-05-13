-- ============================================================================
-- Sandbox-only data backfill — 2026-05-07
-- ============================================================================
-- Apply to Sandbox (ubtlwpcyntelgbykdatn) AFTER yannick_app_tables_2026_05_05.sql.
-- Copies any non-default review/bonus values currently on visits.* into the
-- new app_visit_reviews table so the visits_with_review view returns the
-- same data via COALESCE — Lovable's app stays visually identical.
--
-- Idempotent: only inserts where external_visit_id doesn't already exist
-- (ON CONFLICT DO NOTHING).
-- ============================================================================

INSERT INTO app_visit_reviews (
  external_visit_id,
  review_status, reviewed_at, reviewed_by,
  bonus_status,  bonus_decided_at, bonus_decided_by,
  bonus_denial_note, quality_flag_note
)
SELECT
  id,
  review_status, reviewed_at, reviewed_by,
  bonus_status,  bonus_decided_at, bonus_decided_by,
  bonus_denial_note, quality_flag_note
FROM visits
WHERE review_status        <> 'pending'
   OR bonus_status         <> 'pending'
   OR reviewed_at           IS NOT NULL
   OR reviewed_by           IS NOT NULL
   OR bonus_decided_at      IS NOT NULL
   OR bonus_decided_by      IS NOT NULL
   OR bonus_denial_note     IS NOT NULL
   OR quality_flag_note     IS NOT NULL
ON CONFLICT (external_visit_id) DO NOTHING;

DO $$
DECLARE n INT;
BEGIN
  SELECT COUNT(*) INTO n FROM app_visit_reviews;
  RAISE NOTICE 'app_visit_reviews row count after backfill: %', n;
END
$$;
