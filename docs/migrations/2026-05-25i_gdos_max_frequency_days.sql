-- 2026-05-25i_gdos_max_frequency_days.sql
--
-- Adds the missing piece for Fred's GDO-is-location-bound domain rule
-- (see CLAUDE.md "GDO permits — location-bound" section).
--
-- BACKGROUND
-- The public.gdos table already exists (135 rows, audited, FK'd to both
-- clients and properties). It carries gdo_number, permit_expiration, and
-- permit_document_path. What's MISSING is the city-mandated maximum
-- service frequency — the upper bound the customer cannot exceed (e.g.
-- "Grease Trap must be pumped at least every 90 days"). The customer
-- can negotiate any frequency they want at-or-below this max; what we
-- need to capture is the cap itself.
--
-- WHY NOT ON properties (my first instinct)
-- The gdos table already models exactly what Fred described — one row
-- per permit, FK'd to a property, FK'd to the current client. Adding
-- columns to properties would duplicate that.
--
-- WHY NOT MULTIPLE COLUMNS / TABLE
-- max_frequency_days is a single integer. It belongs on gdos (the
-- permit). One column. Nothing fancy.
--
-- CHECK CONSTRAINT
-- > 0 because zero frequency is meaningless; NULL is allowed because
-- we don't have this value for any of the 135 existing rows yet
-- (backfill comes in Phase 2 via the GDO Bot + Viktor).
--
-- IDEMPOTENT (Rule 5): IF NOT EXISTS, re-runnable.
-- AUDIT (Rule 8): gdos already in the audited set; adding a column is
-- automatically captured in the full-row JSONB diff. No trigger change.

BEGIN;

ALTER TABLE public.gdos
  ADD COLUMN IF NOT EXISTS max_frequency_days INT;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'gdos_max_frequency_days_positive'
  ) THEN
    ALTER TABLE public.gdos
      ADD CONSTRAINT gdos_max_frequency_days_positive
      CHECK (max_frequency_days IS NULL OR max_frequency_days > 0);
  END IF;
END $$;

COMMENT ON COLUMN public.gdos.max_frequency_days IS
  'City-mandated maximum days between Grease Trap cleanings for this GDO. The negotiated service_configs.frequency_days for the same client must be <= this value or it is a compliance risk. Sourced from AT Clients."GT Frequency" via Phase 2 backfill (GDO Bot + Viktor cross-check). NULL = max not yet captured.';

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- 1. Column exists with right shape:
--    SELECT column_name, data_type, is_nullable FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='gdos' AND column_name='max_frequency_days';
--    Expected: integer / YES
--
-- 2. CHECK constraint blocks negative values:
--    UPDATE public.gdos SET max_frequency_days = -5 WHERE id = (SELECT id FROM gdos LIMIT 1);
--    Expected: ERROR — check constraint violated
--
-- 3. NULL is fine:
--    SELECT COUNT(*) FROM gdos WHERE max_frequency_days IS NULL;
--    Expected: 135 (all rows pre-backfill).

-- ============================================================
-- KNOWN DATA ODDITIES (NOT addressed in this migration — surface for ops)
-- ============================================================
-- During the Phase 1 pre-check we found:
--   - 3 pairs of duplicate gdo_number: GDO-05180, GDO-08912, GDO-11433
--     (one of each pair is real, one was a duplicate entry)
--   - property_id=42 has 3 ACTIVE GDOs (gdos.id 63, 64, 65 with different numbers)
--   - client_id=369 has 3 ACTIVE GDOs
--   - 16 rows with NULL permit_expiration
-- These prevent adding UNIQUE(gdo_number) and UNIQUE(property_id) WHERE
-- status='ACTIVE'. They're real ops decisions (which to keep, which to
-- mark INACTIVE) and belong in a separate dedupe migration after Yannick
-- + Viktor reconcile against the source-of-truth AT records.
