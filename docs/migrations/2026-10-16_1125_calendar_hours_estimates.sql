-- ============================================================================
-- 2026-10-16_1125 Calendar "Hours worked": the database decides each visit's minutes
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-15: "check with the average duration of a visit of a client and if we have no duration in our db for
--   that kind of visit then put 1 hour as fallback, kinda like what we did for the average pumped grease." His picks on
--   the mockup (https://claude.ai/artifact/Xhj6ra7QpftNMUnb3HFtyd), 2026-10-16: "1. A 2. A 3. A 4. A":
--     1A  "that kind of visit" = same place, same service (Pumping, Cleaning, Labor, Unclogging...): the last 6
--         measured visits (fewer when there are fewer), 1 hour when there are none;
--     2A  a finished visit counts its measured time; the average only until its measured time arrives;
--     3A  past days are read live (no freeze);
--     4A  all-day visits count, with the average. Jobber's all-day placeholder (12 hours or more) is never a time.
--   Fixed on the mockup: every visit counts as today (dump offloads included), shown to 0.1h, the database decides
--   each visit's minutes and the app only adds them up (like ops.calendar_grease_estimates).
--
-- WHAT IS NEW
--   ops.calendar_hours_estimates(p_from date, p_to date): one row per visit the Calendar counts in its Hours worked
--   tile (live, client on file, dated in range, not cancelled, not skipped: the app's own set, measured equal on
--   2026-10-16 for Oct 1 to Nov 15), with minutes and basis:
--     measured  completed AND visits.duration_minutes between 1 and 719 (the measured time on site; 0 values, values
--               of 720 or more and Jobber's 1440 placeholder never count; none exist today);
--     average   otherwise, the rounded mean of the last 6 measured visits (completed, 1 to 719 minutes, not deleted)
--               at the same property and the same visits.service_type, dated strictly before the visit's date
--               (visit_date, not completed_at: 351 of 716 visits since Jul 1 were marked complete on a later day;
--               strictly before also keeps a same-day sibling out, e.g. two dumps at one site on one day), newest
--               first; readings = how many (1 to 6);
--     one_hour  60 minutes when there is no such visit, or the visit has no service type (an unknown service cannot
--               be "the same service").
--   A visit with no property uses the client's primary property, like fn_grease_estimates_live. Reads public.visits,
--   never ops.v_calendar_visit.duration_minutes (that column mixes the measured time with the scheduled window and
--   Jobber's 1440 placeholder). No table, no freeze, no cron (pick 3A).
--   SECURITY INVOKER (unlike the grease twin, whose helpers are postgres-only, this reads only what a signed-in staff
--   user already reads: public.visits, clients, properties; so RLS keeps applying), pinned search_path, EXECUTE for
--   authenticated + service_role only, p_to - p_from at most 45 days, same shape as calendar_grease_estimates.
--
-- MEASURED (read-only, 2026-10-16; scratchpad hw2/db, hw3/rv_*)
--   Completed visits: 955 samsara_stay, 397 no source (310 with a value, all with actual_arrival_at), 104
--   stop_at_completion, 3 reviewed_blank (no value), 2 dump_site_dwell, 1 gps_150m_cluster. No 0, no 720+, no 1440, no
--   duration on a visit that is not completed. Next 30 days (126 visits, 104 all-day): 62 average of 6, 61 average of 1
--   to 5, 3 one_hour, 0 measured. Backtest Oct 11 to 24 equals the mockup's method re-run today on every day.
--   PAST DAYS MOVE (the mockup said they would not; to be reported to Fred with the ship notice): over 2026 to Oct 15,
--   51 of 246 days change, 28 by 1h or more, +3.3h at most (Oct 9), +44h in all on 1,519h (2.9%), because 85 to 87
--   finished visits with no measured time (83 of them older than 10 days, so they will never be measured) and 17 past
--   visits still marked scheduled (10 dump offloads made from the Dump marker, which nothing completes) now count their
--   average or 1 hour instead of the scheduled length or 0.
--   EXPLAIN ANALYZE over 42 days: 17.8 ms; the history lookup uses idx_visits_property + idx_visits_type.
--
-- KNOWN LIMITS (accepted with picks 2A and 3A, reported to Fred)
--   - Past days also move whenever the time-on-site rules are re-run: on Oct 15 a re-run rewrote 657 measured times
--     and moved 170 past days (Jul 9 by -16h, a correction). The nightly check alone stays within 10 days.
--   - A visit marked complete in Jobber after the nightly measuring run waits a day more; one completed more than 10
--     days late may never be measured and keeps the average.
--   - 3 drive-bys (under 3 min) a person marked reviewed_blank count the average (2.75h in all): Fred's call.
--   - service_type 'Pumping' covers grease trap, grey water and lift station at one property (5 properties mix them).
--   - The hover says "the client's average"; the rule is per property (2 clients with future visits have 2 or more).
--   - VERIFY cannot exercise the property fallback or the deleted-history filter: no unmeasured visit without a
--     property has ever existed and 1 deleted measured visit exists in all history.
-- Rule 8: no table, no audit decision. The app change is the Visit Calendar's (Building Apps, same cycle).
-- ROLLBACK: docs/migrations/2026-10-16_rollback_calendar_hours_estimates.sql (revert the app first, or the tile
--   shows a dash).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';

CREATE FUNCTION ops.calendar_hours_estimates(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, minutes integer, basis text, readings integer)
 LANGUAGE plpgsql
 STABLE SECURITY INVOKER
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RAISE EXCEPTION 'calendar_hours_estimates: bad range % .. % (45 days at most)', p_from, p_to;
  END IF;
  RETURN QUERY
  SELECT v.id, v.visit_date,
         CASE WHEN m.measured THEN v.duration_minutes WHEN a.n > 0 THEN a.avg_min ELSE 60 END,
         CASE WHEN m.measured THEN 'measured' WHEN a.n > 0 THEN 'average' ELSE 'one_hour' END,
         CASE WHEN m.measured THEN 0 ELSE coalesce(a.n, 0) END
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id                       -- the view's inner join, so the sets are equal
    CROSS JOIN LATERAL (
      SELECT coalesce(v.visit_status = 'completed' AND v.duration_minutes BETWEEN 1 AND 719, false) AS measured,
             coalesce(v.property_id,
                      (SELECT p.id FROM public.properties p
                        WHERE p.client_id = v.client_id AND p.is_primary AND p.deleted_at IS NULL
                        ORDER BY p.id LIMIT 1)) AS prop
    ) m
    LEFT JOIN LATERAL (
      SELECT count(*)::integer AS n, round(avg(h.duration_minutes))::integer AS avg_min
        FROM (SELECT h.duration_minutes FROM public.visits h
               WHERE h.property_id = m.prop AND h.service_type = v.service_type
                 AND h.visit_date < v.visit_date AND h.deleted_at IS NULL
                 AND h.visit_status = 'completed' AND h.duration_minutes BETWEEN 1 AND 719
               ORDER BY h.visit_date DESC, h.id DESC
               LIMIT 6) h
    ) a ON NOT m.measured
   WHERE v.deleted_at IS NULL
     AND v.visit_date BETWEEN p_from AND p_to
     AND v.visit_status NOT IN ('cancelled', 'skipped');
END $function$;

COMMENT ON FUNCTION ops.calendar_hours_estimates(date, date) IS
'The Visit Calendar''s Hours worked tile (Fred, 2026-10-16, picks 1A 2A 3A 4A): one row per live, not cancelled, not skipped visit dated in range, with the minutes the tile adds up. measured = a completed visit''s measured time on site (visits.duration_minutes 1 to 719); average = the rounded mean of the last 6 measured visits at the same property and service type dated before it (readings = how many); one_hour = 60 when there are none or the visit has no service type. All-day visits count. Read live: no freeze. p_to - p_from at most 45 days. SECURITY INVOKER. Migration 2026-10-16_1125_calendar_hours_estimates.';

-- A new function is EXECUTE-able by PUBLIC, and Supabase's default privileges add anon, authenticated and
-- service_role by name: revoke from all of them by name, then grant only the two callers
REVOKE ALL ON FUNCTION ops.calendar_hours_estimates(date, date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION ops.calendar_hours_estimates(date, date) TO authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------
-- VERIFY (rolled back on any failure). Positive controls are chosen from today's data, never hardcoded ids.
-- ---------------------------------------------------------------------------------------------------------------
DO $v$
DECLARE
  a date := (now() AT TIME ZONE 'America/New_York')::date - 22;
  b date := (now() AT TIME ZONE 'America/New_York')::date + 22;
  s date; n int; n_fn int; tot int := 0; rows_cmp int := 0; t0 timestamptz; secs numeric;
BEGIN
  -- 1. privileges: authenticated and service_role may call it, anon may not; the ACL equals the grease twin's;
  --    it runs with the caller's rights
  IF has_function_privilege('anon', 'ops.calendar_hours_estimates(date,date)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'ops.calendar_hours_estimates(date,date)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'ops.calendar_hours_estimates(date,date)', 'EXECUTE')
     OR (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'ops.calendar_hours_estimates(date,date)'::regprocedure)
        IS DISTINCT FROM (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'ops.calendar_grease_estimates(date,date)'::regprocedure)
     OR (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = 'ops.calendar_hours_estimates(date,date)'::regprocedure)
  THEN RAISE EXCEPTION 'VERIFY 1: privileges are not what they should be'; END IF;

  -- 2. the range cap refuses p_to - p_from = 46 and accepts 45
  BEGIN
    PERFORM count(*) FROM ops.calendar_hours_estimates(a, a + 46);
    RAISE EXCEPTION 'VERIFY 2: a 46-day span was accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'VERIFY 2%' THEN RAISE; END IF;
  END;
  PERFORM count(*) FROM ops.calendar_hours_estimates(a, a + 45);

  -- 3. the row set is the app's visit set: ops.v_calendar_visit minus cancelled and skipped, every id once
  SELECT count(*) INTO n FROM (
    (SELECT visit_id FROM ops.calendar_hours_estimates(a, b)
     EXCEPT ALL SELECT cv.id FROM ops.v_calendar_visit cv
      WHERE cv.visit_date BETWEEN a AND b AND cv.visit_status NOT IN ('cancelled', 'skipped'))
    UNION ALL
    (SELECT cv.id FROM ops.v_calendar_visit cv
      WHERE cv.visit_date BETWEEN a AND b AND cv.visit_status NOT IN ('cancelled', 'skipped')
     EXCEPT ALL SELECT visit_id FROM ops.calendar_hours_estimates(a, b))) q;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 3: % visits differ between the function and the Calendar''s set', n; END IF;

  -- 4. an independent implementation (a window function instead of the lateral) gives the same minutes, basis and
  --    readings for every visit, over every 46-day slice from 2026-01-01 to 45 days ahead (the wide sweep is what
  --    catches a <= instead of <, or completed_at instead of visit_date: only 3 rows in all of 2026 tell them apart)
  s := DATE '2026-01-01';
  WHILE s <= b + 23 LOOP
    WITH base AS (
      SELECT v.id, v.visit_status, v.duration_minutes, v.service_type, v.visit_date,
             coalesce(v.property_id, (SELECT p.id FROM public.properties p WHERE p.client_id = v.client_id
                                       AND p.is_primary AND p.deleted_at IS NULL ORDER BY p.id LIMIT 1)) AS prop
        FROM public.visits v JOIN public.clients c ON c.id = v.client_id
       WHERE v.deleted_at IS NULL AND v.visit_date BETWEEN s AND s + 45 AND v.visit_status NOT IN ('cancelled', 'skipped')
    ), hist AS (
      SELECT h.id, h.property_id, h.service_type, h.visit_date, h.duration_minutes FROM public.visits h
       WHERE h.deleted_at IS NULL AND h.visit_status = 'completed' AND h.duration_minutes BETWEEN 1 AND 719
    ), pairs AS (
      SELECT bs.id, hs.duration_minutes AS d,
             row_number() OVER (PARTITION BY bs.id ORDER BY hs.visit_date DESC, hs.id DESC) AS rn
        FROM base bs JOIN hist hs ON hs.property_id = bs.prop AND hs.service_type = bs.service_type
                                  AND hs.visit_date < bs.visit_date
    ), agg AS (
      SELECT id, count(*)::int AS cnt, round(avg(d))::int AS mins FROM pairs WHERE rn <= 6 GROUP BY id
    ), ref AS (
      SELECT bs.id,
             CASE WHEN bs.visit_status = 'completed' AND bs.duration_minutes BETWEEN 1 AND 719 THEN bs.duration_minutes
                  WHEN ag.cnt > 0 THEN ag.mins ELSE 60 END AS minutes,
             CASE WHEN bs.visit_status = 'completed' AND bs.duration_minutes BETWEEN 1 AND 719 THEN 'measured'
                  WHEN ag.cnt > 0 THEN 'average' ELSE 'one_hour' END AS basis,
             CASE WHEN bs.visit_status = 'completed' AND bs.duration_minutes BETWEEN 1 AND 719 THEN 0
                  ELSE coalesce(ag.cnt, 0) END AS readings
        FROM base bs LEFT JOIN agg ag ON ag.id = bs.id
    ), fn AS (SELECT * FROM ops.calendar_hours_estimates(s, s + 45))
    SELECT count(*) FILTER (WHERE r.id IS NULL OR f.visit_id IS NULL OR f.minutes IS DISTINCT FROM r.minutes
                                  OR f.basis IS DISTINCT FROM r.basis OR f.readings IS DISTINCT FROM r.readings),
           count(*)
      INTO n, n_fn
      FROM ref r FULL JOIN fn f ON f.visit_id = r.id;
    IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 4: % visits of % .. % differ from the independent implementation', n, s, s + 45; END IF;
    rows_cmp := rows_cmp + n_fn;
    s := s + 46;
  END LOOP;
  IF rows_cmp < 1000 THEN RAISE EXCEPTION 'VERIFY 4: only % rows compared: the sweep proves little', rows_cmp; END IF;

  -- 5. shape: minutes never null and within 1 to 719; measured = its own measured time; one_hour = 60 with 0
  --    readings; average has 1 to 6 readings; every basis occurs (positive controls); all-day visits count (4A)
  SELECT count(*) INTO n FROM ops.calendar_hours_estimates(a, b) f JOIN public.visits v ON v.id = f.visit_id
   WHERE f.minutes IS NULL OR f.minutes NOT BETWEEN 1 AND 719
      OR f.basis NOT IN ('measured', 'average', 'one_hour')
      OR (f.basis = 'measured' AND (f.minutes IS DISTINCT FROM v.duration_minutes OR v.visit_status <> 'completed' OR f.readings <> 0))
      OR (f.basis = 'one_hour' AND (f.minutes <> 60 OR f.readings <> 0))
      OR (f.basis = 'average' AND f.readings NOT BETWEEN 1 AND 6);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 5: % rows break the shape', n; END IF;
  SELECT count(DISTINCT basis) INTO n FROM (
    SELECT basis FROM ops.calendar_hours_estimates(a - 45, a - 1)
    UNION ALL SELECT basis FROM ops.calendar_hours_estimates(a, b)
    UNION ALL SELECT basis FROM ops.calendar_hours_estimates(b + 1, b + 45)) q;
  IF n < 3 THEN RAISE EXCEPTION 'VERIFY 5: only % of the 3 bases occur over 135 days: the checks prove little', n; END IF;
  SELECT count(*) INTO n FROM ops.calendar_hours_estimates(a, b) f JOIN ops.v_calendar_visit cv ON cv.id = f.visit_id
   WHERE cv.is_all_day;
  IF n = 0 THEN RAISE EXCEPTION 'VERIFY 5: no all-day visit in the window: pick 4A is not exercised'; END IF;

  -- 6. as a signed-in app user it works and returns the same rows as the owner (the invoker reads what RLS allows);
  --    as anon it is refused; a 45-day read stays fast
  SELECT count(*), coalesce(sum(minutes), 0) INTO n, tot FROM ops.calendar_hours_estimates(a, a + 45);
  EXECUTE 'SET LOCAL ROLE authenticated';
  t0 := clock_timestamp();
  SELECT count(*) INTO n_fn FROM ops.calendar_hours_estimates(a, a + 45);
  secs := extract(epoch FROM clock_timestamp() - t0);
  IF (SELECT coalesce(sum(minutes), 0) FROM ops.calendar_hours_estimates(a, a + 45)) <> tot OR n_fn <> n THEN
    EXECUTE 'RESET ROLE';
    RAISE EXCEPTION 'VERIFY 6: authenticated sees % rows, the owner %', n_fn, n;
  END IF;
  EXECUTE 'RESET ROLE';
  IF n_fn = 0 THEN RAISE EXCEPTION 'VERIFY 6: no rows as authenticated'; END IF;
  IF secs > 2 THEN RAISE EXCEPTION 'VERIFY 6: a 45-day read took % s', secs; END IF;
  BEGIN
    EXECUTE 'SET LOCAL ROLE anon';
    PERFORM count(*) FROM ops.calendar_hours_estimates(a, b);
    EXECUTE 'RESET ROLE';
    RAISE EXCEPTION 'VERIFY 6: anon could call it';
  EXCEPTION WHEN insufficient_privilege THEN
    EXECUTE 'RESET ROLE';
  END;
  RAISE NOTICE 'VERIFY passed: % rows over 45 days in % s; % rows compared in the sweep', n_fn, round(secs, 3), rows_cmp;
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
