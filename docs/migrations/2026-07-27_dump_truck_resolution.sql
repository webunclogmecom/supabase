-- 2026-07-27  DUMP: stamp the TRUCK on a dump visit at creation time (accurate-or-silent)
--
-- WHY (Fred 2026-07-27): the #dump-visits Slack alert shows Time + Team but never Truck. Root cause is NOT
-- the alert renderer (it already prints `*Truck:* <vehicles.name>` the instant visits.vehicle_id is set):
-- `public.create_dump_visit` has no vehicle parameter and passes a hardcoded NULL into
-- `create_calendar_visit`'s 11th positional argument (p_vehicle_id). Measured: 60 of 62 app-created dumps
-- have vehicle_id IS NULL; the 2 exceptions were backfilled by the hourly `derive-visit-vehicle-id` cron a
-- MEDIAN 21.9 hours after start_at, i.e. long after Slack has posted.
--
-- WHY NOT just call the existing resolver: `public.dump_driver_origin` already returns a truck and is
-- already called on the ETA screens, but scored against GPS ground truth (153 visits / 45 days) it is only
-- 77% correct overall and 68.6% on multi-candidate drivers, and it has no entry at all for Diego (14 of 51
-- real dumps). A Truck line that is wrong 1 time in 4 is worse than no Truck line, and it would write a
-- guess into an AUDITED business column. Fred chose "accurate-or-silent" (2026-07-27).
--
-- THE MODEL (first match wins; every outcome is labelled and the candidate set is returned for the trail):
--   'gps'          - phone-anchored Samsara match. The ACTIVE truck whose latest POSITIONED reading is
--                    <= FRESH_MIN old and within NEAR_M of the driver's phone, AND whose runner-up is at
--                    least MARGIN_M further away, AND where at least MIN_VISIBLE trucks were actually
--                    visible so that "nearest" is a real comparison rather than a sample of one.
--                    ⚠ HONEST HIT RATE, corrected after review (2026-07-27): an earlier draft of this
--                    header claimed this tier is "decisive on 69% of dump moments". That number was
--                    measured IN HINDSIGHT, over telemetry as it exists now. It does NOT transfer to
--                    request time, because `vehicle_telemetry_readings` is BATCH-ingested by a GitHub
--                    Action, not streamed: measured on Prod over 7 days, median recorded_at->created_at
--                    lag is 63 min (p95 155 min) and only 8.2% of positioned rows are visible within 10
--                    minutes of the moment they describe. So at the instant a driver taps GO this tier has
--                    usable data roughly 10% of the time, and after the MIN_VISIBLE guard below it fires
--                    rarer still. That is ACCEPTED, not a bug to "fix" by widening FRESH_MIN: a 60-minute-
--                    old position is not where the truck is now, and stamping it would be exactly the
--                    guess this design exists to avoid. The CALENDAR tier is the workhorse; GPS is a rare
--                    high-confidence bonus and, more usefully, the only thing that can CONTRADICT a wrong
--                    Calendar assignment (see 'conflict').
--   'gps+calendar' - both agree. Highest confidence.
--   'calendar'     - the driver's OWN same-ET-day non-000 visits carry exactly ONE distinct real
--                    visits.vehicle_id. Singleton band measured 91.2% correct.
--   'conflict'     - GPS and Calendar BOTH resolved and DISAGREE. Returns vehicle_id NULL on purpose: we do
--                    not know, and a disagreement is itself a real operational signal (unrecorded
--                    shift-swap, or a wrong Calendar assignment). The caller surfaces both for a human.
--   'none'         - nothing resolved. vehicle_id stays NULL. A correct outcome, not a failure; it matches
--                    the house rule already in the edge fn for ETAs: "the only acceptable failure mode is
--                    silence, never a guess".
--
-- DELIBERATE DEVIATION, documented so it is not "fixed" later: the design sketch also wanted the Calendar
-- tier to require a <=10-min GPS fix on that truck. NOT implemented as a hard gate. Moises reports as few
-- as 1-10 positioned rows a day (a parked truck falls back to hourly heartbeats), so that gate would
-- systematically reject a CORRECT Moises answer. Freshness is therefore recorded as a confidence signal in
-- `candidates.cal_fix_minutes_ago` rather than used to veto the 91.2% singleton band.
--
-- ⚠ Goliath (vehicle id 4) is INACTIVE and is excluded from every candidate set, exactly as
-- derive_visit_vehicle_id.js already excludes it. Truck names are NOT people (Moises/Cloggy/David/Goliath).
--
-- RULE 1 (source-agnostic schema): NO samsara_* column is added anywhere. Provenance rides in the existing
-- jsonb `public.dump_activity.detail` (written by the edge fn's logActivity), never in a prefixed column.
-- RULE 8 (ADR 010 audit standing check): NO new table. `public.visits` is ALREADY audited, so stamping
-- vehicle_id is captured automatically by the existing audit trigger, with app_source='dump-schedule' (the
-- edge fn sets the x-app-source header). No trigger change, no opt-in/opt-out decision needed.
-- `dump_resolve_truck` is a pure READ (STABLE) and writes nothing.
--
-- INTERACTION with the hourly derive-visit-vehicle-id cron: that cron only ever touches rows where
-- vehicle_id IS NULL, so it cannot fight a create-time write, and it remains the post-hoc safety net for
-- every dump this function honestly refuses to guess.

-- ---------------------------------------------------------------------------
-- 1. The resolver. Pure read. Returns at most one truck, plus its full reasoning.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dump_resolve_truck(
  p_driver_id bigint,
  p_lat       numeric DEFAULT NULL,
  p_lng       numeric DEFAULT NULL
)
RETURNS TABLE(vehicle_id bigint, vehicle_name text, confidence text, candidates jsonb)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  FRESH_MIN CONSTANT int     := 10;   -- a positioned fix older than this is not "now"
  NEAR_M    CONSTANT numeric := 250;  -- phone-to-truck match radius (ADR 012 validated 100-150m; 250 is a
                                      -- conservative outer bound that still separates trucks 51km apart)
  MARGIN_M  CONSTANT numeric := 250;  -- the runner-up must be at least this much FURTHER, else it is a tie
  -- ⚠ FAIL-OPEN FIX (review finding, 2026-07-27). The margin gate can only veto a match when it can SEE a
  -- runner-up. Because ingestion is batched (median 63 min lag), the modal resolvable case was exactly ONE
  -- truck visible, where v_second_m is NULL, the margin test is skipped, and a lone truck within 250m was
  -- accepted unconditionally. Simulated against 14 days of live telemetry that band produced 19 WRONG
  -- answers out of 120 resolutions (16%) - a driver in David, whose own fix had not been ingested yet,
  -- parked near Moises and would have been stamped Moises at the HIGHEST confidence label, on an audited
  -- column. In the same simulation every instant with >=2 trucks visible produced ZERO wrong answers
  -- (n=2: 70 correct/0 wrong; n=3: 12 correct/0 wrong), because the runner-up could then do its job.
  -- So: "only one truck is visible" means NOT DECISIVE, never "it must be that one".
  MIN_VISIBLE CONSTANT int := 2;
  v_today     date;
  v_gps_id    bigint  := NULL;
  v_gps_name  text    := NULL;
  v_gps_m     numeric := NULL;
  v_second_m  numeric := NULL;
  v_visible_n int     := 0;   -- how many ACTIVE trucks actually had a visible fresh fix
  v_cal_id    bigint  := NULL;
  v_cal_name  text    := NULL;
  v_cal_n     int     := 0;
  v_cal_age   numeric := NULL;
  v_fixes     jsonb   := '[]'::jsonb;
  v_out_id    bigint  := NULL;
  v_out_name  text    := NULL;
  v_conf      text    := 'none';
BEGIN
  v_today := (now() AT TIME ZONE 'America/New_York')::date;

  -- ---- TIER 2: phone-anchored Samsara match -------------------------------
  -- Only runs when the phone actually sent a usable fix (same bounds as the edge fn's validCoord()).
  IF p_lat IS NOT NULL AND p_lng IS NOT NULL
     AND p_lat BETWEEN -90 AND 90 AND p_lng BETWEEN -180 AND 180
     AND NOT (p_lat = 0 AND p_lng = 0) THEN

    WITH fresh AS (
      -- latest POSITIONED reading per ACTIVE truck
      SELECT DISTINCT ON (t.vehicle_id)
             t.vehicle_id, veh.name, t.latitude, t.longitude, t.recorded_at
      FROM public.vehicle_telemetry_readings t
      JOIN public.vehicles veh
        ON veh.id = t.vehicle_id
       AND veh.status = 'ACTIVE'          -- Goliath (INACTIVE) can never be a candidate
      WHERE t.recorded_at >= now() - make_interval(mins => FRESH_MIN)
        AND t.latitude IS NOT NULL
        AND t.longitude IS NOT NULL
      ORDER BY t.vehicle_id, t.recorded_at DESC
    ),
    ranked AS (
      SELECT f.vehicle_id, f.name, f.recorded_at,
             -- haversine, metres (no extension dependency)
             (2 * 6371000 * asin(sqrt(
                power(sin(radians(f.latitude - p_lat) / 2), 2)
                + cos(radians(p_lat)) * cos(radians(f.latitude))
                  * power(sin(radians(f.longitude - p_lng) / 2), 2)
             )))::numeric AS meters
      FROM fresh f
    ),
    ord AS (
      SELECT r.*, row_number() OVER (ORDER BY r.meters ASC) AS rn FROM ranked r
    )
    SELECT
      (SELECT o.vehicle_id FROM ord o WHERE o.rn = 1),
      (SELECT o.name       FROM ord o WHERE o.rn = 1),
      (SELECT o.meters     FROM ord o WHERE o.rn = 1),
      (SELECT o.meters     FROM ord o WHERE o.rn = 2),
      (SELECT count(*)::int FROM ord o),
      COALESCE((SELECT jsonb_agg(jsonb_build_object(
          'vehicle_id',  o.vehicle_id,
          'name',        o.name,
          'meters',      round(o.meters),
          'minutes_ago', round(extract(epoch FROM (now() - o.recorded_at)) / 60)
        ) ORDER BY o.meters) FROM ord o), '[]'::jsonb)
    INTO v_gps_id, v_gps_name, v_gps_m, v_second_m, v_visible_n, v_fixes;

    -- Reject unless the nearest truck is genuinely AT the phone AND genuinely alone there AND we could
    -- actually SEE enough of the fleet for "nearest" to mean anything. All three must hold.
    IF v_gps_id IS NOT NULL AND (
         v_visible_n < MIN_VISIBLE                                   -- sample of one: not decisive
         OR v_gps_m > NEAR_M                                          -- nearest truck is not at the phone
         OR (v_second_m IS NOT NULL AND (v_second_m - v_gps_m) < MARGIN_M)  -- two trucks together: a tie
       ) THEN
      v_gps_id := NULL; v_gps_name := NULL;
    END IF;
  END IF;

  -- ---- TIER 3: Calendar singleton -----------------------------------------
  -- The driver's OWN same-ET-day, non-dump visits, using the REAL visits.vehicle_id column only.
  -- ⚠ NEVER source this from service_line_items.default_vehicle_id (that is a SERVICE-TYPE default -
  -- pumping->Moises, cleaning->Cloggy - not an assignment, and it is the single largest source of the
  -- ambiguity in dump_driver_truck today).
  SELECT count(DISTINCT v.vehicle_id), min(v.vehicle_id)
    INTO v_cal_n, v_cal_id
  FROM public.visits v
  JOIN public.clients c ON c.id = v.client_id
  WHERE v.deleted_at IS NULL
    AND v.vehicle_id IS NOT NULL
    AND v.visit_date = v_today
    AND c.client_code NOT LIKE '000%'
    AND (
      v.assigned_driver_id = p_driver_id
      OR EXISTS (SELECT 1 FROM public.visit_team vt
                  WHERE vt.visit_id = v.id AND vt.employee_id = p_driver_id)
    );

  IF v_cal_n = 1 THEN
    SELECT veh.name INTO v_cal_name
    FROM public.vehicles veh
    WHERE veh.id = v_cal_id AND veh.status = 'ACTIVE';

    IF v_cal_name IS NULL THEN           -- an INACTIVE truck is not a usable answer
      v_cal_id := NULL;
    ELSE
      SELECT round(extract(epoch FROM (now() - max(t.recorded_at))) / 60)
        INTO v_cal_age
      FROM public.vehicle_telemetry_readings t
      WHERE t.vehicle_id = v_cal_id AND t.latitude IS NOT NULL;
    END IF;
  ELSE
    v_cal_id := NULL;                    -- 0 or 2+ distinct trucks is not an answer
  END IF;

  -- ---- Arbitrate -----------------------------------------------------------
  IF v_gps_id IS NOT NULL AND v_cal_id IS NOT NULL AND v_gps_id <> v_cal_id THEN
    -- Both spoke and they disagree. Refuse to pick: stamp nothing, surface both.
    v_out_id := NULL; v_out_name := NULL; v_conf := 'conflict';
  ELSIF v_gps_id IS NOT NULL THEN
    v_out_id := v_gps_id; v_out_name := v_gps_name;
    v_conf := CASE WHEN v_cal_id = v_gps_id THEN 'gps+calendar' ELSE 'gps' END;
  ELSIF v_cal_id IS NOT NULL THEN
    v_out_id := v_cal_id; v_out_name := v_cal_name; v_conf := 'calendar';
  ELSE
    v_out_id := NULL; v_out_name := NULL; v_conf := 'none';
  END IF;

  RETURN QUERY SELECT
    v_out_id,
    v_out_name,
    v_conf,
    jsonb_strip_nulls(jsonb_build_object(
      'gps_vehicle_id',      v_gps_id,
      'gps_vehicle_name',    v_gps_name,
      'gps_meters',          CASE WHEN v_gps_id IS NOT NULL THEN round(v_gps_m) END,
      'runner_up_meters',    CASE WHEN v_second_m IS NOT NULL THEN round(v_second_m) END,
      'visible_trucks',      v_visible_n,   -- why a GPS answer was (or wasn't) decisive; auditable
      'min_visible_required', MIN_VISIBLE,
      'cal_vehicle_id',      v_cal_id,
      'cal_vehicle_name',    v_cal_name,
      'cal_distinct_trucks', v_cal_n,
      'cal_fix_minutes_ago', v_cal_age,
      'fresh_fixes',         COALESCE(v_fixes, '[]'::jsonb)
    ));
END $function$;

-- Default privileges auto-grant anon/authenticated/service_role on a NEW function, so REVOKE FROM PUBLIC
-- alone is NOT enough (repo memory: reference_supabase_function_default_privileges). Revoke explicitly.
REVOKE ALL     ON FUNCTION public.dump_resolve_truck(bigint, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.dump_resolve_truck(bigint, numeric, numeric) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. create_dump_visit gains p_vehicle_id and stops throwing the truck away.
--
-- ⚠ MUST DROP FIRST, NOT "CREATE OR REPLACE". Adding a parameter changes the signature, so a plain
-- CREATE OR REPLACE would leave the OLD 12-arg function in place as an OVERLOAD - and a PostgREST call
-- with 12 NAMED arguments would then fail with "function is not unique". Dropping is safe here: the only
-- caller is the dump-visit-create edge function (repo-wide grep), it is re-created in the same
-- transaction, and its grants are restored verbatim below (they were: authenticated + service_role, and
-- deliberately NOT anon).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_dump_visit(
  bigint, bigint, bigint[], date, bigint, timestamp with time zone, timestamp with time zone,
  text, text, bigint, bigint[], boolean
);

CREATE OR REPLACE FUNCTION public.create_dump_visit(
  p_client_id bigint,
  p_job_id bigint,
  p_service_line_item_ids bigint[],
  p_visit_date date,
  p_property_id bigint DEFAULT NULL::bigint,
  p_start_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_end_at timestamp with time zone DEFAULT NULL::timestamp with time zone,
  p_title text DEFAULT NULL::text,
  p_notes text DEFAULT NULL::text,
  p_driver_id bigint DEFAULT NULL::bigint,
  p_team_ids bigint[] DEFAULT NULL::bigint[],
  p_push_to_jobber boolean DEFAULT false,
  p_vehicle_id bigint DEFAULT NULL::bigint
)
 RETURNS visits
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v public.visits;
BEGIN
  -- TEST MODE: suppress the AFTER INSERT push for THIS transaction only.
  IF NOT p_push_to_jobber THEN
    PERFORM set_config('app.suppress_jobber_push', 'on', true);
  END IF;

  -- The one sanctioned visit-creating path. Unchanged, so all its validation + children still apply.
  -- ⚠ POSITIONAL call: the 11th argument is create_calendar_visit's p_vehicle_id. It used to be a
  -- hardcoded NULL, which is why every app dump had no truck (fixed 2026-07-27).
  v := public.create_calendar_visit(
         p_client_id, p_job_id, p_service_line_item_ids, p_visit_date,
         p_property_id, NULL, p_start_at, p_end_at, p_title, p_notes,
         p_vehicle_id, p_driver_id, NULL, p_team_ids, NULL);

  -- TEST MODE: make the row permanently inert to every Jobber path (trigger, cron, and push gate).
  IF NOT p_push_to_jobber THEN
    UPDATE public.visits
       SET source = 'manual', sync_state = 'confirmed'
     WHERE id = v.id;
    SELECT * INTO v FROM public.visits WHERE id = v.id;
  END IF;

  RETURN v;
END $function$;

-- Restore the exact pre-drop grant set (verified from pg_proc.proacl before the change):
--   {postgres=X/postgres, authenticated=X/postgres, service_role=X/postgres}  -- note: NO anon
REVOKE ALL ON FUNCTION public.create_dump_visit(
  bigint, bigint, bigint[], date, bigint, timestamp with time zone, timestamp with time zone,
  text, text, bigint, bigint[], boolean, bigint
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_dump_visit(
  bigint, bigint, bigint[], date, bigint, timestamp with time zone, timestamp with time zone,
  text, text, bigint, bigint[], boolean, bigint
) TO authenticated, service_role;
