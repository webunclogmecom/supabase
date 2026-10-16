-- ============================================================================
-- 2026-10-16_1447 Calendar Hours worked: a drive-by marked reviewed_blank counts nothing
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-16, on the 3 visits a person marked "only drove past" (time_on_site_source = 'reviewed_blank'): "I
--   mean they shouldn't even count, because if you do the average will go higher i think, i do not know how you're
--   calculating it, but if they didn't perform a service then they shouldn't count in the average."
-- WHAT CHANGES
--   ops.calendar_hours_estimates (2026-10-16_1125) returns no row for a completed visit marked reviewed_blank, so the
--   Calendar adds nothing for it and it is in no hover row. One line added to the live body (spliced, md5-pinned).
--   They were never in any average: the average only reads visits with a measured time (1 to 719 minutes), and a
--   reviewed_blank visit has none. Today: 8765 (Oct 9, 17 min average), 5990 (Jul 1, 88), 7277 (Jul 22, 60): -2.75h.
-- Rule 8: no table. ROLLBACK: re-run the CREATE OR REPLACE of 2026-10-16_1125 (its body without this line).
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('ops.calendar_hours_estimates(date,date)'::regprocedure)) IS DISTINCT FROM 'cea7584467c6bb602947ad90062fc6f8' THEN
    RAISE EXCEPTION 'the function changed since this file was written: splice again';
  END IF;
END $g$;

-- before: every row of 2026 so far and 45 days ahead, in 46-day slices
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
     AND v.visit_status NOT IN ('cancelled', 'skipped')
     -- 2026-10-16_1447: a drive-by a person marked reviewed_blank (the truck only drove past, no service) is not
     -- counted at all (Fred: "if they didn't perform a service then they shouldn't count")
     AND NOT coalesce(v.visit_status = 'completed' AND v.time_on_site_source = 'reviewed_blank', false);
END $function$;

COMMENT ON FUNCTION ops.calendar_hours_estimates(date, date) IS
'The Visit Calendar''s Hours worked tile (Fred, 2026-10-16, picks 1A 2A 3A 4A): one row per live, not cancelled, not skipped visit dated in range, with the minutes the tile adds up; a completed drive-by a person marked reviewed_blank has no row (it counts nothing). measured = a completed visit''s measured time on site (visits.duration_minutes 1 to 719); average = the rounded mean of the last 6 measured visits at the same property and service type dated before it (readings = how many); one_hour = 60 when there are none or the visit has no service type. All-day visits count. Read live: no freeze. p_to - p_from at most 45 days. SECURITY INVOKER. Migrations 2026-10-16_1125 and 2026-10-16_1447.';

DO $v$
DECLARE n int; n_rb int;
BEGIN
  -- the only change: the reviewed_blank drive-bys left, every other row identical (positive control: there are some)
  SELECT count(*) INTO n_rb FROM hrs_before b JOIN public.visits v ON v.id = b.visit_id
   WHERE v.visit_status = 'completed' AND v.time_on_site_source = 'reviewed_blank';
  IF n_rb = 0 THEN RAISE EXCEPTION 'VERIFY: no reviewed_blank visit was counted before: the check proves nothing'; END IF;
  CREATE TEMP TABLE hrs_after ON COMMIT DROP AS
    SELECT f.* FROM generate_series(DATE '2026-01-01', (now() AT TIME ZONE 'America/New_York')::date + 45, interval '46 days') s(d)
    CROSS JOIN LATERAL ops.calendar_hours_estimates(s.d::date, s.d::date + 45) f;
  SELECT count(*) INTO n FROM (
    (SELECT b.* FROM hrs_before b JOIN public.visits v ON v.id = b.visit_id
      WHERE NOT coalesce(v.visit_status = 'completed' AND v.time_on_site_source = 'reviewed_blank', false)
     EXCEPT ALL SELECT * FROM hrs_after)
    UNION ALL
    (SELECT * FROM hrs_after
     EXCEPT ALL SELECT b.* FROM hrs_before b JOIN public.visits v ON v.id = b.visit_id
      WHERE NOT coalesce(v.visit_status = 'completed' AND v.time_on_site_source = 'reviewed_blank', false))) q;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY: % rows changed besides the drive-bys', n; END IF;
  SELECT count(*) INTO n FROM hrs_after a JOIN public.visits v ON v.id = a.visit_id WHERE v.time_on_site_source = 'reviewed_blank';
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY: % drive-bys still counted', n; END IF;
  -- privileges and security mode unchanged; it still answers a signed-in user
  IF (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'ops.calendar_hours_estimates(date,date)'::regprocedure) IS DISTINCT FROM (SELECT acl FROM acl_before)
     OR (SELECT p.prosecdef FROM pg_proc p WHERE p.oid = 'ops.calendar_hours_estimates(date,date)'::regprocedure)
  THEN RAISE EXCEPTION 'VERIFY: privileges or security mode moved'; END IF;
  EXECUTE 'SET LOCAL ROLE authenticated';
  PERFORM count(*) FROM ops.calendar_hours_estimates((now() AT TIME ZONE 'America/New_York')::date - 7, (now() AT TIME ZONE 'America/New_York')::date + 7);
  EXECUTE 'RESET ROLE';
  RAISE NOTICE 'VERIFY passed: % drive-by rows removed, % rows unchanged', n_rb, (SELECT count(*) FROM hrs_after);
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
