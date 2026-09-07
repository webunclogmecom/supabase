-- 2026-09-06_2210_visit_clash_check_before_jobber_push.sql
--
-- WHY
-- ---
-- 🛑 THE TRUCK-CLASH GUARD FROM `2026-09-06_1833` WAS IN THE WRONG PLACE, AND IT CAUSED THE EXACT
--    DIVERGENCE IT WAS MEANT TO PREVENT. Found by running the live app, not by reading the code.
--
-- The Calendar drawer's Save does NOT call `edit_calendar_visit` directly. For any field Jobber
-- owns it goes through the `save-calendar-visit` EDGE FUNCTION, which is a deliberate saga:
--
--     1. PUSH to Jobber  ->  2. VERIFY by re-reading Jobber  ->  3. COMMIT here
--                                                                (edit_calendar_visit_verified
--                                                                 -> edit_calendar_visit)
--
-- The guard lives in step 3. So when it fired, Jobber had ALREADY been written and verified, and
-- the function fell into its own acknowledged residual branch:
--
--     `Jobber was updated but saving here failed: ${werr.message}.
--      The two are now out of step -- check the visit in Jobber.`
--
-- ⚠ THAT MESSAGE IS ACCURATE, NOT BOILERPLATE. Measured on 2026-09-06 by moving visit 8001
--   (106-ALC) onto the occupied 08:00 Moises slot from the published app:
--
--       Jobber   2026-09-07T12:00:00Z  = 08:00 ET
--       our DB   2026-09-07T12:30:00Z  = 08:30 ET
--
--   A real divergence on a visit scheduled the next morning. Jobber was restored to 12:30Z/13:30Z
--   and re-read to confirm. `public.visits` was never written: count 2695 before and after.
--
-- ⇒ A REFUSAL THAT ARRIVES AT COMMIT TIME IS NOT A REFUSAL, IT IS A DIVERGENCE. Any guard added to
--   a function that some caller invokes AFTER an external side effect has to be askable BEFORE it.
--
-- WHAT THIS DOES
-- --------------
-- Extracts the whole refusal DECISION into `public.fn_visit_edit_clash(p_visit_id, p_patch)`, a
-- read-only function returning the verdict as jsonb, and makes `edit_calendar_visit` call it
-- instead of deciding inline. The edge function then calls the SAME function in its PRE-FLIGHT
-- section, before the first Jobber mutation, and refuses there.
--
-- ⚠ ONE implementation, two callers -- deliberately. A copy of the no-op exemption inside the edge
--   function would be a second implementation of the subtlest rule in this feature (the rule that
--   pinning an already-effective truck must be allowed), and this codebase has been bitten by
--   duplicated rules repeatedly. The DB guard STAYS as the last line of defence: it must, because
--   it protects `edit_calendar_visit` from every other caller, including the local-only fast path.
--
-- ⚠ NOT CHANGED, AND CORRECT ALREADY: the LOCAL-ONLY fast path. `vehicle_id` and `driver_id` are
--   LOCAL_ONLY in the edge function, so a pure truck change never contacts Jobber and the DB guard
--   refusing it has no external side effect to be out of step with.
--
-- ⚠ The DRIVER arm stays advisory and is NOT enforced here, per Fred 2026-09-06: "hard-refuse on
--   truck, warn on driver". `fn_visit_edit_clash` returns the driver list so the form can warn.
--
-- Body of `edit_calendar_visit` copied from `pg_get_functiondef` and spliced by script; the diff
-- removes exactly the 28-line guard block and adds the 12-line call. Signature unchanged, so the
-- `ops` wrapper needs no recreation.

BEGIN;

-- ---------------------------------------------------------------------------------------------
-- PART 1. The shared decision. Read-only, raises nothing: the CALLER decides what a refusal means.
-- Logic copied verbatim from the guard block it replaces, so it starts byte-equivalent in meaning.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_visit_edit_clash(p_visit_id bigint, p_patch jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_visit       public.visits;
  v_new_start   timestamptz;
  v_old_vehicle bigint;
  v_new_vehicle bigint;
  v_clash       jsonb;
BEGIN
  SELECT * INTO v_visit FROM public.visits WHERE id = p_visit_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('refuse', false, 'reason', 'visit_not_found',
                              'truck', '[]'::jsonb, 'driver', '[]'::jsonb);
  END IF;

  -- Resolve the EFFECTIVE values first, because a patch that changes only the time must still be
  -- checked against the truck the visit already has. When the patch does not set a truck, take the
  -- CALENDAR's effective one (which may be defaulted from line items), not visits.vehicle_id, or
  -- the check is blind to a defaulted truck.
  v_new_start   := CASE WHEN p_patch ? 'start_at'   THEN (p_patch->>'start_at')::timestamptz ELSE v_visit.start_at END;
  SELECT cv.vehicle_id INTO v_old_vehicle FROM ops.v_calendar_visit cv WHERE cv.id = p_visit_id;
  v_new_vehicle := CASE WHEN p_patch ? 'vehicle_id' THEN (p_patch->>'vehicle_id')::bigint
                        ELSE v_old_vehicle END;

  -- Refuse ONLY when the edit actually MOVES the visit onto a different truck or a different time.
  -- The Calendar shows an EFFECTIVE truck, so a visit can already display a truck it does not store
  -- (visit 6997 / 032-LG shows Moises with vehicle_source='default'). Pinning that same truck changes
  -- nothing anyone can see and cannot create a clash that did not already exist -- but the first
  -- version of this guard refused it, which is exactly what made "selecting a Truck" look broken.
  IF NOT ((p_patch ? 'start_at' OR p_patch ? 'vehicle_id')
          AND v_new_start IS NOT NULL AND v_new_vehicle IS NOT NULL
          AND (v_new_vehicle IS DISTINCT FROM v_old_vehicle
               OR v_new_start IS DISTINCT FROM v_visit.start_at)) THEN
    RETURN jsonb_build_object('refuse', false, 'reason', 'no_move',
                              'truck', '[]'::jsonb, 'driver', '[]'::jsonb);
  END IF;

  v_clash := public.fn_check_visit_clash(v_new_start, v_new_vehicle, NULL, p_visit_id);

  IF jsonb_array_length(v_clash -> 'truck') = 0 THEN
    RETURN jsonb_build_object('refuse', false, 'reason', 'clear',
                              'truck', v_clash -> 'truck', 'driver', v_clash -> 'driver');
  END IF;

  RETURN jsonb_build_object(
    'refuse',  true,
    'reason',  'visit_truck_clash',
    'message', format('visit_truck_clash: truck %s already has %s at %s',
                 COALESCE((SELECT name FROM vehicles WHERE id = v_new_vehicle), v_new_vehicle::text),
                 v_clash -> 'truck' -> 0 ->> 'client_code',
                 v_clash -> 'truck' -> 0 ->> 'start_local'),
    'hint',    'Pick another time or another truck. A visit lasts one hour.',
    'truck',   v_clash -> 'truck',
    'driver',  v_clash -> 'driver');
END
$fn$;

-- ---------------------------------------------------------------------------------------------
-- PART 2. edit_calendar_visit -- guard block replaced by a call to PART 1. Nothing else touched.
-- ---------------------------------------------------------------------------------------------
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

  -- ONE implementation of the refusal decision, shared with the pre-flight check in the
  -- `save-calendar-visit` edge function. It used to live here as inline SQL; the edge function then
  -- had no way to ask the question BEFORE pushing to Jobber, so the refusal arrived at COMMIT time,
  -- after Jobber had already been written and verified -- turning a clash into a real Jobber/DB
  -- divergence. Measured live 2026-09-06 on visit 8001: Jobber 08:00, our DB 08:30.
  -- The no-op exemption and the effective-truck resolution now live in fn_visit_edit_clash.
  v_clash := public.fn_visit_edit_clash(p_visit_id, p_patch);
  IF COALESCE((v_clash ->> 'refuse')::boolean, false) THEN
    RAISE EXCEPTION USING
      ERRCODE = '22023',
      MESSAGE = v_clash ->> 'message',
      HINT    = v_clash ->> 'hint';
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
$function$;

-- ---------------------------------------------------------------------------------------------
-- PART 3. ops wrapper + grants. The app's client speaks the `ops` schema; the edge function uses
-- the service role on `public`. anon gets nothing: this Calendar is authenticated-only.
-- ⚠ A bare CREATE leaves EXECUTE with PUBLIC, which is not the same as granting it by name.
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ops.fn_visit_edit_clash(p_visit_id bigint, p_patch jsonb)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $w$ SELECT public.fn_visit_edit_clash(p_visit_id, p_patch) $w$;

REVOKE ALL ON FUNCTION public.fn_visit_edit_clash(bigint, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION ops.fn_visit_edit_clash(bigint, jsonb)    FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fn_visit_edit_clash(bigint, jsonb) FROM anon;
REVOKE ALL ON FUNCTION ops.fn_visit_edit_clash(bigint, jsonb)    FROM anon;
GRANT EXECUTE ON FUNCTION public.fn_visit_edit_clash(bigint, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION ops.fn_visit_edit_clash(bigint, jsonb)    TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';

-- ---------------------------------------------------------------------------------------------
-- VERIFY. The refactor must be BEHAVIOUR-PRESERVING, so every assertion is paired: the same three
-- cases that mattered before must still give the same three answers, and the new function must
-- agree with the guard rather than merely existing.
-- ---------------------------------------------------------------------------------------------
DO $verify$
DECLARE
  v_before bigint; v_after bigint;
  v_eff bigint; v_other_start timestamptz; v_j jsonb;
  v_noop_ok boolean := false; v_move_refused boolean := false;
BEGIN
  -- ⚠ VERIFY 6 calls edit_calendar_visit for real (rolled back by a deliberate RAISE), and
  -- vehicle_id is a watched field, so trg_push_visit_update would arm a Jobber push. The rollback
  -- would discard it, but suppressing it transaction-locally means the probe cannot queue an
  -- external side effect at all. Belt and braces on the exact hazard this migration is about.
  PERFORM set_config('app.suppress_jobber_push', 'on', true);

  SELECT count(*) INTO v_before FROM public.visits;

  -- 0. grants: authenticated yes, anon no. A function nobody can call passes every other check.
  IF NOT has_function_privilege('authenticated','public.fn_visit_edit_clash(bigint,jsonb)','EXECUTE')
     OR NOT has_function_privilege('authenticated','ops.fn_visit_edit_clash(bigint,jsonb)','EXECUTE')
     OR NOT has_function_privilege('service_role','public.fn_visit_edit_clash(bigint,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 0 FAILED: fn_visit_edit_clash is not executable by its callers';
  END IF;
  IF has_function_privilege('anon','public.fn_visit_edit_clash(bigint,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 0 FAILED: anon holds EXECUTE on fn_visit_edit_clash';
  END IF;

  -- 1. the fixture must still be the shape this whole feature is about: 6997 DISPLAYS a truck it
  --    does not STORE. If that ever stops being true, checks 2 and 3 test nothing.
  SELECT cv.vehicle_id INTO v_eff FROM ops.v_calendar_visit cv WHERE cv.id = 6997;
  IF v_eff IS NULL OR (SELECT vehicle_id FROM public.visits WHERE id = 6997) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 1 FAILED: 6997 no longer demonstrates stored-vs-effective';
  END IF;
  SELECT cv.start_at INTO v_other_start FROM ops.v_calendar_visit cv WHERE cv.id = 8001;

  -- 2. NO-OP: pinning the truck 6997 already displays must NOT refuse. This is the rule that broke
  --    truck selection once already, and it is the one a duplicated implementation would lose.
  v_j := public.fn_visit_edit_clash(6997, jsonb_build_object('vehicle_id', v_eff));
  IF COALESCE((v_j ->> 'refuse')::boolean, false) THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: the no-op is refused again -> %', v_j;
  END IF;
  IF v_j ->> 'reason' <> 'no_move' THEN
    RAISE EXCEPTION 'VERIFY 2 FAILED: no-op took the wrong branch (%)', v_j ->> 'reason';
  END IF;

  -- 3. REAL MOVE: moving 6997 onto 8001's occupied time must refuse, and must carry a message and
  --    a hint. Without this, "it stopped refusing everything" would pass check 2 just as well.
  v_j := public.fn_visit_edit_clash(6997, jsonb_build_object('start_at', v_other_start));
  IF NOT COALESCE((v_j ->> 'refuse')::boolean, false) THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: a real move onto an occupied truck was allowed -> %', v_j;
  END IF;
  IF v_j ->> 'message' NOT LIKE 'visit_truck_clash:%' OR COALESCE(v_j ->> 'hint','') = '' THEN
    RAISE EXCEPTION 'VERIFY 3 FAILED: refusal is missing its message or hint -> %', v_j;
  END IF;

  -- 4. FREE SLOT: a time nothing occupies must come back clear, or check 3 is just "always refuse".
  v_j := public.fn_visit_edit_clash(6997, jsonb_build_object('start_at', timestamptz '2027-01-15 15:00:00+00'));
  IF COALESCE((v_j ->> 'refuse')::boolean, false) THEN
    RAISE EXCEPTION 'VERIFY 4 FAILED: a free slot was refused -> %', v_j;
  END IF;

  -- 5. THE GUARD STILL ENFORCES IT. The decision function agreeing is not the same as
  --    edit_calendar_visit still raising: PART 2 could have spliced in a call it never checks.
  BEGIN
    PERFORM public.edit_calendar_visit(6997, jsonb_build_object('start_at', v_other_start));
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'visit_truck_clash:%' THEN v_move_refused := true; ELSE RAISE; END IF;
  END;
  IF NOT v_move_refused THEN
    RAISE EXCEPTION 'VERIFY 5 FAILED: edit_calendar_visit no longer refuses a real clash';
  END IF;

  -- 6. AND IT STILL ACCEPTS THE NO-OP, end to end. Rolled back by a deliberate RAISE.
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
    RAISE EXCEPTION 'VERIFY 6 FAILED: edit_calendar_visit refuses the no-op again';
  END IF;

  -- 7. nothing was written by any probe above.
  SELECT count(*) INTO v_after FROM public.visits;
  IF v_after <> v_before THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: visits % -> %', v_before, v_after;
  END IF;
  IF (SELECT vehicle_id FROM public.visits WHERE id = 6997) IS NOT NULL THEN
    RAISE EXCEPTION 'VERIFY 7 FAILED: a probe committed a vehicle_id onto 6997';
  END IF;

  RAISE NOTICE 'VERIFY OK: decision extracted, no-op still allowed, real clash still refused, nothing written';
END
$verify$;

COMMIT;
