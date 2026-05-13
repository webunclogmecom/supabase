-- ============================================================================
-- Sandbox-only anon RLS for app_* tables — 2026-05-07
-- ============================================================================
-- Apply ONLY to Sandbox (ubtlwpcyntelgbykdatn). Do NOT run on Prod.
--
-- Context: Lovable's app currently runs without auth (Fred's Option B,
-- 2026-05-05). To keep the app working when Lovable refactors hooks to use
-- app_visit_reviews / app_shift_reviews, anon needs SELECT/INSERT/UPDATE
-- on these tables — same pattern as the other Sandbox tables (visits,
-- photo_links, properties, etc).
--
-- Prod stays strict (authenticated-only). At Lovable's eventual graduation
-- to real auth, these anon policies are dropped.
-- ============================================================================

-- app_visit_reviews — anon SELECT + INSERT + UPDATE
DROP POLICY IF EXISTS app_visit_reviews_anon_read   ON app_visit_reviews;
DROP POLICY IF EXISTS app_visit_reviews_anon_write  ON app_visit_reviews;
CREATE POLICY app_visit_reviews_anon_read  ON app_visit_reviews
  FOR SELECT TO anon USING (true);
CREATE POLICY app_visit_reviews_anon_write ON app_visit_reviews
  FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY app_visit_reviews_anon_update ON app_visit_reviews
  FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- app_shift_reviews — same pattern
DROP POLICY IF EXISTS app_shift_reviews_anon_read   ON app_shift_reviews;
DROP POLICY IF EXISTS app_shift_reviews_anon_write  ON app_shift_reviews;
DROP POLICY IF EXISTS app_shift_reviews_anon_update ON app_shift_reviews;
CREATE POLICY app_shift_reviews_anon_read  ON app_shift_reviews
  FOR SELECT TO anon USING (true);
CREATE POLICY app_shift_reviews_anon_write ON app_shift_reviews
  FOR INSERT TO anon WITH CHECK (true);
CREATE POLICY app_shift_reviews_anon_update ON app_shift_reviews
  FOR UPDATE TO anon USING (true) WITH CHECK (true);

-- Grants — anon needs INSERT/UPDATE rights at the role level too
GRANT SELECT, INSERT, UPDATE ON app_visit_reviews TO anon;
GRANT SELECT, INSERT, UPDATE ON app_shift_reviews TO anon;
