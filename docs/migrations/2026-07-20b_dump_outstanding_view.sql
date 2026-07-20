-- 2026-07-20b dump_outstanding_visits: a READ-ONLY browse list of undocumented visits
--
-- WHY (Fred 2026-07-20): VIEW ADDRESSES now opens a submenu, "TODAY'S VISITS" (the existing shift route)
-- and "OLDER VISITS" = the still-undocumented ones, "the extra we talked about".
--
-- ⚠ WHY THIS IS A SEPARATE READ-ONLY SURFACE AND NOT dump_manifest_handout_list:
-- that function RECORDS A HAND-OUT as a side effect, which is how "the app can ONLY give the visits to
-- add to manifest ONCE" is enforced. If browsing from the menu called it, merely LOOKING at the list
-- would burn a visit's single hand-out with no dump attached, and the visit would then be hidden from the
-- driver who actually dumps it for the next HANDOUT_TTL_DAYS. Browsing must never consume the hand-out.
-- This view writes nothing and records nothing.
--
-- It is also the shared projection: dump_manifest_handout_list is refactored to select FROM it, so the
-- address cleanup and the gdos LATERAL live in exactly one place and the browse list and the crib sheet
-- can never drift apart.
--
-- Like everything in this feature it touches NO DERM table.
--
-- AUDIT (ADR 010): a view, nothing to audit.

CREATE OR REPLACE VIEW public.dump_outstanding_visits AS
SELECT
  p.visit_id,
  p.client_code,
  p.client_name,
  -- The driver COPIES this onto a DERM sheet, so it must read cleanly. Strip a ", Boca Raton, Florida
  -- 33432, USA" style tail (same rule the route screen uses), and drop city when the address already
  -- names it as its own comma-separated segment, so it is not appended twice. A street merely CONTAINING
  -- the city name ("105 East Hallandale Beach Boulevard" in Hallandale Beach) is not a duplicate, which
  -- is why the test is on a comma-delimited segment rather than a bare substring.
  regexp_replace(p.address, ',\s*USA.*$', '', 'i') AS address,
  CASE
    WHEN p.city IS NOT NULL
     AND regexp_replace(p.address, ',\s*USA.*$', '', 'i') ~* (',\s*' || p.city || '(\s*,|\s*$)')
    THEN NULL ELSE p.city
  END AS city,
  p.visit_date,
  p.completed_at,
  vis.vehicle_id,
  veh.name AS truck,
  gd.gdo_number,
  GREATEST(0, ((now() AT TIME ZONE 'America/New_York')::date - p.visit_date))::int AS age_days,
  (GREATEST(0, ((now() AT TIME ZONE 'America/New_York')::date - p.visit_date))::int > 14) AS needs_office
FROM public.manifest_pickable_visits p
JOIN public.visits vis ON vis.id = p.visit_id
LEFT JOIN public.vehicles veh ON veh.id = vis.vehicle_id
-- ⚠ LATERAL top-1, NOT a plain join: public.gdos holds MULTIPLE rows per client (009-CN has 4, one of
-- them a comma-joined "GDO-a, GDO-b, GDO-c" string). A plain join duplicates rows and the driver sees the
-- same restaurant several times.
LEFT JOIN LATERAL (
  SELECT g.gdo_number
  FROM public.gdos g
  WHERE g.client_id = p.client_id
    AND g.status = 'ACTIVE'
    AND g.gdo_number ~ '^GDO-[0-9]+$'
  ORDER BY g.gdo_number
  LIMIT 1
) gd ON true;

COMMENT ON VIEW public.dump_outstanding_visits IS
  'Read-only browse list of completed visits that still have no live DERM manifest link, with the address '
  'cleaned for copying onto a sheet. Shared projection: dump_manifest_handout_list selects FROM this. '
  'Browsing must never record a hand-out, which is why this exists separately.';

REVOKE ALL ON public.dump_outstanding_visits FROM PUBLIC;
REVOKE ALL ON public.dump_outstanding_visits FROM anon;
REVOKE ALL ON public.dump_outstanding_visits FROM authenticated;
GRANT SELECT ON public.dump_outstanding_visits TO service_role;

-- Refactor the hand-out list onto the shared projection. Behaviour is unchanged: same buckets, same
-- ledger hide rule, same ordering, same recording. Only the source of the columns moved.
DROP FUNCTION IF EXISTS public.dump_manifest_handout_list(bigint, bigint, int);

CREATE FUNCTION public.dump_manifest_handout_list(
  p_driver_id     bigint,
  p_dump_visit_id bigint,
  p_ttl_days      int DEFAULT 7
)
RETURNS TABLE (
  bucket       text,
  visit_id     bigint,
  client_code  text,
  client_name  text,
  address      text,
  city         text,
  visit_date   date,
  completed_at timestamptz,
  age_days     int,
  truck        text,
  gdo_number   text,
  needs_office boolean
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
-- The RETURNS TABLE columns are also plpgsql variables, so unqualified references inside the query are
-- ambiguous and Postgres RAISES 42702 (hit on the ON CONFLICT target). Resolve to the COLUMN.
#variable_conflict use_column
DECLARE
  v_truck_id bigint;
  v_since    timestamptz;
BEGIN
  SELECT o.vehicle_id INTO v_truck_id FROM public.dump_driver_origin(p_driver_id) o;

  SELECT max(v.start_at) INTO v_since
  FROM public.visits v
  WHERE v.assigned_driver_id = p_driver_id
    AND v.client_id IN (76, 365)          -- 000-DP, 000-DH
    AND v.deleted_at IS NULL
    AND v.id <> p_dump_visit_id;

  v_since := COALESCE(v_since, now() - interval '7 days');

  RETURN QUERY
  WITH candidate AS (
    SELECT o.*
    FROM public.dump_outstanding_visits o
    -- Hidden only when handed out on a DIFFERENT dump inside the TTL, so re-opening THIS receipt shows
    -- the same list rather than an alarming empty screen.
    WHERE NOT EXISTS (
      SELECT 1 FROM public.dump_manifest_handout h
      WHERE h.visit_id = o.visit_id
        AND h.dump_visit_id <> p_dump_visit_id
        AND h.handed_at > now() - make_interval(days => p_ttl_days)
    )
  ),
  bucketed AS (
    SELECT c.*,
      CASE
        WHEN v_truck_id IS NOT NULL
         AND c.vehicle_id = v_truck_id
         AND c.completed_at IS NOT NULL
         AND c.completed_at > v_since
        THEN 'load' ELSE 'outstanding'
      END AS bucket
    FROM candidate c
  ),
  recorded AS (
    INSERT INTO public.dump_manifest_handout (visit_id, dump_visit_id, driver_id)
    SELECT b.visit_id, p_dump_visit_id, p_driver_id FROM bucketed b
    ON CONFLICT (visit_id, dump_visit_id) DO NOTHING
    RETURNING 1
  )
  SELECT b.bucket, b.visit_id, b.client_code, b.client_name, b.address, b.city, b.visit_date,
         b.completed_at, b.age_days, b.truck, b.gdo_number, b.needs_office
  FROM bucketed b
  ORDER BY (b.bucket = 'load') DESC,
           CASE WHEN b.bucket = 'load' THEN b.completed_at END ASC,
           CASE WHEN b.bucket <> 'load' THEN b.completed_at END DESC NULLS LAST;
END;
$$;

REVOKE ALL ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, int) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, int) FROM anon;
REVOKE ALL ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, int) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, int) TO service_role;
