-- 2026-07-28  DUMP: county gate, unified GDO resolver, missing-docs list, 6h confirmed-hide
--
-- WHY (Fred 2026-07-28), four separate asks that all land on the same two DB objects:
--   1. "we cannot show visits from Broward to Homestead (MIAMI dump), but we can show both when they
--      select Pompano" -> county-gate the manifest pick-list by the DUMP SITE.
--   2. "add the GDO number on the Miami visits shown to select" -> it is ALREADY rendered; the real defect
--      is the resolver (see below).
--   3. the dump crib sheet must become an ALL-DRIVERS "missing documents" list, newest-completed first.
--   4. VIEW ADDRESSES: confirmed rows hide 6h after being marked (with an in-app escape hatch).
--
-- ============================================================================
-- 1. COUNTY GATE
-- ============================================================================
-- ⚠ THE TRAP THAT WOULD HAVE SHIPPED SILENTLY: public.properties.county stores 'Dade', but the edge
-- function's DUMPS.DH.county literal is 'Miami-Dade', and disposal_facilities/customer.work_orders also use
-- 'Miami-Dade'. A natural `stop.county = dump.county` comparison is therefore ALWAYS FALSE, which renders
-- an EMPTY pick-list at Homestead and files nothing. It fails in the most dangerous direction and it fails
-- silently, because an empty list is a legal state. Hence: normalise to a BUCKET, never compare raw text.
--
-- Vocabulary actually present in public.properties.county (exact counts 2026-07-28):
--   'Dade' 671 | 'Broward' 123 | 'Palm Beach' 6 | 'None' 3 (a STRING, not NULL) | NULL 13
-- so the normaliser must handle: case, whitespace, the 'Miami-Dade' spelling, the literal 'None', '' and
-- NULL. `COALESCE(county,'UNKNOWN')` does NOT catch 'None'.
--
-- PALM BEACH -> BROWARD (Fred's call 2026-07-28). There are 7 completed DERM visits from 3 live RECURRING
-- clients (051-PV Pura Vida Delray, 023-GRO Grove Kosher Delray, 225-PV Pura Vida Boca). This matches the
-- existing ops convention already hardcoded in webhook-jobber's inferCountyFromCity, which files Boca Raton
-- under Broward. Without this they would fall through BOTH branches and become permanently unfilable.
--
-- UNKNOWN is ALLOWED AT BOTH SITES, deliberately. County is set on INSERT only (webhook-jobber), from a
-- 29-city list, and Airtable (its only other writer) is retired, so a NULL county never self-heals. 3 live
-- clients are already countyless (288-PER West Miami, 289-PER Palmetto Bay, 277-VSS Coral Springs). Their
-- first DERM visit must NOT silently vanish from the app: "unknown" is not "Broward".
--
-- ⚠ WHERE THE GATE MAY *NOT* GO: public.manifest_pickable_visits. That view is granted to anon +
-- authenticated, is security_invoker, and is the DERM Tracker /upload "match to visits" matcher. A
-- dump-site predicate there would silently shrink an office app with nothing to do with dump sites - and
-- there is prior art for exactly that accident (DERM Tracker changelog: 214-MYK vanished from /upload after
-- a filter was added to this view). The gate lives in the DUMP-exclusive objects only.
--
-- ⚠ SCOPE: this gate is READ-side (the pick-list). The write RPCs are NOT hard-blocked in this migration,
-- because dump_manifest_mark carries no dump id at all (the driver ticks BEFORE choosing a site on the
-- OLDER VISITS path). Filing a cross-county load remains possible by design; the app simply stops offering
-- it. Note for context: non-Dade grease has been filed onto the Miami-Dade facility 28 times across 12
-- tickets (most recently white 831102 on 2026-07-27), so this is a behaviour change for the crew, not a
-- cosmetic filter.

CREATE OR REPLACE FUNCTION public.fn_dump_county_bucket(p_county text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_county IS NULL THEN 'UNKNOWN'
    WHEN btrim(p_county) = '' THEN 'UNKNOWN'
    WHEN lower(btrim(p_county)) = 'none' THEN 'UNKNOWN'          -- a STRING-typed null, 3 rows
    WHEN lower(btrim(p_county)) IN ('dade', 'miami-dade', 'miami dade') THEN 'DADE'
    WHEN lower(btrim(p_county)) IN ('broward', 'palm beach', 'palm-beach') THEN 'BROWARD'
    ELSE 'UNKNOWN'                                                -- a 5th literal appears -> never strand it
  END;
$function$;

-- Which counties may be filed at a given dump SITE (keyed on the dump client_id, not on a text county).
--   365 = 000-DH Homestead, the MIAMI-DADE facility -> Dade only (+ unknown)
--    76 = 000-DP Pompano,   the BROWARD facility    -> everything
CREATE OR REPLACE FUNCTION public.fn_dump_site_accepts(p_dump_client_id bigint, p_county text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT CASE
    WHEN p_dump_client_id = 365 THEN public.fn_dump_county_bucket(p_county) IN ('DADE', 'UNKNOWN')
    ELSE true                                     -- Pompano (76) accepts both counties
  END;
$function$;

-- ============================================================================
-- 2. UNIFIED GDO RESOLVER
-- ============================================================================
-- The GDO is ALREADY rendered on the pick rows, so nothing new is needed in the UI. What IS broken is the
-- resolver, in two ways found on live data:
--   * `WHERE g.status = 'ACTIVE'` HIDES LIVE PERMITS. 22 ACTIVE rows are already expired and 42 INACTIVE
--     rows are not, so status is not a validity signal. 087-BB is on the outstanding list right now with a
--     real permit that the current view refuses to show. -> prefer ACTIVE via ORDER BY, never require it.
--   * Two screens of the SAME app disagree: this view orders by gdo_number and picks GDO-11024 for Mila,
--     while ops.v_calendar_visit orders by id and picks GDO-14117. One visit, two permit numbers.
-- A GDO is issued to a LOCATION, not a business (repo rule), so a property-level match must win over a
-- client-level one.
-- ⚠ KEEP the '^GDO-[0-9]+$' regex. It is load-bearing: without it the driver would be shown 'Not available'
-- (22 rows), 'Needs review' (4), 'BW' (7), 'GDO-08912-DUPMERGE-147', 'PSO-00025' (a DIFFERENT permit
-- series), and multi-permit comma strings like 'GDO-10877, GDO-15062, GDO-16389'. He copies this straight
-- onto a DERM form under a printed "GDO #" heading. It must be a real GDO number or nothing at all.

CREATE OR REPLACE FUNCTION public.fn_resolve_gdo_number(p_client_id bigint, p_property_id bigint)
RETURNS text
LANGUAGE sql STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT g.gdo_number
  FROM public.gdos g
  WHERE g.gdo_number ~ '^GDO-[0-9]+$'
    AND (g.property_id = p_property_id OR g.client_id = p_client_id)
  ORDER BY
    (g.property_id IS NOT DISTINCT FROM p_property_id) DESC,  -- the permit is bound to the LOCATION
    (g.status = 'ACTIVE') DESC,                                -- prefer, never require
    g.permit_expiration DESC NULLS LAST,
    g.gdo_number
  LIMIT 1;
$function$;

-- Supabase default privileges auto-grant new functions to anon/authenticated/service_role, so REVOKE FROM
-- PUBLIC alone is NOT enough (repo memory: reference_supabase_function_default_privileges).
REVOKE ALL     ON FUNCTION public.fn_resolve_gdo_number(bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_resolve_gdo_number(bigint, bigint) TO service_role;
REVOKE ALL     ON FUNCTION public.fn_dump_county_bucket(text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_dump_county_bucket(text) TO service_role;
REVOKE ALL     ON FUNCTION public.fn_dump_site_accepts(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.fn_dump_site_accepts(bigint, text) TO service_role;

-- ============================================================================
-- 3. dump_outstanding_visits: expose county + a 6h confirmed-hide flag
-- ============================================================================
-- CREATE OR REPLACE VIEW can only APPEND columns, never reorder or drop, so the four new columns go at the
-- end and every existing consumer is untouched. Grants are preserved by CREATE OR REPLACE (no re-GRANT
-- needed); this view is granted only to postgres/service_role/yannick_readonly, i.e. DUMP-exclusive.
--
-- confirmed_hidden: TRUE once a mark is >6h old (Fred: "confirmed visits should hide after 6 hours once
-- marked confirmed"). It is a FLAG, not a filter - the view still returns the row so that:
--   (a) the app can offer a "show confirmed" toggle, and
--   (b) a MISTAKEN mark stays fixable. ⚠ This matters more than it looks: dump_manifest_mark(on=false) is
--       reachable ONLY from VIEW ADDRESSES, and dump_manifest_handout_release can NEVER clear an
--       addresses-sourced mark (those rows carry dump_visit_id = NULL, and `NULL = <value>` is never true).
--       So a hard hide at the VIEW level would make a wrong tap permanently unremovable except by hand SQL,
--       for EVERY driver at once (the ledger PK is visit_id alone, one row per visit globally).
-- ⚠ handed_at is refreshed by ON CONFLICT DO UPDATE on every re-confirm, so this is "6h since the LAST
-- mark", not "6h since first marked". Do not document it as the latter.

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
    -- appended 2026-07-28 --------------------------------------------------
    p.county,
    public.fn_dump_county_bucket(p.county) AS county_bucket,
    (h.visit_id IS NOT NULL AND h.handed_at < now() - interval '6 hours') AS confirmed_hidden,
    h.dump_visit_id AS marked_dump_visit_id
   FROM manifest_pickable_visits p
     JOIN visits vis ON vis.id = p.visit_id
     LEFT JOIN vehicles veh ON veh.id = vis.vehicle_id
     LEFT JOIN LATERAL ( SELECT public.fn_resolve_gdo_number(p.client_id, vis.property_id) AS gdo_number ) gd ON true
     LEFT JOIN dump_manifest_handout h ON h.visit_id = p.visit_id
     LEFT JOIN employees emp ON emp.id = h.driver_id;

-- ============================================================================
-- 4. dump_manifest_handout_list: county-gated, all-drivers "missing documents" list
-- ============================================================================
-- Fred: "show a list of the visits missing documents ... show all incomplete visits regardless of which
-- driver completed them, so subsequent drivers see prior work needing documentation", sorted by completion
-- time, newest first.
--
-- Verified equivalence before changing anything: derm.visits classifies 9 visits as "Missing Docs" today,
-- and public.dump_outstanding_visits contains EXACTLY those 9 visit ids (both=9, derm_only=0, dump_only=0).
-- So the DUMP app's outstanding set ALREADY IS the DERM app's missing-docs set - no new classification is
-- being invented here, the crib sheet simply stops hiding most of it.
--
-- WHAT CHANGES:
--   * county gate on the dump site (see section 1).
--   * NEW `on_this_dump` column. ⚠ Load-bearing: the app's checkbox previously bound to `confirmed`
--     (= on_sheet, a GLOBAL flag). Now that other drivers' rows are visible, binding the checkbox to a
--     global flag would make CONFIRM's `ON CONFLICT (visit_id) DO UPDATE SET dump_visit_id=<this dump>,
--     driver_id=<this driver>` silently STEAL rows another driver had already written to his own sheet.
--     The checkbox must bind to on_this_dump.
--   * ordering is now newest-completed-first across the whole list.
-- WHAT DELIBERATELY DOES NOT CHANGE:
--   * `bucket` keeps its driver-scoped meaning ('load' = this driver's current shift). It is what the Slack
--     CONFIRM alert uses for its "Missing - scheduled today, not added" line. Un-scoping it would turn that
--     line into every unticked visit in the company, listed under the name of whoever happened to confirm.
--     The screen and the alert have different jobs; they stop sharing one predicate here.

-- ⚠ MUST DROP FIRST: adding OUT columns changes the return row type, which CREATE OR REPLACE cannot do
-- ("cannot change return type of existing function"). Safe here: the ONLY caller is the dump-visit-create
-- edge function (repo-wide grep), it is recreated in the same transaction, and its grants are restored
-- verbatim below. Pre-drop proacl, captured live: {postgres=X/postgres, service_role=X/postgres}
-- i.e. NO anon, NO authenticated.
DROP FUNCTION IF EXISTS public.dump_manifest_handout_list(bigint, bigint, integer);

CREATE OR REPLACE FUNCTION public.dump_manifest_handout_list(p_driver_id bigint, p_dump_visit_id bigint, p_ttl_days integer DEFAULT 7)
 RETURNS TABLE(bucket text, visit_id bigint, client_code text, client_name text, address text, city text, visit_date date, completed_at timestamp with time zone, age_days integer, truck text, gdo_number text, needs_office boolean, confirmed boolean, on_this_dump boolean, county text, county_bucket text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_since     timestamptz;
  v_dump_cli  bigint;
BEGIN
  -- which SITE is being filed? (365 Homestead / 76 Pompano) - drives the county gate
  SELECT v.client_id INTO v_dump_cli
  FROM public.visits v WHERE v.id = p_dump_visit_id;

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
    -- COUNTY GATE: Homestead may only be handed Dade (or unknown-county) work; Pompano takes everything.
    -- v_dump_cli NULL (unknown dump) falls through to TRUE rather than hiding everything.
    WHERE v_dump_cli IS NULL OR public.fn_dump_site_accepts(v_dump_cli, o.county)
  )
  SELECT b.bucket, b.visit_id, b.client_code, b.client_name, b.address, b.city, b.visit_date,
         b.completed_at, b.age_days, b.truck, b.gdo_number, b.needs_office,
         b.on_sheet AS confirmed,
         (b.marked_dump_visit_id IS NOT DISTINCT FROM p_dump_visit_id AND b.on_sheet) AS on_this_dump,
         b.county, b.county_bucket
  FROM bucketed b
  -- newest completed first, across the whole list (Fred 2026-07-28)
  ORDER BY b.completed_at DESC NULLS LAST, b.visit_id DESC;
END;
$function$;

-- Restore the exact pre-drop grant set (service_role only; the edge fn is the sole caller).
REVOKE ALL     ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, integer) TO service_role;

-- ============================================================================
-- 5. How many rows does the Homestead gate actually hide? (documented, not enforced)
-- ============================================================================
-- At write time: 9 outstanding rows = 7 Dade + 2 Broward (196-PV Pura Vida Pembroke Pines, 028-HUM Hummus
-- Achla), both completed by the SAME truck (David) on the same day as Dade rows. So at Homestead the driver
-- now sees 7 of 9. The app surfaces a muted "N hidden - file at Pompano" line so the shortfall is stated
-- rather than silent (the repo's own rule: "a blank crib sheet and a broken request look identical to a
-- driver at 2 AM").
