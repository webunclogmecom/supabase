-- ============================================================================
-- 2026-10-07 · DUMP Slack counts: the load window, test dumps, and a deleted dump's marks
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-07: "Is it good now? does it sends notifications with the correct Headline depending on what
--   it notifies? what about the body/format of the message". A 20-agent review of the five Slack messages
--   (headers all correct) found the DUMP numbers wrong on real nights; Fred: fix "All, as in the preview".
--
-- WHAT WAS WRONG (each replayed on Prod data)
--   1. A DELETED dump kept its marks. Diego's dump 8738 (Oct 5 4:13 PM ET) confirmed Michael's 191-TEN and 056-STM,
--      then was soft-deleted from the Visit Calendar at 5:00 PM. Its two dump_manifest_handout rows stayed, so on
--      Michael's dump 8740 (11:21 PM) both counted as already reported: the thread said "Reported on this load (7)"
--      with NO Missing list while two DERM pickups had no manifest (put on sheet 1130 by hand on Oct 6).
--      Only dump_test_cleanup released a dump's marks, and only for [TEST] dumps.
--   2. A dump scheduled AHEAD in the Calendar for the same driver ended the "since his last dump" window in the
--      future, so the load read 0 ("No completed DERM pickups") and Missing could never list anything (dump 7480,
--      Mark, Jul 31: 5 real pickups). Same for a confirm made on an older dump after the driver dumped again.
--   3. A [TEST] dump logged under a real driver's name moved that driver's real window the same way.
--   4. Test and fixture clients (112-YA, ...) counted in a REAL dump's "older" line.
--
-- WHAT CHANGES
--   A. public.dump_manifest_handout_list (body copied from the live definition, md5 pinned; diff = these lines):
--      - the window ends at the driver's last dump that started BEFORE this one (v.start_at < this dump's start,
--        now() if it has none), and ignores [TEST] dumps unless this dump is itself [TEST];
--      - test and fixture clients (public.fn_is_non_customer kinds 'test','fixture') are left out unless this dump
--        is [TEST]. The county gate, the columns, the buckets and the order are unchanged.
--   B. NEW trigger trg_zz_dump_delete_releases_holds on public.visits (AFTER UPDATE OF deleted_at, live -> deleted,
--      dump-site visits only) -> public.fn_dump_delete_releases_holds() deletes that dump's dump_manifest_handout
--      rows (audited by audit_dump_manifest_handout, so each is recoverable from audit.logs.old_row). The pickups
--      go back to Missing / older. SECURITY DEFINER: the Calendar soft-deletes as authenticated, which holds no
--      grant on the ledger. EXECUTE revoked from everyone (a trigger needs none).
--
-- NOT CHANGED
--   - The 8 marks already pointing at deleted dumps (7675, 7676, 8738): all 8 visits are on DERM sheets now, so
--     dump_outstanding_visits no longer lists them; left as they are.
--   - Visits restored after a delete do not get their marks back (re-tick them).
--   - The edge function's wording and new lines ship separately in dump-visit-create (same day).
--
-- PROVEN BEFORE APPLY (rolled-back probe, old body kept as pg_temp.old_handout_list for the control):
--   T0 Michael filing 8745 (nothing ahead, no test dump): old and new identical, 0 rows differ
--   T2 a dump 2 days ahead:        new load 4, OLD load 0 (the bug)
--   T3 a [TEST] dump at 05:00 UTC: new 4, old 3; when the dump being filed is [TEST]: 3 (test dumps still count)
--   T4 025-GRO marked as a test client: left out of a real dump (old: in), kept on a [TEST] dump
--   T5 soft-delete dump 8725 holding 6582: its hold goes, 6582 is unconfirmed again, a hold on 8745 stays;
--      control: soft-deleting a customer visit leaves holds alone
--   T6 Broward 093-KC still hidden at Homestead (county gate unchanged)
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no new table. dump_manifest_handout is audited (audit_dump_manifest_handout).
-- ROLLBACK: DROP TRIGGER trg_zz_dump_delete_releases_holds ON public.visits;
--           DROP FUNCTION public.fn_dump_delete_releases_holds();
--           re-apply the body of public.dump_manifest_handout_list from 2026-09-07_1720 (md5 adfb403e...).
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pre$
BEGIN
  IF md5(pg_get_functiondef('public.dump_manifest_handout_list(bigint,bigint,integer)'::regprocedure)) <> 'adfb403e12a603ce680536c4d3482ac3' THEN
    RAISE EXCEPTION 'dump_manifest_handout_list moved since 2026-09-07_1720: copy the live body again';
  END IF;
END $pre$;

CREATE OR REPLACE FUNCTION public.dump_manifest_handout_list(p_driver_id bigint, p_dump_visit_id bigint, p_ttl_days integer DEFAULT 7)
 RETURNS TABLE(bucket text, visit_id bigint, client_code text, client_name text, address text, city text, visit_date date, completed_at timestamp with time zone, age_days integer, truck text, gdo_number text, needs_office boolean, confirmed boolean, on_this_dump boolean, county text, county_bucket text, held_by text, held_dump_visit_id bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_since     timestamptz;
  v_dump_cli  bigint;
  v_dump_start timestamptz;
  v_is_test   boolean;
BEGIN
  -- which SITE is being filed? (365 Homestead / 76 Pompano) - drives the county gate
  -- and when it started, and whether it is a [TEST] dump (the DUMP app's test mode writes [TEST] in its notes)
  SELECT v.client_id, v.start_at, coalesce(v.notes, '') LIKE '%[TEST]%'
    INTO v_dump_cli, v_dump_start, v_is_test
  FROM public.visits v WHERE v.id = p_dump_visit_id;
  v_is_test := coalesce(v_is_test, false);

  -- "since this driver's last dump" = the current-load window (exclude the dump being filed)
  SELECT max(v.start_at) INTO v_since
  FROM public.visits v
  WHERE v.assigned_driver_id = p_driver_id
    AND public.fn_is_non_customer(v.client_id, ARRAY['dump_site'])
    AND v.deleted_at IS NULL
    AND v.id <> p_dump_visit_id
    -- 2026-10-07: only a dump that started BEFORE this one ends the window. A dump scheduled ahead in the
    -- Calendar put v_since in the future and emptied the load (Mark, dump 7480, Jul 31).
    AND v.start_at < COALESCE(v_dump_start, now())
    -- and a [TEST] dump never moves a real dump's window
    AND (v_is_test OR coalesce(v.notes, '') NOT LIKE '%[TEST]%');
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
    WHERE (v_dump_cli IS NULL OR public.fn_dump_site_accepts(v_dump_cli, o.county))
      -- 2026-10-07: test and fixture clients (112-YA, ...) count only on a [TEST] dump
      AND (v_is_test OR NOT public.fn_is_non_customer((SELECT x.client_id FROM public.visits x WHERE x.id = o.visit_id), ARRAY['test','fixture']))
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

CREATE FUNCTION public.fn_dump_delete_releases_holds() RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- A deleted dump reported nothing: its marks go, so its pickups are "Missing" or "older" again (2026-10-07).
  IF public.fn_is_non_customer(NEW.client_id, ARRAY['dump_site']) THEN
    DELETE FROM public.dump_manifest_handout WHERE dump_visit_id = NEW.id;
  END IF;
  RETURN NULL;
END $function$;
REVOKE ALL ON FUNCTION public.fn_dump_delete_releases_holds() FROM PUBLIC, anon, authenticated, service_role;
CREATE TRIGGER trg_zz_dump_delete_releases_holds
  AFTER UPDATE OF deleted_at ON public.visits
  FOR EACH ROW WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
  EXECUTE FUNCTION public.fn_dump_delete_releases_holds();

DO $verify$
DECLARE acl text;
BEGIN
  SELECT p.proacl::text INTO acl FROM pg_proc p WHERE p.oid = 'public.dump_manifest_handout_list(bigint,bigint,integer)'::regprocedure;
  IF acl IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN RAISE EXCEPTION 'handout_list ACL changed: %', acl; END IF;
  IF has_function_privilege('authenticated', 'public.fn_dump_delete_releases_holds()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.fn_dump_delete_releases_holds()', 'EXECUTE') THEN
    RAISE EXCEPTION 'trigger function is executable by an app role'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_zz_dump_delete_releases_holds' AND tgrelid = 'public.visits'::regclass AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'trigger missing'; END IF;
  IF position('v.start_at < COALESCE(v_dump_start, now())' in pg_get_functiondef('public.dump_manifest_handout_list(bigint,bigint,integer)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'new body not in place'; END IF;
END $verify$;

COMMIT;
