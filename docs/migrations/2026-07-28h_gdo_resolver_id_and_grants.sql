-- 2026-07-28h  GDO resolver: return the ID (not just the number), and grant EXECUTE to the reader roles
--
-- Both items raised by the @Supabase session against 2026-07-28g. Both were right.
--
-- ============================================================================
-- 1. THE GRANT — EXECUTE is NOT laundered through a non-invoker view
-- ============================================================================
-- `ops.v_calendar_visit` is postgres-owned with reloptions NULL, i.e. NOT security_invoker, so the natural
-- assumption is "the view runs as its owner, so the caller's function grant is irrelevant". **That is true
-- for TABLE privileges and FALSE for FUNCTION EXECUTE**: EXECUTE is checked against the QUERYING role even
-- when the function is called from inside an owner-rights view. Verified live before writing this:
--     has_function_privilege('authenticated',      'fn_resolve_gdo_number(bigint,bigint,bigint)') = false
--     has_function_privilege('yannick_readonly',   ... )                                          = false
-- The Visit Calendar runs as `authenticated`, so wiring this into ops.v_calendar_visit as-is would have
-- given every staff user a hard `42501 permission denied for function` on the calendar.
--
-- ⚠ THE SAME TRAP IS ALREADY LIVE IN MY OWN OBJECT. `public.dump_outstanding_visits` calls this function
-- and is granted SELECT to `yannick_readonly`, which has no EXECUTE — so that role would 42501 on a view it
-- is explicitly allowed to read. Fixed here too. (The DUMP app itself is unaffected: the edge function
-- runs as service_role, which already had EXECUTE.)
--
-- ⚠ WHY THIS GRANT ESCALATES NOTHING. The resolver is SECURITY **INVOKER** (prosecdef = false), so it
-- reads `gdos` / `visit_locations` with the caller's own privileges, and both roles already hold SELECT on
-- both tables (verified: authenticated true/true, yannick_readonly true/true). Granting EXECUTE therefore
-- exposes no row the role could not already read with a plain SELECT — it only removes a mechanical
-- blocker. Do NOT "fix" this by making the function SECURITY DEFINER: that would bypass the caller's
-- privileges and RLS for no benefit.
--
-- ============================================================================
-- 2. RETURN THE ID — because gdo_number is NOT unique
-- ============================================================================
-- ops.v_calendar_visit's drawer needs five fields, not one: gdo_number, permit_expiration,
-- max_frequency_days, permit_document_path, status. Resolving only the text number forces every consumer
-- to join back to `gdos` on the number — and **11 GDO numbers are held by 2 different clients each**
-- (verified live: 212-TRUE/213-TRUE, 045-NU/172-NU, 209-TRUE/214-MYK, 139-LTG/144-LTG, 129-BSC/198-ARY,
-- and 6 more). A join on `gdo_number` alone fans out to 2 rows and can render one client another client's
-- permit expiry and PDF link. Requiring every consumer to remember a client_id-scoped join is a footgun
-- that will eventually be forgotten.
--
-- So the ID-returning function becomes the CORE resolver and the text one becomes a thin wrapper over it.
-- One selection rule, in one place, that cannot drift; consumers that need the whole row join on the
-- PRIMARY KEY, where fan-out is impossible:
--     LEFT JOIN LATERAL (SELECT public.fn_resolve_gdo_id(v.client_id, v.property_id, v.id) AS id) r ON true
--     LEFT JOIN public.gdos g ON g.id = r.id
--
-- Selection logic is byte-identical to 2026-07-28g (visit location first, else property/client), so this
-- migration changes NO resolved value. It only changes what is returned and who may call it.

-- ---------------------------------------------------------------------------
-- Core resolver: returns gdos.id
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolve_gdo_id(
  p_client_id   bigint,
  p_property_id bigint,
  p_visit_id    bigint DEFAULT NULL
)
RETURNS bigint
LANGUAGE sql STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(
    -- 1. EXACT: a permit on one of THIS VISIT's own locations. The only non-arbitrary answer.
    --    An exact match wins even when expired (see 2026-07-28g header: naming the right trap with an
    --    expired permit beats naming a different tenant with a valid one). Among several, prefer unexpired.
    (
      SELECT g.id
      FROM public.visit_locations vl
      JOIN public.gdos g
        ON g.client_location_id = vl.client_location_id
       AND g.gdo_number ~ '^GDO-[0-9]+$'
      WHERE p_visit_id IS NOT NULL
        AND vl.visit_id = p_visit_id
      ORDER BY
        (g.permit_expiration IS NULL OR g.permit_expiration >= CURRENT_DATE) DESC,
        (g.status = 'ACTIVE') DESC,
        g.permit_expiration DESC NULLS LAST,
        g.gdo_number
      LIMIT 1
    ),
    -- 2. FALLBACK: client/property-wide. Never require status='ACTIVE' — 22 ACTIVE permits are expired
    --    and 42 INACTIVE ones are not, so requiring it HIDES live permits. Prefer it via ORDER BY.
    (
      SELECT g.id
      FROM public.gdos g
      WHERE g.gdo_number ~ '^GDO-[0-9]+$'
        AND (g.property_id = p_property_id OR g.client_id = p_client_id)
      ORDER BY
        (g.property_id IS NOT DISTINCT FROM p_property_id) DESC,
        (g.status = 'ACTIVE') DESC,
        g.permit_expiration DESC NULLS LAST,
        g.gdo_number
      LIMIT 1
    )
  );
$function$;

-- ---------------------------------------------------------------------------
-- Text wrapper: same signature as before, now delegating so the rule lives in ONE place.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_resolve_gdo_number(
  p_client_id   bigint,
  p_property_id bigint,
  p_visit_id    bigint DEFAULT NULL
)
RETURNS text
LANGUAGE sql STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT g.gdo_number
  FROM public.gdos g
  WHERE g.id = public.fn_resolve_gdo_id(p_client_id, p_property_id, p_visit_id);
$function$;

-- ---------------------------------------------------------------------------
-- Grants. Default privileges auto-grant new functions to anon/authenticated/service_role, so REVOKE FROM
-- PUBLIC alone is not enough (repo memory: reference_supabase_function_default_privileges): revoke, then
-- grant deliberately. anon stays OUT — the 2026-07-12 harden made anon read-only on business data and
-- there is no anon surface that needs permit resolution.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.fn_resolve_gdo_id(bigint, bigint, bigint)     FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.fn_resolve_gdo_number(bigint, bigint, bigint) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.fn_resolve_gdo_id(bigint, bigint, bigint)     TO service_role, authenticated, yannick_readonly;
GRANT EXECUTE ON FUNCTION public.fn_resolve_gdo_number(bigint, bigint, bigint) TO service_role, authenticated, yannick_readonly;
