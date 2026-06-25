-- ============================================================================
-- 2026-06-25 — Visit Team (planned crew can be 0 / 1 / many)
-- ----------------------------------------------------------------------------
-- Fred: the Calendar "Driver" field should be a "Team" — optional (empty), 1, or
-- more (it's the crew, not one driver). visits.assigned_driver_id is a single
-- bigint, so add a visit_team join table (3NF). assigned_driver_id is kept as the
-- DERIVED primary (team[0]) for back-compat with v_calendar_visit.driver_id and
-- the existing push. Jobber's push already takes a team array
-- (teamMemberIdsToAssign / visitEditAssignedUsers.assignedUserIds).
--
--   - visit_team(visit_id, employee_id) — the planned crew (audited; Rule 8).
--   - visits.team_rev — bumped when the team changes, so trg_push_visit_update
--     fires (visit_team is a separate table the visits trigger can't observe).
--   - create_calendar_visit gains p_team_ids bigint[]; edit_calendar_visit reads
--     p_patch->'team_ids'. Both replace visit_team + set assigned_driver_id =
--     team[0] (NULL when empty).
--   - jobber-push-visit (edge fn, separate deploy) resolves visit_team -> all
--     Jobber user GIDs and assigns the whole team (clears when empty).
--   - ops.v_visit_team surfaces a visit's team to the app; ops.create_calendar_visit
--     wrapper gains p_team_ids.
-- ============================================================================

-- 1. visit_team join table (audited) ----------------------------------------
CREATE TABLE IF NOT EXISTS public.visit_team (
  visit_id    bigint NOT NULL REFERENCES public.visits(id)    ON DELETE CASCADE,
  employee_id bigint NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
  PRIMARY KEY (visit_id, employee_id)
);
CREATE INDEX IF NOT EXISTS visit_team_employee_idx ON public.visit_team(employee_id);
ALTER TABLE public.visit_team ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, DELETE ON public.visit_team TO service_role;
-- human-editable crew assignment -> audited (CLAUDE.md Rule 8 opt-in)
DROP TRIGGER IF EXISTS audit_visit_team ON public.visit_team;
CREATE TRIGGER audit_visit_team AFTER INSERT OR UPDATE OR DELETE ON public.visit_team
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- 2. team_rev (fires the push on team-only changes) -------------------------
ALTER TABLE public.visits ADD COLUMN IF NOT EXISTS team_rev integer NOT NULL DEFAULT 0;
COMMENT ON COLUMN public.visits.team_rev IS 'Bumped by the Calendar RPCs when visit_team changes, so trg_push_visit_update fires (visit_team is a separate table the visits trigger cannot observe).';

-- 3. create_calendar_visit gains p_team_ids ---------------------------------
DROP FUNCTION IF EXISTS ops.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint, jsonb);
DROP FUNCTION IF EXISTS public.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint, jsonb);

CREATE FUNCTION public.create_calendar_visit(
  p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_visit_date date,
  p_property_id bigint DEFAULT NULL::bigint, p_client_location_ids bigint[] DEFAULT NULL::bigint[],
  p_start_at timestamp with time zone DEFAULT NULL, p_end_at timestamp with time zone DEFAULT NULL,
  p_title text DEFAULT NULL, p_notes text DEFAULT NULL, p_vehicle_id bigint DEFAULT NULL,
  p_driver_id bigint DEFAULT NULL, p_line_item_prices jsonb DEFAULT NULL,
  p_team_ids bigint[] DEFAULT NULL::bigint[]
)
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

  INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
  SELECT v_visit.id, s.title, '',
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

CREATE FUNCTION ops.create_calendar_visit(
  p_client_id bigint, p_job_id bigint, p_service_line_item_ids bigint[], p_visit_date date,
  p_property_id bigint DEFAULT NULL::bigint, p_client_location_ids bigint[] DEFAULT NULL::bigint[],
  p_start_at timestamp with time zone DEFAULT NULL, p_end_at timestamp with time zone DEFAULT NULL,
  p_title text DEFAULT NULL, p_notes text DEFAULT NULL, p_vehicle_id bigint DEFAULT NULL,
  p_driver_id bigint DEFAULT NULL, p_line_item_prices jsonb DEFAULT NULL,
  p_team_ids bigint[] DEFAULT NULL::bigint[]
)
 RETURNS visits LANGUAGE sql SECURITY DEFINER SET search_path TO 'public'
AS $function$
  SELECT public.create_calendar_visit(p_client_id, p_job_id, p_service_line_item_ids, p_visit_date,
    p_property_id, p_client_location_ids, p_start_at, p_end_at, p_title, p_notes, p_vehicle_id,
    p_driver_id, p_line_item_prices, p_team_ids);
$function$;

GRANT EXECUTE ON FUNCTION public.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint, jsonb, bigint[]) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION ops.create_calendar_visit(bigint, bigint, bigint[], date, bigint, bigint[], timestamp with time zone, timestamp with time zone, text, text, bigint, bigint, jsonb, bigint[]) TO anon, authenticated, service_role;

-- 4. edit_calendar_visit handles team_ids in the patch ----------------------
CREATE OR REPLACE FUNCTION public.edit_calendar_visit(p_visit_id bigint, p_patch jsonb)
 RETURNS visits LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_visit visits; v_ids bigint[]; v_primary bigint; v_stype text; v_derm boolean;
BEGIN
  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'edit_calendar_visit: visit % not found or deleted', p_visit_id; END IF;
  IF p_patch IS NULL OR p_patch = '{}'::jsonb THEN RETURN v_visit; END IF;

  UPDATE visits SET
    notes              = CASE WHEN p_patch ? 'notes'      THEN NULLIF(p_patch->>'notes','')        ELSE notes END,
    start_at           = CASE WHEN p_patch ? 'start_at'   THEN (p_patch->>'start_at')::timestamptz ELSE start_at END,
    end_at             = CASE WHEN p_patch ? 'end_at'     THEN (p_patch->>'end_at')::timestamptz   ELSE end_at END,
    visit_date         = CASE WHEN p_patch ? 'visit_date' THEN (p_patch->>'visit_date')::date      ELSE visit_date END,
    title              = CASE WHEN p_patch ? 'title'      THEN NULLIF(p_patch->>'title','')        ELSE title END,
    vehicle_id         = CASE WHEN p_patch ? 'vehicle_id' THEN (p_patch->>'vehicle_id')::bigint    ELSE vehicle_id END,
    assigned_driver_id = CASE WHEN p_patch ? 'driver_id'  THEN (p_patch->>'driver_id')::bigint     ELSE assigned_driver_id END
  WHERE id = p_visit_id;

  -- Team: replace visit_team, set the derived primary, bump team_rev to fire the push.
  IF p_patch ? 'team_ids' THEN
    DELETE FROM visit_team WHERE visit_id = p_visit_id;
    INSERT INTO visit_team (visit_id, employee_id)
    SELECT p_visit_id, x::bigint FROM jsonb_array_elements_text(p_patch->'team_ids') AS x ON CONFLICT DO NOTHING;
    UPDATE visits SET
      assigned_driver_id = NULLIF(p_patch->'team_ids'->>0, '')::bigint,
      team_rev = team_rev + 1
    WHERE id = p_visit_id;
  END IF;

  IF p_patch ? 'service_line_item_ids' THEN
    SELECT array_agg(x::bigint) INTO v_ids FROM jsonb_array_elements_text(p_patch->'service_line_item_ids') AS x;
    IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
      RAISE EXCEPTION 'edit_calendar_visit: at least one service is required';
    END IF;
    DELETE FROM line_items WHERE visit_id = p_visit_id;
    INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
    SELECT p_visit_id, s.title, '',
      COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1),
      COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0),
      COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0)
        * COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1), false
    FROM service_line_items s WHERE s.id = ANY (v_ids);
    v_primary := v_ids[1];
    SELECT service_type INTO v_stype FROM service_line_items WHERE id = v_primary;
    SELECT bool_or(requires_derm) INTO v_derm FROM service_line_items WHERE id = ANY (v_ids);
    UPDATE visits SET service_line_item_id = v_primary, service_type = v_stype,
      derm_required = COALESCE(v_derm, false), line_items_rev = line_items_rev + 1
    WHERE id = p_visit_id;
  END IF;

  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id;
  RETURN v_visit;
END;
$function$;

-- 5. push trigger also fires on team_rev ------------------------------------
DROP TRIGGER IF EXISTS trg_push_visit_update ON public.visits;
CREATE TRIGGER trg_push_visit_update
AFTER UPDATE ON public.visits FOR EACH ROW
WHEN (
  ( (NEW.source = ANY (ARRAY['visit-calendar'::text, 'supabase_cron'::text]))
    AND ( (OLD.visit_date IS DISTINCT FROM NEW.visit_date)
       OR (OLD.start_at IS DISTINCT FROM NEW.start_at) OR (OLD.end_at IS DISTINCT FROM NEW.end_at)
       OR (OLD.title IS DISTINCT FROM NEW.title) OR (OLD.notes IS DISTINCT FROM NEW.notes)
       OR (OLD.job_id IS DISTINCT FROM NEW.job_id) OR (OLD.service_line_item_id IS DISTINCT FROM NEW.service_line_item_id)
       OR (OLD.line_items_rev IS DISTINCT FROM NEW.line_items_rev) OR (OLD.team_rev IS DISTINCT FROM NEW.team_rev)
       OR (OLD.deleted_at IS DISTINCT FROM NEW.deleted_at) OR (OLD.visit_status IS DISTINCT FROM NEW.visit_status) ) )
  OR ((OLD.deleted_at IS DISTINCT FROM NEW.deleted_at) AND (NEW.deleted_at IS NOT NULL))
  OR ((OLD.visit_status IS DISTINCT FROM NEW.visit_status) AND (NEW.visit_status = 'cancelled'))
)
EXECUTE FUNCTION fn_push_visit_to_jobber();

-- 6. ops.v_visit_team — the app reads a visit's team via the ops schema -----
CREATE OR REPLACE VIEW ops.v_visit_team AS
  SELECT vt.visit_id, vt.employee_id, e.full_name
  FROM visit_team vt JOIN employees e ON e.id = vt.employee_id;
GRANT SELECT ON ops.v_visit_team TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
