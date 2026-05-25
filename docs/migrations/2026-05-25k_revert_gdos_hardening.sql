-- 2026-05-25k_revert_gdos_hardening.sql
--
-- REVERT of 2026-05-25j based on corrected domain understanding from Fred
-- 2026-05-25 PM session.
--
-- WHAT WAS WRONG IN 25j
-- Demoted 2 of Casa Neos's 3 active GDOs (id 63 GDO-10877 + id 64 GDO-15062)
-- assuming they were renewal history from AT. Per Fred today: Casa Neos has 3
-- LEGITIMATE distinct permits — one each for kitchen, lounge, and bar at the
-- same address (40 SW North River Drive). Demoting them was wrong; they're
-- real active permits.
--
-- Also added gdos_property_unique_active UNIQUE INDEX which prohibits
-- multi-GDO properties going forward. That conflicts with Fred's domain
-- rule: a property can have 1+ active GDOs (typically 1, but real
-- multi-facility scenarios exist).
--
-- Also corrected understanding from web research: per Miami-Dade DERM, GDO
-- numbers do NOT change on renewal. So when a permit is renewed, the same
-- gdo_number stays for that specific facility — multiple different gdo_numbers
-- at one property must mean distinct facilities, not renewal history.
--
-- WHAT THIS DOES
--   1. Re-activate gdos id 63 + 64 (Casa Neos)
--   2. Drop the UNIQUE INDEX
--
-- WHAT THIS KEEPS (still correct from 25j)
--   - property_id NOT NULL (every GDO ties to a physical location — true)
--   - max_frequency_days column from 25i (city-mandated ceiling)
--
-- IDEMPOTENT (Rule 5): UPDATE is filtered to status='INACTIVE'; re-run is
-- a no-op. DROP INDEX IF EXISTS.
--
-- AUDIT (Rule 8): 2 UPDATE audit rows generated for the re-activation
-- (app_source='sql'). DROP INDEX doesn't audit.

BEGIN;

-- ============================================================
-- 1. Drop UNIQUE constraint FIRST (must come before re-activation;
--    otherwise the UPDATE below violates the constraint during the txn).
-- ============================================================
DROP INDEX IF EXISTS public.gdos_property_unique_active;

-- ============================================================
-- 2. Re-activate Casa Neos GDOs that 25j wrongly demoted
-- ============================================================
UPDATE public.gdos
SET status = 'ACTIVE',
    notes  = COALESCE(notes || E'\n', '') ||
             '[2026-05-25 PM] Re-activated. The 25j demotion was based on ' ||
             'wrong assumption (treated as renewal history). Per Fred''s ' ||
             'domain rule: Casa Neos has 3 distinct GDOs for 3 distinct ' ||
             'facilities (kitchen/lounge/bar) at the same address. All 3 ' ||
             'must stay ACTIVE. Phase 2 will populate gdos.location_label ' ||
             'to disambiguate them.'
WHERE id IN (63, 64)
  AND status = 'INACTIVE';

COMMIT;

-- ============================================================
-- POST-MIGRATION VERIFICATION
-- ============================================================
-- 1. Casa Neos: 3 active rows again
--    SELECT id, gdo_number, status FROM gdos WHERE property_id = 42 ORDER BY id;
--    Expected: id 63 ACTIVE, id 64 ACTIVE, id 65 ACTIVE
--
-- 2. UNIQUE index gone
--    SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename='gdos';
--    Expected: gdos_property_unique_active NOT in the list
--
-- 3. ACTIVE count back to 135
--    SELECT COUNT(*) FILTER (WHERE status='ACTIVE')::int FROM gdos;
--    Expected: 135
--
-- 4. Can insert a 4th ACTIVE GDO for property 42 without error
--    (constraint dropped so this would succeed — don't actually run unless
--     testing rollback, just check no constraint blocks it):
--    EXPLAIN INSERT INTO gdos (client_id, gdo_number, property_id, status)
--    VALUES (369, 'GDO-TEST123', 42, 'ACTIVE');
--    Expected: plan only, no error.

-- ============================================================
-- DOMAIN RULE GOING FORWARD (write into docs/operations.md GDO section)
-- ============================================================
-- A property can have 1+ active GDOs. Most have 1. Multi-GDO properties
-- (e.g., Casa Neos kitchen/lounge/bar at one address) use gdos.location_label
-- to distinguish them. There's NO database-level prevention of multi-GDO
-- properties — by design. Operationally, ops verifies single-GDO-per-property
-- via the Phase 2 Viktor + GDO Bot reconciliation, not via a unique
-- constraint.
