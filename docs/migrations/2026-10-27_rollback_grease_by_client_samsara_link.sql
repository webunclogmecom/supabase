-- 2026-10-27_rollback_grease_by_client_samsara_link.sql
-- Puts public.get_grease_by_client() back to its 2026-10-27_1925 body (23 columns), verbatim from pg_get_functiondef.
BEGIN;
SET LOCAL lock_timeout = '3s';
DROP FUNCTION public.get_grease_by_client();
CREATE FUNCTION public.get_grease_by_client()
 RETURNS TABLE(client_id bigint, client_code text, client_name text, property_id bigint, property_address text, pump_kind text, trap_size_gallons integer, avg_gallons integer, readings_in_average integer, min_gallons integer, max_gallons integer, last_reading_date date, visit_id bigint, visit_date date, vehicle_id bigint, truck_name text, truck_color text, driver_name text, driver_color text, gallons integer, in_average boolean, note text, above_trap_size boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'ops', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
  PERFORM hr.fn_require_app('admin_review', 'view');
  RETURN QUERY
  WITH t AS MATERIALIZED (
    SELECT s.*, ops.fn_visit_pump_kind(s.visit_id, v.job_id) AS kind
      FROM public.v_visit_tank_service s
      JOIN public.visits v ON v.id = s.visit_id
     WHERE s.visit_kind = 'volume'
       AND NOT EXISTS (SELECT 1 FROM public.v_non_customer_clients n WHERE n.client_id = s.client_id)
  ), a AS MATERIALIZED (
    -- the Calendar's average, as of tomorrow ET so today's readings are in (ops.v_client_sludge_average does the same)
    SELECT f.property_id, f.pump_kind, f.readings_n, f.avg_gallons, f.last_reading_date, f.readings
      FROM ops.fn_client_sludge_averages(ARRAY[(now() AT TIME ZONE 'America/New_York')::date + 1]) f
  ), d AS MATERIALIZED (
    SELECT cv.id AS d_visit_id, cv.driver_id AS d_driver_id
      FROM ops.v_calendar_visit cv WHERE cv.id IN (SELECT t.visit_id FROM t)
  )
  SELECT t.client_id, c.client_code, c.name,
         t.property_id, p.address, t.kind, NULLIF(p.grease_trap_size_gallons, 0)::int,
         a.avg_gallons::int, a.readings_n,
         (SELECT min((r->>'gallons')::numeric) FROM jsonb_array_elements(a.readings) r)::int,
         (SELECT max((r->>'gallons')::numeric) FROM jsonb_array_elements(a.readings) r)::int,
         a.last_reading_date,
         t.visit_id, t.visit_date, t.vehicle_id, vh.name, vh.color_hex,
         e.full_name, e.color_hex,
         CASE WHEN t.sludge_collected_gallons > 0 THEN round(t.sludge_collected_gallons)::int END,
         COALESCE(a.readings @> jsonb_build_array(jsonb_build_object('visit_id', t.visit_id)), false),
         CASE
           -- in the average: only a note when the reading is a little less certain
           WHEN COALESCE(a.readings @> jsonb_build_array(jsonb_build_object('visit_id', t.visit_id)), false) THEN
             CASE t.sludge_reason
               WHEN 'shared_stop_allocated' THEN 'Shared truck stop: the reading is split with the other visit.'
               WHEN 'window_match' THEN 'Matched to the truck stop by time.'
               WHEN 'no_pump_signal' THEN 'No engine data to confirm the pump ran.'
               ELSE NULL END
           WHEN t.vehicle_id IS NULL THEN 'No truck on this visit.'
           WHEN t.sludge_reason = 'no_sensor' THEN 'No sensor on this truck.'
           WHEN t.sludge_reason = 'no_stop' THEN 'No truck stop was found for this visit.'
           WHEN t.sludge_reason IN ('no_config', 'edge_missing') THEN 'The tank level before or after the visit is missing.'
           WHEN t.sludge_reason = 'too_short' THEN 'The truck stop was too short to measure.'
           WHEN t.sludge_reason = 'below_resolution' THEN 'Too small for the sensor to measure on a trap this size.'
           WHEN t.sludge_reason = 'tank_at_ceiling' THEN 'The truck''s tank was full, so the reading may be low.'
           WHEN t.sludge_reason = 'pumped_no_rise' THEN 'The pump ran but the tank level did not go up.'
           WHEN t.sludge_reason = 'rise_without_pump' THEN 'The tank level went up but the pump did not run.'
           WHEN t.sludge_collected_gallons IS NULL THEN 'No reading.'
           WHEN t.sludge_collected_gallons < 40 THEN 'Less than 40 gal, too small to count.'
           WHEN t.sludge_collected_gallons > 3840 THEN 'More than the truck holds (3,840 gal).'
           WHEN t.kind IS NULL THEN 'No pumping service on this visit''s lines.'
           ELSE 'Older than the last 6 readings, so not in the average.'
         END,
         COALESCE(t.sludge_above_trap_size, false)
    FROM t
    JOIN public.clients c ON c.id = t.client_id
    LEFT JOIN public.properties p ON p.id = t.property_id
    LEFT JOIN a ON a.property_id = t.property_id AND a.pump_kind = t.kind
    LEFT JOIN public.vehicles vh ON vh.id = t.vehicle_id
    LEFT JOIN d ON d.d_visit_id = t.visit_id
    LEFT JOIN public.employees e ON e.id = d.d_driver_id
   ORDER BY c.client_code NULLS LAST, t.property_id, t.kind NULLS LAST, t.visit_date DESC, t.visit_id DESC;
END $function$;

REVOKE ALL ON FUNCTION public.get_grease_by_client() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_grease_by_client() TO authenticated, service_role;
COMMENT ON FUNCTION public.get_grease_by_client() IS
  'Admin Review "Grease by client" (Trello 6M9WvSYp): one row per completed pumping visit since the Moises sensor, with the Calendar''s average for its place and pump kind (ops.fn_client_sludge_averages), whether the reading is in it, a plain note when not. View in Admin Review.';
COMMIT;
