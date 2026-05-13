-- ============================================================================
-- Migration: Revoke lingering grease_trap_manhole_count UPDATE grants — 2026-05-11
-- TARGET: Sandbox only (ubtlwpcyntelgbykdatn). Do NOT apply to Production.
-- ============================================================================
-- Context:
--   Lovable migration `20260501033117` granted column-level UPDATE on
--   `properties.grease_trap_manhole_count` to anon + authenticated, to support
--   the (then-correct) Pattern A approach of `useUpdatePropertyManholes`
--   writing directly to the canonical column.
--
--   On 2026-05-11 Lovable rewired `useUpdatePropertyManholes` to write to the
--   new `app_property_overrides` table instead (Pattern B). The Pattern A
--   write path is gone from the code. Those column-level grants are now
--   redundant — and worse, they leave a working path for any future code
--   regression to silently start writing canonical-then-wiped data again.
--
--   This migration closes that door.
-- ============================================================================

BEGIN;

REVOKE UPDATE (grease_trap_manhole_count) ON public.properties FROM anon;
REVOKE UPDATE (grease_trap_manhole_count) ON public.properties FROM authenticated;

COMMIT;

-- Verification:
--   SELECT grantee, column_name, privilege_type
--   FROM information_schema.column_privileges
--   WHERE table_schema='public' AND table_name='properties'
--     AND grantee IN ('anon','authenticated')
--     AND privilege_type IN ('UPDATE','INSERT','DELETE');
--   -- Expected: 0 rows.
