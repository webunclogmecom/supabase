-- 2026-06-25b_ops_ripple_reschedule_visit.sql
-- ops wrapper for the ripple-reschedule RPC so the Calendar App can call it via its
-- ops-schema PostgREST client (schema-per-app pattern, same as ops.create_calendar_visit).
-- Delegates to the SECURITY DEFINER public.ripple_reschedule_visit (2026-06-25_ripple_reschedule_visit_rpc.sql)
-- which does the move + re-anchor + push. Audit (ADR 010): wrapper only — public.visits keeps its audit.
-- Idempotent: CREATE OR REPLACE.

CREATE OR REPLACE FUNCTION ops.ripple_reschedule_visit(
  p_visit_id     bigint,
  p_new_date     date,
  p_new_start_at timestamptz DEFAULT NULL,
  p_new_end_at   timestamptz DEFAULT NULL,
  p_dry_run      boolean     DEFAULT false
) RETURNS TABLE(visit_id bigint, old_date date, new_date date)
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM public.ripple_reschedule_visit(p_visit_id, p_new_date, p_new_start_at, p_new_end_at, p_dry_run);
$$;

GRANT EXECUTE ON FUNCTION ops.ripple_reschedule_visit(bigint, date, timestamptz, timestamptz, boolean)
  TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
