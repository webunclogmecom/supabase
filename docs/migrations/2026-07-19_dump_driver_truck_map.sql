-- 2026-07-19 dump_driver_truck: make the ETA origin lookup fast
--
-- WHY: measured 2026-07-19, public.dump_driver_origin took 860 ms for most drivers and **3,625 ms** for
-- Mark, who is on two trucks. The app asks for both dumps, so that cost was paid twice per screen. That
-- is the bulk of the 10-15 second wait Fred reported ("if it was like around 3 seconds that would be ok").
--
-- The cost is NOT the driver->truck question itself, which is tiny. It is that the question was asked of
-- ops.v_calendar_visit, a very large view whose CTEs compute median prices and job cadences across the
-- WHOLE visits table before any predicate is applied. We were paying for an analytics view to answer
-- "which truck is this guy in".
--
-- WHAT: precompute the mapping into a small table on a schedule, and let the request path read that.
--
-- WHY PRECOMPUTE RATHER THAN REWRITE THE QUERY: the view's effective-vehicle is a COALESCE over
-- visit-level line items then job-level line items joined to service_line_items.default_vehicle_id, and
-- its driver is a three-branch COALESCE over visit_assignments and then inspections. Hand-porting that
-- into a "fast" query risks a subtle mismatch, and a WRONG truck means a confidently wrong ETA, which is
-- the one failure mode this feature must never have. Refreshing FROM the view keeps the answer identical
-- by construction while moving the cost off the request path.
--
-- Staleness is a non-issue: a driver's truck for the day changes at most a few times a day, and the
-- refresh runs every 5 minutes. The freshness that actually matters (the GPS fix) is still read live.
--
-- AUDIT (ADR 010): opt-OUT. Machine-written derived cache of data that already exists elsewhere; no
-- human-editable fields, no customer/billing/DERM/secret data.

CREATE TABLE IF NOT EXISTS public.dump_driver_truck (
  driver_id    bigint      NOT NULL,
  vehicle_id   bigint      NOT NULL,
  refreshed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (driver_id, vehicle_id)
);

COMMENT ON TABLE public.dump_driver_truck IS
  'Precomputed driver -> truck map for today/yesterday ET, refreshed from ops.v_calendar_visit by pg_cron '
  '(dump-driver-truck-refresh). Exists purely to keep the giant view off the ETA request path. '
  'Audit-exempt per ADR 010.';

ALTER TABLE public.dump_driver_truck ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.dump_driver_truck FROM PUBLIC;
REVOKE ALL ON TABLE public.dump_driver_truck FROM anon;
REVOKE ALL ON TABLE public.dump_driver_truck FROM authenticated;
GRANT ALL ON TABLE public.dump_driver_truck TO service_role;

-- Rebuild the map from the canonical view. Today OR yesterday ET, because overnight shifts cross the
-- date (see the 2026-07-19 fix in dump_driver_origin).
CREATE OR REPLACE FUNCTION public.refresh_dump_driver_truck()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, ops, pg_temp
AS $$
DECLARE
  n integer;
BEGIN
  CREATE TEMP TABLE _ddt ON COMMIT DROP AS
    SELECT DISTINCT cv.driver_id, cv.vehicle_id
    FROM ops.v_calendar_visit cv
    WHERE cv.visit_date >= (now() AT TIME ZONE 'America/New_York')::date - 1
      AND cv.visit_date <= (now() AT TIME ZONE 'America/New_York')::date
      AND cv.vehicle_id IS NOT NULL
      AND cv.driver_id IS NOT NULL;

  -- Replace wholesale: a driver who moved off a truck must lose the old row, or he would keep resolving
  -- to yesterday's truck. Deleting only what is absent from the fresh set keeps this a small write.
  DELETE FROM public.dump_driver_truck d
   WHERE NOT EXISTS (SELECT 1 FROM _ddt t WHERE t.driver_id = d.driver_id AND t.vehicle_id = d.vehicle_id);

  INSERT INTO public.dump_driver_truck (driver_id, vehicle_id, refreshed_at)
  SELECT t.driver_id, t.vehicle_id, now() FROM _ddt t
  ON CONFLICT (driver_id, vehicle_id) DO UPDATE SET refreshed_at = now();

  SELECT count(*) INTO n FROM public.dump_driver_truck;
  RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_dump_driver_truck() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.refresh_dump_driver_truck() FROM anon;
REVOKE ALL ON FUNCTION public.refresh_dump_driver_truck() FROM authenticated;
GRANT EXECUTE ON FUNCTION public.refresh_dump_driver_truck() TO service_role;

-- Seed immediately so the map is never empty between deploy and the first cron tick.
SELECT public.refresh_dump_driver_truck();

-- The request path: read the precomputed map, join live telemetry, return the freshest fix.
-- Behaviour is unchanged from the previous version; only the candidate source is different.
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
SET search_path = public, pg_temp
AS $$
  SELECT t.vehicle_id,
         t.vehicle_name,
         t.latitude,
         t.longitude,
         t.minutes_ago,
         t.engine_state
  FROM public.v_vehicle_telemetry_latest t
  JOIN public.dump_driver_truck m ON m.vehicle_id = t.vehicle_id
  WHERE m.driver_id = p_driver_id
    AND t.latitude IS NOT NULL
    AND t.longitude IS NOT NULL
  -- Freshest fix wins. An in-use truck reports every ~6s, a parked one falls back to hourly heartbeats,
  -- so freshness IS the activity signal (speed/engine_state are NULL in ~all rows and sort nothing).
  ORDER BY t.minutes_ago ASC
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.dump_driver_origin(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dump_driver_origin(bigint) FROM anon;
REVOKE ALL ON FUNCTION public.dump_driver_origin(bigint) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.dump_driver_origin(bigint) TO service_role;

-- Keep the map fresh. Every 5 minutes is far more often than truck assignments actually change; the
-- expensive view scan now happens on this schedule instead of on every driver's screen.
SELECT cron.schedule(
  'dump-driver-truck-refresh',
  '*/5 * * * *',
  $cron$ SELECT public.refresh_dump_driver_truck(); $cron$
);

-- ---------------------------------------------------------------------------
-- Second bottleneck, same day: with the map in place the lookup was still 414-819 ms for drivers who
-- HAVE a truck. Cause: public.v_vehicle_telemetry_latest is DISTINCT ON (vehicle_id) over
-- vehicle_telemetry_readings, which is 1.17M rows. Postgres has no loose-index-scan, so it reads the
-- whole thing to find the latest per vehicle - even though we only ever care about the ONE or TWO
-- vehicles this driver is on.
--
-- Fix: skip the view and do a LATERAL top-1 per candidate vehicle, which uses idx_vtr_vehicle_time
-- (vehicle_id, recorded_at DESC) as a direct index lookup.
--
-- One deliberate behaviour improvement: the LATERAL takes the most recent row that actually HAS a
-- position. The view took the latest row unconditionally, so a trailing row with NULL lat/lng would have
-- dropped the origin entirely and bounced the driver to a phone prompt for no reason. Taking the latest
-- positioned fix is still honest because minutes_ago is computed from THAT row, so the staleness gate
-- still judges the position we are actually routing from.
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
SET search_path = public, pg_temp
AS $$
  SELECT m.vehicle_id,
         v.name,
         t.latitude,
         t.longitude,
         round(EXTRACT(epoch FROM now() - t.recorded_at) / 60::numeric) AS minutes_ago,
         t.engine_state
  FROM public.dump_driver_truck m
  JOIN public.vehicles v ON v.id = m.vehicle_id
  CROSS JOIN LATERAL (
    SELECT r.latitude, r.longitude, r.recorded_at, r.engine_state
    FROM public.vehicle_telemetry_readings r
    WHERE r.vehicle_id = m.vehicle_id
      AND r.latitude IS NOT NULL
      AND r.longitude IS NOT NULL
    ORDER BY r.recorded_at DESC
    LIMIT 1
  ) t
  WHERE m.driver_id = p_driver_id
  ORDER BY t.recorded_at DESC
  LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.dump_driver_origin(bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dump_driver_origin(bigint) FROM anon;
REVOKE ALL ON FUNCTION public.dump_driver_origin(bigint) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.dump_driver_origin(bigint) TO service_role;
