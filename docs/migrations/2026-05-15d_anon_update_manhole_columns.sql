-- 2026-05-15d_anon_update_manhole_columns.sql
--
-- Enable the Manhole dual-write Prod mirror path (Lovable Admin Review App
-- 2026-05-15 plan): anon needs UPDATE permission on TWO specific columns:
--   - visits.manhole_count
--   - properties.grease_trap_manhole_count
--
-- All other columns on these tables remain SELECT-only for anon (column-level
-- grant scopes the permission). The companion RLS policy permits anon UPDATE
-- against ANY row (no row-level scoping — Yannick can edit any visit/property).
--
-- Matches the ship-first-harden-later acceptance for non-PII fields. Damage
-- profile: a malicious anon could mis-set manhole counts. Recoverable by
-- re-classify/re-edit. Same risk class as photo_classifications anon writes.

BEGIN;

-- 1. Column-level UPDATE grants
--    anon stays SELECT-only on EVERY OTHER column on these tables.
GRANT UPDATE (manhole_count) ON public.visits TO anon;
GRANT UPDATE (grease_trap_manhole_count) ON public.properties TO anon;

-- 2. RLS UPDATE policies (RLS is row-level, not column-level — so these are
--    permissive on rows, but the GRANT above is what gates which columns).
DROP POLICY IF EXISTS visits_anon_update_manhole ON public.visits;
CREATE POLICY visits_anon_update_manhole
  ON public.visits FOR UPDATE TO anon
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS properties_anon_update_manhole ON public.properties;
CREATE POLICY properties_anon_update_manhole
  ON public.properties FOR UPDATE TO anon
  USING (true) WITH CHECK (true);

COMMIT;

-- Verification queries (run after commit):
--
-- 1) Confirm anon has UPDATE only on the specific columns (and SELECT on all):
--    SELECT column_name, privilege_type
--    FROM information_schema.column_privileges
--    WHERE grantee='anon' AND table_schema='public' AND table_name='visits'
--      AND privilege_type='UPDATE';
--    → expected: 1 row, column_name='manhole_count'
--
-- 2) Smoke test (will succeed):
--    UPDATE visits SET manhole_count = 5 WHERE id = 1619;  -- as anon role
--
-- 3) Smoke test (will fail — proves other cols still locked):
--    UPDATE visits SET visit_status = 'cancelled' WHERE id = 1619;  -- as anon
--    → expected: permission denied for column visit_status
