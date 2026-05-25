-- 2026-05-25j_gdos_hardening.sql
--
-- Phase 1 extension (per Fred 2026-05-25): adds the structural integrity
-- pieces that match the GDO-is-location-bound domain rule. Splits cleanly
-- between "safe constraints I can add today" and "constraints that need
-- Phase 2 Viktor reconciliation first".
--
-- IN THIS MIGRATION
-- 1. Demote 2 stale Casa Neos GDOs (property 42 had 3 active rows; all 3
--    have 0 manifests referencing them and identical expiration dates —
--    clean renewal history. Keep highest gdo_number GDO-16389 (id 65),
--    demote GDO-10877 (id 63) and GDO-15062 (id 64) to INACTIVE.
-- 2. ALTER COLUMN property_id SET NOT NULL — already 0 NULL rows; this is
--    a pure metadata change validating future inserts.
-- 3. CREATE UNIQUE INDEX on (property_id) WHERE status='ACTIVE' — enforces
--    Fred's "one active permit per location" rule going forward.
--
-- NOT IN THIS MIGRATION (deferred to a later migration after Phase 2)
-- - UNIQUE (gdo_number). Three pairs of duplicate gdo_numbers exist
--   between unrelated clients/properties:
--     GDO-05180: Aryeh Hochner (id 66) vs Bet Shira (id 85)  — different addresses
--     GDO-08912: 144-LTG (id 29) vs 139-LTG (id 102)         — same building
--     GDO-11433: 170-PV Pura Vida (id 7) vs 176-SOU What Soup (id 104) — same building
--   At least one row in each pair has the wrong number (probably an AT typo
--   on the GDO Number field). Viktor + the GDO Bot need to cross-check
--   against the city's DERM registry before we can decide which row of
--   each pair is authoritative. Once resolved, a follow-up migration
--   will add UNIQUE (gdo_number).
--
-- AUDIT (Rule 8): 2 UPDATE audit rows generated for the Casa Neos demotion
-- (app_source='sql', hint=NULL — Management API call). ALTER COLUMN and
-- CREATE INDEX don't generate audit rows.
--
-- IDEMPOTENT (Rule 5): UPDATE filters on status='ACTIVE' so re-runs are
-- no-ops. ALTER COLUMN IF NOT EXISTS pattern via DO block. CREATE UNIQUE
-- INDEX IF NOT EXISTS.

BEGIN;

-- ============================================================
-- 1. Dedupe Casa Neos (property 42) — renewal history cleanup
-- ============================================================
UPDATE public.gdos
SET status = 'INACTIVE',
    notes  = COALESCE(notes || E'\n', '') ||
             '[2026-05-25] Marked INACTIVE as part of Phase 1 hardening: ' ||
             'property 42 had 3 active GDOs (renewal history); kept the ' ||
             'highest gdo_number (GDO-16389 / id 65) as current, demoted ' ||
             'this and one other. Re-activate if this is actually the ' ||
             'current permit and the keep decision was wrong.'
WHERE id IN (63, 64)
  AND property_id = 42
  AND client_id = 369
  AND status = 'ACTIVE';

-- ============================================================
-- 2. property_id SET NOT NULL (already 0 NULL rows — safe)
-- ============================================================
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='gdos' AND column_name='property_id'
      AND is_nullable = 'YES'
  ) THEN
    ALTER TABLE public.gdos ALTER COLUMN property_id SET NOT NULL;
  END IF;
END $$;

-- ============================================================
-- 3. UNIQUE per ACTIVE permit on a property
-- ============================================================
CREATE UNIQUE INDEX IF NOT EXISTS gdos_property_unique_active
  ON public.gdos (property_id)
  WHERE status = 'ACTIVE';

COMMENT ON INDEX public.gdos_property_unique_active IS
  'Each property may have at most one ACTIVE GDO at a time. Added 2026-05-25 after Casa Neos renewal cleanup. Prevents future webhook-airtable or manual inserts from accidentally creating multiple active permits per location.';

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- 1. Casa Neos: 1 active, 2 inactive
--    SELECT id, gdo_number, status FROM gdos WHERE property_id = 42 ORDER BY id;
--    Expected: id 63 INACTIVE, id 64 INACTIVE, id 65 ACTIVE
--
-- 2. property_id NOT NULL
--    SELECT is_nullable FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='gdos' AND column_name='property_id';
--    Expected: NO
--
-- 3. UNIQUE index in place
--    SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename='gdos';
--    Expected: gdos_property_unique_active among the results.
--
-- 4. ACTIVE count dropped from 135 → 133
--    SELECT COUNT(*) FILTER (WHERE status='ACTIVE')::int FROM gdos;
--    Expected: 133
--
-- 5. Constraint actively rejects a 2nd ACTIVE GDO for the same property:
--    INSERT INTO gdos (client_id, gdo_number, property_id)
--    VALUES (369, 'GDO-TEST123', 42);
--    Expected: ERROR — duplicate key value violates unique constraint
--    gdos_property_unique_active.

-- ============================================================
-- DEFERRED (Phase 2 + later migration)
-- ============================================================
-- UNIQUE (gdo_number) — needs Viktor/GDO Bot reconciliation of the 3
-- typo'd duplicate pairs before it can be added safely. Surfaced in
-- the migration header above.
