-- ============================================================================
-- 2026-07-03 — Restore ops.create_calendar_visit wrapper (REGRESSION FIX)
-- ============================================================================
-- Symptom: Calendar "New Visit" fails with
--   "Could not find the function ops.create_calendar_visit(...) in the schema cache".
-- The Calendar app's PostgREST client is scoped to the `ops` schema (schema-per-app
-- pattern), so it calls ops.create_calendar_visit — a thin wrapper that forwards to
-- public.create_calendar_visit. That wrapper was DROPPED and never recreated.
--
-- Root cause: the 2026-07-02_line_item_descriptions.sql migration cleaned up old
-- overloads with a schema-UNQUALIFIED DO-block:
--     FOR r IN SELECT oid FROM pg_proc WHERE proname='create_calendar_visit'
--              AND pronargs <> 15  -- no pronamespace filter → matches EVERY schema
-- which dropped BOTH public (14-arg) AND ops (14-arg) overloads, then only recreated
-- public. The ops wrapper was left missing. Prior migrations (2026-06-23/24/25) always
-- recreated BOTH schemas with schema-QUALIFIED drops; 2026-07-02 broke that pattern.
--
-- Fix: recreate ops.create_calendar_visit with the current 15-arg signature (adds
-- p_line_item_descriptions), forwarding to public, restore grants, reload PostgREST.
--
-- PREVENTION (see docs/jobber-calendar-job-migration/jobs-visits-calendar-workflow.md):
--   1. ANY change to public.create_calendar_visit MUST recreate the ops wrapper too.
--   2. NEVER drop functions by a name-only predicate — always schema-qualify the DROP.
--   3. Guard: scripts/probes/check_ops_app_rpcs.js asserts ops app-RPCs exist + mirror
--      public arg counts (run post-migration / in the health check).
-- ============================================================================
-- schema-qualified drop of any stale ops overload (idempotent), then recreate
DROP FUNCTION IF EXISTS ops.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint, jsonb, bigint[]);
DROP FUNCTION IF EXISTS ops.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint, jsonb, bigint[], jsonb);

CREATE FUNCTION ops.create_calendar_visit(
  p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_visit_date date,
  p_property_id bigint DEFAULT NULL::bigint, p_client_location_ids bigint[] DEFAULT NULL::bigint[],
  p_start_at timestamp with time zone DEFAULT NULL, p_end_at timestamp with time zone DEFAULT NULL,
  p_title text DEFAULT NULL, p_notes text DEFAULT NULL, p_vehicle_id bigint DEFAULT NULL,
  p_driver_id bigint DEFAULT NULL, p_line_item_prices jsonb DEFAULT NULL,
  p_team_ids bigint[] DEFAULT NULL::bigint[], p_line_item_descriptions jsonb DEFAULT NULL::jsonb
)
 RETURNS visits LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT public.create_calendar_visit(p_client_id, p_job_id, p_service_line_item_ids, p_visit_date,
    p_property_id, p_client_location_ids, p_start_at, p_end_at, p_title, p_notes, p_vehicle_id,
    p_driver_id, p_line_item_prices, p_team_ids, p_line_item_descriptions);
$function$;

GRANT EXECUTE ON FUNCTION ops.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint, jsonb, bigint[], jsonb) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
