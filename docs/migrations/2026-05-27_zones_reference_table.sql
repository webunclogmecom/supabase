-- 2026-05-27_zones_reference_table.sql
--
-- New canonical reference table `public.zones` to hold UnclogMe operational
-- zone definitions + display colors. Driven by Fred's 2026-05-27 ask to give
-- the Calendar app (and any future zone-aware surface) a single source of
-- truth for zone colors instead of hardcoding them per app.
--
-- BACKGROUND
--   `public.properties.zone TEXT` already holds zone codes (SOUTH, AVE, NMB,
--   BRO, SF/BH, DOWN, MIAMI BEACH, SUNNY, PALM, MID/EDG, WEST). Surfaced into
--   `ops.v_calendar_visit.zone` + ~6 other ops views. Colors had been
--   hardcoded in the Lovable Calendar (and were wrong/missing — Fred's
--   prompt). All 11 zone codes are populated in `public.properties`
--   (audit 2026-05-27).
--
-- DESIGN
--   - `code TEXT PRIMARY KEY` — matches the existing string values on
--     `public.properties.zone`. No FK from properties → zones added in this
--     migration; legacy zone strings stay as-is. The Calendar uses
--     LEFT JOIN semantics (NULL color for unknown zone).
--   - `label TEXT NOT NULL` — best-guess human-friendly name; Fred can
--     UPDATE later (audit trigger captures the change).
--   - `color_hex TEXT NOT NULL` — `#RRGGBB` (CHECK constraint). Web-safe.
--   - `color_token TEXT` — Airtable color token (e.g. `blueBright`). Kept
--     for round-trip parity with AT views while AT exists; harmless after
--     sunset.
--   - `sort_order INT` — controls legend/dropdown order in apps. Stepped
--     by 10 so future inserts slot in cleanly.
--   - `is_active BOOLEAN DEFAULT true` — per CLAUDE.md rule 6 (never hard-
--     delete). Calendar filters `is_active = true`.
--   - `created_at`, `updated_at TIMESTAMPTZ` — trigger-managed.
--
-- 3NF check (CLAUDE.md rule 2):
--   code → label, color_hex, color_token, sort_order, is_active — all
--   depend on the whole key and nothing else. No transitive deps.
--
-- Reference all data (Rule 3): color_hex stays in `public.zones`. NOT
-- denormalized into `public.properties` or any view. Apps either JOIN or
-- fetch the 11-row table once on load.
--
-- Source-agnostic (Rule 1): no source-prefixed columns. `color_token` is
-- source-agnostic ("Airtable color token" happens to be the only consumer
-- today, but the column name is generic).
--
-- Idempotent (Rule 5): `CREATE TABLE IF NOT EXISTS` + `INSERT ... ON
-- CONFLICT (code) DO UPDATE`. Re-runnable.
--
-- Audit (Rule 8): opted in via `audit_zones` trigger. Reference data is
-- human-editable; Fred or ops will likely UPDATE labels/colors over time.

BEGIN;

-- ============================================================
-- 1. Table
-- ============================================================
CREATE TABLE IF NOT EXISTS public.zones (
  code         TEXT PRIMARY KEY,
  label        TEXT NOT NULL,
  color_hex    TEXT NOT NULL CHECK (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  color_token  TEXT,
  sort_order   INTEGER NOT NULL DEFAULT 0,
  is_active    BOOLEAN NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.zones IS
  'Operational zone reference data — codes used by public.properties.zone, plus display label + hex color for app rendering. Seeded 2026-05-27. Edits go through ops/Fred; audit trigger captures changes.';

COMMENT ON COLUMN public.zones.code IS
  'Zone code matching public.properties.zone values (SOUTH, NMB, etc.). No FK because legacy properties.zone may carry strings not yet in this table.';
COMMENT ON COLUMN public.zones.color_hex IS
  '#RRGGBB display color used by Calendar + other zone-aware UIs.';
COMMENT ON COLUMN public.zones.color_token IS
  'Original Airtable color token name (blueBright, tealLight2, etc.). Kept for AT round-trip; harmless after AT sunset.';

-- ============================================================
-- 2. updated_at trigger (Rule 7)
-- ============================================================
DROP TRIGGER IF EXISTS set_updated_at_zones ON public.zones;
CREATE TRIGGER set_updated_at_zones
  BEFORE UPDATE ON public.zones
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- 3. Audit trigger (Rule 8 — opt-in: human-editable reference data)
-- ============================================================
DROP TRIGGER IF EXISTS audit_zones ON public.zones;
CREATE TRIGGER audit_zones
  AFTER INSERT OR UPDATE OR DELETE ON public.zones
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- ============================================================
-- 4. Seed 11 zones (per Fred's 2026-05-27 CSV) — idempotent
-- ============================================================
INSERT INTO public.zones (code, label, color_hex, color_token, sort_order) VALUES
  ('SOUTH',       'South Dade',             '#2D7FF9', 'blueBright',    10),
  ('AVE',         'Aventura',               '#C0F0F0', 'tealLight2',    20),
  ('NMB',         'North Miami Beach',      '#D1F7C4', 'greenLight2',   30),
  ('BRO',         'Broward',                '#FFEAB6', 'yellowLight2',  40),
  ('SF/BH',       'Surfside / Bal Harbour', '#FEE2D5', 'orangeLight2',  50),
  ('DOWN',        'Downtown Miami',         '#FFDCE5', 'redLight2',     60),
  ('MIAMI BEACH', 'Miami Beach',            '#FFDAF6', 'pinkLight2',    70),
  ('SUNNY',       'Sunny Isles',            '#EDE2FE', 'purpleLight2',  80),
  ('PALM',        'Palmetto Bay',           '#ECECEC', 'grayLight2',    90),
  ('MID/EDG',     'Midtown / Edgewater',    '#9CC7FF', 'blueLight1',   100),
  ('WEST',        'West Miami',             '#77D1F3', 'cyanLight1',   110)
ON CONFLICT (code) DO UPDATE SET
  label       = EXCLUDED.label,
  color_hex   = EXCLUDED.color_hex,
  color_token = EXCLUDED.color_token,
  sort_order  = EXCLUDED.sort_order;

-- ============================================================
-- 5. Grants — anon SELECT for Lovable apps; INSERT/UPDATE postgres-only
-- ============================================================
GRANT SELECT ON public.zones TO anon, authenticated;

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- 1. 11 active zones present:
--    SELECT code, label, color_hex, sort_order FROM public.zones
--    WHERE is_active ORDER BY sort_order;
--
-- 2. All current properties.zone values have a matching row (coverage):
--    SELECT DISTINCT p.zone, z.code IS NULL AS missing_color
--    FROM public.properties p LEFT JOIN public.zones z ON z.code = p.zone
--    WHERE p.zone IS NOT NULL;
--    Expected: missing_color = false for all rows.
--
-- 3. Audit trigger active:
--    SELECT * FROM audit.logs
--    WHERE table_name='zones' ORDER BY changed_at DESC LIMIT 5;
--    Expected: 11 INSERT rows from the seed.
