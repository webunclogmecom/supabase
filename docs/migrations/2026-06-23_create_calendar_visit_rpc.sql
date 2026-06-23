-- 2026-06-23_create_calendar_visit_rpc.sql
-- Purpose: one atomic call for the Calendar App's redesigned "Create Visit" form. Inserts a
--   workflow-compliant visit tied to a chosen SC/SA job + its services, plus per-visit
--   line_items and visit_locations, deriving service_type + derm_required server-side. The form
--   has no INSERT grant on line_items, so this runs SECURITY DEFINER.
-- Behavior:
--   * visit: source='visit-calendar', visit_status='scheduled'; service_type = primary service's
--     service_type (GT/CL/WD or NULL — all valid per visits_service_type_chk); derm_required =
--     TRUE iff any chosen service is a pumping item (service_line_items.requires_derm).
--   * line_items: one visit-scoped row per chosen service (name = service_line_items.title).
--   * visit_locations: the passed client_location_ids, else the client's 'Main' (else first
--     active) location.
--   * property: explicit p_property_id, else the job's property, else the client's primary.
--   The visits INSERT fires the existing trg_push_visit_insert (Jobber push, gated to 112-YA) and
--   the audit trigger (visits is audited, ADR 010) — app_source attributes via PostgREST context.
-- Audit (ADR 010): FUNCTION (no trigger). Writes to already-audited public.visits.
-- Grants: anon, authenticated, service_role EXECUTE.

CREATE OR REPLACE FUNCTION public.create_calendar_visit(
  p_client_id            bigint,
  p_job_id               bigint,
  p_service_line_item_ids bigint[],
  p_visit_date           date,
  p_property_id          bigint DEFAULT NULL,
  p_client_location_ids  bigint[] DEFAULT NULL,
  p_start_at             timestamptz DEFAULT NULL,
  p_end_at               timestamptz DEFAULT NULL,
  p_title                text DEFAULT NULL,
  p_notes                text DEFAULT NULL,
  p_vehicle_id           bigint DEFAULT NULL
) RETURNS public.visits
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_primary      bigint;
  v_service_type text;
  v_derm         boolean;
  v_property     bigint;
  v_visit        public.visits;
BEGIN
  IF p_client_id IS NULL OR p_job_id IS NULL OR p_visit_date IS NULL
     OR p_service_line_item_ids IS NULL OR array_length(p_service_line_item_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'create_calendar_visit: client_id, job_id, visit_date and >=1 service are required';
  END IF;

  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status <> 'archived';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'create_calendar_visit: job % is not an active job for client %', p_job_id, p_client_id;
  END IF;

  v_primary := p_service_line_item_ids[1];
  SELECT service_type INTO v_service_type FROM service_line_items WHERE id = v_primary;
  SELECT bool_or(requires_derm) INTO v_derm FROM service_line_items WHERE id = ANY (p_service_line_item_ids);
  v_property := COALESCE(
    p_property_id,
    (SELECT property_id FROM jobs WHERE id = p_job_id),
    (SELECT id FROM properties WHERE client_id = p_client_id AND is_primary ORDER BY id LIMIT 1)
  );

  INSERT INTO visits (client_id, job_id, property_id, vehicle_id, visit_date, start_at, end_at,
                      title, service_type, service_line_item_id, derm_required, notes,
                      visit_status, source)
  VALUES (p_client_id, p_job_id, v_property, p_vehicle_id, p_visit_date, p_start_at, p_end_at,
          p_title, v_service_type, v_primary, COALESCE(v_derm, false), p_notes,
          'scheduled', 'visit-calendar')
  RETURNING * INTO v_visit;

  INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
  SELECT v_visit.id, s.title, '', 1, 0, 0, false
  FROM service_line_items s WHERE s.id = ANY (p_service_line_item_ids);

  -- The AFTER INSERT trigger seed_visit_locations() may have auto-seeded (all GDO-active for
  -- multi-location clients). For a form-created visit the user's choice is authoritative, so reset.
  DELETE FROM visit_locations WHERE visit_id = v_visit.id;
  IF p_client_location_ids IS NOT NULL AND array_length(p_client_location_ids, 1) >= 1 THEN
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, x FROM unnest(p_client_location_ids) AS x
    ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO visit_locations (visit_id, client_location_id)
    SELECT v_visit.id, cl.id FROM client_locations cl
    WHERE cl.client_id = p_client_id AND cl.status = 'active'
    ORDER BY (cl.name = 'Main') DESC, cl.id
    LIMIT 1
    ON CONFLICT DO NOTHING;
  END IF;

  RETURN v_visit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_calendar_visit(bigint,bigint,bigint[],date,bigint,bigint[],timestamptz,timestamptz,text,text,bigint)
  TO anon, authenticated, service_role;
