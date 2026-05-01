-- =============================================================================
-- Delete pre-2026 visits + everything linked — 2026-05-01
-- =============================================================================
-- Per Fred 2026-05-01: visits dated before 2026-01-01 are out of scope. Drop
-- the visits AND every dependent row in the right order.
--
-- Why each step is explicit:
--   - manifest_visits, visit_assignments → CASCADE on visits delete: handled
--   - notes.visit_id, jobber_oversized_attachments.visit_id → NO ACTION:
--     would block; must clear before deleting visits
--   - photo_links, entity_source_links → polymorphic (entity_type+entity_id),
--     no FK constraint, no auto-cascade: must DELETE explicitly
--   - photos → orphan after photo_links cleared; clean up after to keep DB tidy
--
-- All in one transaction. Rollback safe.
-- =============================================================================

BEGIN;

-- 1. Snapshot what we're about to delete (for sanity)
DO $$
DECLARE
  v_count int;
BEGIN
  SELECT COUNT(*) INTO v_count FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL;
  RAISE NOTICE 'Visits to delete: %', v_count;
END $$;

-- 2. NULL out jobber_oversized_attachments.visit_id (NO ACTION FK)
-- These are per-visit oversized files; if the visit goes, lose the link but
-- keep the row (the file itself was already saved to local backup).
UPDATE jobber_oversized_attachments
SET visit_id = NULL
WHERE visit_id IN (
  SELECT id FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL
);

-- 3. Notes attached to about-to-be-deleted visits — clean their dependents first
WITH del_notes AS (
  SELECT id FROM notes
  WHERE visit_id IN (SELECT id FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL)
)
DELETE FROM photo_links
WHERE entity_type = 'note' AND entity_id IN (SELECT id FROM del_notes);

WITH del_notes AS (
  SELECT id FROM notes
  WHERE visit_id IN (SELECT id FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL)
)
DELETE FROM entity_source_links
WHERE entity_type = 'note' AND entity_id IN (SELECT id FROM del_notes);

-- 4. Delete those notes
DELETE FROM notes
WHERE visit_id IN (SELECT id FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL);

-- 5. Photo links pointing to visits being deleted
DELETE FROM photo_links
WHERE entity_type = 'visit'
  AND entity_id IN (SELECT id FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL);

-- 6. Entity source links for those visits
DELETE FROM entity_source_links
WHERE entity_type = 'visit'
  AND entity_id IN (SELECT id FROM visits WHERE visit_date < '2026-01-01' OR visit_date IS NULL);

-- 7. Delete the visits — manifest_visits and visit_assignments cascade
DELETE FROM visits
WHERE visit_date < '2026-01-01' OR visit_date IS NULL;

-- 8. Orphaned photos (no photo_links pointing to them anymore)
-- First their ESL, then the photos themselves. Storage files are NOT removed
-- by this migration — they're harmless cruft in the bucket; can be swept later.
DELETE FROM entity_source_links
WHERE entity_type = 'photo' AND entity_id IN (
  SELECT p.id FROM photos p
  WHERE NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.photo_id = p.id)
);

DELETE FROM photos
WHERE NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.photo_id = photos.id);

-- 9. Final sanity report
DO $$
DECLARE
  v_remaining int;
  v_min_date date;
BEGIN
  SELECT COUNT(*), MIN(visit_date) INTO v_remaining, v_min_date FROM visits;
  RAISE NOTICE 'Visits remaining: % (earliest date: %)', v_remaining, v_min_date;
END $$;

COMMIT;
