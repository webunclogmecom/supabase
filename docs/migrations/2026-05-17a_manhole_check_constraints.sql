-- 2026-05-17a_manhole_check_constraints.sql
--
-- Adds CHECK constraints on manhole count columns to prevent negative
-- values and unreasonable upper bounds. Applied to both Prod and Sandbox.
--
-- Range: 0–50. Zero is valid (some properties don't have manholes).
-- 50 is a generous ceiling — the largest commercial GT installations
-- rarely exceed 20 manholes.
--
-- Companion to migration 15d (anon UPDATE grants on these columns).
-- Without CHECK constraints, the anon-permissive writes allowed any
-- integer including negatives and extreme values.

-- Already applied via Management API 2026-05-17. Recording for docs.

ALTER TABLE public.visits
  ADD CONSTRAINT chk_manhole_count_range
  CHECK (manhole_count >= 0 AND manhole_count <= 50);

ALTER TABLE public.properties
  ADD CONSTRAINT chk_grease_trap_manhole_count_range
  CHECK (grease_trap_manhole_count >= 0 AND grease_trap_manhole_count <= 50);

-- Verification (both should fail):
--   UPDATE visits SET manhole_count = -1 WHERE id = 5085;
--   → violates check constraint "chk_manhole_count_range"
--
--   UPDATE visits SET manhole_count = 51 WHERE id = 5085;
--   → violates check constraint "chk_manhole_count_range"
--
-- Both should succeed:
--   UPDATE visits SET manhole_count = 0 WHERE id = 5085;   -- ✓
--   UPDATE visits SET manhole_count = 50 WHERE id = 5085;  -- ✓
