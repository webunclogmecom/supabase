-- 2026-07-24  DUMP TODAY'S VISITS become selectable-to-manifest (completed stops only)
--
-- WHY (Fred 2026-07-24): the VIEW ADDRESSES -> TODAY'S VISITS list was display-only; Fred wants it
-- selectable like OLDER VISITS so the driver can add today's stops to a manifest. But a DERM manifest
-- documents grease already PUMPED, so only COMPLETED stops may be added -- scheduled stops stay read-only
-- (shown for directions). The app shows a warning card explaining this.
--
-- CHANGE: dump_route_today() gains four per-stop columns so the app can render the shared mark + the
-- selectable/read-only split without a second round-trip:
--   visit_id  -- the stop's visit id, so the app can call {mark}/{link} on it
--   pickable  -- TRUE iff the visit is in dump_outstanding_visits (completed + DERM-required + not yet on
--               a real manifest). This is the authoritative "can be selected" signal; a scheduled stop is
--               FALSE. Reuses the exact same gate as dump_manifest_mark / dump_manifest_link, so the app
--               can never offer a stop the RPCs would reject.
--   on_sheet  -- the shared "on a manifest" mark (dump_manifest_handout), same as OLDER VISITS shows
--   marked_by -- who marked it (driver full_name), or NULL
--
-- Changing the RETURNS TABLE shape requires DROP + CREATE. Grants re-applied (service_role only; anon is
-- read-only per the 2026-07-12 harden). AUDIT: read-only STABLE function, no writes -> opt-out.

BEGIN;

DROP FUNCTION IF EXISTS public.dump_route_today();

CREATE FUNCTION public.dump_route_today()
RETURNS TABLE (
  visit_id      bigint,
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
  service_label text,
  pickable      boolean,
  on_sheet      boolean,
  marked_by     text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, ops
AS $$
  SELECT
    v.id AS visit_id,
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
    v.service_label,
    (o.visit_id IS NOT NULL)      AS pickable,      -- in dump_outstanding_visits => completed DERM, addable
    COALESCE(o.on_sheet, false)   AS on_sheet,      -- shared dump_manifest_handout mark
    o.marked_by
  FROM ops.v_calendar_visit v
  LEFT JOIN public.dump_outstanding_visits o ON o.visit_id = v.id
  WHERE v.visit_date = (now() AT TIME ZONE 'America/New_York')::date
    AND v.client_code NOT LIKE '000%'          -- exclude the dump places (000-DH / 000-DP)
    AND (v.derm_required IS NOT FALSE)         -- DERM manifest reference: drop non-DERM (unclog etc.); keep TRUE + unknown
  ORDER BY v.start_at NULLS LAST, v.client_code
$$;

REVOKE ALL     ON FUNCTION public.dump_route_today() FROM PUBLIC;
REVOKE ALL     ON FUNCTION public.dump_route_today() FROM anon;
REVOKE ALL     ON FUNCTION public.dump_route_today() FROM authenticated;
GRANT  EXECUTE ON FUNCTION public.dump_route_today() TO service_role;

COMMIT;
