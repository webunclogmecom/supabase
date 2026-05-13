-- ============================================================================
-- CHECK constraints on app_visit_reviews / app_shift_reviews — 2026-05-07
-- ============================================================================
-- Mirrors the visits_validate_review_status() trigger Lovable already enforces
-- on the canonical visits table. Once the canonical columns are dropped, we
-- still want the same data integrity on the app tables.
--
-- Apply to BOTH Prod and Sandbox (idempotent — uses ADD CONSTRAINT IF NOT
-- EXISTS via DO block, since plain ADD CONSTRAINT errors on duplicate).
-- ============================================================================

DO $$
BEGIN
  -- app_visit_reviews
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.app_visit_reviews'::regclass
      AND conname = 'app_visit_reviews_review_status_check'
  ) THEN
    ALTER TABLE app_visit_reviews ADD CONSTRAINT app_visit_reviews_review_status_check
      CHECK (review_status IN ('pending', 'approved', 'flagged'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.app_visit_reviews'::regclass
      AND conname = 'app_visit_reviews_bonus_status_check'
  ) THEN
    ALTER TABLE app_visit_reviews ADD CONSTRAINT app_visit_reviews_bonus_status_check
      CHECK (bonus_status IN ('pending', 'approved', 'denied'));
  END IF;

  -- app_shift_reviews
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.app_shift_reviews'::regclass
      AND conname = 'app_shift_reviews_review_status_check'
  ) THEN
    ALTER TABLE app_shift_reviews ADD CONSTRAINT app_shift_reviews_review_status_check
      CHECK (review_status IN ('pending', 'approved', 'flagged'));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.app_shift_reviews'::regclass
      AND conname = 'app_shift_reviews_bonus_status_check'
  ) THEN
    ALTER TABLE app_shift_reviews ADD CONSTRAINT app_shift_reviews_bonus_status_check
      CHECK (bonus_status IN ('pending', 'approved', 'denied'));
  END IF;
END
$$;
