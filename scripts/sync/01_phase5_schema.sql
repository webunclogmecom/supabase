-- ============================================================================
-- Phase 5.1 — Incremental sync schema additions
-- ============================================================================
-- Non-breaking, additive only. Safe to re-run.
-- ============================================================================

-- sync_cursors: one row per entity, tracks last successful delta pull.
CREATE TABLE IF NOT EXISTS public.sync_cursors (
  entity            TEXT PRIMARY KEY,
  last_synced_at    TIMESTAMPTZ,
  last_run_started  TIMESTAMPTZ,
  last_run_finished TIMESTAMPTZ,
  last_run_status   TEXT CHECK (last_run_status IN ('running','success','failed')),
  last_error        TEXT,
  rows_pulled       INTEGER DEFAULT 0,
  rows_populated    INTEGER DEFAULT 0,
  created_at        TIMESTAMPTZ DEFAULT now(),
  updated_at        TIMESTAMPTZ DEFAULT now()
);

-- Seed the 8 Jobber entities with a safe baseline (2020-01-01 so first run
-- pulls everything and then caches updatedAt correctly). Idempotent.
INSERT INTO public.sync_cursors (entity, last_synced_at, last_run_status)
VALUES
  ('clients',    '2020-01-01T00:00:00Z', 'success'),
  ('properties', '2020-01-01T00:00:00Z', 'success'),
  ('jobs',       '2020-01-01T00:00:00Z', 'success'),
  ('visits',     '2020-01-01T00:00:00Z', 'success'),
  ('invoices',   '2020-01-01T00:00:00Z', 'success'),
  ('quotes',     '2020-01-01T00:00:00Z', 'success'),
  ('line_items', '2020-01-01T00:00:00Z', 'success'),
  ('users',      '2020-01-01T00:00:00Z', 'success')
ON CONFLICT (entity) DO NOTHING;

-- Add flag columns to every raw.jobber_pull_* table.
DO $$
DECLARE
  t TEXT;
BEGIN
  FOR t IN SELECT unnest(ARRAY[
    'jobber_pull_clients',
    'jobber_pull_properties',
    'jobber_pull_jobs',
    'jobber_pull_visits',
    'jobber_pull_invoices',
    'jobber_pull_quotes',
    'jobber_pull_line_items',
    'jobber_pull_users'
  ]) LOOP
    EXECUTE format('ALTER TABLE raw.%I ADD COLUMN IF NOT EXISTS ingested_at TIMESTAMPTZ DEFAULT now()', t);
    EXECUTE format('ALTER TABLE raw.%I ADD COLUMN IF NOT EXISTS needs_populate BOOLEAN DEFAULT false', t);
  END LOOP;
END $$;

-- Mark baseline rows as already-populated (they were loaded by the original populate).
UPDATE raw.jobber_pull_clients    SET needs_populate = false WHERE needs_populate IS NULL;
UPDATE raw.jobber_pull_properties SET needs_populate = false WHERE needs_populate IS NULL;
UPDATE raw.jobber_pull_jobs       SET needs_populate = false WHERE needs_populate IS NULL;
UPDATE raw.jobber_pull_visits     SET needs_populate = false WHERE needs_populate IS NULL;
UPDATE raw.jobber_pull_invoices   SET needs_populate = false WHERE needs_populate IS NULL;
UPDATE raw.jobber_pull_quotes     SET needs_populate = false WHERE needs_populate IS NULL;
UPDATE raw.jobber_pull_line_items SET needs_populate = false WHERE needs_populate IS NULL;
UPDATE raw.jobber_pull_users      SET needs_populate = false WHERE needs_populate IS NULL;

SELECT 'phase5_schema applied' AS result;
