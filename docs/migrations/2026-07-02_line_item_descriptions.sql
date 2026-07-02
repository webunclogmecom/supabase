-- ============================================================================
-- 2026-07-02 — Per-line-item descriptions/notes (like Jobber's line-item description)
-- ============================================================================
-- Fred: when creating a visit in the Calendar, allow a free-text description/note per line
-- item (Jobber supports this on its LineItem). line_items.description already exists; this adds
-- the WRITE path: create_calendar_visit gains p_line_item_descriptions jsonb (map
-- { "<service_line_item_id>": "note text" }) stored into line_items.description; and
-- jobber-push-visit.syncVisitLineItems now reads + sends `description` to Jobber
-- (VisitCreateLineItemAttributes.description). Verified end-to-end on 112-YA: DB + Jobber both
-- carried the note. Frontend (the Create-Visit note field) is the paired Building Apps change.
--
-- Adds a param -> changes the signature, so drop any non-15-arg overload first (idempotent),
-- then CREATE OR REPLACE + restore EXECUTE grants (DROP loses grants).
--
-- ⚠⚠ BUG (fixed by 2026-07-03_restore_ops_create_calendar_visit.sql) — DO NOT COPY THIS DO-BLOCK ⚠⚠
-- The DO-block below has NO pronamespace filter, so it dropped `create_calendar_visit` overloads in
-- EVERY schema — including the app-facing `ops.create_calendar_visit` wrapper — and this migration only
-- recreated the `public` one. Result: the Calendar broke with "Could not find the function
-- ops.create_calendar_visit(...) in the schema cache". Always DROP schema-QUALIFIED and recreate the
-- ops wrapper too (see docs/jobber-calendar-job-migration/jobs-visits-calendar-workflow.md; guard:
-- scripts/probes/check_ops_app_rpcs.js).
-- ============================================================================
DO $$ DECLARE r record; BEGIN
  FOR r IN SELECT oid FROM pg_proc WHERE proname='create_calendar_visit' AND pronargs <> 15 LOOP
    EXECUTE 'DROP FUNCTION ' || r.oid::regprocedure; END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.create_calendar_visit(p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_visit_date date, p_property_id bigint DEFAULT NULL::bigint, p_client_location_ids bigint[] DEFAULT NULL::bigint[], p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_title text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_vehicle_id bigint DEFAULT NULL::bigint, p_driver_id bigint DEFAULT NULL::bigint, p_line_item_prices jsonb DEFAULT NULL::jsonb, p_team_ids bigint[] DEFAULT NULL::bigint[], p_line_item_descriptions jsonb DEFAULT NULL::jsonb)
 RETURNS visits LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_primary bigint; v_service_type text; v_derm boolean; v_property bigint; v_visit public.visits;
  v_team bigint[];
BEGIN
  IF p_client_id IS NULL OR p_job_id IS NULL OR p_visit_date IS NULL
     OR p_service_line_item_ids IS NULL OR array_length(p_service_line_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'create_calendar_visit: client_id, job_id, visit_date and >=1 service are required';
  END IF;
  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status <> 'archived';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_calendar_visit: job % is not an active job for client %', p_job_id, p_client_id;
  END IF;

  v_team := COALESCE(p_team_ids, CASE WHEN p_driver_id IS NOT NULL THEN ARRAY[p_driver_id] ELSE '{}'::bigint[] END);
  v_primary := COALESCE(p_team_ids[1], p_driver_id);
  SELECT service_type INTO v_service_type FROM service_line_items WHERE id = p_service_line_item_ids[1];
  SELECT bool_or(requires_derm) INTO v_derm FROM service_line_items WHERE id = ANY (p_service_line_item_ids);
  v_property := COALESCE(p_property_id, (SELECT property_id FROM jobs WHERE id = p_job_id),
    (SELECT id FROM properties WHERE client_id = p_client_id AND is_primary ORDER BY id LIMIT 1));

  INSERT INTO visits (client_id, job_id, property_id, vehicle_id, assigned_driver_id, visit_date, start_at, end_at,
                      title, service_type, service_line_item_id, derm_required, notes, visit_status, source)
  VALUES (p_client_id, p_job_id, v_property, p_vehicle_id, v_primary, p_visit_date, p_start_at, p_end_at,
          p_title, v_service_type, p_service_line_item_ids[1], COALESCE(v_derm, false), p_notes, 'scheduled', 'visit-calendar')
  RETURNING * INTO v_visit;

  INSERT INTO visit_team (visit_id, employee_id)
  SELECT v_visit.id, e FROM unnest(v_team) AS e WHERE e IS NOT NULL ON CONFLICT DO NOTHING;

  -- Per-line-item description/note. p_line_item_descriptions = { "<service_line_item_id>": "note" }.
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
$function$;

GRANT EXECUTE ON FUNCTION public.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint, jsonb, bigint[], jsonb) TO anon, authenticated, service_role;
