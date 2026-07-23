-- 2026-07-23b  DUMP receipt: the manifest checklist shows THIS DRIVER's load, not the older visits
--
-- ============================================================================
-- WHY (Fred 2026-07-23)
-- ============================================================================
-- When a driver makes a dump, the receipt checklist should show the visits from the current shift that
-- THIS driver did (the grease actually on this load), so they tick their own pickups. It was showing the
-- OLDER undocumented list ("outstanding") instead, because the 'load' bucket was keyed on the driver's
-- TRUCK and came up empty. Older catch-up now lives entirely in VIEW ADDRESSES -> OLDER VISITS.
--
-- CHANGE: the 'load' bucket of dump_manifest_handout_list is re-scoped from the driver's truck to the
-- DRIVER (assigned_driver_id) — "this driver's completed, still-undocumented visits since their last
-- dump" (v_since). dump_outstanding_visits gains assigned_driver_id for the filter (append-only column;
-- the function's RETURNS TABLE shape is unchanged). The frontend then renders only the 'load' bucket on
-- the receipt and drops the 'outstanding' section.
--
-- The old truck lookup (dump_driver_origin) is no longer used by this function.
--
-- AUDIT: read-only view + STABLE function, no writes. anon stays read-only; all grants service_role-only.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Browse view gains assigned_driver_id (append-only; existing columns unchanged)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.dump_outstanding_visits AS
SELECT
  p.visit_id,
  p.client_code,
  p.client_name,
  regexp_replace(p.address, ',\s*USA.*$'::text, ''::text, 'i'::text) AS address,
  CASE
    WHEN p.city IS NOT NULL
     AND regexp_replace(p.address, ',\s*USA.*$'::text, ''::text, 'i'::text) ~* ((',\s*'::text || p.city) || '(\s*,|\s*$)'::text)
    THEN NULL::text ELSE p.city
  END AS city,
  p.visit_date,
  p.completed_at,
  vis.vehicle_id,
  veh.name AS truck,
  gd.gdo_number,
  GREATEST(0, (now() AT TIME ZONE 'America/New_York'::text)::date - p.visit_date) AS age_days,
  GREATEST(0, (now() AT TIME ZONE 'America/New_York'::text)::date - p.visit_date) > 14 AS needs_office,
  (h.visit_id IS NOT NULL) AS on_sheet,
  emp.full_name AS marked_by,
  h.handed_at AS marked_at,
  vis.assigned_driver_id
FROM public.manifest_pickable_visits p
JOIN public.visits vis ON vis.id = p.visit_id
LEFT JOIN public.vehicles veh ON veh.id = vis.vehicle_id
LEFT JOIN LATERAL (
  SELECT g.gdo_number FROM public.gdos g
  WHERE g.client_id = p.client_id AND g.status = 'ACTIVE'::text AND g.gdo_number ~ '^GDO-[0-9]+$'::text
  ORDER BY g.gdo_number LIMIT 1
) gd ON true
LEFT JOIN public.dump_manifest_handout h ON h.visit_id = p.visit_id
LEFT JOIN public.employees emp ON emp.id = h.driver_id;

REVOKE ALL ON public.dump_outstanding_visits FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.dump_outstanding_visits TO service_role;

-- ---------------------------------------------------------------------------
-- 2. List fn: 'load' bucket keyed on the DRIVER (assigned_driver_id) since their last dump
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dump_manifest_handout_list(p_driver_id bigint, p_dump_visit_id bigint, p_ttl_days integer DEFAULT 7)
 RETURNS TABLE(bucket text, visit_id bigint, client_code text, client_name text, address text, city text, visit_date date, completed_at timestamp with time zone, age_days integer, truck text, gdo_number text, needs_office boolean, confirmed boolean)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_since timestamptz;
BEGIN
  -- "since this driver's last dump" = the current-load window (exclude the dump being filed)
  SELECT max(v.start_at) INTO v_since
  FROM public.visits v
  WHERE v.assigned_driver_id = p_driver_id
    AND v.client_id IN (76, 365)
    AND v.deleted_at IS NULL
    AND v.id <> p_dump_visit_id;
  v_since := COALESCE(v_since, now() - interval '7 days');

  RETURN QUERY
  WITH bucketed AS (
    SELECT o.*,
      CASE
        WHEN o.assigned_driver_id = p_driver_id
         AND o.completed_at IS NOT NULL AND o.completed_at > v_since
        THEN 'load' ELSE 'outstanding'
      END AS bucket
    FROM public.dump_outstanding_visits o
  )
  SELECT b.bucket, b.visit_id, b.client_code, b.client_name, b.address, b.city, b.visit_date,
         b.completed_at, b.age_days, b.truck, b.gdo_number, b.needs_office,
         b.on_sheet AS confirmed
  FROM bucketed b
  ORDER BY (b.bucket = 'load') DESC,
           CASE WHEN b.bucket = 'load' THEN b.completed_at END ASC,
           CASE WHEN b.bucket <> 'load' THEN b.completed_at END DESC NULLS LAST;
END;
$function$;

REVOKE ALL ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, integer) TO service_role;

COMMIT;
