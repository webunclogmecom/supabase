-- 2026-07-23c  DUMP TODAY'S VISITS: exclude non-DERM visits (e.g. unclogging)
--
-- WHY (Fred 2026-07-23): the TODAY'S VISITS list (VIEW ADDRESSES) showed 043-MIL "Mila", whose visit
-- today is an UNCLOGGING service call ("17 - Service Call - Unclogging"), not grease pumping. It is
-- derm_required = FALSE, so it has nothing to go on a DERM manifest and should not appear on this list.
-- OLDER VISITS + the receipt load already exclude it (they run off manifest_pickable_visits, which is
-- DERM-filtered); only dump_route_today (TODAY'S VISITS) was missing the filter.
--
-- FIX: add `AND (v.derm_required IS NOT FALSE)` to dump_route_today. This drops the definitively-non-DERM
-- visits (derm_required = FALSE, like Mila's unclog) while KEEPING derm_required = TRUE and NULL (unknown)
-- — per the standing DERM rule, an unknown is surfaced, never hidden (a NULL might still need DERM).
-- derm_required is line-item-derived (ADR 018), so this is the authoritative per-visit signal, not
-- service_type. ops.v_calendar_visit already exposes derm_required (verified).
--
-- Nothing else changes: same columns, same order, same grants. Frontend unchanged (TODAY'S VISITS just
-- renders whatever the route returns). Audit: read-only STABLE function, no writes.

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
  gdo_number    text,
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
    v.gdo_number,
    v.latitude,
    v.longitude,
    v.truck_name,
    COALESCE(v.driver_name, v.assigned_driver_name) AS driver_name,
    v.service_label
  FROM ops.v_calendar_visit v
  WHERE v.visit_date = (now() AT TIME ZONE 'America/New_York')::date
    AND v.client_code NOT LIKE '000%'          -- exclude the dump places (000-DH / 000-DP)
    AND (v.derm_required IS NOT FALSE)         -- DERM manifest reference: drop non-DERM (unclog etc.); keep TRUE + unknown
  ORDER BY v.start_at NULLS LAST, v.client_code
$$;

REVOKE ALL     ON FUNCTION public.dump_route_today() FROM PUBLIC;
REVOKE ALL     ON FUNCTION public.dump_route_today() FROM anon;
REVOKE ALL     ON FUNCTION public.dump_route_today() FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.dump_route_today() TO service_role;
