-- 2026-05-26_rollback_hr_sandbox_additions.sql
--
-- Roll back my over-additions to the HR sandbox (klgtrdwrasrlxbmfyvdh).
-- Fred's explicit intent: the sandbox is a PROD MIRROR for Yannick's AI to
-- design the HR schema on top of. I prematurely added the hr schema, views,
-- app_admin_users table, and custom RLS — all of which Yannick's AI should
-- decide for itself. Pulling those back so the sandbox is a clean Prod
-- mirror with nothing UnclogMe doesn't already have in canonical.
--
-- WHAT THIS REMOVES (everything I added in 2026-05-26_hr_sandbox_setup.sql)
--   - DROP SCHEMA hr CASCADE (hr.employees, hr.vehicles, hr.entity_source_links views;
--                              hr.app_admin_users table)
--   - DROP my added RLS policies on public.employees + public.vehicles
--     (employees_admin_all, employees_authenticated_read,
--      vehicles_admin_all, vehicles_authenticated_read)
--     The pre-existing RLS policies that came from the FP clone stay
--     ("Allow service_role full access on ..." + "Authenticated users can read ...")
--
-- WHAT THIS KEEPS
--   - The anon statement_timeout = 15s (universally useful, harmless to keep)
--   - The refreshed employees + vehicles data (the mirror is FRESHER, that's a good thing)
--   - All 40 canonical public.* tables in their cloned-from-Prod state
--
-- IDEMPOTENT (Rule 5): DROP IF EXISTS everywhere. Re-run is a no-op.

BEGIN;

-- 1. Drop the hr schema + everything in it
DROP SCHEMA IF EXISTS hr CASCADE;

-- 2. Drop my added policies (pre-existing FP-clone policies stay)
DROP POLICY IF EXISTS employees_admin_all          ON public.employees;
DROP POLICY IF EXISTS employees_authenticated_read ON public.employees;
DROP POLICY IF EXISTS vehicles_admin_all           ON public.vehicles;
DROP POLICY IF EXISTS vehicles_authenticated_read  ON public.vehicles;

COMMIT;

-- VERIFY
--   SELECT schema_name FROM information_schema.schemata WHERE schema_name='hr';
--   (expected: no rows)
--
--   SELECT policyname FROM pg_policies
--   WHERE schemaname='public' AND tablename IN ('employees','vehicles')
--   ORDER BY tablename, policyname;
--   (expected: only the pre-existing FP-clone policies remain)
