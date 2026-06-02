-- 2026-05-26_hr_sandbox_setup.sql
--
-- Repurpose the (now-decommissioned) Field Portal Sandbox
-- (klgtrdwrasrlxbmfyvdh) into the HR Sandbox for Yannick's new HR Lovable
-- app (Employee Management).
--
-- PRE-FLIGHT (Fred, before running this):
--   1. Confirm Field Portal has been switched off this sandbox and is now
--      reading from Prod (per docs/lovable-field-portal-prod-switch.md).
--      No active Lovable project should be pointing at klgtrdwrasrlxbmfyvdh.
--   2. Snapshot the sandbox (Supabase dashboard → Database → Backups) so
--      we can recover the Field Portal state if anything goes wrong.
--   3. Update GitHub Actions env vars: rename FIELD_PORTAL_* to HR_*
--      (or keep both pointing at the same project ref during transition).
--
-- WHAT THIS DOES
--   A. Drops Field Portal-specific objects (customer schema + app_* tables
--      that belong to Field Portal, NOT to canonical Prod).
--   B. Keeps all 40 canonical public.* tables (Prod mirror — HR needs many
--      for context: employees + vehicles + entity_source_links primarily,
--      but the rest don't cost anything to leave).
--   C. Creates hr schema + hr.app_admin_users + hr.employees/vehicles
--      pass-through views.
--   D. Locks down free-text columns on employees with CHECK constraints
--      (HR is the canonical editor — right time to constrain).
--   E. Anon role timeout bump (Supabase default 3s breaks Lovable on any
--      moderately heavy query — push to 15s per our standing rule).
--   F. Admin-only RLS on public.employees / public.vehicles writes.
--
-- IDEMPOTENT (Rule 5): every CREATE uses IF NOT EXISTS / OR REPLACE.
-- DROP uses IF EXISTS. Re-run is a no-op.
-- AUDIT (Rule 8): hr.app_admin_users INSERTs will trigger audit; canonical
-- table writes are already audit-wired in this sandbox (inherited from clone).
-- NEVER HARD-DELETE (Rule 6): only schema objects dropped, no business
-- data rows deleted.

BEGIN;

-- ============================================================
-- A. Drop Field Portal artifacts
-- ============================================================
DROP SCHEMA IF EXISTS customer CASCADE;
DROP TABLE IF EXISTS public.app_shift_reviews CASCADE;
DROP TABLE IF EXISTS public.app_visit_reviews CASCADE;
DROP TABLE IF EXISTS public.visit_recommendations CASCADE;
-- (Field Portal also added a few views — they'll be re-created if/when
--  needed for HR; not dropping by name to avoid accidentally removing a
--  view that belongs to canonical.)

-- ============================================================
-- B. Anon role timeout bump (Lovable batch queries hit 3s default)
-- ============================================================
ALTER ROLE anon SET statement_timeout = '15s';

-- ============================================================
-- C. HR schema + app-only tables
-- ============================================================
CREATE SCHEMA IF NOT EXISTS hr;

CREATE TABLE IF NOT EXISTS hr.app_admin_users (
  user_id     UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  granted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  granted_by  UUID REFERENCES auth.users(id),
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================
-- D. Vocabulary lock-down DEFERRED
-- ============================================================
-- Originally planned to add CHECK constraints on employees.role + .status,
-- but the actual Prod data has roles ('Admin','Office','Owner','Technician')
-- and CLAUDE.md/Knowledge documents a different vocab ('driver','helper',
-- 'plumber','office','admin'). This is documentation drift vs Jobber-synced
-- reality. HR app's Q5 (in the bootstrap) is where this gets standardized —
-- not in this migration. Once HR settles the vocab, a follow-up migration
-- locks the CHECK.

-- ============================================================
-- E. HR-schema pass-through views (what the Lovable client queries)
-- ============================================================
CREATE OR REPLACE VIEW hr.employees AS
  SELECT id, full_name, role, status, shift, email, phone,
         hire_date, access_level, notes, created_at, updated_at
  FROM public.employees;

CREATE OR REPLACE VIEW hr.vehicles AS
  SELECT id, name, make, model, year, vin, license_plate,
         decal_number, fuel_tank_capacity_gallons,
         grease_tank_capacity_gallons, status, notes,
         created_at, updated_at
  FROM public.vehicles;

CREATE OR REPLACE VIEW hr.entity_source_links AS
  SELECT id, entity_type, entity_id, source_system, source_id,
         source_name, synced_at
  FROM public.entity_source_links
  WHERE entity_type IN ('employee', 'vehicle');

-- ============================================================
-- F. RLS — admin-only writes on canonical, read for authenticated
-- ============================================================
ALTER TABLE public.employees    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vehicles     ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr.app_admin_users  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS employees_admin_all ON public.employees;
CREATE POLICY employees_admin_all ON public.employees
  FOR ALL TO authenticated
  USING ( EXISTS (SELECT 1 FROM hr.app_admin_users WHERE user_id = (SELECT auth.uid())) )
  WITH CHECK ( EXISTS (SELECT 1 FROM hr.app_admin_users WHERE user_id = (SELECT auth.uid())) );

DROP POLICY IF EXISTS employees_authenticated_read ON public.employees;
CREATE POLICY employees_authenticated_read ON public.employees
  FOR SELECT TO authenticated
  USING ( true );

DROP POLICY IF EXISTS vehicles_admin_all ON public.vehicles;
CREATE POLICY vehicles_admin_all ON public.vehicles
  FOR ALL TO authenticated
  USING ( EXISTS (SELECT 1 FROM hr.app_admin_users WHERE user_id = (SELECT auth.uid())) )
  WITH CHECK ( EXISTS (SELECT 1 FROM hr.app_admin_users WHERE user_id = (SELECT auth.uid())) );

DROP POLICY IF EXISTS vehicles_authenticated_read ON public.vehicles;
CREATE POLICY vehicles_authenticated_read ON public.vehicles
  FOR SELECT TO authenticated
  USING ( true );

DROP POLICY IF EXISTS admin_users_self_read ON hr.app_admin_users;
CREATE POLICY admin_users_self_read ON hr.app_admin_users
  FOR SELECT TO authenticated
  USING ( user_id = (SELECT auth.uid()) );

-- ============================================================
-- G. Grants for HR schema + view access
-- ============================================================
GRANT USAGE  ON SCHEMA hr TO authenticated, anon;
GRANT SELECT ON hr.employees, hr.vehicles, hr.entity_source_links TO authenticated;
GRANT ALL    ON hr.app_admin_users TO authenticated;

-- ============================================================
-- H. Add 'hr' to PostgREST exposed schemas
-- ============================================================
-- Done via Supabase Dashboard: Database → API → Exposed schemas → add 'hr'
-- (cannot do via SQL on hosted Supabase). Reminder logged here.

COMMIT;

-- ============================================================
-- POST-MIGRATION (manual, on Supabase Dashboard)
-- ============================================================
-- 1. Database → API Settings → Exposed schemas → add 'hr' (comma-separated)
-- 2. Seed first admin user(s) into hr.app_admin_users by hand:
--      INSERT INTO hr.app_admin_users (user_id, notes)
--      SELECT id, 'Initial admin (Fred)' FROM auth.users WHERE email = 'fredzerpa@gmail.com';
--      (or whichever admin email Yan picks)
-- 3. Regenerate Lovable types pointed at this project's `hr` schema
-- 4. Verify smoke test:
--      SELECT count(*) FROM hr.employees;            -- expect ~9
--      SELECT count(*) FROM hr.vehicles;              -- expect ~3
--      SHOW statement_timeout;                        -- expect 15s on anon
