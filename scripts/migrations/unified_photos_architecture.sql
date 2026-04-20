-- ============================================================================
-- Migration: unified photos + photo_links architecture
-- ============================================================================
-- Purpose:
--   Replace per-entity photo tables (visit_photos, inspection_photos,
--   properties.location_photo_url inline column) with ONE photos table
--   holding intrinsic file/EXIF metadata, plus a polymorphic photo_links
--   table attaching a photo to any entity with a role (before/after/
--   overview/etc).
--
-- Why (the architectural insight):
--   Before/after is NOT a property of the photo — it's a property of how
--   the photo LINKS to an entity. The same photo can be "after" for
--   Monday's visit and "before" for Friday's next visit. Strict 3NF:
--   intrinsic attributes on the photo, relational attributes on the link.
--
-- 3NF check (per column):
--   photos: storage_path, file_name, content_type, size_bytes, width_px,
--   height_px, exif_*, uploaded_* — every column is a direct attribute
--   of the photo PK. source is the provenance observation. 3NF ✓
--   photo_links: photo_id + entity_type + entity_id + role — every
--   column is a direct attribute of the link PK. 3NF ✓
--
-- Replaces ADR 008. Mirrors the entity_source_links polymorphic pattern
-- (see ADR 002) — adding a new photo-owning entity type is a new value
-- of photo_links.entity_type, NOT a new table.
--
-- Safe because:
--   - visit_photos has 0 rows (verified 2026-04-20)
--   - inspection_photos has 0 rows (verified 2026-04-20)
--   - properties.location_photo_url retained temporarily — will be
--     backfilled into photos/photo_links and dropped in a follow-up
--     migration once populate.js is fully cut over.
-- ============================================================================

BEGIN;

-- 1. Intrinsic photo record — one row per actual file
CREATE TABLE IF NOT EXISTS photos (
  id                      BIGSERIAL PRIMARY KEY,
  storage_path            TEXT NOT NULL UNIQUE,
  thumbnail_path          TEXT,
  file_name               TEXT,
  content_type            TEXT,
  size_bytes              BIGINT,
  width_px                INTEGER,
  height_px               INTEGER,
  exif_taken_at           TIMESTAMPTZ,
  exif_latitude           NUMERIC,
  exif_longitude          NUMERIC,
  exif_device             TEXT,
  uploaded_by_employee_id BIGINT REFERENCES employees(id),
  uploaded_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  source                  TEXT NOT NULL DEFAULT 'app',
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE photos IS
  'Intrinsic photo record. One row per file in Supabase Storage. 3NF — all columns are direct attributes of the photo PK. Relational attributes (before/after, parent entity) live in photo_links.';
COMMENT ON COLUMN photos.source IS
  'Provenance: app | jobber_migration | fillout_migration | admin. Direct observation at insert time.';
COMMENT ON COLUMN photos.exif_taken_at IS
  'Timestamp from photo EXIF data if available — may differ from uploaded_at (e.g. bulk upload days later).';

-- 2. Polymorphic photo ↔ entity links
CREATE TABLE IF NOT EXISTS photo_links (
  id            BIGSERIAL PRIMARY KEY,
  photo_id      BIGINT NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
  entity_type   TEXT NOT NULL,
  entity_id     BIGINT NOT NULL,
  role          TEXT NOT NULL,
  caption       TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (photo_id, entity_type, entity_id, role)
);

CREATE INDEX IF NOT EXISTS idx_photo_links_entity
  ON photo_links (entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_photo_links_photo
  ON photo_links (photo_id);

COMMENT ON TABLE photo_links IS
  'Polymorphic bridge. One photo can link to many entities with different roles. Mirrors entity_source_links pattern. Enforced by convention: entity_id references an id in the table named by entity_type.';
COMMENT ON COLUMN photo_links.entity_type IS
  'visit | property | inspection | note | vehicle | expense (future). Controlled vocabulary, documented in docs/schema.md.';
COMMENT ON COLUMN photo_links.role IS
  'Per entity_type: visit → before|after|grease_pit|damage|derm_manifest|address|remote|other. property → overview|access|grease_trap_location|manhole|other. inspection → dashboard|cabin|front|back|tires|other. note → attachment. vehicle → general.';

-- 3. Drop the superseded per-entity photo tables (empty, safe)
DROP TABLE IF EXISTS visit_photos;
DROP TABLE IF EXISTS inspection_photos;

-- 4. properties.location_photo_url — left in place for now. Will be
--    backfilled and dropped in a follow-up migration after populate.js
--    and any consumers are updated.

COMMIT;
