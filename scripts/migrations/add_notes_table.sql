-- ============================================================================
-- Migration: add notes table for free-form client/visit/property text
-- ============================================================================
-- Purpose:
--   Dedicated table for note text (distinct from note *attachments*, which
--   live in the unified photos/photo_links pair per ADR 009).
--
--   A note is attached to a client and optionally scoped to a visit,
--   property, or job. The timestamp (note_date) is load-bearing — the
--   Jobber photo migration triangulates notes to visits by proximity of
--   note_date to visits.visit_date.
--
-- 3NF check (per column):
--   client_id / visit_id / property_id / job_id — FK links. ✓
--   body, note_date, source, tags, created_at, updated_at — direct
--   attributes of the note PK. ✓
--   author_employee_id — FK link. ✓
--   author_name — intentional denorm fallback for unresolvable historical
--   Jobber users (parallel to ADR 004). Justified. ✓
--
-- Consumers:
--   - Jobber photo migration (source='jobber_migration')
--   - Future custom UI / Odoo writes (source='user')
--   - AI summarization writes (source='ai')
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS notes (
  id                  BIGSERIAL PRIMARY KEY,
  client_id           BIGINT NOT NULL REFERENCES clients(id),
  visit_id            BIGINT REFERENCES visits(id),
  property_id         BIGINT REFERENCES properties(id),
  job_id              BIGINT REFERENCES jobs(id),
  body                TEXT NOT NULL,
  author_employee_id  BIGINT REFERENCES employees(id),
  author_name         TEXT,
  note_date           TIMESTAMPTZ NOT NULL,
  source              TEXT NOT NULL DEFAULT 'user',
  tags                TEXT[],
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notes_client
  ON notes (client_id, note_date DESC);
CREATE INDEX IF NOT EXISTS idx_notes_visit
  ON notes (visit_id) WHERE visit_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_notes_property
  ON notes (property_id) WHERE property_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_notes_source
  ON notes (source);

COMMENT ON TABLE notes IS
  'Free-form text notes attached to a client and optionally scoped to a visit/property/job. Attachments (photos) live in photo_links with entity_type=''note'' or routed to their classified parent (visit/property) by the migration classifier.';

COMMENT ON COLUMN notes.note_date IS
  'Original note timestamp. Load-bearing: used by the Jobber photo migration to triangulate notes to visits (±1 day match window on visits.visit_date).';

COMMENT ON COLUMN notes.source IS
  'Provenance: user | jobber_migration | fillout_migration | ai | system. Direct observation at insert time.';

COMMENT ON COLUMN notes.author_name IS
  'Intentional denorm fallback (see ADR 004). Used for historical Jobber notes whose Jobber user can''t be mapped to our employees table. New notes should populate author_employee_id instead.';

-- Auto-update updated_at on UPDATE
CREATE OR REPLACE FUNCTION trg_set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_notes_updated_at ON notes;
CREATE TRIGGER trg_notes_updated_at
  BEFORE UPDATE ON notes
  FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

COMMIT;
