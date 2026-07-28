-- 2026-07-28g  GDO resolution moves from CLIENT-wide to the VISIT'S ACTUAL LOCATION
--
-- WHY. `public.fn_resolve_gdo_number(client, property)` (shipped earlier today in
-- 2026-07-28_dump_county_gate_gdo_and_hide.sql) picks ONE permit per CLIENT. For a single-permit client
-- that is right. For a multi-permit client it was a deterministic-but-arbitrary tiebreak on gdo_number,
-- and I originally described that to Fred as "arbitrary but valid". **That was wrong, and this migration
-- exists because it was wrong.**
--
-- 043-MIL Mila holds two permits on ONE property: GDO-11024 "Restaurant" (client_location_id 163) and
-- GDO-14117 "Bar & Lounge" (client_location_id 444). Its visits genuinely ALTERNATE between the two traps:
--   visit 7386 (07-27) -> location 444 -> Bar & Lounge
--   visit 7334 (07-23) -> location 444 -> Bar & Lounge
--   visit 7273 (07-20) -> location 163 -> Restaurant
-- The client-wide resolver returned GDO-11024 for ALL of them, so every Bar & Lounge pump was being handed
-- the RESTAURANT's permit number - which a driver then copies by hand onto a DERM address manifest under a
-- printed "GDO #" heading. That is not an arbitrary pick among equals; it is a factually wrong permit on a
-- compliance form. Measured fleet-wide: **12 of 319 location-resolvable completed DERM visits** would
-- receive a different (correct) permit under this change.
--
-- THE FIX (credit: the @Supabase session pushed back on tiebreaking by `gdos.nickname` and was right to).
-- A nickname is a DISPLAY LABEL, not a selection key: "Bar & Lounge" vs "Restaurant" tells a human which
-- area a permit covers but carries no information about which trap a given visit pumped, so sorting on it
-- would have been a prettier string sort that LOOKED semantic - the worst kind of fix, because the next
-- reader would trust it. The real selection key is the visit's own location.
--
-- That key exists and is well populated - this is not a someday design:
--   public.visit_locations(visit_id, client_location_id)  -- M:N, the service-grain link
--   public.gdos.client_location_id                        -- 113 of 220 permits carry one
--   coverage: 587 of 591 completed DERM visits (99.3%) have a visit_locations row;
--             043-MIL 17/17, 148-MOR 3/3, 242-WYN 1/2.
--
-- RESOLUTION ORDER (first match wins):
--   1. EXACT: a permit whose client_location_id is one of THIS VISIT's locations.
--   2. otherwise the previous behaviour: property match, then ACTIVE, then expiry, then number.
-- So it is strictly better than before and never worse: when the location link is missing (p_visit_id NULL,
-- or no visit_locations row, or the permit has no client_location_id) it degrades exactly to today's answer.
--
-- ⚠ DELIBERATE: an EXACT location match WINS EVEN IF THAT PERMIT IS EXPIRED. 242-WYN's "Nino Gordo"
-- permit GDO-14760 expired 2025-12-31 while its siblings are valid. Returning the right location's expired
-- number is better than returning a DIFFERENT tenant's valid number: the form must identify the trap that
-- was actually serviced, and an expired permit is a known compliance item the office already tracks, while
-- a wrong-tenant permit is a false statement about which trap was pumped. Among MULTIPLE exact matches
-- (43 visits carry 2-3 locations) we still prefer unexpired, then ACTIVE, then number.
--
-- ⚠ KEEP the '^GDO-[0-9]+$' regex on every branch. Without it the driver can be shown 'Not available',
-- 'Needs review', 'BW', 'PSO-00025' (a different permit series) or a multi-permit comma string.
-- ⚠ Never filter `status = 'ACTIVE'` - 22 ACTIVE permits are expired and 42 INACTIVE ones are not, so it
-- HIDES live permits. Prefer ACTIVE via ORDER BY, never require it.
--
-- ⚠ ORDER OF OPERATIONS. The 2-arg function cannot simply be dropped first: `dump_outstanding_visits`
-- DEPENDS on it ("cannot drop function ... because other objects depend on it"), and DROP ... CASCADE
-- would silently take the view with it. So: (1) create the 3-arg version alongside, (2) re-point the view
-- at it, (3) drop the now-unreferenced 2-arg version. The two coexist only inside this transaction, and
-- nothing calls the 2-arg form during that window, so the "function is not unique" ambiguity never fires.
-- The end state is exactly ONE function, as required.
--
-- RULE 8 (ADR 010): no new table, no schema change to an audited table - this is a pure read function.
-- RULE 1: no source-prefixed columns.

CREATE OR REPLACE FUNCTION public.fn_resolve_gdo_number(
  p_client_id   bigint,
  p_property_id bigint,
  p_visit_id    bigint DEFAULT NULL
)
RETURNS text
LANGUAGE sql STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    -- 1. EXACT: this visit's own location(s). The only non-arbitrary answer.
    (
      SELECT g.gdo_number
      FROM public.visit_locations vl
      JOIN public.gdos g
        ON g.client_location_id = vl.client_location_id
       AND g.gdo_number ~ '^GDO-[0-9]+$'
      WHERE p_visit_id IS NOT NULL
        AND vl.visit_id = p_visit_id
      ORDER BY
        (g.permit_expiration IS NULL OR g.permit_expiration >= CURRENT_DATE) DESC,  -- prefer unexpired
        (g.status = 'ACTIVE') DESC,
        g.permit_expiration DESC NULLS LAST,
        g.gdo_number
      LIMIT 1
    ),
    -- 2. FALLBACK: previous client/property-wide behaviour, unchanged.
    (
      SELECT g.gdo_number
      FROM public.gdos g
      WHERE g.gdo_number ~ '^GDO-[0-9]+$'
        AND (g.property_id = p_property_id OR g.client_id = p_client_id)
      ORDER BY
        (g.property_id IS NOT DISTINCT FROM p_property_id) DESC,   -- a GDO is bound to a LOCATION
        (g.status = 'ACTIVE') DESC,                                 -- prefer, never require
        g.permit_expiration DESC NULLS LAST,
        g.gdo_number
      LIMIT 1
    )
  );
$function$;

-- Default privileges auto-grant new functions to anon/authenticated/service_role, so REVOKE FROM PUBLIC
-- alone is not enough (repo memory: reference_supabase_function_default_privileges).
REVOKE ALL     ON FUNCTION public.fn_resolve_gdo_number(bigint, bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_resolve_gdo_number(bigint, bigint, bigint) TO service_role;

-- ---------------------------------------------------------------------------
-- Repoint the DUMP pick-list so it passes the visit through.
-- Column list is unchanged, so plain CREATE OR REPLACE works and grants are preserved.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.dump_outstanding_visits AS
 SELECT p.visit_id,
    p.client_code,
    p.client_name,
    regexp_replace(p.address, ',\s*USA.*$'::text, ''::text, 'i'::text) AS address,
        CASE
            WHEN p.city IS NOT NULL AND regexp_replace(p.address, ',\s*USA.*$'::text, ''::text, 'i'::text) ~* ((',\s*'::text || p.city) || '(\s*,|\s*$)'::text) THEN NULL::text
            ELSE p.city
        END AS city,
    p.visit_date,
    p.completed_at,
    vis.vehicle_id,
    veh.name AS truck,
    gd.gdo_number,
    GREATEST(0, (now() AT TIME ZONE 'America/New_York'::text)::date - p.visit_date) AS age_days,
    GREATEST(0, (now() AT TIME ZONE 'America/New_York'::text)::date - p.visit_date) > 14 AS needs_office,
    h.visit_id IS NOT NULL AS on_sheet,
    emp.full_name AS marked_by,
    h.handed_at AS marked_at,
    vis.assigned_driver_id,
    p.county,
    public.fn_dump_county_bucket(p.county) AS county_bucket,
    (h.visit_id IS NOT NULL AND h.handed_at < now() - interval '6 hours') AS confirmed_hidden,
    h.dump_visit_id AS marked_dump_visit_id
   FROM manifest_pickable_visits p
     JOIN visits vis ON vis.id = p.visit_id
     LEFT JOIN vehicles veh ON veh.id = vis.vehicle_id
     -- now resolves the permit for THIS VISIT's trap, not just the client's first permit
     LEFT JOIN LATERAL ( SELECT public.fn_resolve_gdo_number(p.client_id, vis.property_id, p.visit_id) AS gdo_number ) gd ON true
     LEFT JOIN dump_manifest_handout h ON h.visit_id = p.visit_id
     LEFT JOIN employees emp ON emp.id = h.driver_id;

-- Step 3: the old 2-arg version is now unreferenced. Drop it so exactly ONE resolver exists and no future
-- caller can accidentally bind to the client-wide form.
DROP FUNCTION IF EXISTS public.fn_resolve_gdo_number(bigint, bigint);

-- ---------------------------------------------------------------------------
-- NOTE FOR @Supabase (owner of ops.v_calendar_visit): that view still resolves the GDO with its own
-- LATERAL ordered by `id`, which is why 043-MIL shows GDO-14117 there and GDO-11024 here. Re-point it at
-- this function - passing the visit id - and the two surfaces agree by construction rather than by two
-- ORDER BYs that drift apart again:
--     LEFT JOIN LATERAL (SELECT public.fn_resolve_gdo_number(v.client_id, v.property_id, v.id) AS gdo) g ON true
-- ---------------------------------------------------------------------------
