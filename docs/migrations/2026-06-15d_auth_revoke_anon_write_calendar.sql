-- ============================================================================
-- 2026-06-15d — A2 Section C APPLIED: revoke anon WRITE on visit_assignments
-- ============================================================================
-- Applied after the Visit Calendar login gate went LIVE in production
-- (calendar.unclogme.app republished with Supabase Auth; login wall confirmed).
-- The app now writes as `authenticated` (authenticated mirror policy + grant from
-- 2026-06-15b cover it); anon no longer needs write here. Only visit_assignments
-- (Calendar-only). The shared `visits` table (A2 Section D) stays anon-writable
-- until DERM Tracker's login is also live (both apps write visits).
-- Reverify: logged-in app saves; anon /rest/v1 write rejected.
-- Reversible: re-create the two anon policies + re-GRANT INSERT,DELETE to anon.
-- ============================================================================

DROP POLICY IF EXISTS "visit_assignments_anon_delete" ON public.visit_assignments;
DROP POLICY IF EXISTS "visit_assignments_anon_insert" ON public.visit_assignments;
REVOKE INSERT, DELETE ON public.visit_assignments FROM anon;
