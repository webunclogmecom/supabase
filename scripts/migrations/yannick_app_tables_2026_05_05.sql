-- ============================================================================
-- Yannick / Lovable app-specific review + bonus tables — 2026-05-05
-- ============================================================================
-- Purpose: relocate Sandbox-only review/bonus state currently living on the
-- canonical `visits` table into dedicated `app_*` tables so that:
--   1. Sandbox refresh (TRUNCATE + reload from Prod) leaves them untouched.
--   2. The canonical `visits` table stays source-agnostic — no app/UI state.
--   3. Future app-graduation has a clean migration path (loose FKs become
--      real FKs once Sandbox = Prod).
--
-- Scope decisions (documented for review before apply):
--   - app_visit_reviews — mirrors the 8 columns Yannick added to visits.
--   - app_shift_reviews — NEW (Lovable's imminent ShiftFormReview.tsx); keyed
--     on (employee_id, shift_date) to match `inspections.shift_date`.
--   - SKIP app_photo_link_overrides + app_property_overrides — re-audit on
--     2026-05-05 confirmed `photo_links.role` and
--     `properties.grease_trap_manhole_count` are CANONICAL columns populated
--     by Jobber/Airtable sync (10K+ rows / 438 rows). The app currently only
--     INSERTs new photo_links rows and READs grease_trap_manhole_count; no
--     UPDATE pattern exists. Override tables added later if/when an admin UI
--     lets users overwrite the canonical values. (Per "no speculative
--     architecture" rule.)
--
-- Convention (from LOVABLE-SYSTEM-PROMPT.md §"App-specific tables"):
--   `external_<entity>_id BIGINT` — loose reference to the internal canonical
--   id WITHOUT a FK constraint. Internal IDs are stable across Sandbox refresh
--   (TRUNCATE+restore from Prod dump preserves the same numeric IDs). Real
--   FOREIGN KEYs would CASCADE-truncate during refresh — never use them.
--
-- Idempotent: re-runnable with no data loss (CREATE … IF NOT EXISTS,
-- CREATE OR REPLACE VIEW). Rerun after Lovable confirms.
--
-- Apply order:
--   1. Run this in PROD first (creates empty tables + views — zero data risk).
--   2. Run in Sandbox (also creates them — but data still lives on visits.*).
--   3. After Lovable refactors hooks to read/write the new tables/views,
--      run yannick_sandbox_cleanup_2026_05_05.sql to migrate the 1 test row
--      from visits and drop the 8 columns + 2 indexes from Sandbox.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. app_visit_reviews
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS app_visit_reviews (
  external_visit_id   BIGINT      PRIMARY KEY,           -- loose FK → visits.id
  review_status       TEXT        NOT NULL DEFAULT 'pending',
  reviewed_at         TIMESTAMPTZ,
  reviewed_by         BIGINT,                             -- loose FK → employees.id
  bonus_status        TEXT        NOT NULL DEFAULT 'pending',
  bonus_decided_at    TIMESTAMPTZ,
  bonus_decided_by    BIGINT,                             -- loose FK → employees.id
  bonus_denial_note   TEXT,
  quality_flag_note   TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_app_visit_reviews_review_status_visit
  ON app_visit_reviews (review_status, external_visit_id DESC);
CREATE INDEX IF NOT EXISTS idx_app_visit_reviews_bonus_status
  ON app_visit_reviews (bonus_status);

-- ---------------------------------------------------------------------------
-- 2. app_shift_reviews
-- ---------------------------------------------------------------------------
-- Keyed on (employee_id, shift_date) to match inspections.shift_date.
-- Inspection-level review/bonus uses this — one row per driver per shift.
CREATE TABLE IF NOT EXISTS app_shift_reviews (
  external_employee_id BIGINT      NOT NULL,              -- loose FK → employees.id
  shift_date           DATE        NOT NULL,
  review_status        TEXT        NOT NULL DEFAULT 'pending',
  reviewed_at          TIMESTAMPTZ,
  reviewed_by          BIGINT,                            -- loose FK → employees.id
  bonus_status         TEXT        NOT NULL DEFAULT 'pending',
  bonus_decided_at     TIMESTAMPTZ,
  bonus_decided_by     BIGINT,                            -- loose FK → employees.id
  bonus_denial_note    TEXT,
  shift_quality_note   TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (external_employee_id, shift_date)
);

CREATE INDEX IF NOT EXISTS idx_app_shift_reviews_review_status_date
  ON app_shift_reviews (review_status, shift_date DESC);
CREATE INDEX IF NOT EXISTS idx_app_shift_reviews_bonus_status
  ON app_shift_reviews (bonus_status);

-- ---------------------------------------------------------------------------
-- 3. updated_at triggers (matches the pattern used elsewhere)
-- ---------------------------------------------------------------------------
-- Reuse the standard trigger function set_updated_at() if it exists; create
-- it if not (some restored Sandboxes lack it).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'set_updated_at'
  ) THEN
    CREATE FUNCTION public.set_updated_at()
      RETURNS TRIGGER LANGUAGE plpgsql AS $f$
    BEGIN
      NEW.updated_at = now();
      RETURN NEW;
    END
    $f$ SET search_path = public, pg_temp;
  END IF;
END
$$;

DROP TRIGGER IF EXISTS trg_app_visit_reviews_updated_at ON app_visit_reviews;
CREATE TRIGGER trg_app_visit_reviews_updated_at
  BEFORE UPDATE ON app_visit_reviews
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_app_shift_reviews_updated_at ON app_shift_reviews;
CREATE TRIGGER trg_app_shift_reviews_updated_at
  BEFORE UPDATE ON app_shift_reviews
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. RLS — only authenticated users can read/write (mirrors other app tables)
-- ---------------------------------------------------------------------------
ALTER TABLE app_visit_reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_shift_reviews ENABLE ROW LEVEL SECURITY;

-- Use auth.uid() IS NOT NULL instead of `true` — clears Supabase advisor's
-- "RLS Policy Always True" lint while functionally equivalent (the policy
-- already targets only the `authenticated` role, where auth.uid() is set).
DROP POLICY IF EXISTS app_visit_reviews_authenticated_all ON app_visit_reviews;
CREATE POLICY app_visit_reviews_authenticated_all ON app_visit_reviews
  FOR ALL TO authenticated
  USING (auth.uid() IS NOT NULL) WITH CHECK (auth.uid() IS NOT NULL);

DROP POLICY IF EXISTS app_shift_reviews_authenticated_all ON app_shift_reviews;
CREATE POLICY app_shift_reviews_authenticated_all ON app_shift_reviews
  FOR ALL TO authenticated
  USING (auth.uid() IS NOT NULL) WITH CHECK (auth.uid() IS NOT NULL);

-- ---------------------------------------------------------------------------
-- 5. Drop-in views (security_invoker so RLS on base tables flows through)
-- ---------------------------------------------------------------------------
-- visits_with_review: same column shape as today's `visits` (with the 8
-- review/bonus columns coming from app_visit_reviews via LEFT JOIN). Lovable
-- can `.from('visits_with_review')` and the rest of the code stays identical.
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

-- inspections_with_review: same shape as inspections + shift-review fields.
-- Join on (employee_id, shift_date) — both columns already exist on
-- inspections. Returns NULL review/bonus columns for inspections without an
-- employee_id (some pre-2026 PRE/POST rows).
CREATE OR REPLACE VIEW inspections_with_review WITH (security_invoker = true) AS
SELECT
  i.id, i.vehicle_id, i.employee_id, i.shift_date, i.inspection_type,
  i.submitted_at, i.sludge_gallons, i.water_gallons, i.gas_level,
  i.is_valve_closed, i.has_issue, i.issue_note, i.created_at, i.updated_at,
  COALESCE(asr.review_status, 'pending') AS shift_review_status,
  asr.reviewed_at                         AS shift_reviewed_at,
  asr.reviewed_by                         AS shift_reviewed_by,
  COALESCE(asr.bonus_status, 'pending')  AS shift_bonus_status,
  asr.bonus_decided_at                    AS shift_bonus_decided_at,
  asr.bonus_decided_by                    AS shift_bonus_decided_by,
  asr.bonus_denial_note                   AS shift_bonus_denial_note,
  asr.shift_quality_note
FROM inspections i
LEFT JOIN app_shift_reviews asr
  ON asr.external_employee_id = i.employee_id
 AND asr.shift_date = i.shift_date;

-- ---------------------------------------------------------------------------
-- 6. Grants — anon doesn't read (RLS + revoke at view level keep it private)
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON app_visit_reviews TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON app_shift_reviews TO authenticated, service_role;
GRANT SELECT ON visits_with_review        TO authenticated, anon, service_role;
GRANT SELECT ON inspections_with_review   TO authenticated, anon, service_role;

-- ---------------------------------------------------------------------------
-- 7. Smoke check — should report:
--    app_visit_reviews=0, app_shift_reviews=0,
--    visits_with_review same row-count as visits,
--    inspections_with_review same row-count as inspections.
-- ---------------------------------------------------------------------------
-- SELECT
--   (SELECT COUNT(*) FROM app_visit_reviews)        AS avr_rows,
--   (SELECT COUNT(*) FROM app_shift_reviews)        AS asr_rows,
--   (SELECT COUNT(*) FROM visits)                   AS visits_rows,
--   (SELECT COUNT(*) FROM visits_with_review)       AS vwr_rows,
--   (SELECT COUNT(*) FROM inspections)              AS insp_rows,
--   (SELECT COUNT(*) FROM inspections_with_review)  AS iwr_rows;
