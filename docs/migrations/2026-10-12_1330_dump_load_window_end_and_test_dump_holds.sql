-- ============================================================================
-- 2026-10-12_1330 DUMP: a load ends when its dump starts, and a [TEST] dump cannot hold a real pickup
-- ============================================================================
-- THE ASK
--   The 2026-10-12 notification audit (after the 11 AM "Admin Review: photos and city emails" false alarms) checked
--   every Slack post against what the apps show. For the DUMP posts it found, each replayed on Prod:
--   (b) "The load window has no upper bound: a confirm or crib sheet on an older dump counts pickups completed
--       after that dump."
--   (c) "A [TEST] dump can hold real customer pickups (confirm and link do not refuse them), which hides them from
--       real dumps until test cleanup."
--   (a) "The parent 'to report on this load' count includes pickups already held by another dump, while the
--       thread's Missing list leaves them out." That one is fixed in the edge function dump-visit-create, in the
--       same cycle (with scripts/checks/dump_load_lines.mjs); there is no SQL change for it.
--   Decision for this cycle: fix (a), (b) and (c), and pick the VERIFY control dump at run time.
--
-- WHAT WAS WRONG (measured 2026-10-12 13:05 ET)
--   b. dump_manifest_handout_list buckets a pickup as 'load' when completed_at > the driver's previous dump start,
--      with no end. dump_manifest_handout_list(40, 8754) (Michael, Homestead, started Oct 8 01:32 ET) returns 5
--      'load' rows completed Oct 11 22:23 to Oct 12 09:44 ET: a confirm on 8754 now would post "Missing (5)" under
--      the Oct 8 thread. It has not happened yet (of 28 real crib-sheet holds of a driver's own pickups, 0 were
--      completed after their dump started), but a crib sheet left open reaches it.
--   c. On a [TEST] dump the list returns every real outstanding pickup (the 2026-10-07 clause only ADDS test
--      clients), and confirm / link insert any outstanding visit. audit.logs: 29 holds of real customer visits on
--      [TEST] dumps (Jul 27-28 dumps 7380-7424, and Oct 5 test dump 8737 holding Michael's real 056-STM 3 minutes
--      before Diego's real dump 8738 took it). While held, a real pickup reads as reported (out of Missing and out
--      of the other-pickups count) until test cleanup. The app sends test_mode only on create, so link reaches a
--      test dump only by a direct call; confirm (the crib sheet of a test-mode GO) is the real path.
--
-- WHAT CHANGES (bodies copied from pg_get_functiondef, md5 pinned below; only these lines differ from the live ones)
--   1. dump_manifest_handout_list: a 'load' row must also be completed no later than 30 minutes after this dump
--      began. "Began" is its start, or the moment the dump visit was created if that is later: an app dump is
--      created at GO, and an office edit in the Visit Calendar can move its start afterwards (dump 7882 was moved
--      29 h after GO), which must never push the driver's real pickups out of Missing. Later pickups become
--      'outstanding' and still show on the crib sheet (the app shows both lists together), so nothing leaves the
--      driver's phone. The 30 minutes cover the start that Jobber rounds down to the minute (8740: 39 s before
--      GO, 8754: 52 s) and a completion tapped just after GO. A dump with no start (unknown id) keeps no end, as
--      today. The test rule becomes one rule both ways: is a test client = this dump is [TEST] (a real dump was
--      already leaving them out; a [TEST] dump now lists ONLY them).
--   2. dump_manifest_handout_confirm and dump_manifest_link: on a [TEST] dump, insert only test and fixture clients'
--      visits (public.fn_is_non_customer kinds 'test','fixture', the same call as the list). Real dumps unchanged.
--
-- NOT CHANGED, on purpose (questions for Fred)
--   - A real dump still accepts a test client's visit through link (OLDER VISITS lists every truck's outstanding
--     visits, test clients included). 0 such holds exist; refusing it would show "that dump is no longer
--     available" in the app, which is misleading, so it waits for a decision.
--   - A second GO at the same site within 90 minutes reuses the first dump (IDEMPOTENCY_MINUTES in the edge
--     function), so a pickup completed between that dump's start + 30 min and the second GO leaves Missing (it
--     stays on the crib sheet). Never seen in history; it goes with the question about the 30 minutes.
--   - The 'outstanding' bucket has no age limit (the app shows rows over 14 days with an OFFICE tag by design).
--   - p_ttl_days stays unused. The county gate, columns, buckets, order and grants are unchanged.
--   - Holds are still not released when their visit is filed or its manifest is soft-deleted.
--
-- PROVEN BEFORE APPLY (rolled-back runs against Prod, 2026-10-12 13:10 to 13:20 ET; VERIFY 3c and 4b 14:10 to
--   14:40 ET)
--   * Probe, old bodies kept as pg_temp copies:
--     T1 dump 8754: old 5 'load' rows, new 0; the same 5 visits come back as 'outstanding' (none lost).
--     T2 all real GOs in dump_activity: 0 rows appear or vanish; every bucket change is load -> outstanding for a
--        pickup done more than 30 min after that dump began.
--     T3 a dump with no start (unknown id): identical.
--     T4 [TEST] dump 8750: old lists 5 real pickups, new 0; with 001-VIN made a test client, new lists only 6564;
--        real dump 8754 leaves the test client out under both bodies.
--     T5 confirm [real 6033, test 6564] on [TEST] 8750: new records 6564 only, old records both.
--     T6 a real confirm on real dump 8754 still records 6033.
--     T7 link on [TEST] 8750 (un-deleted inside the probe): new 6564 only, old both; link to real 8754 still works.
--     T8 a pickup held on another live dump comes back as load + confirmed + not on this dump, with held_by
--        (what dump-visit-create's loadCounts() names on its own line).
--     T9 a start moved 2 h earlier after GO (the Calendar-edit case): the load still ends 30 min after GO.
--   * This file with COMMIT swapped for ROLLBACK: every VERIFY block passes.
--   * 15 mutants, each run the same way, each stopped where named: a new line removed from list, confirm or link
--     (VERIFY 2, 4 mutants), the end kept in the text but made endless (VERIFY 3), late pickups dropped instead of
--     moved (VERIFY 3 control), the test rule kept in the text but bypassed (VERIFY 4), the confirm filter kept but
--     bypassed (VERIFY 4 control), an EXECUTE grant to authenticated (VERIFY 1), a moved live body (the md5 pin),
--     and the five the final review found passing every block: a real confirm or link that records nothing
--     (VERIFY 4b confirm, 4b link), a real dump that lists test clients (VERIFY 4b list), the end anchored on the
--     start only (VERIFY 2), every load emptied (VERIFY 3c).
--
-- WHAT VERIFY CHECKS (in the order it runs; every control is picked at run time and RAISES when it has nothing to
--   test with, because a NOTICE never reaches the Management API caller)
--   1 grants; 2 the new lines are in place; 3 no load row on a real GO of the last 30 days was completed more than
--   30 min after it began, and 3b the later pickups of the newest such dump are still listed, as outstanding;
--   3c the load rows equal a raw count of the same pickups on real dumps, on the next visit on the schedule (a GO
--   now) and on visits created long after their start; 4 a [TEST] dump lists and takes no real pickup; 4b a real
--   dump still records a real pickup through confirm and through link, and stops listing it once its client is made
--   a test client. 4 and 4b write only inside subtransactions that undo themselves (dump_manifest_handout, and one
--   non_customer_clients row with an explicit negative id, so its id sequence does not move: measured); they run
--   under lock_timeout 3 s.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no new table, no schema change to a table. dump_manifest_handout stays
--   audited (audit_dump_manifest_handout); these functions only narrow what they insert.
-- GRANTS: CREATE OR REPLACE keeps each function's ACL ({postgres=X/postgres,service_role=X/postgres}); VERIFY 1
--   re-reads it and asserts that anon and authenticated cannot execute. No new function.
-- LOCKS: functions only, no app-read view is touched; lock_timeout is set anyway. VERIFY takes about 4 s (3c calls
--   the list once per anchor).
-- ROLLBACK: re-apply the three bodies whose md5 the $pre$ block pins (list from 2026-10-07_1225_dump_load_window_
--   and_deleted_dump_holds; confirm from 2026-07-23_dump_shared_manifest_mark; link from
--   2026-09-07_1610_repoint_dump_consumers) and check, in the same transaction, that each md5 is back to its pin.
--   dump-visit-create does not depend on this file.
-- ============================================================================

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pre$
BEGIN
  IF md5(pg_get_functiondef('public.dump_manifest_handout_list(bigint,bigint,integer)'::regprocedure)) <> '7f154b086ee002dcc29e1a0f8dbccdb9' THEN
    RAISE EXCEPTION 'public.dump_manifest_handout_list(bigint,bigint,integer) moved since 2026-10-12 13:05 ET: copy the live body again';
  END IF;
  IF md5(pg_get_functiondef('public.dump_manifest_handout_confirm(bigint,bigint,bigint[])'::regprocedure)) <> '4783f29da9bd8d105b4654bdf2bdf401' THEN
    RAISE EXCEPTION 'public.dump_manifest_handout_confirm(bigint,bigint,bigint[]) moved since 2026-10-12 13:05 ET: copy the live body again';
  END IF;
  IF md5(pg_get_functiondef('public.dump_manifest_link(bigint,bigint,bigint[])'::regprocedure)) <> '4d9976c3398db883cbf3f9287930facd' THEN
    RAISE EXCEPTION 'public.dump_manifest_link(bigint,bigint,bigint[]) moved since 2026-10-12 13:05 ET: copy the live body again';
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
  v_dump_made timestamptz;
  v_load_end  timestamptz;
BEGIN
  -- which SITE is being filed? (365 Homestead / 76 Pompano) - drives the county gate
  -- and when it started, and whether it is a [TEST] dump (the DUMP app's test mode writes [TEST] in its notes)
  SELECT v.client_id, v.start_at, coalesce(v.notes, '') LIKE '%[TEST]%', v.created_at
    INTO v_dump_cli, v_dump_start, v_is_test, v_dump_made
  FROM public.visits v WHERE v.id = p_dump_visit_id;
  v_is_test := coalesce(v_is_test, false);
  -- 2026-10-12: the load ends 30 minutes after this dump began: its start, or when it was created if that is later
  -- (an app dump is created at GO, and a Visit Calendar edit can move its start afterwards). Without an end, a crib
  -- sheet or confirm on an older dump counted pickups done days later (dump 8754, Oct 8: 5 pickups of Oct 11-12).
  -- The 30 minutes cover the start that Jobber rounds down to the minute (8740: 39 s, 8754: 52 s) and a completion
  -- tapped just after GO. One fixed value for both sites; if a site ever needs another, make it a dump site column.
  -- A dump with no start (unknown id) keeps no end, as before.
  v_load_end := CASE WHEN v_dump_start IS NULL THEN 'infinity'::timestamptz
                     ELSE GREATEST(v_dump_start, v_dump_made) + interval '30 minutes' END;

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
         -- 2026-10-12: and not after this dump began (+ 30 min). Later pickups fall to 'outstanding', still listed.
         AND o.completed_at <= v_load_end
        THEN 'load' ELSE 'outstanding'
      END AS bucket
    FROM public.dump_outstanding_visits o
    -- COUNTY GATE: Homestead may only be handed Dade (or unknown-county) work; Pompano takes everything.
    -- v_dump_cli NULL (unknown dump) falls through to TRUE rather than hiding everything.
    WHERE (v_dump_cli IS NULL OR public.fn_dump_site_accepts(v_dump_cli, o.county))
      -- 2026-10-07: test and fixture clients (112-YA, ...) count only on a [TEST] dump.
      -- 2026-10-12: and a [TEST] dump lists ONLY them, so a test run never holds a real pickup (test dump 8737 held
      -- Michael's real 056-STM on Oct 5, which read as reported until test cleanup).
      AND public.fn_is_non_customer((SELECT x.client_id FROM public.visits x WHERE x.id = o.visit_id), ARRAY['test','fixture']) = v_is_test
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
$function$
;

CREATE OR REPLACE FUNCTION public.dump_manifest_handout_confirm(p_driver_id bigint, p_dump_visit_id bigint, p_visit_ids bigint[])
 RETURNS TABLE(visit_id bigint, client_code text, client_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_ids bigint[] := COALESCE(p_visit_ids, ARRAY[]::bigint[]);
  v_is_test boolean;
BEGIN
  -- 2026-10-12: a [TEST] dump takes only test and fixture clients' visits (dump_manifest_handout_list lists only those)
  SELECT coalesce(v.notes, '') LIKE '%[TEST]%' INTO v_is_test FROM public.visits v WHERE v.id = p_dump_visit_id;
  v_is_test := coalesce(v_is_test, false);

  -- remove THIS dump's own previously-recorded marks that are no longer ticked. Scoped to this dump's
  -- provenance, so a partial-load confirm can never delete a VIEW ADDRESSES or other-dump mark.
  DELETE FROM public.dump_manifest_handout h
   WHERE h.dump_visit_id = p_dump_visit_id
     AND NOT (h.visit_id = ANY (v_ids));

  -- upsert the ticked ones (only genuinely-outstanding visits); re-point provenance to this dump.
  INSERT INTO public.dump_manifest_handout (visit_id, dump_visit_id, driver_id, source, handed_at)
  SELECT o.visit_id, p_dump_visit_id, p_driver_id, 'dump', now()
  FROM public.dump_outstanding_visits o
  WHERE o.visit_id = ANY (v_ids)
    AND (NOT v_is_test OR public.fn_is_non_customer((SELECT x.client_id FROM public.visits x WHERE x.id = o.visit_id), ARRAY['test','fixture']))
  ON CONFLICT (visit_id) DO UPDATE
    SET dump_visit_id = p_dump_visit_id, driver_id = p_driver_id, source = 'dump', handed_at = now();

  RETURN QUERY
  SELECT o.visit_id, o.client_code, o.client_name
  FROM public.dump_outstanding_visits o
  JOIN public.dump_manifest_handout h ON h.visit_id = o.visit_id AND h.dump_visit_id = p_dump_visit_id
  ORDER BY o.completed_at DESC NULLS LAST;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.dump_manifest_link(p_driver_id bigint, p_dump_visit_id bigint, p_visit_ids bigint[])
 RETURNS TABLE(visit_id bigint, client_code text, client_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_ids bigint[] := COALESCE(p_visit_ids, ARRAY[]::bigint[]);
  v_is_test boolean;
BEGIN
  -- the target must be a live dump visit; otherwise link nothing
  IF NOT EXISTS (
    SELECT 1 FROM public.visits v
    WHERE v.id = p_dump_visit_id AND public.fn_is_non_customer(v.client_id, ARRAY['dump_site']) AND v.deleted_at IS NULL
  ) THEN
    RETURN;
  END IF;
  -- 2026-10-12: a [TEST] dump takes only test and fixture clients' visits (the edge function checks only the dump)
  SELECT coalesce(v.notes, '') LIKE '%[TEST]%' INTO v_is_test FROM public.visits v WHERE v.id = p_dump_visit_id;

  -- link each genuinely-outstanding ticked visit to this dump
  INSERT INTO public.dump_manifest_handout (visit_id, dump_visit_id, driver_id, source, handed_at)
  SELECT o.visit_id, p_dump_visit_id, p_driver_id, 'addresses', now()
  FROM public.dump_outstanding_visits o
  WHERE o.visit_id = ANY (v_ids)
    AND (NOT v_is_test OR public.fn_is_non_customer((SELECT x.client_id FROM public.visits x WHERE x.id = o.visit_id), ARRAY['test','fixture']))
  ON CONFLICT (visit_id) DO UPDATE
    SET dump_visit_id = p_dump_visit_id, driver_id = p_driver_id, source = 'addresses', handed_at = now();

  RETURN QUERY
  SELECT o.visit_id, o.client_code, o.client_name
  FROM public.dump_outstanding_visits o
  JOIN public.dump_manifest_handout h ON h.visit_id = o.visit_id AND h.dump_visit_id = p_dump_visit_id
  WHERE o.visit_id = ANY (v_ids)
  ORDER BY o.completed_at DESC NULLS LAST;
END;
$function$
;


DO $verify$
DECLARE
  f text;
  v_bad int;
  v_n int;
  v_ctl bigint;
  v_test_dump bigint;
  v_test_driver bigint;
  v_real_visit bigint;
  v_real_dump bigint;
  v_real_driver bigint;
  v_rows int;
BEGIN
  -- 1. grants: unchanged, and no app role can call them
  FOREACH f IN ARRAY ARRAY['public.dump_manifest_handout_list(bigint,bigint,integer)',
                           'public.dump_manifest_handout_confirm(bigint,bigint,bigint[])',
                           'public.dump_manifest_link(bigint,bigint,bigint[])'] LOOP
    IF (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = f::regprocedure) IS DISTINCT FROM '{postgres=X/postgres,service_role=X/postgres}' THEN
      RAISE EXCEPTION 'VERIFY 1: % ACL changed', f; END IF;
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'VERIFY 1: % is executable by an app role', f; END IF;
    IF NOT (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = f::regprocedure) THEN
      RAISE EXCEPTION 'VERIFY 1: % lost SECURITY DEFINER', f; END IF;
  END LOOP;

  -- 2. the new lines are in place (link has no live [TEST] dump to call it on, so this is its check; probe T7
  --    exercised it)
  IF position('AND o.completed_at <= v_load_end' in pg_get_functiondef('public.dump_manifest_handout_list(bigint,bigint,integer)'::regprocedure)) = 0
  -- the end is anchored on the later of start and creation (probe T9); real data rarely tells the two apart
  OR position('GREATEST(v_dump_start, v_dump_made) + interval ''30 minutes''' in pg_get_functiondef('public.dump_manifest_handout_list(bigint,bigint,integer)'::regprocedure)) = 0
  OR position('ARRAY[''test'',''fixture'']) = v_is_test' in pg_get_functiondef('public.dump_manifest_handout_list(bigint,bigint,integer)'::regprocedure)) = 0
  OR position('AND (NOT v_is_test OR public.fn_is_non_customer' in pg_get_functiondef('public.dump_manifest_handout_confirm(bigint,bigint,bigint[])'::regprocedure)) = 0
  OR position('AND (NOT v_is_test OR public.fn_is_non_customer' in pg_get_functiondef('public.dump_manifest_link(bigint,bigint,bigint[])'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'VERIFY 2: a new body is not in place'; END IF;

  -- 3. (b) on every real app dump of the last 30 days, no 'load' row was completed more than 30 min after it began
  SELECT count(*) INTO v_bad
  FROM (SELECT DISTINCT a.driver_id, a.dump_visit_id, GREATEST(v.start_at, v.created_at) AS began
          FROM public.dump_activity a JOIN public.visits v ON v.id = a.dump_visit_id
         WHERE a.action = 'create' AND a.at > now() - interval '30 days' AND coalesce(v.notes, '') NOT LIKE '%[TEST]%') g
  CROSS JOIN LATERAL public.dump_manifest_handout_list(g.driver_id, g.dump_visit_id) l
  WHERE l.bucket = 'load' AND l.completed_at > g.began + interval '30 minutes';
  IF v_bad <> 0 THEN RAISE EXCEPTION 'VERIFY 3: % load rows were completed more than 30 minutes after their dump began', v_bad; END IF;

  -- 3b. control, picked at run time (a fixed dump id goes vacuous as soon as its pickups are filed): the newest real
  --     dump whose driver has a pickup still waiting that he completed more than 30 min after that dump began. Each
  --     such pickup must still be LISTED for that dump, as 'outstanding'. The old body called them 'load'; a body
  --     that filtered them out would drop them. Either one fails here.
  SELECT d.id INTO v_ctl
  FROM public.visits d
  WHERE public.fn_is_non_customer(d.client_id, ARRAY['dump_site']) AND d.deleted_at IS NULL
    AND coalesce(d.notes, '') NOT LIKE '%[TEST]%' AND d.start_at IS NOT NULL AND d.assigned_driver_id IS NOT NULL
    AND d.start_at > now() - interval '90 days'
    AND EXISTS (SELECT 1 FROM public.dump_outstanding_visits o JOIN public.visits x ON x.id = o.visit_id
                 WHERE o.assigned_driver_id = d.assigned_driver_id
                   AND o.completed_at > GREATEST(d.start_at, d.created_at) + interval '30 minutes'
                   AND public.fn_dump_site_accepts(d.client_id, o.county)
                   AND NOT public.fn_is_non_customer(x.client_id, ARRAY['test','fixture']))
  ORDER BY d.start_at DESC, d.id DESC
  LIMIT 1;
  IF v_ctl IS NULL THEN
    RAISE EXCEPTION 'VERIFY 3 control: no real dump of the last 90 days has a later pickup of its driver still waiting, so nothing here shows that a load ends. Find out why before applying.';
  END IF;
  SELECT count(*), count(*) FILTER (WHERE l.visit_id IS NULL OR l.bucket <> 'outstanding') INTO v_n, v_bad
  FROM public.visits d
  JOIN public.dump_outstanding_visits o ON o.assigned_driver_id = d.assigned_driver_id
   AND o.completed_at > GREATEST(d.start_at, d.created_at) + interval '30 minutes'
  JOIN public.visits x ON x.id = o.visit_id
  LEFT JOIN LATERAL (SELECT l0.visit_id, l0.bucket FROM public.dump_manifest_handout_list(d.assigned_driver_id, d.id) l0
                      WHERE l0.visit_id = o.visit_id) l ON true
  WHERE d.id = v_ctl AND public.fn_dump_site_accepts(d.client_id, o.county)
    AND NOT public.fn_is_non_customer(x.client_id, ARRAY['test','fixture']);
  IF v_n = 0 OR v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3 control: % of % later pickups of dump % are not listed as outstanding', v_bad, v_n, v_ctl;
  END IF;

  -- 3c. the 'load' rows are exactly the raw count: the driver's own waiting pickups completed after his last earlier
  --     real dump and no later than 30 min after the anchor began (the later of start and creation), through the
  --     anchor's county gate, real clients only. One statement, so one snapshot. Anchors, picked at run time:
  --     every real live dump of the last 30 days with its own driver; the next visit on the schedule, standing in
  --     for a GO now (the list reads only the anchor's client, start, creation and notes, so any visit row serves);
  --     and up to 5 visits created more than 30 min after their start with a waiting pickup in between, where the
  --     later-of-the-two anchor matters. The last two go with every driver who has a real pickup waiting.
  --     Positive control: the anchors must hold at least one load row. Without it a body that empties every load
  --     passed every block (the review's RM5): real dumps alone often hold no waiting pickup.
  WITH wo AS MATERIALIZED (
    SELECT o.visit_id, o.assigned_driver_id, o.completed_at, o.county
      FROM public.dump_outstanding_visits o JOIN public.visits x ON x.id = o.visit_id
     WHERE NOT public.fn_is_non_customer(x.client_id, ARRAY['test','fixture'])),
  drv AS (SELECT DISTINCT assigned_driver_id AS driver_id FROM wo WHERE assigned_driver_id IS NOT NULL),
  anchors AS (
    SELECT d.assigned_driver_id AS driver_id, d.id, d.client_id, d.start_at, d.created_at FROM public.visits d
     WHERE public.fn_is_non_customer(d.client_id, ARRAY['dump_site']) AND d.deleted_at IS NULL
       AND coalesce(d.notes, '') NOT LIKE '%[TEST]%' AND d.start_at > now() - interval '30 days'
       AND d.assigned_driver_id IS NOT NULL
    UNION
    SELECT drv.driver_id, n.id, n.client_id, n.start_at, n.created_at FROM drv CROSS JOIN LATERAL (
      SELECT v.id, v.client_id, v.start_at, v.created_at FROM public.visits v
       WHERE v.deleted_at IS NULL AND v.start_at > now() AND coalesce(v.notes, '') NOT LIKE '%[TEST]%'
       ORDER BY v.start_at, v.id LIMIT 1) n
    UNION
    SELECT drv.driver_id, m.id, m.client_id, m.start_at, m.created_at FROM drv CROSS JOIN LATERAL (
      SELECT v.id, v.client_id, v.start_at, v.created_at FROM public.visits v
       WHERE v.deleted_at IS NULL AND v.start_at > now() - interval '30 days' AND coalesce(v.notes, '') NOT LIKE '%[TEST]%'
         AND v.created_at > v.start_at + interval '30 minutes'
         AND EXISTS (SELECT 1 FROM wo WHERE wo.assigned_driver_id = drv.driver_id
                      AND wo.completed_at > v.start_at + interval '30 minutes'
                      AND wo.completed_at <= v.created_at + interval '30 minutes')
       ORDER BY v.created_at DESC, v.id DESC LIMIT 5) m),
  win AS (
    SELECT a.*, GREATEST(a.start_at, a.created_at) + interval '30 minutes' AS load_end,
           coalesce((SELECT max(d.start_at) FROM public.visits d
                      WHERE d.assigned_driver_id = a.driver_id AND public.fn_is_non_customer(d.client_id, ARRAY['dump_site'])
                        AND d.deleted_at IS NULL AND d.id <> a.id AND d.start_at < a.start_at
                        AND coalesce(d.notes, '') NOT LIKE '%[TEST]%'), now() - interval '7 days') AS since
      FROM anchors a),
  cmp AS (
    SELECT w.id, w.driver_id,
           (SELECT count(*) FROM public.dump_manifest_handout_list(w.driver_id, w.id) l WHERE l.bucket = 'load') AS fn_load,
           (SELECT count(*) FROM wo
             WHERE wo.assigned_driver_id = w.driver_id AND wo.completed_at > w.since AND wo.completed_at <= w.load_end
               AND public.fn_dump_site_accepts(w.client_id, wo.county)) AS raw_load
      FROM win w)
  SELECT count(*) FILTER (WHERE fn_load <> raw_load), coalesce(sum(raw_load), 0), count(*),
         (array_agg(format('anchor %s driver %s: %s vs %s', id, driver_id, fn_load, raw_load)) FILTER (WHERE fn_load <> raw_load))[1]
    INTO v_bad, v_n, v_rows, f
    FROM cmp;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'VERIFY 3c: % of % anchors list a load that is not the raw count (first, function vs raw: %)', v_bad, v_rows, f;
  END IF;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'VERIFY 3c control: none of % anchors holds a load row (no driver has a real pickup waiting inside a load window), so nothing shows a real load is counted. It clears once a driver completes a pickup after his last dump; find out why before applying.', v_rows;
  END IF;

  -- 4. (c) a [TEST] dump lists no real pickup, and its confirm refuses one that is otherwise eligible
  SELECT v.id, v.assigned_driver_id INTO v_test_dump, v_test_driver FROM public.visits v
   WHERE public.fn_is_non_customer(v.client_id, ARRAY['dump_site']) AND coalesce(v.notes, '') LIKE '%[TEST]%'
   ORDER BY v.id DESC LIMIT 1;
  SELECT o.visit_id INTO v_real_visit FROM public.dump_outstanding_visits o JOIN public.visits x ON x.id = o.visit_id
   WHERE NOT o.on_sheet AND x.client_id IS NOT NULL AND NOT public.fn_is_non_customer(x.client_id, ARRAY['test','fixture'])
     AND public.fn_dump_site_accepts((SELECT client_id FROM public.visits WHERE id = v_test_dump), o.county)
   ORDER BY o.visit_id LIMIT 1;
  IF v_test_dump IS NULL OR v_real_visit IS NULL THEN
    RAISE EXCEPTION 'VERIFY 4 control: no [TEST] dump (%) or no real waiting pickup (%) to test with. Find out why before applying.', v_test_dump, v_real_visit;
  END IF;
  IF EXISTS (SELECT 1 FROM public.dump_manifest_handout_list(coalesce(v_test_driver, 0), v_test_dump) l JOIN public.visits x ON x.id = l.visit_id
             WHERE NOT public.fn_is_non_customer(x.client_id, ARRAY['test','fixture'])) THEN
    RAISE EXCEPTION 'VERIFY 4: [TEST] dump % still lists a real pickup', v_test_dump; END IF;
  -- mutation control, in a subtransaction that undoes itself: the old confirm recorded this real visit
  BEGIN
    SELECT count(*) INTO v_rows FROM public.dump_manifest_handout_confirm(coalesce(v_test_driver, 0), v_test_dump, ARRAY[v_real_visit]);
    IF v_rows <> 0 OR EXISTS (SELECT 1 FROM public.dump_manifest_handout WHERE visit_id = v_real_visit AND dump_visit_id = v_test_dump) THEN
      RAISE EXCEPTION 'VERIFY 4 control: [TEST] dump % accepted real visit %', v_test_dump, v_real_visit; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'verify-undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify-undo' THEN RAISE; END IF;
  END;

  -- 4b. a REAL dump still takes and lists real pickups, and lists no test client (bodies that refused every real
  --     confirm or link, or let a real dump list test clients, passed every block above: the review's RM1 to RM3).
  --     The real dump: the newest live one that started more than a day ago (no driver is working it now) and whose
  --     site takes that pickup's county. Each step runs in a subtransaction that undoes itself; the test-client
  --     mark uses an explicit negative id, so non_customer_clients_id_seq does not move.
  SELECT d.id, d.assigned_driver_id INTO v_real_dump, v_real_driver FROM public.visits d
   WHERE public.fn_is_non_customer(d.client_id, ARRAY['dump_site']) AND d.deleted_at IS NULL
     AND coalesce(d.notes, '') NOT LIKE '%[TEST]%' AND d.assigned_driver_id IS NOT NULL
     AND d.start_at < now() - interval '1 day' AND d.start_at > now() - interval '90 days'
     AND public.fn_dump_site_accepts(d.client_id, (SELECT o.county FROM public.dump_outstanding_visits o WHERE o.visit_id = v_real_visit))
   ORDER BY d.start_at DESC, d.id DESC LIMIT 1;
  IF v_real_dump IS NULL THEN
    RAISE EXCEPTION 'VERIFY 4b control: no real live dump of the last 90 days (older than a day) takes visit %. Find out why before applying.', v_real_visit;
  END IF;
  BEGIN
    SELECT count(*) INTO v_rows FROM public.dump_manifest_handout_confirm(v_real_driver, v_real_dump, ARRAY[v_real_visit]) c
     WHERE c.visit_id = v_real_visit;
    IF v_rows <> 1 OR NOT EXISTS (SELECT 1 FROM public.dump_manifest_handout WHERE visit_id = v_real_visit AND dump_visit_id = v_real_dump) THEN
      RAISE EXCEPTION 'VERIFY 4b confirm: real dump % did not record real visit %', v_real_dump, v_real_visit; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'verify-undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify-undo' THEN RAISE; END IF;
  END;
  BEGIN
    SELECT count(*) INTO v_rows FROM public.dump_manifest_link(v_real_driver, v_real_dump, ARRAY[v_real_visit]) k
     WHERE k.visit_id = v_real_visit;
    IF v_rows <> 1 OR NOT EXISTS (SELECT 1 FROM public.dump_manifest_handout WHERE visit_id = v_real_visit AND dump_visit_id = v_real_dump) THEN
      RAISE EXCEPTION 'VERIFY 4b link: real dump % did not record real visit %', v_real_dump, v_real_visit; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'verify-undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify-undo' THEN RAISE; END IF;
  END;
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.dump_manifest_handout_list(v_real_driver, v_real_dump) l WHERE l.visit_id = v_real_visit) THEN
      RAISE EXCEPTION 'VERIFY 4b control: real dump % does not list real waiting visit %', v_real_dump, v_real_visit; END IF;
    INSERT INTO public.non_customer_clients (id, client_id, client_code, kind, reason)
      SELECT -v_real_visit, x.client_id, c.client_code, 'test', '[TEST] VERIFY of 2026-10-12_1330, undone at once'
        FROM public.visits x JOIN public.clients c ON c.id = x.client_id WHERE x.id = v_real_visit;
    IF EXISTS (SELECT 1 FROM public.dump_manifest_handout_list(v_real_driver, v_real_dump) l WHERE l.visit_id = v_real_visit) THEN
      RAISE EXCEPTION 'VERIFY 4b list: real dump % lists visit % of a test client', v_real_dump, v_real_visit; END IF;
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'verify-undo';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'verify-undo' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'VERIFY passed (control dump %, test dump %, real dump %, real visit %, % load rows on the 3c anchors)', v_ctl, v_test_dump, v_real_dump, v_real_visit, v_n;
END $verify$;

COMMIT;
