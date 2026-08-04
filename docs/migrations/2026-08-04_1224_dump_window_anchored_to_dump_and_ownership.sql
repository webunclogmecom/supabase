-- DUMP: anchor the selection window to the DUMP VISIT, and let the crib sheet name who holds a visit
--
-- Fred 2026-08-04, on the finding that re-confirming kept extending the window:
--   "anchor it to the dump visit time."
-- and, on a second driver taking a visit someone else already selected:
--   "if a visit is already taken and another driver wants to take it, he gets a warning dialog letting
--    him know of what he's doing so he can confirm first before proceeding"
--
-- CHANGE 1 - THE WINDOW IS NOW A PROPERTY OF THE DUMP RUN, NOT OF THE LAST TAP.
-- confirmed_hidden / confirm_expires_at / confirm_minutes_left were all measured from
-- dump_manifest_handout.handed_at, which ON CONFLICT DO UPDATE refreshes on every confirm and link. That
-- meant a driver who kept confirming held a visit open forever, and confirming ONE new visit silently
-- reset the clock for every other visit already on that dump (both proven by probe before this change).
-- All three now measure from COALESCE(dv.start_at, h.handed_at) via a new LEFT JOIN visits dv.
--   * dv.start_at is the dump run's own time, set to now() when the driver taps GO.
--   * the COALESCE fallback covers a mark with NO dump (dump_manifest_mark writes dump_visit_id = NULL);
--     such a row keeps the old handed_at behaviour rather than losing its window entirely.
-- ⚠ handed_at is STILL exposed as marked_at and is still what ON CONFLICT refreshes. It is now "when it
--   was last ticked", not "when the window started". Do not re-point the window at it.
-- ⚠ dv.start_at is NOT always "when the dump happened": live row visit 6593 / dump 7469 was marked 49
--   HOURS BEFORE its dump's start_at (the dump was created 07-30 for an 08-02 slot). Anchoring there
--   gives that shape a window that opens later, which is the honest reading of "the dump visit time",
--   but it is the reason this is a COALESCE and not a bare column.
--
-- CHANGE 2 - dump_manifest_handout_list GAINS held_by + held_dump_visit_id.
-- The crib sheet could already tell that a visit was `confirmed` and not `on_this_dump`, but it could not
-- say WHO held it, so the app had nothing to put in a warning. Both values come straight off
-- dump_outstanding_visits (marked_by / marked_dump_visit_id) - no new joins were added to the function.
-- RETURNS TABLE cannot be widened by CREATE OR REPLACE, so this is DROP + CREATE inside ONE transaction;
-- the function is never absent to a concurrent caller. DEFAULT 7 on p_ttl_days is preserved (the edge fn
-- calls it with two arguments).
-- Re-locked explicitly after recreation: anon=false, service_role=true. Supabase default privileges would
-- otherwise hand a freshly created function to anon/authenticated.
--
-- NOT CHANGED, deliberately: the ledger PK is still visit_id alone, so a second driver CAN still take a
-- visit. Fred's ruling is that this stays possible and is gated by a confirmation dialog in the app, not
-- forbidden in the database ("we don't care if a driver gets notified or not").
-- Also unchanged: the 2026-08-03_1945 generated-sheet WHERE, and the 22-column list/order of the view.
--
-- ROLLED-BACK PROBE, control fired (view 0 rows -> 11 with the sheets soft-deleted):
--   before simulated re-confirm            224 min left
--   after handed_at := now()               224 min left   <- no longer extends. THIS IS THE FIX.
--   dump start_at backdated 7h             hidden, 0 min left
--   dump start_at 1h ago                   not hidden, 300 min left
--   crib-sheet rows carrying held_by       6
-- Nothing committed: 17 live sheets, view still 0 rows, newest mark unchanged.
--
-- ADR 010 rule 8: view + function only, no table or column -> no audit-trigger decision.
-- REVERSIBLE: re-point the three expressions at h.handed_at and drop the two columns.

BEGIN;

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
    fn_dump_county_bucket(p.county) AS county_bucket,
    h.visit_id IS NOT NULL AND COALESCE(dv.start_at, h.handed_at) < (now() - fn_dump_confirm_window()) AS confirmed_hidden,
    h.dump_visit_id AS marked_dump_visit_id,
    COALESCE(dv.start_at, h.handed_at) + fn_dump_confirm_window() AS confirm_expires_at,
        CASE
            WHEN h.visit_id IS NULL THEN NULL::integer
            ELSE GREATEST(0, (EXTRACT(epoch FROM COALESCE(dv.start_at, h.handed_at) + fn_dump_confirm_window() - now()) / 60::numeric)::integer)
        END AS confirm_minutes_left
   FROM manifest_pickable_visits p
     JOIN visits vis ON vis.id = p.visit_id
     LEFT JOIN vehicles veh ON veh.id = vis.vehicle_id
     LEFT JOIN LATERAL ( SELECT fn_resolve_gdo_number(p.client_id, vis.property_id, p.visit_id) AS gdo_number) gd ON true
     LEFT JOIN dump_manifest_handout h ON h.visit_id = p.visit_id
     LEFT JOIN visits dv ON dv.id = h.dump_visit_id
     LEFT JOIN employees emp ON emp.id = h.driver_id
  WHERE NOT (EXISTS ( SELECT 1
           FROM derm.address_sheet_clients a
             JOIN derm.address_sheets s ON s.id = a.sheet_id
          WHERE a.visit_id = p.visit_id AND s.deleted_at IS NULL));

DROP FUNCTION public.dump_manifest_handout_list(bigint, bigint, integer);

CREATE FUNCTION public.dump_manifest_handout_list(p_driver_id bigint, p_dump_visit_id bigint, p_ttl_days integer DEFAULT 7)
 RETURNS TABLE(bucket text, visit_id bigint, client_code text, client_name text, address text, city text, visit_date date, completed_at timestamp with time zone, age_days integer, truck text, gdo_number text, needs_office boolean, confirmed boolean, on_this_dump boolean, county text, county_bucket text, held_by text, held_dump_visit_id bigint)
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
         b.county, b.county_bucket,
         b.marked_by AS held_by,
         b.marked_dump_visit_id AS held_dump_visit_id
  FROM bucketed b
  -- newest completed first, across the whole list (Fred 2026-07-28)
  ORDER BY b.completed_at DESC NULLS LAST, b.visit_id DESC;
END;
$function$;

REVOKE ALL     ON FUNCTION public.dump_manifest_handout_list(bigint,bigint,integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.dump_manifest_handout_list(bigint,bigint,integer) TO service_role;

COMMIT;