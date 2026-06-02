-- 2026-05-26_calendar_visit_anon_insert_rls.sql
--
-- Allow the Visit Calendar Lovable app (anon JWT) to INSERT new visits
-- directly into public.visits with source='visit-calendar'. Companion to
-- the 2026-05-26_calendar_visit_anon_write_rls.sql which added UPDATE.
--
-- Architecture decision (Fred 2026-05-26): visits land in canonical first,
-- Jobber back-sync is a separate forward-task. Mirrors the existing
-- cron_generate_recurring_visits.js pattern (source='supabase_cron'),
-- which already writes visits to canonical that may not yet exist in
-- Jobber. Calendar-created visits are tagged source='visit-calendar' so
-- they're auditable + back-sync-able later.
--
-- 3NF check (Rule 2): no schema change; only INSERT policy + column grants.
--
-- Audit (Rule 8): public.visits already has audit_visits trigger
-- (opted in 2026-05-17). Every INSERT lands in audit.logs with
-- app_source='visit-calendar' (header attribution from supabase-prod-write client).
--
-- Source-of-truth (Rule 4): we are knowingly creating canonical visits
-- without a Jobber GID. They get entity_source_links retroactively when
-- Jobber back-sync runs (deferred). source='visit-calendar' is the
-- escape-hatch tag so future audits know which rows skipped Jobber.
--
-- Idempotent (Rule 5): DROP POLICY IF EXISTS + CREATE POLICY.
-- No source-prefixed columns (Rule 1).

BEGIN;

-- ============================================================
-- 1. anon INSERT policy on public.visits
-- ============================================================
-- WITH CHECK enforces that any Calendar-created visit MUST have
-- source='visit-calendar'. Stops anon from impersonating Jobber sync.

DROP POLICY IF EXISTS visits_anon_calendar_insert ON public.visits;
CREATE POLICY visits_anon_calendar_insert
  ON public.visits
  FOR INSERT
  TO anon
  WITH CHECK (source = 'visit-calendar');

-- ============================================================
-- 2. Column-grained INSERT grant
-- ============================================================
-- Only columns the Calendar drawer + day-cell quick-add can set.
-- Reject attempts to set system-managed columns (created_at, updated_at,
-- public_id, id) and audit-sensitive ones (completed_by).

GRANT INSERT (
  client_id, property_id, vehicle_id, job_id,
  visit_date, start_at, end_at, completed_at,
  duration_minutes, title, service_type, visit_status,
  derm_required, source
) ON public.visits TO anon;

-- ============================================================
-- 3. Reload PostgREST schema cache so the new policy + grants are picked up
-- ============================================================
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- VERIFY (run after applying)
-- ============================================================
-- 1. Policies on visits — expect 7 total now (added visits_anon_calendar_insert):
--    SELECT policyname, cmd, roles FROM pg_policies
--    WHERE schemaname='public' AND tablename='visits' ORDER BY policyname;
--
-- 2. INSERT column grants:
--    SELECT column_name, privilege_type
--    FROM information_schema.column_privileges
--    WHERE table_schema='public' AND table_name='visits' AND grantee='anon'
--      AND privilege_type='INSERT'
--    ORDER BY column_name;
--    (expect 14 rows matching the GRANT above)
--
-- 3. Smoke test (anon should be able to create with source='visit-calendar',
--    rejected without it):
--
--    curl -X POST \
--      'https://wbasvhvvismukaqdnouk.supabase.co/rest/v1/visits' \
--      -H 'apikey: <anon>' -H 'Authorization: Bearer <anon>' \
--      -H 'Content-Type: application/json' \
--      -H 'Prefer: return=representation' \
--      -H 'X-App-Source: visit-calendar' \
--      -d '{"client_id":<test_client>, "visit_date":"2026-12-31",
--           "service_type":"GT", "visit_status":"scheduled",
--           "source":"visit-calendar"}'
--    → 201 with the new row, audit.logs gets app_source='visit-calendar'
--
--    Try the same WITHOUT source='visit-calendar' or with a different value
--    → 401/42501 (WITH CHECK policy rejects).
