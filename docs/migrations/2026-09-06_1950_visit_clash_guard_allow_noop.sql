-- 2026-09-06_1950_visit_clash_guard_allow_noop.sql
--
-- WHY
-- ---
-- Fred, 2026-09-06: *"when clicking on a visit and it opens the drawer, i need you to test the
-- feature of selecting a Truck, which seems to not be working."*
--
-- 🛑 IT WAS MY OWN GUARD FROM `2026-09-06_1833`, AND IT WAS REFUSING A NO-OP.
--
-- `ops.v_calendar_visit` shows an EFFECTIVE truck: COALESCE(stored, visit line-item default,
-- job line-item default). So a visit can DISPLAY a truck it does not store. Measured:
--
--   visit 6997  032-LG   assigned_vehicle_id = NULL   effective = 1 (Moises)   source = 'default'
--   visit 8001  106-ALC  assigned_vehicle_id = 1      effective = 1 (Moises)   source = 'assigned'
--
-- Those two are the estate's one real clash. The Calendar already draws BOTH on Moises.
-- So an operator opening 032-LG and choosing **Moises** -- the truck the chip already shows -- was
-- told `visit_truck_clash: truck Moises already has 106-ALC at 08:30 AM` and the save failed.
--
-- **Pinning the truck a visit already displays changes nothing observable and cannot create a clash
-- that did not already exist.** The guard was measuring the state of the world rather than the
-- effect of the edit. Refusing it is what made "selecting a Truck" look broken.
--
-- THE FIX: refuse only when the edit actually MOVES the visit -- a different effective truck, or a
-- different start time. A patch that resolves to the values already in force is never refused.
--
-- SCOPE: `edit_calendar_visit` only. `create_calendar_visit` is unchanged and correct: a create
-- always adds a visit that was not there, so it can never be a no-op.
--
-- ⚠ THE CLASH ITSELF IS NOT DISMISSED. `fn_check_visit_clash` still reports that pair, so the
-- pre-check the app will call still warns. This only stops the WRITE being blocked when the write
-- changes nothing.
--
-- ⚠ STILL OPEN AND NOT FIXED HERE: the drawer does not surface the refusal at all. When the guard
-- legitimately fires the operator sees the save do nothing, with no message. That is an app change,
-- and it is why a correct refusal is indistinguishable from a broken control today.
--
-- Body copied from `pg_get_functiondef` and spliced; diff removes exactly the three lines rewritten
-- (the DECLARE, the `ELSE` arm, and the `IF` condition). Signature unchanged, so the `ops` wrapper
-- needs no recreation.

BEGIN;

CREATE OR REPLACE FUNCTION public.edit_calendar_visit(p_visit_id bigint, p_patch jsonb)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_visit visits; v_ids bigint[]; v_primary bigint; v_stype text; v_derm boolean;
        v_new_start timestamptz; v_new_vehicle bigint; v_clash jsonb; v_old_vehicle bigint;
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
  SELECT cv.vehicle_id INTO v_old_vehicle FROM ops.v_calendar_visit cv WHERE cv.id = p_visit_id;
  v_new_vehicle := CASE WHEN p_patch ? 'vehicle_id' THEN (p_patch->>'vehicle_id')::bigint
                        ELSE v_old_vehicle END;
  -- Refuse ONLY when the edit actually MOVES the visit onto a different truck or a different time.
  -- The Calendar shows an EFFECTIVE truck, so a visit can already display a truck it does not store
  -- (visit 6997 / 032-LG shows Moises with vehicle_source='default'). Pinning that same truck changes
  -- nothing anyone can see and cannot create a clash that did not already exist -- but the first
  -- version of this guard refused it, which is exactly what made "selecting a Truck" look broken.
  IF (p_patch ? 'start_at' OR p_patch ? 'vehicle_id')
     AND v_new_start IS NOT NULL AND v_new_vehicle IS NOT NULL
     AND (v_new_vehicle IS DISTINCT FROM v_old_vehicle
          OR v_new_start IS DISTINCT FROM v_visit.start_at) THEN
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

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------------------------
-- VERIFY. The no-op must now pass, and every REAL clash must still be refused. Both directions,
-- because a guard that stops refusing everything looks identical to a guard that was fixed.
-- ---------------------------------------------------------------------------------------------
DO $verify$
DECLARE
  v_before bigint; v_after bigint; v_eff bigint; v_other_start timestamptz;
  v_noop_ok boolean := false; v_real_refused boolean := false; v_time_refused boolean := false;
  v_stored bigint;
BEGIN
  SELECT count(*) INTO v_before FROM public.visits;

  -- the fixture must still be the shape this migration is about
  SELECT cv.vehicle_id INTO v_eff FROM ops.v_calendar_visit cv WHERE cv.id = 6997;
  SELECT v.vehicle_id  INTO v_stored FROM public.visits v WHERE v.id = 6997;
  IF v_eff IS NULL OR v_stored IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 0 FAILED: 6997 no longer shows a defaulted truck (stored=%, effective=%)', v_stored, v_eff;
  END IF;
  SELECT cv.start_at INTO v_other_start FROM ops.v_calendar_visit cv WHERE cv.id = 8001;

  -- 1. THE FIX: pinning the truck the visit ALREADY displays must now be ACCEPTED.
  BEGIN
    BEGIN
      PERFORM public.edit_calendar_visit(6997, jsonb_build_object('vehicle_id', v_eff));
      v_noop_ok := true;
      RAISE EXCEPTION 'PROBE_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'PROBE_ROLLBACK' THEN RAISE; END IF;
    END;
  END;
  IF NOT v_noop_ok THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: assigning the already-effective truck is still refused';
  END IF;

  -- 2. REGRESSION CONTROL: moving 8001 onto a DIFFERENT visit's slot must STILL be refused.
  --    Without this, "the guard stopped refusing" would pass check 1 just as well.
  BEGIN
    PERFORM public.edit_calendar_visit(8001, jsonb_build_object(
      'start_at', (SELECT cv.start_at FROM ops.v_calendar_visit cv WHERE cv.id = 6997)));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'visit_truck_clash:%' THEN v_time_refused := true; ELSE RAISE; END IF;
  END;
  IF NOT v_time_refused THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: moving a visit onto an occupied truck slot is no longer refused';
  END IF;

  -- 3. A genuinely NEW clashing assignment must still be refused: take a visit that does NOT
  --    currently resolve to Moises and try to put it on Moises at the occupied time.
  DECLARE v_victim bigint;
  BEGIN
    SELECT cv.id INTO v_victim FROM ops.v_calendar_visit cv
     WHERE cv.start_at = v_other_start AND cv.id NOT IN (6997, 8001)
       AND cv.vehicle_id IS DISTINCT FROM v_eff
       AND cv.visit_status NOT IN ('cancelled','completed','skipped')
     LIMIT 1;
    IF v_victim IS NOT NULL THEN
      BEGIN
        PERFORM public.edit_calendar_visit(v_victim, jsonb_build_object('vehicle_id', v_eff));
      EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE 'visit_truck_clash:%' THEN v_real_refused := true; ELSE RAISE; END IF;
      END;
      IF NOT v_real_refused THEN
        RAISE EXCEPTION 'VERIFY 3 FAILED: visit % was allowed onto an occupied truck', v_victim;
      END IF;
      RAISE NOTICE 'VERIFY 3 OK on victim %', v_victim;
    ELSE
      RAISE NOTICE 'VERIFY 3 SKIPPED: no third visit shares that minute (check 2 still covers the real case)';
    END IF;
  END;

  -- 4. nothing was written
  SELECT count(*) INTO v_after FROM public.visits;
  IF v_after <> v_before THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: visits % -> %', v_before, v_after;
  END IF;
  IF (SELECT vehicle_id FROM public.visits WHERE id = 6997) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: the no-op probe committed a vehicle_id onto 6997';
  END IF;

  RAISE NOTICE 'VERIFY OK: no-op accepted, real clashes still refused, nothing written';
END
$verify$;

COMMIT;
