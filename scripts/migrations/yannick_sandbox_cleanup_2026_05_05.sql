-- ============================================================================
-- Sandbox-only cleanup after Lovable migrates to app_visit_reviews — 2026-05-05
-- ============================================================================
-- Runs ONLY in Sandbox (Prod never had these columns).
--
-- Pre-conditions:
--   - yannick_app_tables_2026_05_05.sql has been applied to Sandbox.
--   - Lovable has switched all hooks/queries to read from `visits_with_review`
--     view and write through `app_visit_reviews` table.
--
-- Steps:
--   1. Migrate any non-default review/bonus rows from visits.* → app_visit_reviews
--      (only known row at writing: visit 1610 — review=approved, bonus=approved,
--      both _by/_at NULL).
--   2. Drop the 8 review/bonus columns from visits.
--   3. The 2 indexes (idx_visits_review_status_date, idx_visits_bonus_status)
--      are dropped automatically by ALTER TABLE … DROP COLUMN.
--   4. Drop the visits_with_review view's dependency on the dropped columns
--      is non-existent because the view we shipped reads from app_visit_reviews
--      already; visits.* in the view does NOT include the 8 columns by name.
--
-- Roll-forward only — once columns are dropped, the only way back is
-- recreating them and copying from app_visit_reviews. Don't run until
-- Lovable confirms migration is live in Sandbox.
-- ============================================================================

BEGIN;

-- 1. Migrate any rows where review/bonus differs from defaults
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

-- 2. Sanity check: log how many rows we migrated
DO $$
DECLARE n INT;
BEGIN
  SELECT COUNT(*) INTO n FROM app_visit_reviews;
  RAISE NOTICE 'app_visit_reviews now has % rows', n;
END
$$;

-- 2.4. Drop the validation trigger that enforces the review/bonus enums on
-- visits — it depends on the columns we're about to drop. The same enum
-- enforcement is now baked into app_visit_reviews via CHECK constraints.
DROP TRIGGER IF EXISTS visits_validate_review_status_trg ON visits;
DROP FUNCTION IF EXISTS public.visits_validate_review_status();

-- 2.5. Replace the Sandbox 3-way COALESCE view with the Prod-compatible
-- definition BEFORE dropping the columns. Otherwise DROP COLUMN fails on
-- the view dependency (the override referenced v.review_status etc.).
-- After this, visits_with_review COALESCEs only over app_visit_reviews —
-- which is correct now that all writes flow through app_*.
CREATE OR REPLACE VIEW visits_with_review WITH (security_invoker = true) AS
SELECT
  v.id, v.client_id, v.property_id, v.job_id, v.vehicle_id,
  v.visit_date, v.start_at, v.end_at, v.completed_at, v.duration_minutes,
  v.title, v.service_type, v.visit_status,
  v.actual_arrival_at, v.actual_departure_at, v.is_gps_confirmed,
  v.created_at, v.updated_at, v.invoice_id, v.completed_by,
  COALESCE(avr.review_status, 'pending')  AS review_status,
  avr.reviewed_at,
  avr.reviewed_by,
  COALESCE(avr.bonus_status, 'pending')   AS bonus_status,
  avr.bonus_decided_at,
  avr.bonus_decided_by,
  avr.bonus_denial_note,
  avr.quality_flag_note
FROM visits v
LEFT JOIN app_visit_reviews avr ON avr.external_visit_id = v.id;

-- 3. Drop the 8 columns from canonical visits (CASCADE drops the 2 indexes)
ALTER TABLE visits DROP COLUMN IF EXISTS review_status;
ALTER TABLE visits DROP COLUMN IF EXISTS reviewed_at;
ALTER TABLE visits DROP COLUMN IF EXISTS reviewed_by;
ALTER TABLE visits DROP COLUMN IF EXISTS bonus_status;
ALTER TABLE visits DROP COLUMN IF EXISTS bonus_decided_at;
ALTER TABLE visits DROP COLUMN IF EXISTS bonus_decided_by;
ALTER TABLE visits DROP COLUMN IF EXISTS bonus_denial_note;
ALTER TABLE visits DROP COLUMN IF EXISTS quality_flag_note;

-- 4. Verify visits is back to baseline width (Prod has 20 columns)
DO $$
DECLARE n INT;
BEGIN
  SELECT COUNT(*) INTO n FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'visits';
  RAISE NOTICE 'visits column count after cleanup: %  (expected 20)', n;
  IF n <> 20 THEN
    RAISE WARNING 'Sandbox visits has % columns (expected 20); inspect manually before commit.', n;
  END IF;
END
$$;

COMMIT;
