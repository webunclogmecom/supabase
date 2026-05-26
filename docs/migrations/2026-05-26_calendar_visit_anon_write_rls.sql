-- 2026-05-26_calendar_visit_anon_write_rls.sql
--
-- Allow the Visit Calendar Lovable app (anon JWT) to UPDATE the columns
-- it needs for drawer Save + drag-and-drop reschedule, plus manage
-- visit_assignments rows when the Driver dropdown changes.
--
-- Per ship-first pattern (feedback_ship_first_harden_later.md):
--   visits + visit_assignments are non-PII Prod tables wired to a Lovable
--   app. Defer revoke-anon work to one batched pass after all four
--   customer-facing apps ship. For now, allow anon writes scoped to the
--   exact columns the app touches.
--
-- 3NF check (Rule 2): no schema changes; only RLS policy + grants.
--
-- Audit (Rule 8): public.visits has the audit trigger already
-- (audit_visits, opted in 2026-05-17 per CLAUDE.md). Every UPDATE the
-- Calendar makes will land in audit.logs with app_source='visit-calendar'
-- (header attribution from supabase-prod.ts).
--
-- Source-of-truth (Rule 4): the Calendar is the *editor* for visit_date,
-- vehicle_id, visit_status, completed_at. Jobber syncs continue to upsert
-- these fields too — last-write-wins on the human-driven columns is
-- intentional (Yannick re-schedules in Calendar, Jobber catches up; or
-- vice versa via webhook).
--
-- Idempotent (Rule 5): DROP POLICY IF EXISTS then CREATE POLICY.
--
-- Source-of-prefixed columns (Rule 1): none introduced.

BEGIN;

-- ============================================================
-- 1. anon UPDATE on public.visits (selected columns)
-- ============================================================
-- RLS USING/WITH CHECK uses (true) — anon-permissive at row scope.
-- Column-level write restriction happens via REVOKE/GRANT below.

DROP POLICY IF EXISTS visits_anon_calendar_update ON public.visits;
CREATE POLICY visits_anon_calendar_update
  ON public.visits
  FOR UPDATE
  TO anon
  USING (true)
  WITH CHECK (true);

-- Restrict UPDATE to ONLY the columns the Calendar drawer touches.
-- (REVOKE first so partial older grants don't leak. Then GRANT specific
--  column UPDATEs. SELECT/INSERT/DELETE stay at default — SELECT is
--  already granted by the ops-permissive pattern via the view; INSERT/
--  DELETE intentionally not granted because new visits come from Jobber.)
REVOKE UPDATE ON public.visits FROM anon;
GRANT  UPDATE (visit_date, vehicle_id, visit_status, completed_at,
               actual_arrival_at, actual_departure_at,
               manhole_count, manhole_breakdown, trap_condition_notes,
               ticket_number, derm_required)
       ON public.visits TO anon;

-- ============================================================
-- 2. anon INSERT/DELETE on public.visit_assignments (driver changes)
-- ============================================================
-- The drawer's Driver dropdown change = DELETE old + INSERT new row
-- (the table has PK = (visit_id, employee_id), no separate id column,
--  so we can't UPDATE in place when the employee changes).

ALTER TABLE public.visit_assignments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS visit_assignments_anon_select ON public.visit_assignments;
CREATE POLICY visit_assignments_anon_select
  ON public.visit_assignments
  FOR SELECT
  TO anon
  USING (true);

DROP POLICY IF EXISTS visit_assignments_anon_insert ON public.visit_assignments;
CREATE POLICY visit_assignments_anon_insert
  ON public.visit_assignments
  FOR INSERT
  TO anon
  WITH CHECK (true);

DROP POLICY IF EXISTS visit_assignments_anon_delete ON public.visit_assignments;
CREATE POLICY visit_assignments_anon_delete
  ON public.visit_assignments
  FOR DELETE
  TO anon
  USING (true);

GRANT SELECT, INSERT, DELETE ON public.visit_assignments TO anon;

-- ============================================================
-- 3. Reload PostgREST so the new policies + column grants are honored
-- ============================================================
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- VERIFY (run after applying)
-- ============================================================
-- 1. Policies on visits:
--    SELECT policyname, cmd, roles FROM pg_policies
--    WHERE schemaname='public' AND tablename='visits'
--    ORDER BY policyname;
--    (expect: visits_anon_calendar_update for UPDATE TO anon)
--
-- 2. Column grants on visits:
--    SELECT grantee, privilege_type, column_name
--    FROM information_schema.column_privileges
--    WHERE table_schema='public' AND table_name='visits' AND grantee='anon'
--    ORDER BY column_name, privilege_type;
--    (expect: anon UPDATE on visit_date, vehicle_id, visit_status,
--     completed_at, actual_arrival_at, actual_departure_at,
--     manhole_count, manhole_breakdown, trap_condition_notes,
--     ticket_number, derm_required — and NOTHING else)
--
-- 3. Smoke test (curl as anon):
--    curl -X PATCH \
--      'https://wbasvhvvismukaqdnouk.supabase.co/rest/v1/visits?id=eq.<some_scheduled_visit_id>' \
--      -H 'apikey: <anon>' -H 'Authorization: Bearer <anon>' \
--      -H 'Content-Type: application/json' \
--      -H 'Prefer: return=representation' \
--      -H 'X-App-Source: visit-calendar' \
--      -d '{"visit_date":"2026-06-15"}'
--    (expect: HTTP 200 with the updated row; audit.logs row added with
--     app_source='visit-calendar')
