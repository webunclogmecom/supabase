-- 2026-07-22b  Driver checklist for the manifest hand-out (#2) — split view from record, add release.
--
-- ============================================================================
-- WHY (Fred)
-- ============================================================================
-- The crib sheet used to RECORD a hand-out for every visit the moment the receipt screen was fetched
-- (an INSERT inside dump_manifest_handout_list, fired from a React mount). So merely looking at the
-- screen, or landing on the wrong dump, marked clients as handed out — and with the 2026-07-22
-- hide-until-filed change there is no longer a 7-day auto-expiry to undo that. Fred's fix: make it a
-- CHECKLIST. The driver ticks the clients whose grease is actually on this load and taps Confirm;
-- only the ticked ones get recorded (and hidden from other dumps until filed). Nothing is recorded by
-- viewing. A release path lets a wrong tick be undone.
--
-- ============================================================================
-- THREE FUNCTIONS
-- ============================================================================
--  1. dump_manifest_handout_list  — now READ-ONLY (no INSERT) + a `confirmed` flag per row so the UI
--     can pre-check what was already confirmed on THIS dump. Same hide rule (a visit handed out on
--     ANOTHER dump is hidden until filed). DROP+CREATE because the return shape gains a column.
--  2. dump_manifest_handout_confirm(driver, dump_visit, visit_ids[]) — sets THIS dump's confirmed
--     hand-outs to EXACTLY visit_ids: deletes this dump's rows no longer ticked, inserts the ticked
--     ones. Idempotent, so re-confirming with a changed selection both adds and removes. Only visits
--     that are genuinely outstanding and not already claimed by another dump can be confirmed
--     (defense against a stale client tapping a since-claimed visit). Returns the confirmed rows so
--     the edge fn can build the Slack alert.
--  3. dump_manifest_handout_release(dump_visit, visit_ids[]) — explicit undo: removes the given
--     visits' hand-outs for this dump. NULL/empty visit_ids releases ALL of this dump's hand-outs.
--
-- The hand-out ledger is empty (feature never ran for a real driver), so there is nothing to migrate.
--
-- GRANTS: all three are service_role-only (the dump edge fn holds service_role; anon is read-only by
-- the 2026-07-12 harden and must never write). Default privileges auto-grant PUBLIC/anon on a fresh
-- function, so each is explicitly REVOKEd from PUBLIC/anon/authenticated then GRANTed to service_role.
-- AUDIT (ADR 010): dump_manifest_handout keeps its existing posture; these are its writers.

-- ---------------------------------------------------------------------------
-- 1. READ-ONLY list with a `confirmed` flag
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.dump_manifest_handout_list(bigint, bigint, integer);

CREATE FUNCTION public.dump_manifest_handout_list(p_driver_id bigint, p_dump_visit_id bigint, p_ttl_days integer DEFAULT 7)
 RETURNS TABLE(bucket text, visit_id bigint, client_code text, client_name text, address text, city text, visit_date date, completed_at timestamp with time zone, age_days integer, truck text, gdo_number text, needs_office boolean, confirmed boolean)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_truck_id bigint;
  v_since    timestamptz;
BEGIN
  SELECT o.vehicle_id INTO v_truck_id FROM public.dump_driver_origin(p_driver_id) o;

  SELECT max(v.start_at) INTO v_since
  FROM public.visits v
  WHERE v.assigned_driver_id = p_driver_id
    AND v.client_id IN (76, 365)
    AND v.deleted_at IS NULL
    AND v.id <> p_dump_visit_id;
  v_since := COALESCE(v_since, now() - interval '7 days');

  RETURN QUERY
  WITH candidate AS (
    SELECT o.*
    FROM public.dump_outstanding_visits o
    -- hidden while handed out on a DIFFERENT dump (until filed; p_ttl_days deliberately unused).
    WHERE NOT EXISTS (
      SELECT 1 FROM public.dump_manifest_handout h
      WHERE h.visit_id = o.visit_id
        AND h.dump_visit_id <> p_dump_visit_id
    )
  ),
  bucketed AS (
    SELECT c.*,
      CASE
        WHEN v_truck_id IS NOT NULL AND c.vehicle_id = v_truck_id
         AND c.completed_at IS NOT NULL AND c.completed_at > v_since
        THEN 'load' ELSE 'outstanding'
      END AS bucket
    FROM candidate c
  )
  SELECT b.bucket, b.visit_id, b.client_code, b.client_name, b.address, b.city, b.visit_date,
         b.completed_at, b.age_days, b.truck, b.gdo_number, b.needs_office,
         EXISTS (SELECT 1 FROM public.dump_manifest_handout h
                  WHERE h.visit_id = b.visit_id AND h.dump_visit_id = p_dump_visit_id) AS confirmed
  FROM bucketed b
  ORDER BY (b.bucket = 'load') DESC,
           CASE WHEN b.bucket = 'load' THEN b.completed_at END ASC,
           CASE WHEN b.bucket <> 'load' THEN b.completed_at END DESC NULLS LAST;
END;
$function$;

REVOKE ALL ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 2. CONFIRM — set this dump's hand-outs to exactly the ticked visit_ids
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dump_manifest_handout_confirm(p_driver_id bigint, p_dump_visit_id bigint, p_visit_ids bigint[])
 RETURNS TABLE(visit_id bigint, client_code text, client_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_ids bigint[] := COALESCE(p_visit_ids, ARRAY[]::bigint[]);
BEGIN
  -- remove any previously-confirmed visit for THIS dump that is no longer ticked
  DELETE FROM public.dump_manifest_handout h
   WHERE h.dump_visit_id = p_dump_visit_id
     AND NOT (h.visit_id = ANY (v_ids));

  -- confirm the ticked ones — but ONLY visits that are genuinely still outstanding and not already
  -- claimed by a different dump (a since-claimed or since-filed visit cannot be confirmed here).
  INSERT INTO public.dump_manifest_handout (visit_id, dump_visit_id, driver_id)
  SELECT o.visit_id, p_dump_visit_id, p_driver_id
  FROM public.dump_outstanding_visits o
  WHERE o.visit_id = ANY (v_ids)
    AND NOT EXISTS (
      SELECT 1 FROM public.dump_manifest_handout h2
      WHERE h2.visit_id = o.visit_id AND h2.dump_visit_id <> p_dump_visit_id)
  ON CONFLICT (visit_id, dump_visit_id) DO NOTHING;

  RETURN QUERY
  SELECT o.visit_id, o.client_code, o.client_name
  FROM public.dump_outstanding_visits o
  JOIN public.dump_manifest_handout h ON h.visit_id = o.visit_id AND h.dump_visit_id = p_dump_visit_id
  ORDER BY o.completed_at DESC NULLS LAST;
END;
$function$;

REVOKE ALL ON FUNCTION public.dump_manifest_handout_confirm(bigint, bigint, bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dump_manifest_handout_confirm(bigint, bigint, bigint[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 3. RELEASE — explicit undo for a wrong tick
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dump_manifest_handout_release(p_dump_visit_id bigint, p_visit_ids bigint[] DEFAULT NULL)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_n integer;
BEGIN
  DELETE FROM public.dump_manifest_handout h
   WHERE h.dump_visit_id = p_dump_visit_id
     AND (p_visit_ids IS NULL OR h.visit_id = ANY (p_visit_ids));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$function$;

REVOKE ALL ON FUNCTION public.dump_manifest_handout_release(bigint, bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dump_manifest_handout_release(bigint, bigint[]) TO service_role;
