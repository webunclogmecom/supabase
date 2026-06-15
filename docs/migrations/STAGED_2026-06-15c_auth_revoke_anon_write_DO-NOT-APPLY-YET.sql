-- ============================================================================
-- A2 (STAGED — ⛔ DO NOT APPLY YET) — revoke anon WRITE on high-value tables
-- ============================================================================
-- The breaking half of Option A (auth gate, docs/specs/2026-06-15-app-auth-gate-design.md §13).
-- Removes anon's ability to INSERT/UPDATE/DELETE the payroll/DERM/visits tables, so those
-- writes require a logged-in (authenticated) session. The authenticated mirror policies +
-- grants from 2026-06-15b already let the logged-in apps keep writing.
--
-- ⛔ APPLY PER-APP, AND ONLY AFTER THAT APP'S SUPABASE LOGIN IS LIVE IN PRODUCTION.
--    The live apps currently write as ANON (no login). Applying a section before its app
--    authenticates will BREAK that app's writes. Apply each section, then verify that app
--    can still save while logged in.
--    READS stay anon until Phase 1.5 — this migration touches WRITE only.
-- Rollback: re-create the dropped anon policy (same USING/WITH CHECK) + re-GRANT to anon.
-- Audit (ADR 010): RLS policy/grant change only.
-- ============================================================================

-- ===== SECTION A — Admin Review (apply after grease-buddy-dash.lovable.app login is live) =====
DROP POLICY IF EXISTS "visit_reviews_anon_insert" ON public.visit_reviews;
DROP POLICY IF EXISTS "visit_reviews_anon_update" ON public.visit_reviews;
REVOKE INSERT, UPDATE, DELETE ON public.visit_reviews FROM anon;

DROP POLICY IF EXISTS "shift_reviews_anon_insert" ON public.shift_reviews;
DROP POLICY IF EXISTS "shift_reviews_anon_update" ON public.shift_reviews;
REVOKE INSERT, UPDATE, DELETE ON public.shift_reviews FROM anon;

DROP POLICY IF EXISTS "photo_classifications_anon_insert" ON public.photo_classifications;
DROP POLICY IF EXISTS "photo_classifications_anon_update" ON public.photo_classifications;
REVOKE INSERT, UPDATE, DELETE ON public.photo_classifications FROM anon;

-- ===== SECTION B — DERM Tracker (apply after derm.unclogme.app login is live) =====
DROP POLICY IF EXISTS "anon_insert_derm_manifests" ON public.derm_manifests;
DROP POLICY IF EXISTS "anon_update_derm_manifests" ON public.derm_manifests;
REVOKE INSERT, UPDATE ON public.derm_manifests FROM anon;

DROP POLICY IF EXISTS "anon_delete_manifest_visits" ON public.manifest_visits;
DROP POLICY IF EXISTS "anon_insert_manifest_visits" ON public.manifest_visits;
REVOKE INSERT, DELETE ON public.manifest_visits FROM anon;

DROP POLICY IF EXISTS "anon_insert_dmnp" ON public.derm_manifest_number_proposals;
DROP POLICY IF EXISTS "anon_update_dmnp" ON public.derm_manifest_number_proposals;
REVOKE INSERT, UPDATE ON public.derm_manifest_number_proposals FROM anon;

-- ===== SECTION C — Visit Calendar — ✅ APPLIED 2026-06-15 (migration 2026-06-15d) =====
-- Calendar published with the login gate; verified anon write blocked / authenticated allowed.
DROP POLICY IF EXISTS "visit_assignments_anon_delete" ON public.visit_assignments;
DROP POLICY IF EXISTS "visit_assignments_anon_insert" ON public.visit_assignments;
REVOKE INSERT, DELETE ON public.visit_assignments FROM anon;

-- ===== SECTION D — visits (SHARED: Calendar inserts/updates, DERM updates manhole/derm_required) =====
--   ⛔ Apply ONLY after BOTH Calendar AND DERM Tracker logins are live.
--   visits has mixed {anon,authenticated} policies → recreate them authenticated-only; drop anon-only ones.
DROP POLICY IF EXISTS "visits_anon_update_manhole" ON public.visits;            -- authenticated mirror already exists
DROP POLICY IF EXISTS "visits_anon_update_manhole_authn" ON public.visits;      -- recreate cleanly below (single authenticated policy)
CREATE POLICY "visits_authenticated_update_manhole" ON public.visits AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "visits_calendar_insert" ON public.visits;
CREATE POLICY "visits_calendar_insert" ON public.visits AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (source = 'visit-calendar'::text);

DROP POLICY IF EXISTS "visits_calendar_update" ON public.visits;
CREATE POLICY "visits_calendar_update" ON public.visits AS PERMISSIVE FOR UPDATE TO authenticated USING (source = 'visit-calendar'::text) WITH CHECK (source = 'visit-calendar'::text);

DROP POLICY IF EXISTS "anon_update_visit_derm_required" ON public.visits;
CREATE POLICY "authenticated_update_visit_derm_required" ON public.visits AS PERMISSIVE FOR UPDATE TO authenticated USING (visit_status = 'completed'::text) WITH CHECK (visit_status = 'completed'::text);

REVOKE INSERT, UPDATE ON public.visits FROM anon;

-- After all sections applied: anon can READ the apps' data (Phase 1.5 closes that) but can no longer
-- WRITE payroll/DERM/visits. Verify each app still saves while logged in.
