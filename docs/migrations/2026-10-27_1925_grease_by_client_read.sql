-- 2026-10-27_1925_grease_by_client_read.sql
--
-- Trello 6M9WvSYp "Clients pumping readings table". Fred (Slack, 2026-10-23): "creating a table of the clients with
-- their corresponding pumping readings, and the table should show the average and the listed visits with the correct
-- readings." Fred's picks (2026-10-27): the page lives in Admin Review; every completed pumping visit since the sensors
-- started (2026-08-20) is listed, on any truck; the average is the SAME one the Calendar's Grease pumped tile uses.
--
-- What this adds: ONE read function, public.get_grease_by_client(). Nothing existing changes.
--   * One row per completed pumping visit (v_visit_tank_service.visit_kind = 'volume', i.e. service_type Pumping and not
--     a dump site) since 2026-08-20, test / fixture / dump clients left out (v_non_customer_clients).
--   * The group a visit belongs to is (client, property, pump kind), the grain of ops.fn_client_sludge_averages.
--   * The group's average, readings count and last reading date come ONLY from ops.fn_client_sludge_averages with
--     as_of = tomorrow (ET), exactly what ops.v_client_sludge_average and the Calendar read. min / max are over the same
--     readings (the jsonb list the function returns). The app computes no number.
--   * in_average = the visit is one of the readings that function used. It is the arbiter: the note below only says
--     WHY a visit is not in it, in plain words (operator-message rule, root CLAUDE.md / Supabase CLAUDE.md 2026-09-14).
--   * gallons = the sensor's sludge_collected_gallons, shown only when positive (a flagged reading keeps its number so a
--     person can judge it; a missing one is NULL, never 0).
-- Access: View in Admin Review (hr.fn_require_app), the same gate as get_water_visits for a period.
-- Rule 8 (audit): no table, nothing to opt in or out.
-- Grants: revoked from PUBLIC and anon by name (default privileges hand out EXECUTE), granted to authenticated and
-- service_role, and asserted with has_function_privilege below.

BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE FUNCTION public.get_grease_by_client()
RETURNS TABLE(
  client_id bigint, client_code text, client_name text,
  property_id bigint, property_address text, pump_kind text, trap_size_gallons integer,
  avg_gallons integer, readings_in_average integer, min_gallons integer, max_gallons integer, last_reading_date date,
  visit_id bigint, visit_date date, vehicle_id bigint, truck_name text, truck_color text,
  driver_name text, driver_color text,
  gallons integer, in_average boolean, note text, above_trap_size boolean)
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

COMMENT ON FUNCTION public.get_grease_by_client() IS
  'Admin Review "Grease by client" (Trello 6M9WvSYp): one row per completed pumping visit since 2026-08-20 with its '
  'client / place / pump kind group, the Calendar''s average for that group (ops.fn_client_sludge_averages, never '
  'recomputed), in_average and a plain note saying why a visit is not in it. View in Admin Review.';

REVOKE ALL ON FUNCTION public.get_grease_by_client() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_grease_by_client() TO authenticated, service_role;

-- VERIFY (runs as postgres, no request claims, so the access check passes: hr.fn_access_caller gives a caller with
-- no claims everything)
DO $verify$
DECLARE r record; n_rows int; n_groups int; n_avg_mismatch int; n_bad int; n_ctrl int;
BEGIN
  -- grants
  IF has_function_privilege('anon', 'public.get_grease_by_client()', 'EXECUTE') THEN RAISE EXCEPTION 'anon can execute'; END IF;
  IF NOT has_function_privilege('authenticated', 'public.get_grease_by_client()', 'EXECUTE') THEN RAISE EXCEPTION 'authenticated cannot execute'; END IF;

  CREATE TEMP TABLE g ON COMMIT DROP AS SELECT * FROM public.get_grease_by_client();
  SELECT count(*) INTO n_rows FROM g;
  IF n_rows < 200 THEN RAISE EXCEPTION 'expected 200+ pumping visits, got %', n_rows; END IF;

  -- every visit once
  IF (SELECT count(DISTINCT visit_id) FROM g) <> n_rows THEN RAISE EXCEPTION 'a visit appears twice'; END IF;

  -- the group average is the Calendar's average, byte for byte (ops.v_client_sludge_average)
  SELECT count(*) INTO n_avg_mismatch FROM (
    SELECT DISTINCT g.property_id, g.pump_kind, g.avg_gallons, g.readings_in_average, g.last_reading_date FROM g
     WHERE g.avg_gallons IS NOT NULL) x
   LEFT JOIN ops.v_client_sludge_average v ON v.property_id = x.property_id AND v.pump_kind = x.pump_kind
   WHERE v.avg_gallons IS DISTINCT FROM x.avg_gallons OR v.readings_n IS DISTINCT FROM x.readings_in_average
      OR v.last_reading_date IS DISTINCT FROM x.last_reading_date;
  IF n_avg_mismatch > 0 THEN RAISE EXCEPTION '% groups differ from ops.v_client_sludge_average', n_avg_mismatch; END IF;

  -- each group's in_average rows are exactly its readings count, and their gallons average back to the group average
  SELECT count(*) INTO n_bad FROM (
    SELECT property_id, pump_kind, max(readings_in_average) n, count(*) FILTER (WHERE in_average) k,
           max(avg_gallons) av, round(avg(gallons) FILTER (WHERE in_average)) recomputed
      FROM g WHERE avg_gallons IS NOT NULL GROUP BY 1, 2) x
   WHERE x.n <> x.k OR abs(x.av - x.recomputed) > 1;
  IF n_bad > 0 THEN RAISE EXCEPTION '% groups whose listed readings do not add up to the average', n_bad; END IF;

  -- a visit not in the average always says why; a visit in it never carries a left-out sentence
  SELECT count(*) INTO n_bad FROM g WHERE NOT in_average AND note IS NULL;
  IF n_bad > 0 THEN RAISE EXCEPTION '% left-out visits with no note', n_bad; END IF;
  SELECT count(*) INTO n_bad FROM g WHERE in_average AND note IS NOT NULL
     AND note NOT IN ('Shared truck stop: the reading is split with the other visit.', 'Matched to the truck stop by time.',
                      'No engine data to confirm the pump ran.');
  IF n_bad > 0 THEN RAISE EXCEPTION '% counted visits with a left-out note', n_bad; END IF;

  -- no zero gallons: a missing reading is NULL
  IF EXISTS (SELECT 1 FROM g WHERE gallons = 0) THEN RAISE EXCEPTION 'a 0 gallon reading is shown'; END IF;

  -- positive controls: a David or Cloggy pumping visit reads "No sensor on this truck."; Moises has counted readings
  SELECT count(*) INTO n_ctrl FROM g WHERE truck_name IN ('David', 'Cloggy') AND note = 'No sensor on this truck.';
  IF n_ctrl = 0 THEN RAISE EXCEPTION 'control: no David / Cloggy visit reads No sensor'; END IF;
  SELECT count(*) INTO n_ctrl FROM g WHERE truck_name = 'Moises' AND in_average;
  IF n_ctrl < 100 THEN RAISE EXCEPTION 'control: only % counted Moises readings', n_ctrl; END IF;
  -- no test client
  IF EXISTS (SELECT 1 FROM g WHERE client_code = '112-YA') THEN RAISE EXCEPTION '112-YA is listed'; END IF;

  SELECT count(DISTINCT (client_id, property_id, pump_kind)) INTO n_groups FROM g;
  RAISE NOTICE 'get_grease_by_client: % visits, % groups, % counted', n_rows, n_groups, (SELECT count(*) FROM g WHERE in_average);
END $verify$;

COMMIT;
