-- 2026-09-06_1833_visit_truck_clash_guard.sql
--
-- WHY
-- ---
-- Fred, 2026-09-06: *"you need to remember to put that a visit lasts an hour, and we can't have
-- like 2 visits at the same time for the same Truck or Driver/Team, so make sure they don't clash"*,
-- and on the enforcement shape: *"hard-refuse on truck, warn on driver"*.
--
-- Two rules, deliberately enforced at DIFFERENT strengths:
--   TRUCK  -> HARD REFUSE. One truck cannot be in two places.
--   DRIVER -> ADVISORY only. A driver can legitimately ride as a second crew member, so the app
--             warns from `fn_check_visit_clash` and the operator decides.
--
-- 🛑 THIS IS DELIBERATELY NOT A TABLE CONSTRAINT, AND THAT IS THE LOAD-BEARING DECISION.
-- Visits also arrive from the Jobber poll and from `fn_generate_sa_visits`. A CHECK or an EXCLUDE
-- constraint would start REJECTING rows Jobber considers valid, which converts a scheduling
-- opinion of ours into a sync outage. The guard therefore lives only in the two HUMAN paths,
-- `create_calendar_visit` and `edit_calendar_visit`.
--
-- 🛑 THE DEFECT THAT ALMOST SHIPPED: `visits.vehicle_id` IS NOT THE TRUCK THE APP SHOWS.
-- The live clash Fred screenshotted is 2026-09-07: `032-LG` 08:00 ET and `106-ALC` 08:30 ET, both
-- shown as truck **Moises** in the Calendar. But `visits.vehicle_id` for `032-LG` (visit 6997) is
-- **NULL**. `ops.v_calendar_visit` exposes an EFFECTIVE vehicle:
--     COALESCE(v.vehicle_id, <min default_vehicle_id over the VISIT's line items>,
--                            <min default_vehicle_id over the JOB's unbilled line items>)
-- and `vehicle_source` reads 'assigned' vs 'default'. A guard written against the stored column
-- would therefore have returned a confident ZERO on the exact case it was built for.
-- ⇒ `fn_check_visit_clash` reads `ops.v_calendar_visit` for the EXISTING side, so it inherits the
--   effective-vehicle rule AND the `is_all_day` rule with no second implementation.
-- ⚠ The NEW side (a row that does not exist yet) cannot come from the view, so the JOB-level arm is
--   reproduced once in `fn_effective_vehicle_for_job`. That IS a second copy, and VERIFY 6 below
--   cross-checks it against the view on live data so drift fails loudly instead of silently.
--
-- MEASURED BEFORE APPLYING (ops.v_calendar_visit, timed, not all-day, not cancelled/completed/
-- skipped, starts < 60 min apart): exactly **ONE** clashing pair exists, all-time, and it is Fred's
-- screenshot. So this is PREVENTION, not a cleanup, and the guard refuses nothing historical.
--
-- WHAT ELSE CHANGES
-- -----------------
-- `create_calendar_visit` now defaults `end_at` to `start_at + 1 hour` when the caller sends a start
-- and no end. The Calendar's create form can send a start alone, and a NULL end made the visit read
-- as untimed downstream. `edit_calendar_visit` deliberately does NOT do this: the workflow doc's
-- rule is that duration is preserved by the CALLER, and silently re-timing an edited visit would
-- break that.
--
-- 🛑 BOTH FUNCTION BODIES WERE COPIED, NEVER RETYPED (Supabase/CLAUDE.md's CREATE OR REPLACE rule).
-- They were extracted with `pg_get_functiondef`, spliced by script, and diffed: `edit` removes
-- ZERO original lines, `create` changes exactly TWO (the DECLARE, and `p_end_at` -> `v_end_at` in
-- the INSERT VALUES). Signatures are unchanged, so the `ops.*` wrappers need no recreation.
--
-- AUDIT (rule 8): no new table. `public.visits` keeps its existing `audit_visits` trigger.

BEGIN;

-- ---------------------------------------------------------------------------------------------
-- PART 1. The effective truck for a job that has no visit yet.
-- Only the JOB-level arm of the view's COALESCE can apply before the row exists.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_effective_vehicle_for_job(p_vehicle_id bigint, p_job_id bigint)
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    p_vehicle_id,
    (SELECT min(sli.default_vehicle_id)
       FROM line_items li2
       JOIN service_line_items sli
         ON sli.code = lpad(substring(btrim(li2.name), '^([0-9]+)'), 2, '0')
      WHERE li2.job_id = p_job_id AND li2.visit_id IS NULL AND li2.invoice_id IS NULL));
$function$;

COMMENT ON FUNCTION public.fn_effective_vehicle_for_job(bigint, bigint) IS
  'Effective truck for a not-yet-created visit. Mirrors the JOB-level arm of ops.v_calendar_visit''s '
  'effv LATERAL. Kept in sync by VERIFY 6 of 2026-09-06_1833; if that assertion fails the view moved.';

-- ---------------------------------------------------------------------------------------------
-- PART 2. The clash reader. Read-only, and the single source of truth for "is this slot taken".
-- Returns BOTH kinds so the app can hard-block on truck and merely warn on driver.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_check_visit_clash(
  p_start_at         timestamptz,
  p_vehicle_id       bigint  DEFAULT NULL,
  p_team_ids         bigint[] DEFAULT NULL,
  p_exclude_visit_id bigint  DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'ops'
AS $function$
  WITH cand AS (
    SELECT cv.id, cv.client_code, cv.vehicle_id, cv.assigned_driver_id, cv.start_at,
           to_char(cv.start_at AT TIME ZONE 'America/New_York', 'HH12:MI AM') AS start_local
      FROM ops.v_calendar_visit cv
     WHERE p_start_at IS NOT NULL
       AND cv.start_at IS NOT NULL
       AND cv.is_all_day IS NOT TRUE
       AND cv.visit_status NOT IN ('cancelled','completed','skipped')
       AND (p_exclude_visit_id IS NULL OR cv.id <> p_exclude_visit_id)
       -- a visit lasts one hour, so two starts inside an hour of each other collide
       AND abs(extract(epoch FROM (cv.start_at - p_start_at))) < 3600
  )
  SELECT jsonb_build_object(
    'truck', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'visit_id', id, 'client_code', client_code, 'start_local', start_local) ORDER BY start_at)
              FROM cand WHERE p_vehicle_id IS NOT NULL AND vehicle_id = p_vehicle_id), '[]'::jsonb),
    'driver', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'visit_id', id, 'client_code', client_code, 'start_local', start_local) ORDER BY start_at)
              FROM cand
              WHERE p_team_ids IS NOT NULL
                AND (assigned_driver_id = ANY (p_team_ids)
                     OR EXISTS (SELECT 1 FROM public.visit_team vt
                                 WHERE vt.visit_id = cand.id AND vt.employee_id = ANY (p_team_ids)))),
              '[]'::jsonb));
$function$;

COMMENT ON FUNCTION public.fn_check_visit_clash(timestamptz, bigint, bigint[], bigint) IS
  'Read-only slot check for the Visit Calendar. truck[] is a HARD block (enforced in '
  'create/edit_calendar_visit); driver[] is ADVISORY and the operator may override (Fred 2026-09-06). '
  'Reads ops.v_calendar_visit so the EFFECTIVE vehicle and the is_all_day rule are not re-implemented.';

REVOKE ALL ON FUNCTION public.fn_check_visit_clash(timestamptz, bigint, bigint[], bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_check_visit_clash(timestamptz, bigint, bigint[], bigint)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.fn_effective_vehicle_for_job(bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_effective_vehicle_for_job(bigint, bigint)
  TO authenticated, service_role;

-- ops wrapper: the app's client is pinned to the ops schema (see the workflow doc's RULE).
CREATE OR REPLACE FUNCTION ops.fn_check_visit_clash(
  p_start_at         timestamptz,
  p_vehicle_id       bigint  DEFAULT NULL,
  p_team_ids         bigint[] DEFAULT NULL,
  p_exclude_visit_id bigint  DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT public.fn_check_visit_clash(p_start_at, p_vehicle_id, p_team_ids, p_exclude_visit_id);
$function$;

REVOKE ALL ON FUNCTION ops.fn_check_visit_clash(timestamptz, bigint, bigint[], bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ops.fn_check_visit_clash(timestamptz, bigint, bigint[], bigint)
  TO authenticated, service_role;

-- ---------------------------------------------------------------------------------------------
-- PART 3. create_calendar_visit -- body COPIED from pg_get_functiondef, two lines changed.
-- ---------------------------------------------------------------------------------------------
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
  PERFORM 1 FROM jobs WHERE id = p_job_id AND client_id = p_client_id AND job_status <> 'archived';
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
  v_end_at := COALESCE(p_end_at, CASE WHEN p_start_at IS NOT NULL THEN p_start_at + interval '1 hour' END);

  -- HARD REFUSE a second visit on the same TRUCK inside the hour. One truck cannot be in two places.
  -- The same-DRIVER case is deliberately NOT refused: a driver can ride as a second crew member, so
  -- it is advisory and surfaced by fn_check_visit_clash for the app to warn on. (Fred, 2026-09-06.)
  -- The EFFECTIVE truck is used, not p_vehicle_id: the Calendar shows a truck defaulted from the
  -- job's line items when none is assigned, and the live clash this guard exists for has a NULL
  -- vehicle_id on one side. Reading the stored column would return a confident zero on that case.
  v_eff_vehicle := public.fn_effective_vehicle_for_job(p_vehicle_id, p_job_id);
  IF p_start_at IS NOT NULL AND v_eff_vehicle IS NOT NULL THEN
    v_clash := public.fn_check_visit_clash(p_start_at, v_eff_vehicle, v_team, NULL);
    IF jsonb_array_length(v_clash -> 'truck') > 0 THEN
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

-- ---------------------------------------------------------------------------------------------
-- PART 4. edit_calendar_visit -- body COPIED from pg_get_functiondef, ZERO original lines removed.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.edit_calendar_visit(p_visit_id bigint, p_patch jsonb)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_visit visits; v_ids bigint[]; v_primary bigint; v_stype text; v_derm boolean;
        v_new_start timestamptz; v_new_vehicle bigint; v_clash jsonb;
BEGIN
  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'edit_calendar_visit: visit % not found or deleted', p_visit_id; END IF;
  -- A skipped visit is removed from Jobber and holds its cadence slot — editing it would silently move
  -- that slot. Un-skip first (parity with ripple_reschedule_visit's guard). Added 2026-07-03.
  IF v_visit.visit_status = 'skipped' THEN
    RAISE EXCEPTION 'edit_calendar_visit: visit % is skipped — un-skip it first (unskip_visit)', p_visit_id;
  END IF;
  IF p_patch IS NULL OR p_patch = '{}'::jsonb THEN RETURN v_visit; END IF;

  -- Same hard truck refusal as create_calendar_visit: moving a visit onto an occupied slot is the
  -- same hazard as booking one there. Resolve the EFFECTIVE values first, because a patch that
  -- changes only the time must still be checked against the truck the visit already has.
  -- When the patch does not set a truck, take the CALENDAR's effective one (which may be defaulted
  -- from line items), not visits.vehicle_id, or the check is blind to a defaulted truck.
  v_new_start   := CASE WHEN p_patch ? 'start_at'   THEN (p_patch->>'start_at')::timestamptz ELSE v_visit.start_at END;
  v_new_vehicle := CASE WHEN p_patch ? 'vehicle_id' THEN (p_patch->>'vehicle_id')::bigint
                        ELSE (SELECT cv.vehicle_id FROM ops.v_calendar_visit cv WHERE cv.id = p_visit_id) END;
  IF (p_patch ? 'start_at' OR p_patch ? 'vehicle_id')
     AND v_new_start IS NOT NULL AND v_new_vehicle IS NOT NULL THEN
    v_clash := public.fn_check_visit_clash(v_new_start, v_new_vehicle, NULL, p_visit_id);
    IF jsonb_array_length(v_clash -> 'truck') > 0 THEN
      RAISE EXCEPTION USING
        ERRCODE = '22023',
        MESSAGE = format('visit_truck_clash: truck %s already has %s at %s',
          COALESCE((SELECT name FROM vehicles WHERE id = v_new_vehicle), v_new_vehicle::text),
          v_clash -> 'truck' -> 0 ->> 'client_code',
          v_clash -> 'truck' -> 0 ->> 'start_local'),
        HINT = 'Pick another time or another truck. A visit lasts one hour.';
    END IF;
  END IF;

  UPDATE visits SET
    notes              = CASE WHEN p_patch ? 'notes'      THEN NULLIF(p_patch->>'notes','')        ELSE notes END,
    start_at           = CASE WHEN p_patch ? 'start_at'   THEN (p_patch->>'start_at')::timestamptz ELSE start_at END,
    end_at             = CASE WHEN p_patch ? 'end_at'     THEN (p_patch->>'end_at')::timestamptz   ELSE end_at END,
    visit_date         = CASE WHEN p_patch ? 'visit_date' THEN (p_patch->>'visit_date')::date      ELSE visit_date END,
    title              = CASE WHEN p_patch ? 'title'      THEN NULLIF(p_patch->>'title','')        ELSE title END,
    vehicle_id         = CASE WHEN p_patch ? 'vehicle_id' THEN (p_patch->>'vehicle_id')::bigint    ELSE vehicle_id END,
    assigned_driver_id = CASE WHEN p_patch ? 'driver_id'  THEN (p_patch->>'driver_id')::bigint     ELSE assigned_driver_id END
  WHERE id = p_visit_id;

  -- Team: replace + bump team_rev ONLY when the set actually changes (on-purpose signal).
  IF p_patch ? 'team_ids' THEN
    DECLARE v_incoming bigint[]; v_current bigint[];
    BEGIN
      SELECT COALESCE(array_agg(DISTINCT x::bigint ORDER BY x::bigint), '{}')
        INTO v_incoming FROM jsonb_array_elements_text(p_patch->'team_ids') AS x WHERE NULLIF(x,'') IS NOT NULL;
      SELECT COALESCE(array_agg(DISTINCT employee_id ORDER BY employee_id), '{}')
        INTO v_current FROM visit_team WHERE visit_id = p_visit_id;
      IF v_incoming IS DISTINCT FROM v_current THEN
        DELETE FROM visit_team WHERE visit_id = p_visit_id;
        INSERT INTO visit_team (visit_id, employee_id) SELECT p_visit_id, unnest(v_incoming) ON CONFLICT DO NOTHING;
        UPDATE visits SET assigned_driver_id = NULLIF(p_patch->'team_ids'->>0, '')::bigint, team_rev = team_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  -- Catalog path: services chosen from the catalog. Replace + bump ONLY on a real change.
  IF p_patch ? 'service_line_item_ids' THEN
    SELECT array_agg(x::bigint) INTO v_ids FROM jsonb_array_elements_text(p_patch->'service_line_item_ids') AS x;
    IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
      RAISE EXCEPTION 'edit_calendar_visit: at least one service is required';
    END IF;
    DECLARE v_inc text[]; v_cur text[]; v_prev_desc jsonb;
    BEGIN
      -- snapshot existing descriptions (name -> note) BEFORE any delete, to carry forward notes the
      -- patch does not explicitly provide (preserves descriptions on a qty/price-only edit).
      SELECT COALESCE(jsonb_object_agg(name, description), '{}'::jsonb) INTO v_prev_desc
        FROM (SELECT DISTINCT ON (name) name, description FROM line_items
              WHERE visit_id = p_visit_id AND NULLIF(btrim(description),'') IS NOT NULL
              ORDER BY name, id) d;
      SELECT array_agg(sig ORDER BY sig) INTO v_inc FROM (
        SELECT s.title || '|' || round(COALESCE((p_patch->'line_item_prices'->s.id::text->>'quantity')::numeric, 1), 3)::text
               || '|' || round(COALESCE((p_patch->'line_item_prices'->s.id::text->>'unit_price')::numeric, s.unit_price, 0), 2)::text
               || '|' || COALESCE(CASE WHEN (p_patch->'line_item_descriptions') ? s.id::text
                                       THEN NULLIF(btrim(p_patch->'line_item_descriptions'->>s.id::text), '')
                                       ELSE NULLIF(btrim(v_prev_desc->>s.title), '') END, '') AS sig
        FROM service_line_items s WHERE s.id = ANY (v_ids)) z;
      SELECT array_agg(sig ORDER BY sig) INTO v_cur FROM (
        SELECT name || '|' || round(quantity,3)::text || '|' || round(unit_price,2)::text
               || '|' || COALESCE(NULLIF(btrim(description),''),'') AS sig
        FROM line_items WHERE visit_id = p_visit_id) z;
      IF v_inc IS DISTINCT FROM v_cur THEN
        DELETE FROM line_items WHERE visit_id = p_visit_id;
        INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
        SELECT p_visit_id, s.title,
          COALESCE(CASE WHEN (p_patch->'line_item_descriptions') ? s.id::text
                        THEN NULLIF(btrim(p_patch->'line_item_descriptions'->>s.id::text), '')
                        ELSE NULLIF(btrim(v_prev_desc->>s.title), '') END, ''),
          COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1),
          COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0),
          COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'unit_price')::numeric, s.unit_price, 0)
            * COALESCE((p_patch->'line_item_prices' -> s.id::text ->> 'quantity')::numeric, 1), false
        FROM service_line_items s WHERE s.id = ANY (v_ids);
        v_primary := v_ids[1];
        SELECT service_type INTO v_stype FROM service_line_items WHERE id = v_primary;
        SELECT bool_or(public.fn_line_item_requires_derm(title)) INTO v_derm FROM service_line_items WHERE id = ANY (v_ids);
        UPDATE visits SET service_line_item_id = v_primary, service_type = v_stype,
          derm_required = v_derm, line_items_rev = line_items_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  -- Arbitrary path: full line list. Replace + bump ONLY on a real change.
  IF p_patch ? 'line_items' THEN
    IF jsonb_typeof(p_patch->'line_items') <> 'array' OR jsonb_array_length(p_patch->'line_items') = 0 THEN
      RAISE EXCEPTION 'edit_calendar_visit: line_items must be a non-empty array';
    END IF;
    DECLARE v_inc text[]; v_cur text[]; v_prev_desc jsonb;
    BEGIN
      SELECT COALESCE(jsonb_object_agg(name, description), '{}'::jsonb) INTO v_prev_desc
        FROM (SELECT DISTINCT ON (name) name, description FROM line_items
              WHERE visit_id = p_visit_id AND NULLIF(btrim(description),'') IS NOT NULL
              ORDER BY name, id) d;
      SELECT array_agg(sig ORDER BY sig) INTO v_inc FROM (
        SELECT (li->>'name') || '|' || round(COALESCE((li->>'quantity')::numeric,1),3)::text
               || '|' || round(COALESCE((li->>'unit_price')::numeric,0),2)::text
               || '|' || COALESCE(CASE WHEN li ? 'description'
                                       THEN NULLIF(btrim(li->>'description'), '')
                                       ELSE NULLIF(btrim(v_prev_desc->>(li->>'name')), '') END, '') AS sig
        FROM jsonb_array_elements(p_patch->'line_items') AS li WHERE COALESCE(li->>'name','') <> '') z;
      SELECT array_agg(sig ORDER BY sig) INTO v_cur FROM (
        SELECT name || '|' || round(quantity,3)::text || '|' || round(unit_price,2)::text
               || '|' || COALESCE(NULLIF(btrim(description),''),'') AS sig
        FROM line_items WHERE visit_id = p_visit_id) z;
      IF v_inc IS DISTINCT FROM v_cur THEN
        DELETE FROM line_items WHERE visit_id = p_visit_id;
        INSERT INTO line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
        SELECT p_visit_id, li->>'name',
          COALESCE(CASE WHEN li ? 'description'
                        THEN NULLIF(btrim(li->>'description'), '')
                        ELSE NULLIF(btrim(v_prev_desc->>(li->>'name')), '') END, ''),
          COALESCE((li->>'quantity')::numeric, 1),
          COALESCE((li->>'unit_price')::numeric, 0),
          COALESCE((li->>'unit_price')::numeric, 0) * COALESCE((li->>'quantity')::numeric, 1),
          COALESCE((li->>'taxable')::boolean, false)
        FROM jsonb_array_elements(p_patch->'line_items') AS li WHERE COALESCE(li->>'name','') <> '';
        SELECT s.id, s.service_type INTO v_primary, v_stype
        FROM jsonb_array_elements(p_patch->'line_items') WITH ORDINALITY AS t(li, ord)
        JOIN service_line_items s ON s.code = split_part(t.li->>'name', ' - ', 1)
        ORDER BY t.ord LIMIT 1;
        SELECT bool_or(public.fn_line_item_requires_derm(li->>'name')) INTO v_derm
        FROM jsonb_array_elements(p_patch->'line_items') AS li;
        UPDATE visits SET
          service_line_item_id = COALESCE(v_primary, service_line_item_id),
          service_type = COALESCE(v_stype, service_type),
          derm_required = v_derm,
          line_items_rev = line_items_rev + 1 WHERE id = p_visit_id;
      END IF;
    END;
  END IF;

  SELECT * INTO v_visit FROM visits WHERE id = p_visit_id;
  RETURN v_visit;
END;
$function$
;

-- ---------------------------------------------------------------------------------------------
-- PART 5. PostgREST schema reload, so the app can call the new RPCs immediately.
-- ---------------------------------------------------------------------------------------------
NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------------------------
-- VERIFY. Every assertion carries a control. A guard that refuses nothing and a guard that
-- refuses everything both look "applied"; only a paired positive/negative result separates them.
-- ---------------------------------------------------------------------------------------------
DO $verify$
DECLARE
  v_n int; v_j jsonb; v_before bigint; v_after bigint;
  v_clash_start timestamptz; v_free_start timestamptz;
  v_stored bigint; v_effective bigint;
  v_fired boolean; v_end timestamptz; v_ok boolean;
BEGIN
  SELECT count(*) INTO v_before FROM public.visits;

  -- 1. objects + grants. anon must NOT hold EXECUTE (this app is authenticated-only).
  IF NOT has_function_privilege('authenticated', 'public.fn_check_visit_clash(timestamptz,bigint,bigint[],bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'ops.fn_check_visit_clash(timestamptz,bigint,bigint[],bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: authenticated cannot execute fn_check_visit_clash';
  END IF;
  IF has_function_privilege('anon', 'public.fn_check_visit_clash(timestamptz,bigint,bigint[],bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: anon holds EXECUTE on fn_check_visit_clash';
  END IF;

  -- 2. THE MUTATION CONTROL FOR THE WHOLE DESIGN. Visit 6997 (032-LG, 2026-09-07 08:00 ET) must
  --    have a NULL stored vehicle_id while the Calendar resolves a real truck for it. If these ever
  --    become equal this assertion is no longer testing anything and must be re-pointed.
  SELECT v.vehicle_id INTO v_stored     FROM public.visits v            WHERE v.id = 6997;
  SELECT cv.vehicle_id INTO v_effective FROM ops.v_calendar_visit cv    WHERE cv.id = 6997;
  IF v_stored IS NOT NULL OR v_effective IS NULL THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: fixture 6997 no longer demonstrates stored(%) vs effective(%)', v_stored, v_effective;
  END IF;

  -- 3. POSITIVE CONTROL: the one real clash in the estate must be DETECTED, via the effective truck.
  SELECT cv.start_at INTO v_clash_start FROM ops.v_calendar_visit cv WHERE cv.id = 6997;
  v_j := public.fn_check_visit_clash(v_clash_start, v_effective, NULL, 6997);
  IF jsonb_array_length(v_j -> 'truck') = 0 THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: the known 2026-09-07 Moises clash was NOT detected -> %', v_j;
  END IF;

  -- 4. NEGATIVE CONTROL: a slot nothing occupies must come back empty on BOTH arms. Without this,
  --    a function that returns every visit would pass check 3.
  v_free_start := timestamptz '2027-01-15 15:00:00+00';
  v_j := public.fn_check_visit_clash(v_free_start, v_effective, ARRAY[1::bigint], NULL);
  IF jsonb_array_length(v_j -> 'truck') <> 0 OR jsonb_array_length(v_j -> 'driver') <> 0 THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: a free slot reported a clash -> %', v_j;
  END IF;

  -- 5. The DRIVER arm must actually work, or "advisory" is a promise with no implementation.
  -- Look for visit 8001's driver AT 8001's own time, excluding a DIFFERENT visit. Excluding 8001
  -- itself would remove the only row that driver has in the window, and the arm would report empty
  -- for a reason that says nothing about whether it works. (That mistake failed this VERIFY once.)
  v_j := public.fn_check_visit_clash(
           (SELECT cv.start_at FROM ops.v_calendar_visit cv WHERE cv.id = 8001), NULL,
           (SELECT ARRAY[cv.assigned_driver_id] FROM ops.v_calendar_visit cv WHERE cv.id = 8001), 6997);
  IF jsonb_array_length(v_j -> 'driver') = 0 THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: the driver arm found nothing for a driver known to be booked';
  END IF;

  -- 6. DRIFT DETECTOR: fn_effective_vehicle_for_job must agree with the view wherever their inputs
  --    overlap (no stored vehicle, no visit-level line items). A disagreement means the view moved.
  SELECT count(*) INTO v_n
    FROM ops.v_calendar_visit cv
    JOIN public.visits v ON v.id = cv.id
   WHERE v.vehicle_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM public.line_items li WHERE li.visit_id = v.id)
     AND public.fn_effective_vehicle_for_job(v.vehicle_id, v.job_id) IS DISTINCT FROM cv.vehicle_id;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'VERIFY 6 FAILED: fn_effective_vehicle_for_job disagrees with ops.v_calendar_visit on % rows', v_n;
  END IF;

  -- 7. THE GUARD FIRES. Creating onto the occupied Moises slot must raise 22023 visit_truck_clash.
  --    The RAISE rolls its own subtransaction back, so nothing is written.
  v_fired := false;
  BEGIN
    PERFORM public.create_calendar_visit(
      p_client_id => 295, p_job_id => 646, p_service_line_item_ids => ARRAY[22::bigint],
      p_visit_date => '2026-09-07', p_start_at => v_clash_start, p_vehicle_id => v_effective);
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'visit_truck_clash:%' THEN v_fired := true; ELSE RAISE; END IF;
  END;
  IF NOT v_fired THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: create_calendar_visit accepted a clashing truck slot';
  END IF;

  -- 8. THE GUARD DOES NOT OVER-FIRE, AND end_at DEFAULTS TO ONE HOUR. Both in one probe, rolled
  --    back by a deliberate RAISE. PL/pgSQL variable assignments survive the subtransaction abort,
  --    which is what lets the result be read after the rollback.
  v_ok := false;
  BEGIN
    SELECT (public.create_calendar_visit(
      p_client_id => 295, p_job_id => 646, p_service_line_item_ids => ARRAY[22::bigint],
      p_visit_date => '2027-01-15', p_start_at => v_free_start, p_vehicle_id => v_effective)).end_at
      INTO v_end;
    v_ok := (v_end = v_free_start + interval '1 hour');
    RAISE EXCEPTION 'PROBE_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'PROBE_ROLLBACK' THEN RAISE; END IF;
  END;
  IF NOT v_ok THEN
    RAISE EXCEPTION 'VERIFY 8 FAILED: a free slot was refused, or end_at did not default to +1h (got %)', v_end;
  END IF;

  -- 9. THE EDIT GUARD FIRES. Moving visit 6997 onto 8001's truck+time must be refused.
  v_fired := false;
  BEGIN
    PERFORM public.edit_calendar_visit(6997, jsonb_build_object(
      'start_at', (SELECT cv.start_at FROM ops.v_calendar_visit cv WHERE cv.id = 8001)));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'visit_truck_clash:%' THEN v_fired := true; ELSE RAISE; END IF;
  END;
  IF NOT v_fired THEN
    RAISE EXCEPTION 'VERIFY 9 FAILED: edit_calendar_visit accepted a move onto an occupied truck slot';
  END IF;

  -- 10. NOTHING WAS WRITTEN by any of the probes above.
  SELECT count(*) INTO v_after FROM public.visits;
  IF v_after <> v_before THEN
    RAISE EXCEPTION 'VERIFY 10 FAILED: visits went % -> %, a probe committed', v_before, v_after;
  END IF;

  RAISE NOTICE 'VERIFY OK: 10 assertions, guard fires on truck, does not over-fire, driver advisory works, nothing written';
END
$verify$;

COMMIT;
