-- 2026-07-18 dump_driver_origin
--
-- WHY: the DUMP app shows the driver a live ETA to the dump he picks. Fred's constraint (2026-07-18) is
-- that we must NOT ask the driver's phone for his location. We already ingest Samsara truck telemetry,
-- so we can resolve "where is this driver" from the truck he is on today and never prompt him.
--
-- WHAT: given a driver, return the single best current GPS fix among the trucks he is assigned to on
-- TODAY's route, plus how old that fix is. The caller (dump-visit-create, constant FRESH_MIN) decides
-- whether the fix is fresh enough to route from, so the staleness threshold stays one tunable constant
-- in one place instead of being buried in a migration.
--
-- TWO THINGS VERIFIED AGAINST LIVE DATA BEFORE WRITING THIS (do not "simplify" them back):
--
--   1. Candidates come from ops.v_calendar_visit, NOT public.visits.vehicle_id. The raw column is NULL on
--      100% of today's visits (~49% overall). The Calendar's truck comes from an EFFECTIVE vehicle: the
--      view LATERAL-joins a fallback that derives the vehicle from the job's service line item when the
--      visit itself carries none. Keying on the raw column would have returned zero candidates almost
--      always, silently degrading every ETA to the phone-prompt fallback and defeating the whole design.
--      The view is also already soft-delete aware, so we inherit that filter instead of re-stating it.
--
--   2. Ordering is by minutes_ago ASC only. An earlier draft ordered by "is moving"
--      (engine_state = 'On' OR speed > 0). Against 14 days of readings, speed_meters_per_sec is NULL in
--      100% of 61,885 rows and engine_state is NULL in 99.4%, so that flag is always false and sorts
--      nothing. Freshness is the honest signal anyway: a truck in use reports roughly every 6 seconds
--      (median gap 0.10 min) while a parked one falls back to hourly heartbeats, so the freshest fix
--      belongs to the truck actually being driven.
--
-- A fresh fix on a truck parked at the yard is a CORRECT origin (the driver is at the yard, about to
-- drive), so this deliberately does not try to require motion.
--
-- AUDIT (ADR 010): read-only function, touches no business table and writes nothing. Opt-out, no trigger.

DROP FUNCTION IF EXISTS public.dump_driver_origin(bigint);

CREATE FUNCTION public.dump_driver_origin(p_driver_id bigint)
RETURNS TABLE (
  vehicle_id   bigint,
  vehicle_name text,
  latitude     numeric,
  longitude    numeric,
  minutes_ago  numeric,
  engine_state text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, ops, pg_temp
AS $$
  WITH cands AS (
    SELECT DISTINCT cv.vehicle_id
    FROM ops.v_calendar_visit cv
    WHERE cv.driver_id = p_driver_id
      -- TODAY **OR YESTERDAY** (ET), deliberately. The dump runs are overnight: a driver who started at
      -- 10 PM and dumps at 3 AM has crossed the ET calendar date, and per the operating-date rule his
      -- evening visits keep the PRIOR date while now() is already the next one. Observed live on
      -- 2026-07-19 at 03:29 ET: driver 37's route was dated 07-18, so a today-only window returned no
      -- candidates and needlessly pushed him to the phone prompt - the exact friction this feature
      -- exists to avoid. Widening the window is safe because the caller still gates on FRESH_MIN: a
      -- truck from yesterday that is not currently reporting can never win, it just cannot be missed.
      AND cv.visit_date >= (now() AT TIME ZONE 'America/New_York')::date - 1
      AND cv.visit_date <= (now() AT TIME ZONE 'America/New_York')::date
      AND cv.vehicle_id IS NOT NULL
  )
  SELECT t.vehicle_id,
         t.vehicle_name,
         t.latitude,
         t.longitude,
         t.minutes_ago,
         t.engine_state
  FROM public.v_vehicle_telemetry_latest t
  JOIN cands c ON c.vehicle_id = t.vehicle_id
  WHERE t.latitude IS NOT NULL
    AND t.longitude IS NOT NULL
  ORDER BY t.minutes_ago ASC
  LIMIT 1;
$$;

-- Default privileges auto-grant anon/authenticated on new public functions, so REVOKE FROM PUBLIC alone
-- is NOT enough (see memory: reference_supabase_function_default_privileges). Revoke explicitly, then
-- grant only service_role, which is the edge function's identity.
REVOKE ALL ON FUNCTION public.dump_driver_origin(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dump_driver_origin(bigint) FROM anon;
REVOKE ALL ON FUNCTION public.dump_driver_origin(bigint) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.dump_driver_origin(bigint) TO service_role;
