-- 2026-09-15_1233_calendar_visit_default_30_minutes.sql
--
-- WHY: A NEW CALENDAR VISIT DEFAULTS TO 30 MINUTES, NOT ONE HOUR.
-- ---------------------------------------------------------------------------
-- Fred, 2026-09-15: "make visits have a timeframe of 30 minutes by default, instead of the 1 hour it
-- have right now". The Visit Calendar's create form sends p_start_at and p_end_at = null, so the
-- duration of every visit created there is this function's default. One expression changes:
--   v_end_at := COALESCE(p_end_at, CASE WHEN p_start_at IS NOT NULL THEN p_start_at + interval '1 hour' END)
-- becomes                                                              p_start_at + interval '30 minutes'
-- Callers that send an explicit p_end_at (create_dump_visit, the DUMP app) are unaffected.
-- edit_calendar_visit still never re-times a visit (duration is preserved by the CALLER).
-- The truck clash rule ("starting within the hour") is a separate predicate and is untouched.
--
-- Body spliced from the LIVE definition read 2026-09-15 12:3x ET (after @Supabase's 2026-09-15_1100),
-- md5 92d5d8b1f59bee9f4d9bab519c741ca1 pinned below; a different live body aborts before anything changes.
-- RULE 8: function replace only; no table changes. Grants/owner unchanged by CREATE OR REPLACE.

BEGIN;

DO $pre$
DECLARE v_md5 text; v_n int;
BEGIN
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'create_calendar_visit';
  IF v_n <> 1 THEN RAISE EXCEPTION 'PRE 1: % overloads of public.create_calendar_visit (expected 1)', v_n; END IF;
  SELECT md5(pg_get_functiondef(p.oid)) INTO v_md5 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'create_calendar_visit';
  IF v_md5 <> '92d5d8b1f59bee9f4d9bab519c741ca1' THEN RAISE EXCEPTION 'PRE 2: live body md5 % is not the one this file was spliced from; re-read and re-splice', v_md5; END IF;
END $pre$;

CREATE OR REPLACE FUNCTION public.create_calendar_visit(p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_visit_date date, p_property_id bigint DEFAULT NULL::bigint, p_client_location_ids bigint[] DEFAULT NULL::bigint[], p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_vehicle_id bigint DEFAULT NULL::bigint, p_driver_id bigint DEFAULT NULL::bigint, p_line_item_prices jsonb DEFAULT NULL::jsonb, p_team_ids bigint[] DEFAULT NULL::bigint[], p_line_item_descriptions jsonb DEFAULT NULL::jsonb)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_primary bigint; v_service_type text; v_derm boolean; v_property bigint; v_visit public.visits;
  v_team bigint[]; v_end_at timestamptz; v_clash jsonb; v_eff_vehicle bigint;
BEGIN
  IF p_client_id IS NULL OR p_job_id IS NULL OR p_visit_date IS NULL
     OR p_service_line_item_ids IS NULL OR array_length(p_service_line_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'create_calendar_visit: client_id, job_id, visit_date and >=1 service are required';
  END IF;
  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status NOT IN ('archived', 'destroyed');
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_calendar_visit: job % is not an active job for client %', p_job_id, p_client_id;
  END IF;

  v_team := COALESCE(p_team_ids, CASE WHEN p_driver_id IS NOT NULL THEN ARRAY[p_driver_id] ELSE '{}'::bigint[] END);
  v_primary := COALESCE(p_team_ids[1], p_driver_id);
  SELECT service_type INTO v_service_type FROM service_line_items WHERE id = p_service_line_item_ids[1];
  SELECT bool_or(public.fn_line_item_requires_derm(title)) INTO v_derm FROM service_line_items WHERE id = ANY (p_service_line_item_ids);
  v_property := COALESCE(p_property_id, (SELECT property_id FROM jobs WHERE id = p_job_id),
    (SELECT id FROM properties WHERE client_id = p_client_id AND is_primary ORDER BY id LIMIT 1));

  -- A visit lasts one hour unless the caller says otherwise (Fred, 2026-09-06). The create form can
  -- send a start with no end, and a NULL end made the visit read as untimed downstream.
  v_end_at := COALESCE(p_end_at, CASE WHEN p_start_at IS NOT NULL THEN p_start_at + interval '30 minutes' END);

  -- HARD REFUSE a second visit on the same TRUCK inside the hour. One truck cannot be in two places.
  -- The same-DRIVER case is deliberately NOT refused: a driver can ride as a second crew member, so
  -- it is advisory and surfaced by fn_check_visit_clash for the app to warn on. (Fred, 2026-09-06.)
  -- The EFFECTIVE truck is used, not p_vehicle_id: the Calendar shows a truck defaulted from the
  -- job's line items when none is assigned, and the live clash this guard exists for has a NULL
  -- vehicle_id on one side. Reading the stored column would return a confident zero on that case.
  v_eff_vehicle := public.fn_effective_vehicle_for_job(p_vehicle_id, p_job_id);
  IF p_start_at IS NOT NULL AND v_eff_vehicle IS NOT NULL THEN
    v_clash := public.fn_check_visit_clash(p_start_at, v_eff_vehicle, v_team, NULL);
    IF jsonb_array_length(v_clash -> 'truck') > 0
     AND public.fn_visit_clash_guard_enabled() THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = format('visit_truck_clash: truck %s already has %s at %s',
          COALESCE((SELECT name FROM vehicles WHERE id = v_eff_vehicle), v_eff_vehicle::text),
          v_clash -> 'truck' -> 0 ->> 'client_code',
          v_clash -> 'truck' -> 0 ->> 'start_local'),
        HINT = 'Pick another time or another truck. A visit lasts one hour.';
    END IF;
  END IF;

  INSERT INTO visits (client_id, job_id, property_id, vehicle_id, assigned_driver_id, visit_date, start_at, end_at,
                      title, service_type, service_line_item_id, derm_required, notes, visit_status, source)
  VALUES (p_client_id, p_job_id, v_property, p_vehicle_id, v_primary, p_visit_date, p_start_at, v_end_at,
          p_title, v_service_type, p_service_line_item_ids[1], v_derm, p_notes, 'scheduled', 'visit-calendar')
  RETURNING * INTO v_visit;

  INSERT INTO visit_team (visit_id, employee_id)
  SELECT v_visit.id, e FROM unnest(v_team) AS e WHERE e IS NOT NULL ON CONFLICT DO NOTHING;

  -- Per-line-item description/note (like Jobber's line-item description). p_line_item_descriptions
  -- is a jsonb map { "<service_line_item_id>": "note text" }; absent/blank -> '' (Fred 2026-07-02).
  INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
  SELECT v_visit.id, s.title,
    COALESCE(NULLIF(btrim(p_line_item_descriptions ->> s.id::text), ''), ''),
    COALESCE((p_line_item_prices -> s.id::text ->> 'quantity')::numeric, 1),
    COALESCE((p_line_item_prices -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0),
    COALESCE((p_line_item_prices -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0)
      * COALESCE((p_line_item_prices -> s.id::text ->> 'quantity')::numeric, 1), false
  FROM service_line_items s WHERE s.id = ANY (p_service_line_item_ids);

  DELETE FROM visit_locations WHERE visit_id = v_visit.id;
  IF p_client_location_ids IS NOT NULL AND array_length(p_client_location_ids, 1) >= 1 THEN
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, x FROM unnest(p_client_location_ids) AS x ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, cl.id FROM client_locations cl
    WHERE cl.client_id = p_client_id AND cl.status = 'active'
    ORDER BY (cl.name = 'Main') DESC, cl.id LIMIT 1 ON CONFLICT DO NOTHING;
  END IF;
  RETURN v_visit;
END;
$function$
;

DO $verify$
DECLARE v_def text; v_n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname = 'create_calendar_visit';
  IF v_def LIKE '%interval ''1 hour''%' THEN RAISE EXCEPTION 'VERIFY 1: the one-hour default is still in the body'; END IF;
  SELECT (length(v_def) - length(replace(v_def, 'interval ''30 minutes''', ''))) / length('interval ''30 minutes''') INTO v_n;
  IF v_n <> 1 THEN RAISE EXCEPTION 'VERIFY 2: expected exactly one 30-minute interval, found %', v_n; END IF;
  RAISE NOTICE 'VERIFY ok: create_calendar_visit defaults end_at to start_at + 30 minutes';
END $verify$;

COMMIT;
