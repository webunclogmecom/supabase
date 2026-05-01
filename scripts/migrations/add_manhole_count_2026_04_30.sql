-- ============================================================================
-- Add grease_trap_manhole_count to properties (2026-04-30)
-- ============================================================================
-- Per Fred (2026-04-30): some grease-trap clients have multiple manholes per
-- location (e.g. a single restaurant with 3 trap covers). We want to track
-- the count per property so drivers know how many to service and routing can
-- factor capacity correctly.
--
-- This is a NEW data point — not in Airtable today. Manual entry by Diego
-- via Supabase Studio (or future Odoo UI).
--
-- Default 0 — only set explicitly when Airtable supplies a value (per Fred
-- 2026-05-01 — initial DEFAULT 1 was wrong; it caused 318 properties to
-- inherit a phantom "1 manhole" reading without Airtable evidence).
--
-- Future: if per-manhole detail (size, location notes, cover photos) is
-- needed, refactor to a property_manholes child table. For now, integer
-- count is sufficient.
-- ============================================================================

BEGIN;

ALTER TABLE properties
  ADD COLUMN IF NOT EXISTS grease_trap_manhole_count INTEGER NOT NULL DEFAULT 0;

-- If column already exists with the old DEFAULT 1, normalize it.
ALTER TABLE properties ALTER COLUMN grease_trap_manhole_count SET DEFAULT 0;

COMMENT ON COLUMN properties.grease_trap_manhole_count IS
  'Number of grease trap manholes (covers) at this property. Default 0; only set when Airtable Clients.manholes explicitly supplies a value.';

COMMIT;
