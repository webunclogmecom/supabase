-- ============================================================================
-- 2026-10-16_1506 Calendar Hours worked: a past visit with no measured time counts 1 hour
-- ============================================================================
-- THE ASK
--   Asked in plain words: some past visits have no time from Samsara (finished but never measured, or still marked
--   "scheduled" although the day is over, mostly dump offloads); should they count their usual length (the average)
--   or nothing? Fred, 2026-10-16: "count 1 hour then for them".
-- WHAT CHANGES
--   ops.calendar_hours_estimates: a visit dated before today (ET) with no measured time returns 60 minutes, basis
--   one_hour, readings 0, whatever its average. Today and later are unchanged (a finished visit counts its measured
--   time, any other visit the last-6 average at that place for that service, else 1 hour), measured visits are
--   unchanged, drive-bys still count nothing. Three lines spliced into the live body (md5-pinned).
--   ⚠ Yesterday's visits finished without a measured time read 1 hour from midnight until the nightly measuring run
--   (03:20 ET) gives them their time; a visit marked complete after that run waits a day more.
-- Rule 8: no table. ROLLBACK: re-run the CREATE OR REPLACE of 2026-10-16_1447 (the body without these lines).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('ops.calendar_hours_estimates(date,date)'::regprocedure)) IS DISTINCT FROM '348cbaf17337ed7bd544719c89be33d4' THEN
    RAISE EXCEPTION 'the function changed since this file was written: splice again';
  END IF;
END $g$;

CREATE TEMP TABLE hrs_before ON COMMIT DROP AS
  SELECT f.* FROM generate_series(DATE '2026-01-01', (now() AT TIME ZONE 'America/New_York')::date + 45, interval '46 days') s(d)
  CROSS JOIN LATERAL ops.calendar_hours_estimates(s.d::date, s.d::date + 45) f;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS
  SELECT p.proacl::text AS acl FROM pg_proc p WHERE p.oid = 'ops.calendar_hours_estimates(date,date)'::regprocedure;

CREATE OR REPLACE FUNCTION ops.calendar_hours_estimates(p_from date, p_to date)
 RETURNS TABLE(visit_id bigint, visit_date date, minutes integer, basis text, readings integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'ops', 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR (p_to - p_from) > 45 THEN
    RAISE EXCEPTION 'calendar_hours_estimates: bad range % .. % (45 days at most)', p_from, p_to;
  END IF;
  RETURN QUERY
  SELECT v.id, v.visit_date,
         CASE WHEN m.measured THEN v.duration_minutes WHEN m.past THEN 60 WHEN a.n > 0 THEN a.avg_min ELSE 60 END,
         CASE WHEN m.measured THEN 'measured' WHEN m.past THEN 'one_hour' WHEN a.n > 0 THEN 'average' ELSE 'one_hour' END,
         CASE WHEN m.measured OR m.past THEN 0 ELSE coalesce(a.n, 0) END
    FROM public.visits v
    JOIN public.clients c ON c.id = v.client_id                       -- the view's inner join, so the sets are equal
    CROSS JOIN LATERAL (
      SELECT coalesce(v.visit_status = 'completed' AND v.duration_minutes BETWEEN 1 AND 719, false) AS measured,
             -- 2026-10-16_1506: a visit dated before today (ET) with no measured time (finished but never
             -- measured, or still marked scheduled after its day) counts 1 hour (Fred: "count 1 hour then for them")
             v.visit_date < (now() AT TIME ZONE 'America/New_York')::date AS past,
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
    ) a ON NOT m.measured AND NOT m.past
   WHERE v.deleted_at IS NULL
     AND v.visit_date BETWEEN p_from AND p_to
     AND v.visit_status NOT IN ('cancelled', 'skipped')
     -- 2026-10-16_1447: a drive-by a person marked reviewed_blank (the truck only drove past, no service) is not
     -- counted at all (Fred: "if they didn't perform a service then they shouldn't count")
     AND NOT coalesce(v.visit_status = 'completed' AND v.time_on_site_source = 'reviewed_blank', false);
END $function$;

COMMENT ON FUNCTION ops.calendar_hours_estimates(date, date) IS
'The Visit Calendar''s Hours worked tile (Fred, 2026-10-16, picks 1A 2A 3A 4A): one row per live, not cancelled, not skipped visit dated in range, with the minutes the tile adds up; a completed drive-by a person marked reviewed_blank has no row (it counts nothing). measured = a completed visit''s measured time on site (visits.duration_minutes 1 to 719); a visit dated before today with no measured time = one_hour (60); otherwise average = the rounded mean of the last 6 measured visits at the same property and service type dated before it (readings = how many), or one_hour = 60 when there are none or the visit has no service type. All-day visits count. Read live: no freeze. p_to - p_from at most 45 days. SECURITY INVOKER. Migrations 2026-10-16_1125, 2026-10-16_1447 and 2026-10-16_1506.';

DO $v$
DECLARE n int; n_chg int; t date := (now() AT TIME ZONE 'America/New_York')::date;
BEGIN
  CREATE TEMP TABLE hrs_after ON COMMIT DROP AS
    SELECT f.* FROM generate_series(DATE '2026-01-01', (now() AT TIME ZONE 'America/New_York')::date + 45, interval '46 days') s(d)
    CROSS JOIN LATERAL ops.calendar_hours_estimates(s.d::date, s.d::date + 45) f;
  -- same visits, and every row is either unchanged or is a past unmeasured visit now at 60 / one_hour / 0
  SELECT count(*) INTO n FROM hrs_before b FULL JOIN hrs_after a ON a.visit_id = b.visit_id
   WHERE a.visit_id IS NULL OR b.visit_id IS NULL
      OR (b.visit_date >= t OR b.basis = 'measured')
         AND (a.minutes, a.basis, a.readings, a.visit_date) IS DISTINCT FROM (b.minutes, b.basis, b.readings, b.visit_date)
      OR (b.visit_date < t AND b.basis <> 'measured')
         AND (a.minutes, a.basis, a.readings, a.visit_date) IS DISTINCT FROM (60, 'one_hour', 0, b.visit_date);
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY: % rows differ from the rule', n; END IF;
  -- positive control: past visits that counted an average before now count 1 hour
  SELECT count(*) INTO n_chg FROM hrs_before b WHERE b.visit_date < t AND b.basis = 'average';
  IF n_chg = 0 THEN RAISE EXCEPTION 'VERIFY: no past average to change: the check proves nothing'; END IF;
  -- and a visit still to come keeps its average (positive control the other way)
  IF NOT EXISTS (SELECT 1 FROM hrs_after a WHERE a.visit_date >= t AND a.basis = 'average') THEN
    RAISE EXCEPTION 'VERIFY: no future average left: the check proves nothing';
  END IF;
  IF (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'ops.calendar_hours_estimates(date,date)'::regprocedure) IS DISTINCT FROM (SELECT acl FROM acl_before)
     OR (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = 'ops.calendar_hours_estimates(date,date)'::regprocedure)
  THEN RAISE EXCEPTION 'VERIFY: privileges or security mode moved'; END IF;
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM count(*) FROM ops.calendar_hours_estimates(t - 7, t + 7);
  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'VERIFY passed: % past averages now 1 hour', n_chg;
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
