-- ============================================================================
-- 2026-09-08_0400_visit_clash_guard_kill_switch.sql
--
-- Turn the truck-clash REFUSAL off, behind a flag, without deleting the guard.
--
-- Fred, 2026-09-08: "i need that to be turned off, for now. Document it so we know how to
-- do it again, but disable it, it seems Diego can't work with it."
--
-- The guard was built 2026-09-06 (_1833, _1950, _2210) from Fred's own ask: "we can't have
-- like 2 visits at the same time for the same Truck". In practice it blocks dispatch faster
-- than it prevents mistakes, so it goes OFF NOW and stays re-enablable in one UPDATE.
--
-- ============================================================================
-- HOW TO TURN IT BACK ON. One statement, no deploy, takes effect immediately:
--
--     UPDATE public.app_config SET value = 'true', updated_at = now()
--      WHERE key = 'visit_clash_guard_enabled';
--
-- And to turn it off again:
--
--     UPDATE public.app_config SET value = 'false', updated_at = now()
--      WHERE key = 'visit_clash_guard_enabled';
--
-- Check the current state with:
--     SELECT public.fn_visit_clash_guard_enabled();
--
-- No app publish, no edge-function deploy and no migration is needed either way. The flag
-- is read on every call, so a flip applies to the next visit anyone drags or saves.
-- ============================================================================
--
-- 🛑 WHY TWO FUNCTIONS ARE GATED AND NOT ONE. There are TWO independent refusal points,
--    and gating only the obvious one would have left creation still blocked:
--
--      public.create_calendar_visit   calls the DETECTOR directly and RAISES on its own
--                                     (`IF jsonb_array_length(v_clash->'truck') > 0`)
--      public.fn_visit_edit_clash     returns {refuse:true}, and THREE callers act on it:
--                                       - public.edit_calendar_visit (raises 22023)
--                                       - the save-calendar-visit edge fn (pre-flight,
--                                         before the Jobber push)
--                                       - the Calendar's drag-and-drop guard
--
--    So gating `fn_visit_edit_clash` disables edit, drag-drop AND the edge-function
--    pre-flight in one place, and `create_calendar_visit` needs its own gate. Both are in
--    this migration. Verified below by exercising both, plus a control that re-enables the
--    flag and proves the refusal comes straight back.
--
-- 🛑 THE DETECTOR IS NOT TOUCHED. public.fn_check_visit_clash still runs and still reports
--    what it finds; `fn_visit_edit_clash` still returns the populated `truck` and `driver`
--    arrays, now with reason 'guard_disabled' instead of 'visit_truck_clash'. So clashes
--    stay MEASURABLE while nothing is blocked, and re-enabling needs no re-derivation.
--    A consumer that keys on `refuse` stops blocking; one that reads `truck` can still warn.
--
-- ⚠ THE DRIVER/TEAM SIGNAL WAS ALWAYS ADVISORY and is unchanged: it never blocked anything.
--
-- ⚠ FAIL-SAFE DEFAULT: fn_visit_clash_guard_enabled() returns TRUE when the config row is
--    MISSING. A deleted row therefore restores the guard rather than silently leaving a
--    safety check off forever. That means the row must EXIST with 'false' to keep it off,
--    which the VERIFY asserts.
--
-- ⚠ WHAT THIS DOES NOT DO: it does not clean up existing double-bookings and it does not
--    stop Jobber creating them. It was always prevention, not cleanup.
--
-- Audit: N/A (one config row + two function replaces).
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. the flag, and the one place it is read
-- ---------------------------------------------------------------------------
insert into public.app_config (key, value, updated_at)
values ('visit_clash_guard_enabled', 'false', now())
on conflict (key) do update set value = 'false', updated_at = now();

create or replace function public.fn_visit_clash_guard_enabled()
returns boolean
language sql
stable
set search_path to ''
as $fn$
  -- Fail SAFE: a missing row means ENABLED, so deleting the row cannot silently leave the
  -- guard off. Anything other than the exact string 'false' counts as enabled.
  select coalesce(
           (select lower(btrim(c.value)) <> 'false'
              from public.app_config c
             where c.key = 'visit_clash_guard_enabled'),
           true);
$fn$;

comment on function public.fn_visit_clash_guard_enabled() is
  'Is the truck-clash REFUSAL active? Reads public.app_config.visit_clash_guard_enabled. '
  'Set to false 2026-09-08 at Fred''s request (it was blocking dispatch). Flip the row to '
  'true to restore blocking immediately, with no deploy. Returns TRUE when the row is '
  'missing, so a deleted row restores the guard rather than disabling it silently. '
  'Read by public.fn_visit_edit_clash and public.create_calendar_visit, which are the two '
  'independent refusal points.';

-- ---------------------------------------------------------------------------
-- 2. gate the EDIT path (also covers the edge-fn pre-flight and drag-and-drop)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_visit_edit_clash(p_visit_id bigint, p_patch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  -- ===================================================================================
  -- 2026-09-08 KILL SWITCH. Fred: "i need that to be turned off, for now ... it seems
  -- Diego can't work with it." The DETECTOR above still runs and its findings are still
  -- returned, so the clash stays MEASURABLE and the app can still choose to warn; only
  -- the REFUSAL is suppressed. Flip public.app_config.visit_clash_guard_enabled back to
  -- 'true' to restore blocking. This single branch also disables the edge function's
  -- pre-flight check and the drag-and-drop guard, because both read `refuse` from here.
  -- ===================================================================================
  IF NOT public.fn_visit_clash_guard_enabled() THEN
    RETURN jsonb_build_object(
      'refuse',  false,
      'reason',  'guard_disabled',
      'message', format('clash detected but the guard is OFF: truck %s already has %s at %s',
                   COALESCE((SELECT name FROM vehicles WHERE id = v_new_vehicle), v_new_vehicle::text),
                   v_clash -> 'truck' -> 0 ->> 'client_code',
                   v_clash -> 'truck' -> 0 ->> 'start_local'),
      'truck',   v_clash -> 'truck',
      'driver',  v_clash -> 'driver');
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
$function$

;

-- ---------------------------------------------------------------------------
-- 3. gate the CREATE path, which raises on its own
-- ---------------------------------------------------------------------------
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

commit;

-- ---------------------------------------------------------------------------
-- VERIFY. Exercises BOTH refusal points and, critically, flips the flag back ON to prove
-- the guard still works when re-enabled. Without that control, "nothing refused" passes
-- just as well if the guard were broken rather than merely switched off.
--
-- Fixture: moving visit 6575 (013-DIM) onto truck Cloggy at 2026-09-08 14:00Z, where 6997
-- (032-LG) already sits. Measured BEFORE this migration, that returned refuse:true.
-- ---------------------------------------------------------------------------
do $verify$
declare
  v_mover  bigint := 6575;
  v_patch  jsonb;
  v_out    jsonb;
  v_slot   timestamptz;
  v_truck  bigint;
begin
  select start_at, vehicle_id into v_slot, v_truck
    from ops.v_calendar_visit where id = 6997;
  if v_slot is null or v_truck is null then
    raise exception 'VERIFY 0 FAILED: fixture visit 6997 has no slot/truck; pick a new fixture';
  end if;
  v_patch := jsonb_build_object('start_at', v_slot, 'vehicle_id', v_truck);

  -- 1. the flag is OFF and the reader agrees
  if public.fn_visit_clash_guard_enabled() then
    raise exception 'VERIFY 1 FAILED: guard still reports ENABLED after the migration';
  end if;

  -- 2. the edit path no longer refuses, and STILL reports what it found
  v_out := public.fn_visit_edit_clash(v_mover, v_patch);
  if (v_out->>'refuse')::boolean then
    raise exception 'VERIFY 2 FAILED: edit path still refuses with the guard off: %', v_out;
  end if;
  if v_out->>'reason' <> 'guard_disabled' then
    raise exception 'VERIFY 2b FAILED: expected reason guard_disabled, got %', v_out->>'reason';
  end if;
  -- the detector must NOT have been silenced: the clash is still visible
  if jsonb_array_length(v_out->'truck') = 0 then
    raise exception 'VERIFY 2c FAILED: detector was silenced; clash is no longer measurable';
  end if;

  -- 3. CONTROL. Re-enable and prove the refusal returns. This is the whole point of the
  --    flag, and it is what makes "turn it back on" a documented, tested operation.
  update public.app_config set value = 'true' where key = 'visit_clash_guard_enabled';
  if not public.fn_visit_clash_guard_enabled() then
    raise exception 'VERIFY 3 FAILED: flag flipped to true but the reader still says disabled';
  end if;
  v_out := public.fn_visit_edit_clash(v_mover, v_patch);
  if not (v_out->>'refuse')::boolean then
    raise exception 'VERIFY 3b FAILED (control): guard re-enabled but the edit path does not refuse. The guard is BROKEN, not merely off';
  end if;
  if v_out->>'reason' <> 'visit_truck_clash' then
    raise exception 'VERIFY 3c FAILED: re-enabled reason is %, expected visit_truck_clash', v_out->>'reason';
  end if;

  -- 4. put it back OFF, which is the state Fred asked for
  update public.app_config set value = 'false', updated_at = now()
   where key = 'visit_clash_guard_enabled';
  if public.fn_visit_clash_guard_enabled() then
    raise exception 'VERIFY 4 FAILED: could not restore the disabled state';
  end if;

  -- 5. the create path is gated too, checked at the source rather than by creating a visit
  if pg_get_functiondef('public.create_calendar_visit'::regproc)
       !~ 'fn_visit_clash_guard_enabled' then
    raise exception 'VERIFY 5 FAILED: create_calendar_visit is NOT gated; creation would still be blocked';
  end if;

  -- 6. the fail-safe default. Anything but the literal 'false' must read as ENABLED.
  update public.app_config set value = 'no' where key = 'visit_clash_guard_enabled';
  if not public.fn_visit_clash_guard_enabled() then
    raise exception 'VERIFY 6 FAILED: a non-false value read as disabled; the flag is not fail-safe';
  end if;
  update public.app_config set value = 'false', updated_at = now()
   where key = 'visit_clash_guard_enabled';

  raise notice 'VERIFY ok: guard OFF; edit path returns refuse=false reason=guard_disabled with the clash still reported; re-enabling restored the refusal; create path gated; fail-safe default holds';
end
$verify$;
