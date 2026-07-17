-- 2026-07-17_dump_route_today.sql
-- DUMP Schedule app — "View Addresses" now shows TODAY'S CLIENT ROUTE (Fred 2026-07-17:
-- "the Addresses of the Clients for that day/shift ... excluding the Dump Places (000 clients)").
--
-- The public DUMP page (dump.unclogme.app) talks ONLY to the dump-visit-create edge function and has
-- no Supabase client; ops.v_calendar_visit is NOT PostgREST-exposed (api schemas = public,
-- graphql_public). So we expose today's route through a SECURITY DEFINER RPC the edge fn calls with its
-- service_role key. It reads ops.v_calendar_visit (already soft-delete safe -> v_visits_live, and
-- Jobber-first merged), filtered to the ET operating date and excluding the 000 dump clients.
--
-- Audit (Rule 8): OPT-OUT — this is a read-only STABLE function, not a table; it performs no writes, so
-- no audit trigger applies. No customer.* / billing / DERM writes.
--
-- Grants: locked to service_role only (the edge fn). anon/authenticated cannot call it directly
-- (defense in depth; the address list only reaches the public page through the one controlled edge fn).
-- Per the default-privileges gotcha, REVOKE from PUBLIC is not enough — anon/authenticated are
-- auto-granted by default privileges, so revoke them explicitly.

CREATE OR REPLACE FUNCTION public.dump_route_today()
RETURNS TABLE (
  client_code   text,
  client_name   text,
  visit_status  text,
  start_at      timestamptz,
  is_all_day    boolean,
  address       text,
  city          text,
  state         text,
  zip           text,
  county        text,
  latitude      double precision,
  longitude     double precision,
  truck_name    text,
  driver_name   text,
  service_label text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, ops
AS $$
  SELECT
    v.client_code,
    v.client_name,
    v.visit_status,
    v.start_at,
    v.is_all_day,
    v.address,
    v.city,
    v.state,
    v.zip,
    v.county,
    v.latitude,
    v.longitude,
    v.truck_name,
    COALESCE(v.driver_name, v.assigned_driver_name) AS driver_name,
    v.service_label
  FROM ops.v_calendar_visit v
  WHERE v.visit_date = (now() AT TIME ZONE 'America/New_York')::date
    AND v.client_code NOT LIKE '000%'          -- exclude the dump places (000-DH / 000-DP)
  ORDER BY v.start_at NULLS LAST, v.client_code
$$;

REVOKE ALL     ON FUNCTION public.dump_route_today() FROM PUBLIC;
REVOKE ALL     ON FUNCTION public.dump_route_today() FROM anon;
REVOKE ALL     ON FUNCTION public.dump_route_today() FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.dump_route_today() TO service_role;
