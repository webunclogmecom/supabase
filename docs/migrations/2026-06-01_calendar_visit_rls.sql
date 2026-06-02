-- ============================================================================
-- 2026-06-01_calendar_visit_rls.sql
-- Let the Calendar app (anon/authenticated) INSERT + UPDATE ONLY its own visits
-- (source='visit-calendar'). The RLS policies existed but were inert: no table-level
-- INSERT/UPDATE grant, and the UPDATE policy was unscoped (USING true). Tighten +
-- grant. Also expose the new visits.service_line_item_id on the ops.visits view.
--
-- Safety: INSERT/UPDATE are both gated to source='visit-calendar' (WITH CHECK), so
-- the public anon role can only create/edit calendar visits — not touch jobber/cron
-- rows. Service-role + crons are unaffected (separate ALL policy + table owner).
-- ============================================================================

-- INSERT: only calendar-sourced visits
DROP POLICY IF EXISTS visits_anon_calendar_insert ON public.visits;
DROP POLICY IF EXISTS visits_calendar_insert ON public.visits;
CREATE POLICY visits_calendar_insert ON public.visits
  FOR INSERT TO anon, authenticated
  WITH CHECK (source = 'visit-calendar');

-- UPDATE: only calendar-sourced visits (was USING true — too broad)
DROP POLICY IF EXISTS visits_anon_calendar_update ON public.visits;
DROP POLICY IF EXISTS visits_calendar_update ON public.visits;
CREATE POLICY visits_calendar_update ON public.visits
  FOR UPDATE TO anon, authenticated
  USING (source = 'visit-calendar')
  WITH CHECK (source = 'visit-calendar');

GRANT INSERT, UPDATE ON public.visits TO anon, authenticated;

-- ops.visits: expose service_line_item_id (column was added to public.visits later)
CREATE OR REPLACE VIEW ops.visits AS
  SELECT id, client_id, property_id, job_id, vehicle_id, visit_date, start_at, end_at,
    completed_at, duration_minutes, title, service_type, visit_status, actual_arrival_at,
    actual_departure_at, is_gps_confirmed, created_at, updated_at, invoice_id, completed_by,
    source, manhole_count, manhole_breakdown, ticket_number, trap_condition_notes,
    derm_required, service_line_item_id
  FROM public.visits;
